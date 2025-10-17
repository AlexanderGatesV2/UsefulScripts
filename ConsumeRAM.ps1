<#
.SYNOPSIS
  Temporarily consumes RAM to drive Available Memory at or below a target percentage.

.DESCRIPTION
  This script measures usable RAM and (optionally) allocates memory in fixed-size
  byte[] chunks until the system's *Available* RAM percentage is less than or equal
  to a specified target. It supports Windows 10/11 on PowerShell 5.1+ and 7+,
  including x64 and ARM64.

  Memory is measured via CIM/WMI (Win32_OperatingSystem) and cross-checked using the
  performance counter '\Memory\Available MBytes'. Results are reconciled to a single
  snapshot. Allocation is done with strong references stored in a List[byte[]] to
  prevent GC reclamation until release.

  Press Ctrl+C at any time: allocations are released cleanly and a final snapshot is printed.

.PARAMETER TargetAvailablePercent
  The target percentage of Available Physical Memory to achieve (e.g., 15).
  Allocation stops once Available% <= TargetAvailablePercent, or when MaxMB is reached.

.PARAMETER MaxMB
  Upper bound on the total MB to allocate. Default is 80% of total RAM.

.PARAMETER BlockSizeMB
  Allocation chunk size (MB) for each step. Default: 64 MB.

.PARAMETER HoldSeconds
  How long to keep the memory allocated *after* reaching the target. Default: 60 seconds.

.PARAMETER ReleaseGradually
  If set, memory is released in reverse chunk order with brief delays between frees.

.PARAMETER DryRun
  Show a computed plan (required MB/chunks) but do not allocate memory.

.PARAMETER AggressiveGC
  When releasing memory, perform a more aggressive garbage collection pass.

.PARAMETER WhatIf
  Shows what would happen if the command runs. (SupportsShouldProcess)

.PARAMETER Confirm
  Prompts for confirmation before running the command. (SupportsShouldProcess)

.EXAMPLE
  PS> .\Set-AvailableRAM.ps1 -TargetAvailablePercent 15 -HoldSeconds 60 -Verbose
  Drives Available RAM to ~≤ 15%, holds for 60 seconds, and releases memory.

.EXAMPLE
  PS> .\Set-AvailableRAM.ps1 -TargetAvailablePercent 20 -DryRun
  Prints the plan (how much would be allocated and in how many chunks) without allocating.

.EXAMPLE
  PS> .\Set-AvailableRAM.ps1 -TargetAvailablePercent 25 -BlockSizeMB 32 -MaxMB 2048 -ReleaseGradually
  Uses 32 MB chunks, will not exceed 2048 MB, releases memory gradually.

.NOTES
  - No admin rights or external modules required.
  - Console output only (respects -Verbose / -Debug), no persistent logging.
  - No CPU throttling is performed (only small optional delays during gradual release).
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [ValidateRange(0,100)]
    [int]$TargetAvailablePercent,

    [Parameter()]
    [ValidateRange(1, 1024*1024)]
    [int]$BlockSizeMB = 64,

    [Parameter()]
    [ValidateRange(0, 24*3600)]
    [int]$HoldSeconds = 60,

    [Parameter()]
    [switch]$ReleaseGradually,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$AggressiveGC,

    [Parameter()]
    [ValidateRange(1, 1024*1024)]
    [int]$MaxMB
)

#region Helpers & State ---------------------------------------------------------

$script:Allocations = $null
$script:CancelFlag  = $false
$script:CtrlCSub    = $null

function Get-RamSnapshot {
    <#
    .SYNOPSIS
      Returns a reconciled snapshot of current physical memory metrics.
    .OUTPUTS
      PSCustomObject with: TotalMB, AvailMB, UsedMB, AvailPercent, Source, Timestamp
    #>
    [CmdletBinding()]
    param()

    $wmi = Get-CimInstance -ClassName Win32_OperatingSystem -Verbose:$false
    $totalKB = [double]$wmi.TotalVisibleMemorySize
    $freeKB  = [double]$wmi.FreePhysicalMemory
    $wmiAvailMB  = [math]::Round($freeKB / 1024, 2)
    $wmiTotalMB  = [math]::Round($totalKB / 1024, 2)

    $counterAvailMB = $null
    try {
        $ctr = Get-Counter '\Memory\Available MBytes' -ErrorAction Stop
        if ($ctr.CounterSamples -and $ctr.CounterSamples.CookedValue -ne $null) {
            $counterAvailMB = [double]([math]::Round($ctr.CounterSamples[0].CookedValue, 2))
        }
    } catch { $counterAvailMB = $null }

    $availMB = if ($null -ne $counterAvailMB -and $counterAvailMB -ge 0 -and $counterAvailMB -le $wmiTotalMB*1.2) {
        $counterAvailMB
    } else { $wmiAvailMB }

    $usedMB = [math]::Max(0, $wmiTotalMB - $availMB)
    $pct    = if ($wmiTotalMB -gt 0) { [math]::Round(($availMB / $wmiTotalMB) * 100, 2) } else { 0 }

    [pscustomobject]@{
        TotalMB      = [int][math]::Round($wmiTotalMB)
        AvailMB      = [int][math]::Round($availMB)
        UsedMB       = [int][math]::Round($usedMB)
        AvailPercent = $pct
        Source       = if ($null -ne $counterAvailMB) { 'WMI+Counter' } else { 'WMI' }
        Timestamp    = (Get-Date)
    }
}

function Start-RamStress {
    <#
    .SYNOPSIS
      Allocates memory in chunks until Available% <= target or MaxMB reached.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0,100)]
        [int]$TargetPercent,
        [Parameter(Mandatory)]
        [ValidateRange(1, 1024*1024)]
        [int]$BlockSizeMB,
        [Parameter(Mandatory)]
        [ValidateRange(1, 1024*1024)]
        [int]$MaxMB
    )

    $snap0 = Get-RamSnapshot
    Write-Verbose ("Start snapshot => Total: {0:N0} MB, Avail: {1:N0} MB ({2}%), Used: {3:N0} MB, Source: {4}" -f `
        $snap0.TotalMB, $snap0.AvailMB, $snap0.AvailPercent, $snap0.UsedMB, $snap0.Source)

    if ($snap0.AvailPercent -le $TargetPercent) {
        Write-Verbose "Target already met. No allocation needed."
        return @{
            StartSnapshot = $snap0; FinalSnapshot = $snap0; AllocatedMB = 0; Chunks = 0
            HitTarget = $true; HitMax = $false; Duration = [timespan]::Zero
        }
    }

    $targetAvailMB = [math]::Floor($snap0.TotalMB * ($TargetPercent / 100.0))
    $estNeedMB     = [math]::Max(0, $snap0.AvailMB - $targetAvailMB)
    $planMB        = [math]::Min($estNeedMB, $MaxMB)
    $planChunks    = [int][math]::Ceiling([double]$planMB / $BlockSizeMB)

    Write-Verbose ("Plan => Need ~{0:N0} MB to hit target (initial est), cap {1:N0} MB ⇒ {2} chunk(s) of {3} MB" -f `
        $estNeedMB, $MaxMB, $planChunks, $BlockSizeMB)

    if ($PSCmdlet.ShouldProcess(("Allocate in {0} MB chunks until ≤ {1}% or MaxMB" -f $BlockSizeMB, $TargetPercent))) {
        $script:Allocations = New-Object 'System.Collections.Generic.List[byte[]]'
        $allocatedMB = 0; $chunks = 0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            while (-not $script:CancelFlag) {
                $snap = Get-RamSnapshot
                if ($snap.AvailPercent -le $TargetPercent) { Write-Verbose "Target reached."; break }
                if ($allocatedMB -ge $MaxMB) { Write-Verbose "MaxMB reached."; break }

                $remainingMB = $MaxMB - $allocatedMB
                $thisMB      = [int]([math]::Min($BlockSizeMB, $remainingMB))
                if ($thisMB -le 0) { break }

                $thisBytes = [int64]$thisMB * 1MB
                Write-Verbose ("Allocating chunk {0}: {1} MB" -f ($chunks + 1), $thisMB)

                $arr = New-Object byte[] $thisBytes
                for ($p = 0; $p -lt $arr.Length; $p += 4096) { $arr[$p] = 1 } # touch pages
                $script:Allocations.Add($arr) | Out-Null

                $allocatedMB += $thisMB
                $chunks++
            }
        } catch {
            Write-Warning "Allocation error: $($_.Exception.Message)"
        } finally { $sw.Stop() }

        $final     = Get-RamSnapshot
        $hitTarget = ($final.AvailPercent -le $TargetPercent)
        $hitMax    = ($allocatedMB -ge $MaxMB) -and -not $hitTarget

        return @{
            StartSnapshot = $snap0; FinalSnapshot = $final
            AllocatedMB = $allocatedMB; Chunks = $chunks
            HitTarget = $hitTarget; HitMax = $hitMax
            Duration = $sw.Elapsed
        }
    }
}

function Stop-RamStress {
    <#
    .SYNOPSIS
      Releases allocated memory.
    #>
    [CmdletBinding()]
    param(
        [switch]$ReleaseGradually,
        [switch]$AggressiveGC
    )

    if ($null -eq $script:Allocations -or $script:Allocations.Count -eq 0) { return }

    $totalBytes = (($script:Allocations | ForEach-Object { $_.Length }) | Measure-Object -Sum).Sum
    $totalMB    = [int][math]::Round($totalBytes / 1MB, 0)

    Write-Verbose ("Releasing {0} chunk(s) totaling ~{1:N0} MB" -f $script:Allocations.Count, $totalMB)

    if ($ReleaseGradually) {
        for ($i = $script:Allocations.Count - 1; $i -ge 0; $i--) {
            $script:Allocations[$i] = $null
            Start-Sleep -Milliseconds 25
        }
        $script:Allocations.Clear()
    } else {
        for ($i = 0; $i -lt $script:Allocations.Count; $i++) { $script:Allocations[$i] = $null }
        $script:Allocations.Clear()
    }

    if ($AggressiveGC) {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
    }
}

function Show-SummaryRow {
    param(
        [string]$Phase,
        $Snap,
        [int]$AllocatedMB = 0,
        [int]$Chunks = 0,
        [TimeSpan]$Elapsed = [TimeSpan]::Zero
    )
    [pscustomobject]@{
        Phase        = $Phase
        TotalMB      = $Snap.TotalMB
        AvailMB      = $Snap.AvailMB
        AvailPercent = $Snap.AvailPercent
        AllocatedMB  = $AllocatedMB
        Chunks       = $Chunks
        Elapsed      = if ($Elapsed -and $Elapsed.Ticks -gt 0) { $Elapsed.ToString('hh\:mm\:ss\.fff') } else { '' }
    }
}

#endregion Helpers & State ------------------------------------------------------

#region Main Control Flow -------------------------------------------------------

$initialSnap = Get-RamSnapshot
if (-not $PSBoundParameters.ContainsKey('MaxMB')) {
    $MaxMB = [int]([math]::Floor($initialSnap.TotalMB * 0.80))
}

$preRows = New-Object System.Collections.Generic.List[object]
$preRows.Add( (Show-SummaryRow -Phase 'Before' -Snap $initialSnap) ) | Out-Null

if ($DryRun) {
    $targetAvailMB = [math]::Floor($initialSnap.TotalMB * ($TargetAvailablePercent / 100.0))
    $needMB        = [math]::Max(0, $initialSnap.AvailMB - $targetAvailMB)
    $planMB        = [math]::Min($needMB, $MaxMB)
    $planChunks    = if ($BlockSizeMB -gt 0) { [int][math]::Ceiling( [double]$planMB / $BlockSizeMB ) } else { 0 }

    Write-Verbose ("[DryRun] Total {0:N0} MB, Avail {1:N0} MB ({2}%), Target ≤ {3}% ⇒ Need ~{4:N0} MB" -f `
        $initialSnap.TotalMB, $initialSnap.AvailMB, $initialSnap.AvailPercent, $TargetAvailablePercent, $needMB)
    Write-Verbose ("[DryRun] Plan: Allocate up to {0:N0} MB (MaxMB={1:N0}) in {2} chunk(s) of {3} MB" -f `
        $planMB, $MaxMB, $planChunks, $BlockSizeMB)

    $preRows.Add([pscustomobject]@{
        Phase='Plan'; TotalMB=$initialSnap.TotalMB; AvailMB=$initialSnap.AvailMB
        AvailPercent=$initialSnap.AvailPercent; AllocatedMB=$planMB; Chunks=$planChunks; Elapsed=''
    }) | Out-Null

    $preRows | Format-Table -AutoSize | Out-String | Write-Host

    return [pscustomobject]@{
        Phase='Plan'; TargetAvailablePercent=$TargetAvailablePercent
        TotalMB=$initialSnap.TotalMB; CurrentAvailMB=$initialSnap.AvailMB
        CurrentAvailPercent=$initialSnap.AvailPercent
        EstimatedAllocateMB=$planMB; EstimatedChunks=$planChunks
        BlockSizeMB=$BlockSizeMB; MaxMB=$MaxMB
        CanReachTarget = ($planMB -ge $needMB)
        Timestamp=(Get-Date)
    }
}

if ($initialSnap.AvailPercent -le $TargetAvailablePercent) {
    $preRows.Add( (Show-SummaryRow -Phase 'NoOp' -Snap $initialSnap -AllocatedMB 0 -Chunks 0) ) | Out-Null
    $preRows | Format-Table -AutoSize | Out-String | Write-Host
    return [pscustomobject]@{
        Phase='NoOp'; TargetAvailablePercent=$TargetAvailablePercent
        TotalMB=$initialSnap.TotalMB; FinalAvailMB=$initialSnap.AvailMB
        FinalAvailPercent=$initialSnap.AvailPercent
        AllocatedMB=0; Chunks=0; HitTarget=$true; HitMax=$false; DurationSeconds=0
        Timestamp=(Get-Date)
    }
}

# Ctrl+C handler
try {
    $script:CancelFlag = $false
    if ($null -ne $script:CtrlCSub -and $script:CtrlCSub.SourceIdentifier) {
        Unregister-Event -SourceIdentifier $script:CtrlCSub.SourceIdentifier -ErrorAction SilentlyContinue
        $script:CtrlCSub = $null
    }
    $script:CtrlCSub = Register-ObjectEvent -InputObject ([Console]) -EventName 'CancelKeyPress' -Action {
        $script:CancelFlag = $true
        Write-Verbose "Ctrl+C detected: initiating cleanup..." -Verbose
    }
} catch { Write-Debug "Unable to register Ctrl+C handler: $($_.Exception.Message)" }

# Allocation
$allocResult = Start-RamStress `
    -TargetPercent $TargetAvailablePercent `
    -BlockSizeMB $BlockSizeMB `
    -MaxMB $MaxMB `
    -Verbose:($PSBoundParameters.ContainsKey('Verbose')) `
    -WhatIf:$WhatIfPreference

$allocRow = Show-SummaryRow -Phase 'AfterAlloc' -Snap $allocResult.FinalSnapshot `
    -AllocatedMB $allocResult.AllocatedMB -Chunks $allocResult.Chunks -Elapsed $allocResult.Duration
$preRows.Add($allocRow) | Out-Null
$preRows | Format-Table -AutoSize | Out-String | Write-Host

if (-not $allocResult.HitTarget -and $allocResult.HitMax) {
    Write-Host ("Note: MaxMB cap ({0} MB) reached before meeting target ≤ {1}% (final Available: {2}%)." -f `
        $MaxMB, $TargetAvailablePercent, $allocResult.FinalSnapshot.AvailPercent)
    Stop-RamStress -ReleaseGradually:$ReleaseGradually -AggressiveGC:$AggressiveGC `
        -Verbose:($PSBoundParameters.ContainsKey('Verbose'))
    $finalSnap = Get-RamSnapshot
    (Show-SummaryRow -Phase 'AfterRelease' -Snap $finalSnap) | Format-Table -AutoSize | Out-String | Write-Host

    if ($script:CtrlCSub -and $script:CtrlCSub.SourceIdentifier) {
        Unregister-Event -SourceIdentifier $script:CtrlCSub.SourceIdentifier -ErrorAction SilentlyContinue
    }
    $script:CtrlCSub = $null

    return [pscustomobject]@{
        Phase='Completed'; TargetAvailablePercent=$TargetAvailablePercent
        TotalMB=$finalSnap.TotalMB; FinalAvailMB=$finalSnap.AvailMB
        FinalAvailPercent=$finalSnap.AvailPercent
        AllocatedMB=$allocResult.AllocatedMB; Chunks=$allocResult.Chunks
        HitTarget=$false; HitMax=$true; DurationSeconds=[int]$allocResult.Duration.TotalSeconds
        Timestamp=(Get-Date)
    }
}

# Hold
if (-not $script:CancelFlag -and $allocResult.AllocatedMB -gt 0 -and $HoldSeconds -gt 0) {
    Write-Verbose ("Holding allocations for {0} seconds. Press Ctrl+C to release early..." -f $HoldSeconds)
    $holdSw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $script:CancelFlag -and $holdSw.Elapsed.TotalSeconds -lt $HoldSeconds) {
        Start-Sleep -Milliseconds 200
    }
    $holdSw.Stop()
    if ($script:CancelFlag) { Write-Verbose "Hold interrupted by Ctrl+C." } else { Write-Verbose "Hold complete." }
}

# Release
Stop-RamStress -ReleaseGradually:$ReleaseGradually -AggressiveGC:$AggressiveGC `
    -Verbose:($PSBoundParameters.ContainsKey('Verbose'))
$finalSnap2 = Get-RamSnapshot

$summary = @()
$summary += Show-SummaryRow -Phase 'Before'      -Snap $allocResult.StartSnapshot
$summary += Show-SummaryRow -Phase 'AfterAlloc'  -Snap $allocResult.FinalSnapshot -AllocatedMB $allocResult.AllocatedMB -Chunks $allocResult.Chunks -Elapsed $allocResult.Duration
$summary += Show-SummaryRow -Phase 'AfterRelease'-Snap $finalSnap2
$summary | Format-Table -AutoSize | Out-String | Write-Host

$result = [pscustomobject]@{
    Phase='Completed'; TargetAvailablePercent=$TargetAvailablePercent
    TotalMB=$finalSnap2.TotalMB; FinalAvailMB=$finalSnap2.AvailMB
    FinalAvailPercent=$finalSnap2.AvailPercent
    AllocatedMB=$allocResult.AllocatedMB; Chunks=$allocResult.Chunks
    HitTarget=$allocResult.HitTarget; HitMax=$allocResult.HitMax
    DurationSeconds=[int]$allocResult.Duration.TotalSeconds
    Timestamp=(Get-Date)
}

if ($script:CtrlCSub -and $script:CtrlCSub.SourceIdentifier) {
    Unregister-Event -SourceIdentifier $script:CtrlCSub.SourceIdentifier -ErrorAction SilentlyContinue
}
$script:CtrlCSub = $null

return $result

#endregion Main Control Flow ---------------------------------------------------
