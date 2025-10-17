<#
.SYNOPSIS
Configures Windows Update Target Release settings.

.DESCRIPTION
Creates (if missing) and sets the following registry values under:
HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate

    TargetReleaseVersion      (DWORD)  = 1
    ProductVersion            (STRING) = Windows 11
    TargetReleaseVersionInfo  (STRING) = 24H2

The script is idempotent and works in both 32-bit and 64-bit PowerShell.

#>

# Ensure script runs with admin rights
If (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Restarting script as Administrator..."
    Start-Process -FilePath "powershell" -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

# Define registry path and values
$RegPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$Values = @{
    'TargetReleaseVersion'     = @{ Type = 'DWord';  Data = 1 }
    'ProductVersion'           = @{ Type = 'String'; Data = 'Windows 11' }
    'TargetReleaseVersionInfo' = @{ Type = 'String'; Data = '24H2' }
}

# Ensure key exists (handle 64-bit registry properly)
If (-not (Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force | Out-Null
    Write-Host "Created registry path: $RegPath"
}

# Apply each setting idempotently
foreach ($name in $Values.Keys) {
    $expected = $Values[$name].Data
    $type     = $Values[$name].Type

    $current = (Get-ItemProperty -Path $RegPath -Name $name -ErrorAction SilentlyContinue).$name
    if ($null -eq $current) {
        New-ItemProperty -Path $RegPath -Name $name -Value $expected -PropertyType $type -Force | Out-Null
        Write-Host "Added $name = $expected"
    }
    elseif ($current -ne $expected) {
        Set-ItemProperty -Path $RegPath -Name $name -Value $expected -Force
        Write-Host "Updated $name to $expected"
    }
    else {
        Write-Host "$name is already set to $expected (no change)"
    }
}

Write-Host "`n✅ Windows Update Target Release policy configured successfully."
