<#
.FOR TESTING ONLY — run only on isolated/test systems or VMs. Do not run on production or personal user accounts without explicit consent.

.SYNOPSIS
Generates (and optionally cleans up) synthetic AppCompat Compatibility Assistant Store entries for testing detection / cleanup logic.

.DESCRIPTION
This streamlined version ONLY writes (or removes) binary values in:
    HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store
Each value name is a synthetic executable path under:
    %LOCALAPPDATA%\TestCleanupJunk\CompatStore\<RunId>\dummy_<n>.exe
The binary data is a single 0x53 byte (mirroring common artifacts). No files are created on disk; only registry entries are produced.

Use -Cleanup to remove ALL synthetic TestCleanupJunk CompatStore entries (across all prior runs). Use -DryRun to preview actions.

.EXAMPLE
# Dry run – show what 25 (default) entries would be added without modifying registry
PS> .\Make-JunkRegistry.ps1 -DryRun -Verbose

.EXAMPLE
# Create 100 AppCompat store entries; emit concise JSON pointer
PS> .\Make-JunkRegistry.ps1 -AppCompatCount 100 -AsJson -Confirm:$false

.EXAMPLE
# Remove all previously created synthetic TestCleanupJunk CompatStore entries
PS> .\Make-JunkRegistry.ps1 -Cleanup -Confirm:$false

.EXAMPLE
# Run embedded acceptance self-test
PS> .\Make-JunkRegistry.ps1 -RunAcceptanceTests -Confirm:$false

.NOTES
Author: Alexander Gates
Requires: Windows PowerShell 5.1+ or PowerShell 7+
Exit Codes:
 0  Success (including DryRun / cleanup)
 1  Parameter validation failure
 4  Unknown/unhandled error

.LINK
No external links – standalone script.
#
.PARAMETER GenerateAppCompatStoreEntries
Create registry values in the Compatibility Assistant Store key (HKCU) pointing at synthetic executable paths under %LOCALAPPDATA%\TestCleanupJunk\CompatStore\<RunId>. Enabled by default; specify -GenerateAppCompatStoreEntries:$false to disable all create behavior (useful only with -Cleanup or for testing validation).

.PARAMETER AppCompatCount
How many AppCompat store entries (dummy exe + registry value) to create when -GenerateAppCompatStoreEntries is specified. Default 25, max 500.
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [switch]$DryRun,
    [switch]$Cleanup,
    [switch]$AsJson,
    [switch]$RunAcceptanceTests,
    [bool]$GenerateAppCompatStoreEntries = $true,
    [ValidateRange(1,500)][int]$AppCompatCount = 25,
    [Parameter(DontShow)][switch]$NoExit
)

#region Globals & Initialization -------------------------------------------------
$script:StartTime = Get-Date
$script:ExitCode = 0
$script:RunId   = (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0,8))
# (Legacy variables from prior junk tree version removed)
$script:ReportDir = Join-Path -Path $env:USERPROFILE -ChildPath 'TestCleanupReports'
$script:LogDir    = Join-Path -Path $script:ReportDir -ChildPath 'Logs'
$null = New-Item -ItemType Directory -Path $script:ReportDir -ErrorAction SilentlyContinue | Out-Null
$null = New-Item -ItemType Directory -Path $script:LogDir -ErrorAction SilentlyContinue | Out-Null
$script:LogFile   = Join-Path -Path $script:LogDir -ChildPath ("Run_{0}.log" -f $script:RunId)
$script:CreatedItems = New-Object System.Collections.Generic.List[object]
$script:DeletedItems = New-Object System.Collections.Generic.List[object]
$script:Random = [Random]::new()
$script:AppCompatEntries = New-Object System.Collections.Generic.List[object]
$script:CompatStoreKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store'
$script:CompatBaseDir = Join-Path $env:LOCALAPPDATA ("TestCleanupJunk\\CompatStore\\$($script:RunId)")

#endregion Globals ----------------------------------------------------------------

#region Logging -------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [switch]$NoConsole
    )
    $ts = (Get-Date).ToString('o')
    $line = "[$ts] [$Level] $Message"
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }
    if (-not $NoConsole) {
        switch ($Level) {
            'INFO'  { Write-Host $Message -ForegroundColor Gray }
            'WARN'  { Write-Warning $Message }
            'ERROR' { Write-Error $Message }
        }
    }
}

function Initialize-Logging { Write-Log -Level INFO -Message "Log started for RunId=$($script:RunId); DryRun=$DryRun; Cleanup=$Cleanup" -NoConsole:$false }
Initialize-Logging
#endregion Logging ----------------------------------------------------------------

#region Utility & Validation ------------------------------------------------------
function Test-IsElevated { return ([bool]([Security.Principal.WindowsIdentity]::GetCurrent()).Groups -match 'S-1-5-32-544') }

function Test-ParametersValid {
    if (-not $GenerateAppCompatStoreEntries -and -not $Cleanup) {
        $script:ExitCode = 1; throw 'Invalid parameter combination.'
    }
}
#endregion Utility & Validation ---------------------------------------------------

# (Legacy junk registry helpers removed)

#region AppCompat Store Generation ----------------------------------------------
function New-AppCompatStoreEntries {
    if (-not $GenerateAppCompatStoreEntries) { return }
    Write-Log -Level INFO -Message "Generating $AppCompatCount AppCompat Compatibility Assistant Store entries (no files)" 
    if ($DryRun) {
        for ($i=0; $i -lt $AppCompatCount; $i++) {
            $fakePath = Join-Path $script:CompatBaseDir ("dummy_$i.exe")
            Write-Log -Level INFO -Message "[DryRun] Would add store value for path: $fakePath" 
            $script:AppCompatEntries.Add([pscustomobject]@{ Path=$fakePath; Data='53'; DryRun=$true }) | Out-Null
        }
        return
    }
    # Ensure store key only (no directory / file creation)
    for ($i=0; $i -lt $AppCompatCount; $i++) {
        $exeName = "dummy_$i.exe"
        $fullPath = Join-Path $script:CompatBaseDir $exeName
        $valueData = [byte[]](0x53)
        try {
            New-ItemProperty -Path $script:CompatStoreKey -Name $fullPath -Value $valueData -PropertyType Binary -Force | Out-Null
            $script:AppCompatEntries.Add([pscustomobject]@{ Path=$fullPath; Data='53'; DryRun=$false }) | Out-Null
            Write-Log -Level INFO -Message "Created AppCompat store value for synthetic path $fullPath"
        } catch {
            Write-Log -Level ERROR -Message "Failed AppCompat store value for $fullPath : $_"
        }
    }
}

function Remove-AppCompatStoreEntries {
    Write-Log -Level INFO -Message 'Cleaning ALL synthetic TestCleanupJunk AppCompat store entries.'
    if ($DryRun) { Write-Log -Level INFO -Message '[DryRun] Would remove matching AppCompat store values.'; return }
    if (Test-Path $script:CompatStoreKey) {
        $pattern = '*TestCleanupJunk\\CompatStore*'
        try {
            $props = (Get-ItemProperty -Path $script:CompatStoreKey)
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like $pattern) {
                    try {
                        Remove-ItemProperty -Path $script:CompatStoreKey -Name $p.Name -ErrorAction Stop
                        Write-Log -Level INFO -Message "Removed store value: $($p.Name)"
                    } catch { Write-Log -Level WARN -Message "Failed remove store value: $($p.Name) $_" }
                }
            }
        } catch { Write-Log -Level WARN -Message "Enumeration failed: $_" }
    }
}
#endregion AppCompat Store Generation -------------------------------------------
#endregion Registry Helpers -------------------------------------------------------

#region Reporting -----------------------------------------------------------------
function Write-RunReport {
    param(
        [string]$Mode # Create | Cleanup | DryRun
    )
    $duration = (Get-Date) - $script:StartTime
    $report = [pscustomobject]@{
        Mode                 = $Mode
        RunId                = $script:RunId
        CompatStoreKey       = $script:CompatStoreKey
        AppCompatCountRequested = if ($GenerateAppCompatStoreEntries -and $Mode -ne 'Cleanup') { $AppCompatCount } else { 0 }
        AppCompatEntries     = if ($Mode -eq 'Create' -or $Mode -eq 'DryRun') { $script:AppCompatEntries } else { @() }
        DurationSeconds      = [math]::Round($duration.TotalSeconds,2)
        RunParameters        = $PSBoundParameters
        TimestampUtc         = (Get-Date).ToUniversalTime().ToString('o')
        Username             = [Environment]::UserName
        PID                  = $PID
        DryRun               = $DryRun.IsPresent
    }
    $jsonPath = Join-Path $script:ReportDir ("Run_{0}.json" -f $script:RunId)
    try { $report | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8 } catch { Write-Log -Level WARN -Message "Failed to write report JSON: $jsonPath ($_ )" }
    Write-Log -Level INFO -Message "Report written: $jsonPath"
    Write-Host "Summary: Mode=$Mode AppCompatCreated=$($script:AppCompatEntries.Count) Duration=$([math]::Round($duration.TotalSeconds,2))s" -ForegroundColor Cyan
    Write-Host "Report: $jsonPath" -ForegroundColor Cyan
    if ($AsJson) { @{ Mode=$Mode; ReportPath=$jsonPath } | ConvertTo-Json -Depth 3 | Write-Output }
}
# End Reporting Section ----------------------------------------------------------

function Remove-AppCompatEntries {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param()
    if ($PSCmdlet.ShouldProcess($script:CompatStoreKey,'Remove synthetic AppCompat entries')) {
        Remove-AppCompatStoreEntries
    }
}
# End Cleanup Section ------------------------------------------------------------

function Invoke-CreateRun {
    Write-Log -Level INFO -Message "Beginning AppCompat entry creation: Count=$AppCompatCount"
    New-AppCompatStoreEntries
}
# End Core Creation Logic --------------------------------------------------------

#region Main Execution ------------------------------------------------------------
function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()
    try {
        Test-ParametersValid
        if ($Cleanup) {
            Remove-AppCompatEntries
            Write-RunReport -Mode 'Cleanup'
            return
        }
        if ($DryRun) { Write-Log -Level WARN -Message 'Running in DryRun mode: no registry changes will be made.' }
        Invoke-CreateRun
        Write-RunReport -Mode ($(if ($DryRun) { 'DryRun' } else { 'Create' }))
    } catch {
        if (-not $script:ExitCode) { $script:ExitCode = 4 }
        Write-Log -Level ERROR -Message "Unhandled error: $_"
        if (-not $DryRun) { Write-Error $_ }
    }
}
#endregion Main Execution ---------------------------------------------------------

#region Acceptance Tests ----------------------------------------------------------
function Invoke-AcceptanceTests {
    Write-Host 'Running acceptance tests (AppCompat-only)...' -ForegroundColor Yellow
    $testCount = 7
    $testStart = Get-Date
    $creationJsonRaw = & $PSCommandPath -AppCompatCount $testCount -AsJson -NoExit -Confirm:$false 2>$null | Out-String
    Start-Sleep -Milliseconds 200
    $creationObj = $null
    if (-not [string]::IsNullOrWhiteSpace($creationJsonRaw)) {
        $lastBrace = $creationJsonRaw.LastIndexOf('{')
        if ($lastBrace -ge 0) {
            $candidate = $creationJsonRaw.Substring($lastBrace)
            try { $creationObj = $candidate | ConvertFrom-Json -ErrorAction Stop } catch { }
        }
    }
    $latest = $null
    if ($creationObj -and $creationObj.ReportPath -and (Test-Path $creationObj.ReportPath)) {
        $latest = Get-Item -LiteralPath $creationObj.ReportPath
    } else {
        $latest = Get-ChildItem -Path $script:ReportDir -Filter 'Run_*.json' | Where-Object { $_.LastWriteTime -ge $testStart.AddSeconds(-2) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    $json = $null
    if ($latest) { $json = Get-Content -Raw -Path $latest.FullName | ConvertFrom-Json }
    $asserts = 0; $fails=0
    if ($json -and $json.AppCompatEntries.Count -eq $testCount) { $asserts++ } else { Write-Host 'FAIL: AppCompatEntries count mismatch or report not found' -ForegroundColor Red; $fails++ }
    # Cleanup
    & $PSCommandPath -Cleanup -NoExit -Confirm:$false -Verbose:$false | Out-Null
    # Verify removal (none of the created value names should remain)
    $remaining = @()
    if (Test-Path $script:CompatStoreKey -and $json) {
        $props = Get-ItemProperty -Path $script:CompatStoreKey
        foreach ($entry in $json.AppCompatEntries) { if ($props.PSObject.Properties.Name -contains $entry.Path) { $remaining += $entry.Path } }
    }
    if ($remaining.Count -eq 0) { $asserts++ } else { Write-Host 'FAIL: Some AppCompat entries still present after cleanup' -ForegroundColor Red; $fails++ }
    if ($fails -eq 0) { Write-Host "ACCEPTANCE TESTS PASS ($asserts assertions)" -ForegroundColor Green } else { Write-Host "ACCEPTANCE TESTS FAIL ($fails failures / $asserts assertions)" -ForegroundColor Red }
}
#endregion Acceptance Tests -------------------------------------------------------

if ($RunAcceptanceTests) {
    Invoke-AcceptanceTests
    return
}

Invoke-Main

# Ensure exit code is set (for external automation harnesses)
if (-not $script:ExitCode) { $script:ExitCode = 0 }
if (-not $NoExit) { exit $script:ExitCode } else { return $script:ExitCode }

<#
CHANGELOG
v2.0.0 - Removed legacy junk registry tree functionality; script now exclusively manages synthetic AppCompat Compatibility Assistant Store entries. Simplified parameters and acceptance tests.
#>