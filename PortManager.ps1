<#
.SYNOPSIS
    Idempotent Windows Firewall port manager with NetSecurity/netsh dual-engine support.

.DESCRIPTION
    Opens or blocks ports in Windows Firewall with state detection and idempotency.
    Works on Windows 8/Server 2012+ with PowerShell 5.1+ and 7+.
    Automatically detects NetSecurity cmdlets; falls back to netsh if unavailable.
    Supports managing multiple directions (Inbound, Outbound, or both) in a single command.

.USAGE EXAMPLES
    Interactive mode:
        .\PortManager.ps1

    Non-interactive (automation/CI-CD):
        .\PortManager.ps1 -Port 443 -Action Open -Protocol TCP -Direction Inbound -Profile Domain,Private -Force
        .\PortManager.ps1 -Port 53 -Action Block -Protocol UDP -Direction Outbound -Profile Public -WhatIf
        .\PortManager.ps1 -Port 3389 -Action Open -Force
        pwsh -File .\PortManager.ps1 -Port 8080 -Action Block -Protocol TCP -Force
        
    Block both directions in one command:
        .\PortManager.ps1 -Port 445 -Action Block -Direction Inbound,Outbound -Force
        .\PortManager.ps1 -Port 3389 -Action Open -Direction Inbound,Outbound -Protocol TCP -Force

.TESTING NOTES
    Verify with NetSecurity:
        Get-NetFirewallRule | Where-Object {$_.DisplayName -like "*PortManager*"}
        Get-NetFirewallRule -DisplayName "PortManager_Open_Inbound_TCP_443" | Get-NetFirewallPortFilter

    Verify with netsh:
        netsh advfirewall firewall show rule name=all | findstr /i "443"
        netsh advfirewall firewall show rule name="PortManager_Open_Inbound_TCP_443"

    Reverse an action:
        .\PortManager.ps1 -Port 443 -Action Block -Force  # (if previously opened)
        .\PortManager.ps1 -Port 443 -Action Open -Force   # (to reopen)

.NOTES
    Exit codes: 0 = success/no-op, non-zero = error
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 65535)]
    [int]$Port,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Open', 'Block')]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [ValidateSet('TCP', 'UDP')]
    [string]$Protocol = 'TCP',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Inbound', 'Outbound')]
    [string[]]$Direction = @('Inbound'),

    [Parameter(Mandatory = $false)]
    [ValidateSet('Domain', 'Private', 'Public')]
    [string[]]$Profile = @('Domain', 'Private', 'Public'),

    [Parameter(Mandatory = $false)]
    [string]$RuleName,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helper Functions

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-NetSecurityAvailable {
    return (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue) -ne $null
}

function Get-EffectivePortState {
    param(
        [int]$Port,
        [string]$Protocol,
        [string]$Direction,
        [string[]]$Profile
    )

    $result = @{
        State = 'Unknown'
        MatchedRule = $null
        RuleName = $null
    }

    if (Test-NetSecurityAvailable) {
        # Use NetSecurity cmdlets
        $directionMap = @{ 'Inbound' = 'Inbound'; 'Outbound' = 'Outbound' }
        $rules = Get-NetFirewallRule -Direction $directionMap[$Direction] -Enabled True -ErrorAction SilentlyContinue

        foreach ($rule in $rules) {
            $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            if ($portFilter -and $portFilter.LocalPort -contains $Port -and $portFilter.Protocol -eq $Protocol) {
                $addressFilter = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
                
                # Check if rule applies to requested profiles
                $ruleProfiles = @($rule.Profile -split ',').Trim()
                $matchesProfile = $false
                foreach ($p in $Profile) {
                    if ($ruleProfiles -contains $p -or $ruleProfiles -contains 'Any') {
                        $matchesProfile = $true
                        break
                    }
                }

                if ($matchesProfile) {
                    $result.MatchedRule = $rule
                    $result.RuleName = $rule.DisplayName
                    
                    if ($rule.Action -eq 'Allow') {
                        $result.State = 'Open'
                        return $result
                    }
                    elseif ($rule.Action -eq 'Block') {
                        $result.State = 'Blocked'
                        return $result
                    }
                }
            }
        }
    }
    else {
        # Fallback to netsh parsing
        $directionMap = @{ 'Inbound' = 'in'; 'Outbound' = 'out' }
        $netshDir = $directionMap[$Direction]
        
        $output = netsh advfirewall firewall show rule name=all 2>&1 | Out-String
        $rules = $output -split "Rule Name:"
        
        foreach ($ruleText in $rules) {
            if ($ruleText -match "LocalPort:\s+$Port" -and 
                $ruleText -match "Protocol:\s+$Protocol" -and
                $ruleText -match "Direction:\s+$netshDir" -and
                $ruleText -match "Enabled:\s+Yes") {
                
                # Extract rule name
                if ($ruleText -match "^([^\r\n]+)") {
                    $result.RuleName = $matches[1].Trim()
                }
                
                if ($ruleText -match "Action:\s+Allow") {
                    $result.State = 'Open'
                    return $result
                }
                elseif ($ruleText -match "Action:\s+Block") {
                    $result.State = 'Blocked'
                    return $result
                }
            }
        }
    }

    return $result
}

function Ensure-PortOpen {
    param(
        [int]$Port,
        [string]$Protocol,
        [string]$Direction,
        [string[]]$Profile,
        [string]$RuleName
    )

    if (-not $RuleName) {
        $RuleName = "PortManager_Open_${Direction}_${Protocol}_${Port}"
    }
    else {
        # If custom name provided and direction not in name, append it for uniqueness
        if ($RuleName -notmatch $Direction) {
            $RuleName = "${RuleName}_${Direction}"
        }
    }

    $profileStr = $Profile -join ','

    if (Test-NetSecurityAvailable) {
        # Check if rule exists
        $existingRule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue

        if ($existingRule) {
            # Update existing rule
            if ($PSCmdlet.ShouldProcess("Rule: $RuleName", "Enable/Update Allow rule")) {
                Set-NetFirewallRule -DisplayName $RuleName -Enabled True -Action Allow -Direction $Direction -Profile $Profile -ErrorAction Stop
            }
        }
        else {
            # Create new rule
            if ($PSCmdlet.ShouldProcess("Port $Port/$Protocol $Direction", "Create Allow rule")) {
                New-NetFirewallRule -DisplayName $RuleName -Direction $Direction -Protocol $Protocol `
                    -LocalPort $Port -Action Allow -Profile $Profile -Enabled True -ErrorAction Stop | Out-Null
            }
        }
    }
    else {
        # Use netsh
        $directionMap = @{ 'Inbound' = 'in'; 'Outbound' = 'out' }
        $netshDir = $directionMap[$Direction]
        $netshProfile = $Profile -join ','

        # Check if rule exists
        $existingRule = netsh advfirewall firewall show rule name="$RuleName" 2>&1 | Out-String
        
        if ($existingRule -match "No rules match") {
            # Create new rule
            if ($PSCmdlet.ShouldProcess("Port $Port/$Protocol $Direction", "Create Allow rule")) {
                $result = netsh advfirewall firewall add rule name="$RuleName" dir=$netshDir action=allow `
                    protocol=$Protocol localport=$Port profile=$netshProfile enable=yes 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "netsh failed: $result"
                }
            }
        }
        else {
            # Update existing rule
            if ($PSCmdlet.ShouldProcess("Rule: $RuleName", "Enable/Update Allow rule")) {
                $result = netsh advfirewall firewall set rule name="$RuleName" new enable=yes action=allow `
                    dir=$netshDir protocol=$Protocol localport=$Port profile=$netshProfile 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "netsh failed: $result"
                }
            }
        }
    }

    Write-Outcome -Action "Opened" -Port $Port -Protocol $Protocol -Direction $Direction -Profile $profileStr
}

function Ensure-PortBlocked {
    param(
        [int]$Port,
        [string]$Protocol,
        [string]$Direction,
        [string[]]$Profile,
        [string]$RuleName
    )

    if (-not $RuleName) {
        $RuleName = "PortManager_Block_${Direction}_${Protocol}_${Port}"
    }
    else {
        # If custom name provided and direction not in name, append it for uniqueness
        if ($RuleName -notmatch $Direction) {
            $RuleName = "${RuleName}_${Direction}"
        }
    }

    $profileStr = $Profile -join ','

    if (Test-NetSecurityAvailable) {
        # Check if rule exists
        $existingRule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue

        if ($existingRule) {
            # Update existing rule
            if ($PSCmdlet.ShouldProcess("Rule: $RuleName", "Enable/Update Block rule")) {
                Set-NetFirewallRule -DisplayName $RuleName -Enabled True -Action Block -Direction $Direction -Profile $Profile -ErrorAction Stop
            }
        }
        else {
            # Create new rule
            if ($PSCmdlet.ShouldProcess("Port $Port/$Protocol $Direction", "Create Block rule")) {
                New-NetFirewallRule -DisplayName $RuleName -Direction $Direction -Protocol $Protocol `
                    -LocalPort $Port -Action Block -Profile $Profile -Enabled True -ErrorAction Stop | Out-Null
            }
        }
    }
    else {
        # Use netsh
        $directionMap = @{ 'Inbound' = 'in'; 'Outbound' = 'out' }
        $netshDir = $directionMap[$Direction]
        $netshProfile = $Profile -join ','

        # Check if rule exists
        $existingRule = netsh advfirewall firewall show rule name="$RuleName" 2>&1 | Out-String
        
        if ($existingRule -match "No rules match") {
            # Create new rule
            if ($PSCmdlet.ShouldProcess("Port $Port/$Protocol $Direction", "Create Block rule")) {
                $result = netsh advfirewall firewall add rule name="$RuleName" dir=$netshDir action=block `
                    protocol=$Protocol localport=$Port profile=$netshProfile enable=yes 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "netsh failed: $result"
                }
            }
        }
        else {
            # Update existing rule
            if ($PSCmdlet.ShouldProcess("Rule: $RuleName", "Enable/Update Block rule")) {
                $result = netsh advfirewall firewall set rule name="$RuleName" new enable=yes action=block `
                    dir=$netshDir protocol=$Protocol localport=$Port profile=$netshProfile 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "netsh failed: $result"
                }
            }
        }
    }

    Write-Outcome -Action "Blocked" -Port $Port -Protocol $Protocol -Direction $Direction -Profile $profileStr
}

function Write-Outcome {
    param(
        [string]$Action,
        [int]$Port,
        [string]$Protocol,
        [string]$Direction,
        [string]$Profile
    )
    
    Write-Host "$Action $Protocol $($Direction.ToLower()) port $Port (Profiles: $Profile)."
}

#endregion

#region Main Logic

try {
    # Check elevation
    if (-not (Test-IsElevated)) {
        Write-Error "This script requires administrator privileges. Please run as Administrator."
        exit 1
    }

    # Interactive mode if Port or Action not provided
    $isInteractive = (-not $Port) -or (-not $Action)

    if ($isInteractive) {
        Write-Host "=== Windows Firewall Port Manager ===" -ForegroundColor Cyan
        Write-Host ""

        # Get Port
        do {
            $portInput = Read-Host "Enter port number (1-65535)"
            $portValid = [int]::TryParse($portInput, [ref]$Port) -and $Port -ge 1 -and $Port -le 65535
            if (-not $portValid) {
                Write-Host "Invalid port. Please enter a number between 1 and 65535." -ForegroundColor Yellow
            }
        } while (-not $portValid)

        # Get Action
        do {
            $actionInput = Read-Host "Action (Open/Block)"
            $Action = $actionInput.Trim()
            $actionValid = $Action -in @('Open', 'Block')
            if (-not $actionValid) {
                Write-Host "Invalid action. Please enter 'Open' or 'Block'." -ForegroundColor Yellow
            }
        } while (-not $actionValid)

        # Get Protocol
        $protocolInput = Read-Host "Protocol (TCP/UDP) [default: TCP]"
        if ($protocolInput.Trim()) {
            $Protocol = $protocolInput.Trim()
            if ($Protocol -notin @('TCP', 'UDP')) {
                Write-Host "Invalid protocol. Defaulting to TCP." -ForegroundColor Yellow
                $Protocol = 'TCP'
            }
        }

        # Get Direction
        $directionInput = Read-Host "Direction (Inbound/Outbound/Both) [default: Inbound]"
        if ($directionInput.Trim()) {
            $dirInput = $directionInput.Trim()
            if ($dirInput -eq 'Both') {
                $Direction = @('Inbound', 'Outbound')
            }
            elseif ($dirInput -in @('Inbound', 'Outbound')) {
                $Direction = @($dirInput)
            }
            else {
                Write-Host "Invalid direction. Defaulting to Inbound." -ForegroundColor Yellow
                $Direction = @('Inbound')
            }
        }

        Write-Host ""
    }

    # Validate required parameters
    if (-not $Port -or -not $Action) {
        Write-Error "Port and Action are required. Use -Port and -Action parameters for non-interactive mode."
        exit 1
    }

    # Process each direction
    $profileStr = $Profile -join ','
    $hasChanges = $false
    
    foreach ($dir in $Direction) {
        # Check current state
        $currentState = Get-EffectivePortState -Port $Port -Protocol $Protocol -Direction $dir -Profile $Profile

        # Idempotency check
        if ($Action -eq 'Open' -and $currentState.State -eq 'Open') {
            Write-Host "Port $Port/$Protocol $($dir.ToLower()) is already OPEN (Profiles: $profileStr). No change."
            continue
        }

        if ($Action -eq 'Block' -and $currentState.State -eq 'Blocked') {
            Write-Host "Port $Port/$Protocol $($dir.ToLower()) is already BLOCKED (Profiles: $profileStr). No change."
            continue
        }

        # Apply confirmation logic (only once if multiple directions)
        if (-not $hasChanges -and -not $Force -and -not $WhatIfPreference) {
            $directionList = $Direction -join ', '
            $confirmPrompt = "Are you sure you want to $Action port $Port/$Protocol for direction(s): $directionList and profiles: $profileStr"
            if (-not $PSCmdlet.ShouldContinue($confirmPrompt, "Confirm Firewall Change")) {
                Write-Host "Operation cancelled by user."
                exit 0
            }
        }

        # Execute action
        if ($Action -eq 'Open') {
            Ensure-PortOpen -Port $Port -Protocol $Protocol -Direction $dir -Profile $Profile -RuleName $RuleName
        }
        else {
            Ensure-PortBlocked -Port $Port -Protocol $Protocol -Direction $dir -Profile $Profile -RuleName $RuleName
        }
        
        $hasChanges = $true
    }

    exit 0
}
catch {
    Write-Error "ERROR: $($_.Exception.Message)"
    exit 1
}

#endregion