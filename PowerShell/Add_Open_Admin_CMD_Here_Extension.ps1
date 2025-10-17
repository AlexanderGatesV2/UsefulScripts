<#
.SYNOPSIS
Create context-menu "Open command window here as administrator" entries and enable EnableLinkedConnections,
relaunching the script elevated automatically if needed.

.DESCRIPTION
- Adds keys under HKCR for Directory, Directory\Background, and Drive to show "Open command window here as administrator"
- Removes HKCR\LibraryFolder\background\shell\OpenCmdHereAsAdmin if present (the "[-HKEY...]" behavior)
- Sets HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\EnableLinkedConnections = 1 (DWORD)
- Uses 64-bit registry view to avoid redirection issues
- Idempotent: only changes values if needed
- If not running as Admin, re-launches itself elevated (uses `pwsh` when available, otherwise `powershell`)
- Compatible with PowerShell 5.1+ and 7+
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Elevation check & relaunch elevated if required ---
function Test-IsElevated {
    try {
        $current = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

if (-not (Test-IsElevated)) {
    Write-Host "Not running elevated. Relaunching elevated..."
    # choose pwsh if available (PowerShell Core/7+), otherwise fall back to Windows PowerShell
    $pwshCmd = (Get-Command pwsh -ErrorAction SilentlyContinue)
    if ($null -ne $pwshCmd) {
        $exe = $pwshCmd.Path
    } else {
        # Use powershell.exe from PSHOME (works for Windows PowerShell 5.1)
        $exe = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path $exe)) {
            # Fallback to just 'powershell' (should resolve in PATH)
            $exe = 'powershell'
        }
    }

    # Build argument list: -NoProfile -ExecutionPolicy Bypass -File "<script>" <original args>
    $argList = @(
        '-NoProfile'
        '-ExecutionPolicy'; 'Bypass'
        '-File'; $PSCommandPath
    )
    if ($args.Count -gt 0) {
        # Append each argument (preserve as separate args so quoting is handled)
        $argList += $args
    }

    # Start elevated and exit current process
    Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs -WindowStyle Normal
    exit 0
}
#endregion

#region --- helper functions for 64-bit registry operations ---
function Open-BaseKey64 {
    param([Microsoft.Win32.RegistryHive]$Hive)
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
}

function Ensure-SubKeyAndSetValue {
    param(
        [Microsoft.Win32.RegistryKey]$BaseKey,
        [string]$SubKeyPath,
        [string]$ValueName,      # use "" for default (unnamed) value
        [object]$ValueData,
        [Microsoft.Win32.RegistryValueKind]$Kind = [Microsoft.Win32.RegistryValueKind]::String
    )

    $key = $BaseKey.CreateSubKey($SubKeyPath)
    if (-not $key) { throw "Failed to create/open registry key: $SubKeyPath" }

    $existing = $null
    try { $existing = $key.GetValue($ValueName) } catch {}

    # Compare existing to desired (stringify for comparison when necessary)
    $needSet = $false
    if ($existing -eq $null) {
        $needSet = $true
    } else {
        # For DWord compare numeric vs numeric, otherwise compare as string
        if ($Kind -eq [Microsoft.Win32.RegistryValueKind]::DWord) {
            if ([int]$existing -ne [int]$ValueData) { $needSet = $true }
        } else {
            if ("$existing" -ne "$ValueData") { $needSet = $true }
        }
    }

    if ($needSet) {
        $key.SetValue($ValueName, $ValueData, $Kind)
        Write-Host "Set $SubKeyPath\$ValueName -> $ValueData"
    } else {
        Write-Host "No change for $SubKeyPath\$ValueName (already set)"
    }

    $key.Close()
}

function Ensure-SubKeyRemoveValue {
    param(
        [Microsoft.Win32.RegistryKey]$BaseKey,
        [string]$SubKeyPath,
        [string]$ValueName
    )
    $key = $BaseKey.OpenSubKey($SubKeyPath, $true)
    if ($null -ne $key) {
        $vals = $key.GetValueNames()
        if ($vals -contains $ValueName) {
            $key.DeleteValue($ValueName)
            Write-Host "Removed value '$ValueName' from $SubKeyPath"
        } else {
            Write-Host "Value '$ValueName' not present in $SubKeyPath"
        }
        $key.Close()
    } else {
        Write-Host "Key $SubKeyPath does not exist (nothing to remove)"
    }
}

function Remove-SubKeyIfExists {
    param(
        [Microsoft.Win32.RegistryKey]$BaseKey,
        [string]$SubKeyPath
    )
    try {
        $sub = $BaseKey.OpenSubKey($SubKeyPath)
        if ($null -ne $sub) {
            $sub.Close()
            $BaseKey.DeleteSubKeyTree($SubKeyPath)
            Write-Host "Deleted registry key: $SubKeyPath"
            return $true
        } else {
            Write-Host "Registry key not present: $SubKeyPath"
            return $false
        }
    } catch {
        Write-Warning "Failed to delete $SubKeyPath: $_"
        return $false
    }
}
#endregion

#region --- Main registry operations ---
try {
    $hkcr = Open-BaseKey64 -Hive 'ClassesRoot'
    $hklm = Open-BaseKey64 -Hive 'LocalMachine'

    $commandValue = 'cmd /c echo|set/p="%L"|powershell -NoP -W 1 -NonI -NoL "SaPs ''cmd'' -Args ''/c \""\""cd /d' + '$([char]34+$Input+[char]34)' + '^\&^\& start /b cmd.exe\"\""'' -Verb RunAs"'
    # The above uses doubled single-quotes to keep literal quotes inside the string. It's equivalent to original .reg content.

    $commandValue_Background = 'cmd /c echo|set/p="%V"|powershell -NoP -W 1 -NonI -NoL "SaPs ''cmd'' -Args ''/c \""\""cd /d' + '$([char]34+$Input+[char]34)' + '^\&^\& start /b cmd.exe\"\""'' -Verb RunAs"'

    $items = @(
        @{ Key = 'Directory\shell\OpenCmdHereAsAdmin';        CommandKey = 'Directory\shell\OpenCmdHereAsAdmin\command'; CommandValue = $commandValue },
        @{ Key = 'Directory\Background\shell\OpenCmdHereAsAdmin'; CommandKey = 'Directory\Background\shell\OpenCmdHereAsAdmin\command'; CommandValue = $commandValue_Background },
        @{ Key = 'Drive\shell\OpenCmdHereAsAdmin';            CommandKey = 'Drive\shell\OpenCmdHereAsAdmin\command'; CommandValue = $commandValue }
    )

    foreach ($item in $items) {
        Ensure-SubKeyAndSetValue -BaseKey $hkcr -SubKeyPath $item.Key -ValueName "" -ValueData "Open command window here as administrator"
        Ensure-SubKeyRemoveValue -BaseKey $hkcr -SubKeyPath $item.Key -ValueName "Extended"
        Ensure-SubKeyAndSetValue -BaseKey $hkcr -SubKeyPath $item.Key -ValueName "Icon" -ValueData "imageres.dll,-5324"
        Ensure-SubKeyAndSetValue -BaseKey $hkcr -SubKeyPath $item.CommandKey -ValueName "" -ValueData $item.CommandValue
    }

    # Remove the LibraryFolder\background\shell\OpenCmdHereAsAdmin key if present
    Remove-SubKeyIfExists -BaseKey $hkcr -SubKeyPath 'LibraryFolder\background\shell\OpenCmdHereAsAdmin'

    # Set EnableLinkedConnections under HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System = 1 (DWORD)
    $sysPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $sysKey = $hklm.CreateSubKey($sysPath)
    if (-not $sysKey) { throw "Failed to open or create $sysPath" }
    $existing = $sysKey.GetValue('EnableLinkedConnections', $null)
    if ($existing -ne 1) {
        $sysKey.SetValue('EnableLinkedConnections', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        Write-Host "Set HKLM:\$sysPath\EnableLinkedConnections = 1"
    } else {
        Write-Host "HKLM:\$sysPath\EnableLinkedConnections already = 1 (no change)"
    }
    $sysKey.Close()

    $hkcr.Close()
    $hklm.Close()

    Write-Host "Completed registry changes."
    Write-Host "You may need to sign out/in or restart Explorer for context-menu changes to show immediately."
} catch {
    Write-Error "Error: $_"
    exit 1
}
#endregion
