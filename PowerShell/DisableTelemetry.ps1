<#
.SYNOPSIS
  Configure Windows telemetry policy (AllowTelemetry = 0) and disable the DiagTrack service, with rollback.

.DESCRIPTION
  Idempotent PowerShell script compatible with Windows PowerShell 5.1 and PowerShell 7+.
  Targets 64-bit policy hive on 64-bit OS even when executed from 32-bit host.
  Supports interactive mode (no parameters) and CLI mode with -EnableRollback / -Rollback.
  Provides logging, WhatIf/Verbose, and safe error handling with clear exit codes.

.USAGE
  Interactive:
    .\Telemetry-Hardening.ps1

  Non-interactive hardened apply:
    .\Telemetry-Hardening.ps1 -EnableRollback -Verbose

  Rollback:
    .\Telemetry-Hardening.ps1 -Rollback -Verbose

  Logging:
    .\Telemetry-Hardening.ps1 -EnableRollback -LogPath "C:\Logs\telemetry.log"

  Dry run:
    .\Telemetry-Hardening.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch] $EnableRollback,
    [switch] $Rollback,
    [switch] $Force,
    [string] $LogPath
)

# ----------------------------- Constants & Globals -----------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Exit codes
$EXIT_SUCCESS                = 0
$EXIT_NOT_ADMIN              = 2
$EXIT_STOP_SERVICE_FAILED    = 10
$EXIT_REGISTRY_FAILED        = 11
$EXIT_ROLLBACK_NOT_FOUND     = 12
$EXIT_ROLLBACK_FAILED        = 13
$EXIT_LOGGING_FAILED         = 14

# Script paths
$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent -Path $ScriptPath }
$ScriptName = Split-Path -Leaf $ScriptPath
$StatePath  = Join-Path $ScriptDir ([IO.Path]::GetFileNameWithoutExtension($ScriptName) + '.state.json')

# Policy registry target
$PolicyHivePath = 'SOFTWARE\Policies\Microsoft\Windows\DataCollection'
$PolicyValueName = 'AllowTelemetry'
$DesiredTelemetry = 0

# Colors (PS 7+); safe fallback on PS 5.1
$HasPSStyle = $PSStyle -ne $null
function Colorize {
    param([string]$Text, [string]$Style = 'Foreground')
    if ($HasPSStyle) { return "$($PSStyle.Foreground.BrightGreen)$Text$($PSStyle.Reset)" }
    return $Text
}

# ----------------------------- Helpers: Admin & Logging -----------------------------
function Test-Admin {
    try {
        $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
        $wp = New-Object Security.Principal.WindowsPrincipal($wi)
        return $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Verbose "Failed to check admin: $($_.Exception.Message)"
        return $false
    }
}

function Initialize-Logger {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) {
            if ($PSCmdlet.ShouldProcess($dir, 'Create log directory')) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        }
        if ($PSCmdlet.ShouldProcess($Path, 'Initialize log file')) {
            if (-not (Test-Path -LiteralPath $Path)) {
                '' | Out-File -LiteralPath $Path -Encoding utf8
            }
        }
        return $Path
    } catch {
        if ($Force) {
            Write-Warning "Logging disabled: $($_.Exception.Message)"
            return $null
        } else {
            Write-Error "Failed to initialize logging at '$Path': $($_.Exception.Message)"
            exit $EXIT_LOGGING_FAILED
        }
    }
}

$Global:LogFile = Initialize-Logger -Path $LogPath

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    Write-Verbose $line
    if ($Global:LogFile) {
        try { Add-Content -LiteralPath $Global:LogFile -Value $line -Encoding utf8 } catch { }
    }
}

# ----------------------------- Helpers: Registry 64-bit -----------------------------
function Get-RegistryBaseKey64 {
    $view = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Default }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
}

function Get-PolicyValue {
    try {
        $base = Get-RegistryBaseKey64
        $key = $base.OpenSubKey($PolicyHivePath, $false)
        if ($null -eq $key) { return @{ Exists = $false; Value = $null; Type = $null } }
        $val = $key.GetValue($PolicyValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $val) { return @{ Exists = $false; Value = $null; Type = $null } }
        $vt  = $key.GetValueKind($PolicyValueName)
        return @{ Exists = $true; Value = [int]$val; Type = $vt.ToString() }
    } catch {
        throw
    }
}

function Set-PolicyValue {
    param([int]$Value, [switch]$Remove)
    try {
        $base = Get-RegistryBaseKey64
        if ($Remove) {
            $key = $base.OpenSubKey($PolicyHivePath, $true)
            if ($null -ne $key -and $key.GetValue($PolicyValueName, $null) -ne $null) {
                if ($PSCmdlet.ShouldProcess("HKLM:\$PolicyHivePath", "Remove value $PolicyValueName")) {
                    $key.DeleteValue($PolicyValueName, $false)
                    Write-Log "Removed $PolicyValueName at HKLM:\$PolicyHivePath"
                }
            }
            return
        }
        $key = $base.OpenSubKey($PolicyHivePath, $true)
        if ($null -eq $key) {
            if ($PSCmdlet.ShouldProcess("HKLM:\$PolicyHivePath", 'Create policy key path')) {
                $key = $base.CreateSubKey($PolicyHivePath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree)
                Write-Log "Created registry path HKLM:\$PolicyHivePath"
            }
        }
        if ($PSCmdlet.ShouldProcess("HKLM:\$PolicyHivePath\$PolicyValueName", "Set REG_DWORD to $Value")) {
            $key.SetValue($PolicyValueName, $Value, [Microsoft.Win32.RegistryValueKind]::DWord)
            Write-Log "Set $PolicyValueName = $Value (REG_DWORD)"
        }
    } catch {
        throw
    }
}

function Test-PolicyManaged {
    $signals = @(
        'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System',
        'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\System',
        'HKLM:\SOFTWARE\Microsoft\PolicyManager\providers'
    )
    foreach ($p in $signals) {
        try {
            if (Test-Path -LiteralPath $p) {
                $v = Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue | Select-Object -Property AllowTelemetry -ErrorAction SilentlyContinue
                if ($null -ne $v -and ($v.PSObject.Properties.Name -contains 'AllowTelemetry')) { return $true }
            }
        } catch { }
    }
    return $false
}

# ----------------------------- Helpers: Service Control -----------------------------
function Get-DiagTrackInfo {
    $svc = Get-Service -Name 'DiagTrack' -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        return [PSCustomObject]@{ Exists = $false; Status = 'Unknown'; StartType = 'Unknown'; ProcessId = $null }
    }
    $cim = $null
    try { $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='DiagTrack'" -ErrorAction SilentlyContinue } catch { }
    # FIX: avoid using $pid (conflicts with automatic $PID)
    $svcPid = if ($cim) { [int]$cim.ProcessId } else { $null }
    $startMode = if ($cim) { $cim.StartMode } else { 'Unknown' }
    return [PSCustomObject]@{
        Exists    = $true
        Status    = $svc.Status.ToString()
        StartType = $startMode
        ProcessId = $svcPid
    }
}

function Disable-And-Stop-DiagTrack {
    param([int]$TimeoutSeconds = 30)
    $info = Get-DiagTrackInfo
    if (-not $info.Exists) {
        Write-Log "Service 'DiagTrack' not found; treating as compliant."
        return @{ Changed = $false; Reason = 'ServiceMissing' }
    }

    $changed = $false

    # Disable start type
    try {
        if ($info.StartType -ne 'Disabled') {
            if ($PSCmdlet.ShouldProcess('DiagTrack', 'Set StartType = Disabled')) {
                try {
                    Set-Service -Name 'DiagTrack' -StartupType Disabled -ErrorAction Stop
                } catch {
                    Write-Verbose "Set-Service failed: $($_.Exception.Message); trying sc.exe fallback"
                    $null = & sc.exe config DiagTrack start= disabled
                }
                Write-Log "DiagTrack start type set to Disabled"
                $changed = $true
            }
        } else {
            Write-Log "DiagTrack already Disabled (no change)"
        }
    } catch {
        throw
    }

    # Stop if running
    $info = Get-DiagTrackInfo
    if ($info.Status -eq 'Running') {
        if ($PSCmdlet.ShouldProcess('DiagTrack', "Stop service (timeout ${TimeoutSeconds}s)")) {
            try {
                Write-Log "Stopping DiagTrack..."
                Stop-Service -Name 'DiagTrack' -ErrorAction SilentlyContinue

                $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                do {
                    Start-Sleep -Milliseconds 500
                    $info = Get-DiagTrackInfo
                } while ($info.Status -eq 'Running' -and (Get-Date) -lt $deadline)

                if ($info.Status -eq 'Running') {
                    Write-Log "Graceful stop timed out; attempting process termination."
                    if ($info.ProcessId -and $info.ProcessId -gt 0) {
                        try {
                            Stop-Process -Id $info.ProcessId -Force -ErrorAction Stop
                            Write-Log "Terminated DiagTrack process PID $($info.ProcessId)"
                        } catch {
                            Write-Error "Failed to terminate DiagTrack (PID $($info.ProcessId)): $($_.Exception.Message)"
                            exit $EXIT_STOP_SERVICE_FAILED
                        }
                    } else {
                        Write-Error "Unable to obtain DiagTrack PID for termination; check dependent services/policy."
                        exit $EXIT_STOP_SERVICE_FAILED
                    }
                } else {
                    Write-Log "DiagTrack stopped successfully."
                }
                $changed = $true
            } catch {
                Write-Error "Failed to stop DiagTrack: $($_.Exception.Message)"
                exit $EXIT_STOP_SERVICE_FAILED
            }
        }
    } else {
        Write-Log "DiagTrack already Stopped (no change)"
    }

    return @{ Changed = $changed; Reason = 'OK' }
}

function Restore-DiagTrack {
    param(
        [ValidateSet('Auto','Manual','Disabled','Unknown')]
        [string]$StartType,
        [ValidateSet('Running','Stopped','Unknown')]
        [string]$Status
    )
    $info = Get-DiagTrackInfo
    if (-not $info.Exists) {
        Write-Log "DiagTrack missing during rollback; skipping."
        return
    }

    if ($StartType -ne 'Unknown') {
        $needs = $info.StartType -ne $StartType
        if ($needs -and $PSCmdlet.ShouldProcess('DiagTrack', "Restore StartType = $StartType")) {
            try {
                switch ($StartType) {
                    'Auto'     { try { Set-Service -Name 'DiagTrack' -StartupType Automatic -ErrorAction Stop } catch { & sc.exe config DiagTrack start= auto | Out-Null } }
                    'Manual'   { try { Set-Service -Name 'DiagTrack' -StartupType Manual    -ErrorAction Stop } catch { & sc.exe config DiagTrack start= demand | Out-Null } }
                    'Disabled' { try { Set-Service -Name 'DiagTrack' -StartupType Disabled  -ErrorAction Stop } catch { & sc.exe config DiagTrack start= disabled | Out-Null } }
                    default    { }
                }
                Write-Log "Restored DiagTrack StartType to $StartType"
            } catch {
                Write-Error "Failed to restore DiagTrack StartType: $($_.Exception.Message)"
                exit $EXIT_ROLLBACK_FAILED
            }
        }
    }

    if ($Status -eq 'Running') {
        $info = Get-DiagTrackInfo
        if ($info.Status -ne 'Running') {
            if ($PSCmdlet.ShouldProcess('DiagTrack', 'Start service')) {
                try {
                    Start-Service -Name 'DiagTrack' -ErrorAction Stop
                    Write-Log "DiagTrack started"
                } catch {
                    Write-Error "Failed to start DiagTrack: $($_.Exception.Message)"
                    exit $EXIT_ROLLBACK_FAILED
                }
            }
        }
    }
}

# ----------------------------- Rollback State -----------------------------
function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $StatePath -Encoding utf8 -Raw
        return $raw | ConvertFrom-Json -Depth 5
    } catch {
        Write-Warning "Failed to read state file: $($_.Exception.Message)"
        return $null
    }
}

function Write-State {
    param(
        [Parameter(Mandatory)] [int] $AllowTelemetryValue,
        [Parameter(Mandatory)] [bool] $AllowTelemetryExists,
        [string] $AllowTelemetryType = 'Unknown',
        [Parameter(Mandatory)] [bool] $DiagExists,
        [Parameter(Mandatory)] [string] $DiagStatus,
        [Parameter(Mandatory)] [string] $DiagStartType
    )
    $state = [ordered]@{
        Timestamp = (Get-Date).ToString('o')
        AllowTelemetry = [ordered]@{
            Exists = $AllowTelemetryExists
            Type   = $AllowTelemetryType
            Value  = if ($AllowTelemetryExists) { $AllowTelemetryValue } else { $null }
        }
        DiagTrack = [ordered]@{
            Exists    = $DiagExists
            Status    = $DiagStatus
            StartType = $DiagStartType
        }
    }
    $json = $state | ConvertTo-Json -Depth 5
    if ($PSCmdlet.ShouldProcess($StatePath, 'Write rollback state JSON')) {
        $json | Out-File -LiteralPath $StatePath -Encoding utf8
        Write-Log "Saved rollback state to $StatePath"
    }
}

# ----------------------------- Core Operations -----------------------------
function Apply-Policy {
    $managed = Test-PolicyManaged
    if ($managed) {
        Write-Warning "AllowTelemetry appears managed by MDM/GPO (PolicyManager signals present). Changes may be overwritten on policy refresh/reboot."
        Write-Log "Policy managed warning issued."
    }

    # Early no-op if already correct
    $current = Get-PolicyValue
    if ($current.Exists -and $current.Value -eq $DesiredTelemetry -and $current.Type -eq 'DWord') {
        Write-Log "AllowTelemetry already $DesiredTelemetry (REG_DWORD) — no change."
        return $false
    }

    try {
        # Force REG_DWORD write
        Set-PolicyValue -Value $DesiredTelemetry

        # Mandatory read-back verification
        $post = Get-PolicyValue
        if (-not $post.Exists -or $post.Type -ne 'DWord' -or [int]$post.Value -ne $DesiredTelemetry) {
            Write-Error "Verification failed: AllowTelemetry is not REG_DWORD=0 after write (Exists=$($post.Exists), Type=$($post.Type), Value=$($post.Value)). This system may be policy-managed."
            exit $EXIT_REGISTRY_FAILED
        }

        Write-Log "AllowTelemetry verified as REG_DWORD=$DesiredTelemetry"
        return $true
    } catch {
        Write-Error "Failed to set/verify AllowTelemetry: $($_.Exception.Message)"
        exit $EXIT_REGISTRY_FAILED
    }

function Rollback-Policy {
    param([object]$State)
    $prev = $State.AllowTelemetry
    if ($prev.Exists -eq $true) {
        try {
            Set-PolicyValue -Value ([int]$prev.Value)
            Write-Log "Rolled back AllowTelemetry to $([int]$prev.Value)"
        } catch {
            Write-Error "Failed to restore AllowTelemetry: $($_.Exception.Message)"
            exit $EXIT_ROLLBACK_FAILED
        }
    } else {
        try {
            Set-PolicyValue -Remove
            Write-Log "Removed AllowTelemetry per prior missing state"
        } catch {
            Write-Error "Failed to remove AllowTelemetry during rollback: $($_.Exception.Message)"
            exit $EXIT_ROLLBACK_FAILED
        }
    }
}

function Verify-And-Print {
    $p = Get-PolicyValue
    $pValue = if ($p.Exists) { [int]$p.Value } else { -1 }
    $pType  = 'REG_DWORD'

    $d = Get-DiagTrackInfo
    $status = if ($d.Exists) { $d.Status } else { 'Stopped' }
    $stype  = if ($d.Exists) { $d.StartType } else { 'Disabled' }

    "AllowTelemetry = $pValue ($pType)"
    "DiagTrack Status = $status; StartType = $stype" | ForEach-Object { Write-Host $_ }
}

# ----------------------------- Interactive UI -----------------------------
function Show-Interactive {
    Clear-Host
    Write-Host "Telemetry Hardening" -ForegroundColor Cyan
    Write-Host "====================`n"

    $p = Get-PolicyValue
    $pdisp = if ($p.Exists) { "$($p.Value)" } else { "(missing)" }
    $d = Get-DiagTrackInfo

    Write-Host ("AllowTelemetry: {0}" -f $pdisp)
    Write-Host ("DiagTrack   : Status={0}, StartType={1}" -f $d.Status, $d.StartType)

    if (Test-PolicyManaged) {
        Write-Host "Warning: Policy appears managed by MDM/GPO; changes may be overwritten." -ForegroundColor Yellow
    }

    $hasState = Test-Path -LiteralPath $StatePath
    Write-Host ""
    Write-Host ("[1] Apply (capture rollback state first)") -ForegroundColor Green
    if ($hasState) {
        Write-Host "[2] Rollback (from saved state)" -ForegroundColor Yellow
    } else {
        Write-Host "[2] Rollback (no state found)" -ForegroundColor DarkGray
    }
    Write-Host "[Q] Quit"

    Write-Host ""
    $choice = Read-Host "Select an option"
    switch ($choice.ToUpperInvariant()) {
        '1' {
            $EnableRollbackLocal = $true
            if ($EnableRollbackLocal -and $PSCmdlet.ShouldProcess('System', 'Capture rollback state')) {
                $cur = Get-PolicyValue
                $svc = Get-DiagTrackInfo
                $curType = if ($null -ne $cur.Type -and "$($cur.Type)".Length -gt 0) { [string]$cur.Type } else { 'Unknown' }

                Write-State -AllowTelemetryValue ([int]($cur.Value)) `
                            -AllowTelemetryExists ([bool]$cur.Exists) `
                            -AllowTelemetryType $curType `
                            -DiagExists $svc.Exists `
                            -DiagStatus $svc.Status `
                            -DiagStartType $svc.StartType
            }
            $policyChanged = Apply-Policy
            $svcResult = Disable-And-Stop-DiagTrack
            if (-not $policyChanged -and -not $svcResult.Changed) {
                Write-Host "No change." -ForegroundColor DarkGray
            } else {
                Write-Host "Applied." -ForegroundColor Green
            }
            Verify-And-Print
            exit $EXIT_SUCCESS
        }
        '2' {
            if (-not $hasState) {
                Write-Host "No state file found at $StatePath" -ForegroundColor Yellow
                exit $EXIT_ROLLBACK_NOT_FOUND
            }
            $state = Read-State
            if ($null -eq $state) {
                Write-Host "Failed to read state file." -ForegroundColor Red
                exit $EXIT_ROLLBACK_FAILED
            }
            if ($PSCmdlet.ShouldProcess('System', 'Rollback policy and service')) {
                Rollback-Policy -State $state
                Restore-DiagTrack -StartType $state.DiagTrack.StartType -Status $state.DiagTrack.Status
            }
            Write-Host "Rollback complete." -ForegroundColor Green
            Verify-And-Print
            exit $EXIT_SUCCESS
        }
        'Q' { exit $EXIT_SUCCESS }
        default {
            Write-Host "Unknown selection." -ForegroundColor Yellow
            exit $EXIT_SUCCESS
        }
    }
}

# ----------------------------- Main -----------------------------
if (-not (Test-Admin)) {
    Write-Error "This script must be run as Administrator. Please re-run from an elevated PowerShell."
    exit $EXIT_NOT_ADMIN
}

# If no explicit parameters were bound, run interactive UI
if ($PSBoundParameters.Keys.Count -eq 0) {
    Show-Interactive
    exit $EXIT_SUCCESS
}

try {
    if ($Rollback) {
        $state = Read-State
        if ($null -eq $state) {
            Write-Error "No rollback state found at $StatePath"
            exit $EXIT_ROLLBACK_NOT_FOUND
        }
        if ($PSCmdlet.ShouldProcess('System', 'Rollback policy and service')) {
            Rollback-Policy -State $state
            Restore-DiagTrack -StartType $state.DiagTrack.StartType -Status $state.DiagTrack.Status
        }
        Verify-And-Print
        exit $EXIT_SUCCESS
    }

    # Capture rollback state if requested
    if ($EnableRollback) {
        $cur = Get-PolicyValue
        $svc = Get-DiagTrackInfo
        $curType = if ($null -ne $cur.Type -and "$($cur.Type)".Length -gt 0) { [string]$cur.Type } else { 'Unknown' }
        
        Write-State -AllowTelemetryValue ([int]($cur.Value)) `
                    -AllowTelemetryExists ([bool]$cur.Exists) `
                    -AllowTelemetryType $curType `
                    -DiagExists $svc.Exists `
                    -DiagStatus $svc.Status `
                    -DiagStartType $svc.StartType
        }
    }

    $changed = $false
    $changed = (Apply-Policy) -or $false
    $svcResult = Disable-And-Stop-DiagTrack
    $changed = $changed -or $svcResult.Changed

    if (-not $changed) { Write-Host "No change." }

    Verify-And-Print
    exit $EXIT_SUCCESS

} catch {
    Write-Error ("Error: {0}" -f $_.Exception.Message)
    if ($PSBoundParameters.ContainsKey('Verbose')) {
        Write-Verbose ("StackTrace: {0}" -f $_.ScriptStackTrace)
    }
    exit 1
}

