<#
.SYNOPSIS
    Generates a system information image and sets it as the desktop wallpaper.

.DESCRIPTION
    This script collects key system information (OS details, IP address, device name, etc.),
    renders it into an image using .NET System.Drawing, and sets it as the desktop wallpaper.
    Designed for Windows 10/11 (x64 and ARM64) with no external dependencies.

.PARAMETER OutputPath
    Path where the wallpaper image will be saved. Default: %LOCALAPPDATA%\SysStamp\wallpaper.bmp

.PARAMETER FontName
    Font name to use for rendering text. Default: Consolas

.PARAMETER Size
    Override resolution (WxH format, e.g., "2560x1440"). If not specified, uses primary monitor resolution.

.PARAMETER DryRun
    Generate the image but do not set it as wallpaper.

.PARAMETER Preview
    Open the generated image in the default image viewer.

.PARAMETER Verbose
    Enable detailed logging output.

.EXAMPLE
    .\Set-SysStampWallpaper.ps1
    Generate and set wallpaper with default settings.

.EXAMPLE
    .\Set-SysStampWallpaper.ps1 -DryRun -Verbose
    Generate wallpaper without setting it, with verbose output.

.EXAMPLE
    .\Set-SysStampWallpaper.ps1 -Size 2560x1440 -FontName "Courier New"
    Generate wallpaper with custom resolution and font.

.NOTES
    Author: SysStamp Wallpaper Generator
    Version: 1.0.0
    Requires: Windows 10/11, PowerShell 5.1+, .NET Framework
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "${env:LOCALAPPDATA}\SysStamp\wallpaper.bmp",
    [string]$FontName = "Consolas",
    [string]$Size = "",
    [switch]$DryRun,
    [switch]$Preview,
    [switch]$DebugMode
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Enable verbose output if requested
if ($DebugMode) {
    $VerbosePreference = "Continue"
}

#region Helper Functions

function Write-VerboseLog {
    param([string]$Message)
    if ($DebugMode) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
    }
}

function Get-SystemInformation {
    <#
    .SYNOPSIS
        Collects all required system information.
    #>
    
    Write-VerboseLog "Collecting system information..."
    
    $info = @{}
    
    try {
        # OS Information from Registry
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
        $productName    = (Get-ItemProperty -Path $regPath -Name ProductName -ErrorAction SilentlyContinue).ProductName
        $displayVersion = (Get-ItemProperty -Path $regPath -Name DisplayVersion -ErrorAction SilentlyContinue).DisplayVersion
        $releaseId      = (Get-ItemProperty -Path $regPath -Name ReleaseId -ErrorAction SilentlyContinue).ReleaseId
        $currentBuild   = (Get-ItemProperty -Path $regPath -Name CurrentBuild -ErrorAction SilentlyContinue).CurrentBuild
        $ubr            = (Get-ItemProperty -Path $regPath -Name UBR -ErrorAction SilentlyContinue).UBR
        $editionId      = (Get-ItemProperty -Path $regPath -Name EditionID -ErrorAction SilentlyContinue).EditionID
        
        # OS Information from CIM
        $osInfo = Get-CimInstance Win32_OperatingSystem
        $csInfo = Get-CimInstance Win32_ComputerSystem
        $procInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
        
        # Determine architecture
        $arch = if ([Environment]::Is64BitOperatingSystem) {
            if ($procInfo.Architecture -eq 12 -or $csInfo.SystemType -match "ARM") {
                "arm64 (AArch64)"
            } else {
                "x64 (AMD64)"
            }
        } else {
            "x86"
        }
        
        # Build version string
        $versionDisplay = if ($displayVersion) { $displayVersion } elseif ($releaseId) { $releaseId } else { "N/A" }
        $buildString = "$currentBuild"
        if ($ubr) {
            $buildString += ".$ubr"
        }
        # ---- Windows 11 normalization logic ----
        $buildInt = 0
        [int]::TryParse($currentBuild, [ref]$buildInt) | Out-Null
        if ($buildInt -ge 22000) {
            if ($productName -match '^Windows 10') {
                # Replace leading "Windows 10" with "Windows 11"
                $productName = $productName -replace '^Windows 10','Windows 11'
            } elseif (-not ($productName -match '^Windows 11')) {
                # Construct a reasonable name if not already 11
                if ($editionId) {
                    $productName = "Windows 11 $editionId"
                } else {
                    $productName = "Windows 11"
                }
            }
        }

        $info["OS"] = "Windows"
        $info["OS Name"] = if ($productName) { $productName } else { $osInfo.Caption }
        $info["OS Version"] = "$versionDisplay (Build $buildString)"
        $info["OS Arch"] = $arch
        $info["Device Name"] = $env:COMPUTERNAME
        $info["IP Address"] = Get-PrimaryIPv4Address
        $info["Timestamp"] = Get-Date -Format "yyyy-MM-dd HH:mm:ss K"
        
    } catch {
        Write-Warning "Error collecting system information: $_"
        # Provide fallback values
        $info["OS"] = "Windows"
        $info["OS Name"] = "Windows"
        $info["OS Version"] = "Unknown"
        $info["OS Arch"] = "Unknown"
        $info["Device Name"] = $env:COMPUTERNAME
        $info["IP Address"] = "Unknown"
        $info["Timestamp"] = Get-Date -Format "yyyy-MM-dd HH:mm:ss K"
    }
    
    return $info
}

function Get-PrimaryIPv4Address {
    <#
    .SYNOPSIS
        Gets the primary IPv4 address (non-loopback, non-APIPA, non-virtual).
    #>
    
    Write-VerboseLog "Determining primary IPv4 address..."
    
    try {
        # Try using Get-NetIPConfiguration first (Windows 8+)
        if (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
            $configs = Get-NetIPConfiguration -Detailed | Where-Object {
                $_.IPv4DefaultGateway -and 
                $_.NetAdapter.Status -eq 'Up' -and
                $_.InterfaceAlias -notmatch 'Hyper-V|VMware|VirtualBox|WSL|Loopback'
            }
            
            if ($configs) {
                $primaryConfig = $configs | Select-Object -First 1
                $ipv4 = $primaryConfig.IPv4Address | Where-Object {
                    $_.IPAddress -notmatch '^127\.' -and
                    $_.IPAddress -notmatch '^169\.254\.'
                } | Select-Object -First 1
                
                if ($ipv4) {
                    return $ipv4.IPAddress
                }
            }
        }
        
        # Fallback to .NET method
        Add-Type -AssemblyName System.Net.NetworkInformation -ErrorAction SilentlyContinue
        
        $interfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
            $_.OperationalStatus -eq 'Up' -and
            $_.NetworkInterfaceType -ne 'Loopback' -and
            $_.Description -notmatch 'Hyper-V|VMware|VirtualBox|WSL'
        }
        
        foreach ($interface in $interfaces) {
            $props = $interface.GetIPProperties()
            $gateway = $props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' }
            
            if ($gateway) {
                $unicast = $props.UnicastAddresses | Where-Object {
                    $_.Address.AddressFamily -eq 'InterNetwork' -and
                    $_.Address.ToString() -notmatch '^127\.' -and
                    $_.Address.ToString() -notmatch '^169\.254\.'
                } | Select-Object -First 1
                
                if ($unicast) {
                    return $unicast.Address.ToString()
                }
            }
        }
        
        # Last resort: any non-loopback IPv4
        $anyIP = $interfaces | ForEach-Object {
            $_.GetIPProperties().UnicastAddresses | Where-Object {
                $_.Address.AddressFamily -eq 'InterNetwork' -and
                $_.Address.ToString() -notmatch '^127\.' -and
                $_.Address.ToString() -notmatch '^169\.254\.'
            }
        } | Select-Object -First 1
        
        if ($anyIP) {
            return $anyIP.Address.ToString()
        }
        
    } catch {
        Write-Warning "Error getting IP address: $_"
    }
    
    return "No IPv4"
}

function Get-ScreenResolution {
    <#
    .SYNOPSIS
        Gets the primary screen resolution.
    #>
    
    Write-VerboseLog "Detecting screen resolution..."
    
    # If Size parameter is specified, parse and use it
    if ($Size) {
        if ($Size -match '^(\d+)x(\d+)$') {
            return @{
                Width = [int]$Matches[1]
                Height = [int]$Matches[2]
            }
        } else {
            Write-Warning "Invalid size format. Using auto-detection."
        }
    }
    
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        if ($screen) {
            return @{
                Width = $screen.Bounds.Width
                Height = $screen.Bounds.Height
            }
        }
    } catch {
        Write-Warning "Could not detect screen resolution: $_"
    }
    
    # Fallback resolution
    return @{
        Width = 1920
        Height = 1080
    }
}

function New-SystemInfoImage {
    <#
    .SYNOPSIS
        Creates the system information image.
    #>
    param(
        [hashtable]$SystemInfo,
        [hashtable]$Resolution,
        [string]$FontName,
        [string]$OutputPath
    )

    # --- Normalization to avoid array math issues ---
    # Coerce resolution to single hashtable with int Width/Height
    if ($Resolution -is [System.Array]) {
        $Resolution = $Resolution | Select-Object -First 1
    }
    if ($null -eq $Resolution) {
        $Resolution = @{ Width = 1920; Height = 1080 }
    } elseif ($Resolution -isnot [hashtable]) {
        if ($Resolution.PSObject.Properties['Width'] -and $Resolution.PSObject.Properties['Height']) {
            $Resolution = @{ Width = [int]$Resolution.Width; Height = [int]$Resolution.Height }
        } else {
            $Resolution = @{ Width = 1920; Height = 1080 }
        }
    } else {
        $Resolution = @{ Width = [int]$Resolution.Width; Height = [int]$Resolution.Height }
    }
    
    Write-VerboseLog "Creating system information image..."
    
    try {
        # Load System.Drawing assembly
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        
        # Create bitmap
        $bitmap = New-Object System.Drawing.Bitmap($Resolution.Width, $Resolution.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        
        # Set high quality rendering
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        
        # Create gradient background
        $rect = New-Object System.Drawing.Rectangle(0, 0, $Resolution.Width, $Resolution.Height)
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $rect,
            [System.Drawing.Color]::FromArgb(255, 20, 25, 40),
            [System.Drawing.Color]::FromArgb(255, 40, 45, 60),
            [System.Drawing.Drawing2D.LinearGradientMode]::Vertical
        )
        $graphics.FillRectangle($brush, $rect)
        
        # Try to create font
        $fontSize = [Math]::Max(14, [Math]::Min(32, [int]($Resolution.Height / 35)))
        try {
            $font = New-Object System.Drawing.Font($FontName, $fontSize, [System.Drawing.FontStyle]::Regular)
        } catch {
            Write-Warning "Font '$FontName' not available. Using default font."
            $font = New-Object System.Drawing.Font("Courier New", $fontSize, [System.Drawing.FontStyle]::Regular)
        }
        
        # Text colors
        $labelBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 180, 180, 190))
        $valueBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
        $watermarkBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(80, 255, 255, 255))
        
        # Calculate positions
        $leftMargin   = [int]($Resolution.Width * 0.05)
        $topMargin    = [int]($Resolution.Height * 0.15)
        $colGap       = 20
        $rightMargin  = [int]($Resolution.Width * 0.05)
        $linePad      = 6
        $labelWidth   = 300
        $textWidth    = [int]($Resolution.Width - $leftMargin - $rightMargin - $labelWidth - $colGap)

        # Ensure fonts exist and sizes are numeric
        $FontSize = [float]$FontSize
        try {
            $font      = New-Object System.Drawing.Font($FontName, $FontSize, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
            $labelFont = New-Object System.Drawing.Font($FontName, $FontSize, [System.Drawing.FontStyle]::Bold,    [System.Drawing.GraphicsUnit]::Pixel)
        } catch {
            $font      = New-Object System.Drawing.Font("Consolas", $FontSize, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
            $labelFont = New-Object System.Drawing.Font("Consolas", $FontSize, [System.Drawing.FontStyle]::Bold,    [System.Drawing.GraphicsUnit]::Pixel)
        }

        $labelBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235,235,235))
        $textBrush  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(240,240,240))

        # String formatting with wrapping
        $stringFormat               = New-Object System.Drawing.StringFormat
        $stringFormat.Trimming      = [System.Drawing.StringTrimming]::EllipsisCharacter
        $stringFormat.FormatFlags   = 0

        function Write-KeyValueRow {
            param(
                [System.Drawing.Graphics]$g,
                [string]$Key,
                [object]$Value,
                [ref]$Y
            )
            $labelText = "${Key}:"

            # Normalize value to string (handle arrays/multiple values)
            if ($null -eq $Value) {
                $valueText = ""
            } elseif ($Value -is [System.Array]) {
                $valueText = ($Value | ForEach-Object { $_ -as [string] } | Where-Object { $_ } ) -join [Environment]::NewLine
            } else {
                $valueText = [string]$Value
            }

            # Measure with constrained widths
            $labelSize = $g.MeasureString($labelText, $labelFont, [int]$labelWidth, $stringFormat)
            $valueSize = $g.MeasureString($valueText, $font,      [int]$textWidth,  $stringFormat)
            $rowHeight = [math]::Ceiling([math]::Max($labelSize.Height, $valueSize.Height))

            # Draw into rectangles
            $labelRect = New-Object System.Drawing.RectangleF([float]$leftMargin, [float]$Y.Value, [float]$labelWidth, [float]$rowHeight)
            $valueRect = New-Object System.Drawing.RectangleF([float]($leftMargin + $labelWidth + $colGap), [float]$Y.Value, [float]$textWidth, [float]$rowHeight)

            $g.DrawString($labelText, $labelFont, $labelBrush, $labelRect, $stringFormat)
            $g.DrawString($valueText, $font,      $textBrush,  $valueRect, $stringFormat)

            $Y.Value = [int]([math]::Ceiling($Y.Value + $rowHeight + $linePad))
        }

        # Draw system info (ordered list if available)
        $orderedKeys = @(
            "OS Version","OS","OS Arch","OS Name","IP Address","Device Name","Timestamp"
        ) | Where-Object { $SystemInfo.ContainsKey($_) }

        if (-not $orderedKeys -or $orderedKeys.Count -eq 0) {
            $orderedKeys = $SystemInfo.Keys
        }

        $yRef = [ref][int]$topMargin
        foreach ($key in $orderedKeys) {
            Write-KeyValueRow -g $graphics -Key $key -Value ($SystemInfo[$key]) -Y $yRef
        }


        # Draw watermark
        try {
            $watermarkFont = New-Object System.Drawing.Font($FontName, 10, [System.Drawing.FontStyle]::Italic)
        } catch {
            $watermarkFont = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Italic)
        }
        
        $watermarkText = "SysStamp • $OutputPath"
        $watermarkSize = $graphics.MeasureString($watermarkText, $watermarkFont)
        $watermarkX = $Resolution.Width - $watermarkSize.Width - 20
        $watermarkY = $Resolution.Height - $watermarkSize.Height - 20
        $graphics.DrawString($watermarkText, $watermarkFont, $watermarkBrush, $watermarkX, $watermarkY)
        
        # Save the image
        $directory = [System.IO.Path]::GetDirectoryName($OutputPath)
        if (-not (Test-Path $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            Write-VerboseLog "Created directory: $directory"
        }
        
        $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
        Write-VerboseLog "Image saved to: $OutputPath"
        
        # Optionally save as PNG
        $pngPath = $OutputPath -replace '\.bmp$', '.png'
        if ($pngPath -ne $OutputPath) {
            $bitmap.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
            Write-VerboseLog "PNG copy saved to: $pngPath"
        }
        
        # Cleanup
        $watermarkFont.Dispose()
        $watermarkBrush.Dispose()
        $valueBrush.Dispose()
        $labelBrush.Dispose()
        $font.Dispose()
        $brush.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
        
        return $true
        
    } catch {
        Write-Error "Failed to create image: $_"
        return $false
    }
}

function Set-DesktopWallpaper {
    <#
    .SYNOPSIS
        Sets the desktop wallpaper using Windows API.
    #>
    param([string]$ImagePath)
    
    Write-VerboseLog "Setting desktop wallpaper..."
    
    try {
        # Define the SystemParametersInfo function
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Wallpaper {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
    
    public const int SPI_SETDESKWALLPAPER = 20;
    public const int SPIF_UPDATEINIFILE = 1;
    public const int SPIF_SENDCHANGE = 2;
}
"@ -ErrorAction SilentlyContinue
        
        # Set registry values for wallpaper style
        $regPath = "HKCU:\Control Panel\Desktop"
        Set-ItemProperty -Path $regPath -Name WallpaperStyle -Value 10 -Type String -Force  # Fill
        Set-ItemProperty -Path $regPath -Name TileWallpaper -Value 0 -Type String -Force    # No tile
        
        Write-VerboseLog "Registry values updated (WallpaperStyle=10, TileWallpaper=0)"
        
        # Convert to absolute path
        $absolutePath = [System.IO.Path]::GetFullPath($ImagePath)
        
        # Set wallpaper
        $result = [Wallpaper]::SystemParametersInfo(
            [Wallpaper]::SPI_SETDESKWALLPAPER,
            0,
            $absolutePath,
            [Wallpaper]::SPIF_UPDATEINIFILE -bor [Wallpaper]::SPIF_SENDCHANGE
        )
        
        if ($result -eq 0) {
            $lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-Warning "SystemParametersInfo returned 0. Last Win32 error: $lastError"
            
            # Try alternative method
            Write-VerboseLog "Attempting alternative wallpaper update method..."
            Start-Process -FilePath "RUNDLL32.EXE" -ArgumentList "user32.dll,UpdatePerUserSystemParameters" -NoNewWindow -Wait
        } else {
            Write-VerboseLog "Wallpaper set successfully"
        }
        
        return $true
        
    } catch {
        Write-Error "Failed to set wallpaper: $_"
        return $false
    }
}

#endregion

#region Main Execution

try {
    Write-Host "`n=== SysStamp Wallpaper Generator ===" -ForegroundColor Green
    Write-Host "Generating system information wallpaper...`n" -ForegroundColor White
    
    # Collect system information
    $systemInfo = Get-SystemInformation
    
    # Display collected information
    Write-Host "System Information:" -ForegroundColor Yellow
    foreach ($key in $systemInfo.Keys) {
        Write-Host "  ${key}: $($systemInfo[$key])" -ForegroundColor Gray
    }
    Write-Host ""
    
    # Get screen resolution
    $resolution = Get-ScreenResolution
    Write-Host "Resolution: $($resolution.Width) x $($resolution.Height)" -ForegroundColor Cyan
    Write-Host "Font: $FontName" -ForegroundColor Cyan
    Write-Host ""
    
    # Create the image
    $imageCreated = New-SystemInfoImage -SystemInfo $systemInfo -Resolution $resolution -FontName $FontName -OutputPath $OutputPath
    
    if (-not $imageCreated) {
        Write-Error "Failed to create wallpaper image"
        exit 1
    }
    
    Write-Host "✓ Wallpaper image created: $OutputPath" -ForegroundColor Green
    
    # Preview if requested
    if ($Preview) {
        Write-Host "Opening image preview..." -ForegroundColor Yellow
        Start-Process $OutputPath
    }
    
    # Set wallpaper unless DryRun
    if (-not $DryRun) {
        $wallpaperSet = Set-DesktopWallpaper -ImagePath $OutputPath
        
        if ($wallpaperSet) {
            Write-Host "✓ Desktop wallpaper updated successfully!" -ForegroundColor Green
        } else {
            Write-Warning "Wallpaper may not have updated immediately. Try logging out and back in."
        }
    } else {
        Write-Host "DryRun mode: Wallpaper NOT set (image generated only)" -ForegroundColor Yellow
    }
    
    Write-Host "`nOperation completed successfully!`n" -ForegroundColor Green
    exit 0
    
} catch {
    Write-Error "Script execution failed: $_"
    Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Ensure you're running PowerShell 5.1 or later" -ForegroundColor Gray
    Write-Host "  2. Check that .NET Framework is installed" -ForegroundColor Gray
    Write-Host "  3. Verify write permissions to $OutputPath" -ForegroundColor Gray
    Write-Host "  4. Try running with -Verbose for detailed output" -ForegroundColor Gray
    exit 1
}

#endregion