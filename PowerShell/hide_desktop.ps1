<#
.SYNOPSIS
Hide or restore desktop items by setting NoDesktop=1 or 0 under HKCU and HKLM,
with automatic elevation and reboot.

.DESCRIPTION
- Default: asks the user to confirm hiding all desktop icons (NoDesktop=1)
- With -Revert: restores desktop visibility (NoDesktop=0)
- Works on PowerShell 5.1+ and 7+
- Uses 64-bit registry view
#>

param(
    [switch]$Revert
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Elevation check & relaunch
function Test-IsElevated {
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

if (-not (Test-IsElevated)) {
    Write-Host "Not running as Administrator. Relaunching elevated..."
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    $exe = if ($pwsh) { $pwsh.Path } else { (Join-Path $PSHOME 'powershell.exe') }
    if (-not (Test-Path $exe)) { $exe = 'powershell' }

    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if ($Revert) { $argList += '-Revert' }
    $argList += $args
    Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs
    exit 0
}
#endregion

#region Registry helpers (64-bit view)
function Open-BaseKey64([Microsoft.Win32.RegistryHive]$Hive) {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
}

function Set-DWord {
    param(
        [Microsoft.Win32.RegistryKey]$BaseKey,
        [string]$SubKey,
        [string]$Name,
        [int]$Value
    )
    $k = $BaseKey.CreateSubKey($SubKey)
    if (-not $k) { throw "Failed to open/create $SubKey" }
    $existing = $k.GetValue($Name, $null)
    if ($existing -ne $Value) {
        $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::DWord)
        Write-Host "Set $($BaseKey.Name)\$SubKey\$Name = $Value"
    } else {
        Write-Host "No change for $($BaseKey.Name)\$SubKey\$Name (already $Value)"
    }
    $k.Close()
}
#endregion

# Common variables
$hkcu = Open-BaseKey64 -Hive 'CurrentUser'
$hklm = Open-BaseKey64 -Hive 'LocalMachine'
$sub  = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'

if ($Revert) {
    Write-Host "Reverting: restoring desktop items..."
    Set-DWord -BaseKey $hkcu -SubKey $sub -Name 'NoDesktop' -Value 0
    Set-DWord -BaseKey $hklm -SubKey $sub -Name 'NoDesktop' -Value 0
    Write-Host "`nDesktop items restored. System will reboot in 10 seconds."
    Start-Process -FilePath 'shutdown.exe' -ArgumentList @('/r','/t','10') -WindowStyle Hidden
    Read-Host "`nPress Enter to exit"
    exit 0
}

# Normal mode: prompt user first
$choiceYes = New-Object System.Management.Automation.Host.ChoiceDescription '&Yes','Hide desktop items'
$choiceNo  = New-Object System.Management.Automation.Host.ChoiceDescription '&No','Cancel'
$selection = $Host.UI.PromptForChoice('Confirm',
  'Do you want to hide and disable all items on the desktop?',
  [System.Management.Automation.Host.ChoiceDescription[]]@($choiceYes,$choiceNo), 1)

if ($selection -ne 0) {
    Write-Host "Canceled."
    Read-Host "Press Enter to exit"
    exit 0
}

# Apply change
Set-DWord -BaseKey $hkcu -SubKey $sub -Name 'NoDesktop' -Value 1
Set-DWord -BaseKey $hklm -SubKey $sub -Name 'NoDesktop' -Value 1
Write-Host "`nDesktop items are now hidden and disabled."
Write-Host "The system will reboot in 10 seconds to apply the changes."

Start-Process -FilePath 'shutdown.exe' -ArgumentList @('/r','/t','10') -WindowStyle Hidden
Read-Host "`nPress Enter to exit"
