<#
.SYNOPSIS
    Compares the contents of two directories based on file names.

.DESCRIPTION
    This script takes two directory paths as input. It identifies files that
    are present in both directories, marking them as 'Found'. Files present
    only in the SourcePath are marked as 'Missing'. Files present only in
    the DestinationPath are marked as 'Added'.

.PARAMETER SourcePath
    The path to the first directory (reference directory) to compare.

.PARAMETER DestinationPath
    The path to the second directory (difference directory) to compare.

.EXAMPLE
    .\Compare-DirectoryContents.ps1 -SourcePath "C:\FolderA" -DestinationPath "C:\FolderB"

.NOTES
    -   'Found' indicates an item is present in both SourcePath and DestinationPath.
    -   'Missing' indicates an item is found only in SourcePath.
    -   'Added' indicates an item is found only in DestinationPath.
    -   This script compares items based solely on their relative paths (effectively, file names if comparing flat directories).
    -   It does not compare file contents, sizes, or modification times for determining 'Found' status.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourcePath,

    [Parameter(Mandatory=$true)]
    [string]$DestinationPath
)

function Compare-DirectoryContents {
    param(
        [string]$Path1,
        [string]$Path2
    )

    Write-Host "Comparing '$Path1' and '$Path2'..." -ForegroundColor Cyan

    # Ensure paths end with a backslash for consistent relative path calculation
    # Using Resolve-Path to get the full, canonical path and ensure it's a directory
    $Path1 = (Resolve-Path -Path $Path1 -ErrorAction Stop).Path
    $Path2 = (Resolve-Path -Path $Path2 -ErrorAction Stop).Path

    # Add a trailing backslash if not present, for consistent relative path calculation
    if (-not $Path1.EndsWith('\')) { $Path1 += '\' }
    if (-not $Path2.EndsWith('\')) { $Path2 += '\' }

    # Check if SourcePath exists (already handled by Resolve-Path -ErrorAction Stop, but good for clarity)
    if (-not (Test-Path -Path $Path1 -PathType Container)) {
        Write-Error "Error: Source directory '$Path1' does not exist."
        return
    }

    # Check if DestinationPath exists
    if (-not (Test-Path -Path $Path2 -PathType Container)) {
        Write-Error "Error: Destination directory '$Path2' does not exist."
        return
    }

    try {
        Write-Host "Getting items from '$Path1'..."
        # Get all items (files and directories) recursively from the source path
        # Create custom objects with a 'RelativePath' property
        $sourceItems = Get-ChildItem -Path $Path1 -Recurse | ForEach-Object {
            [PSCustomObject]@{
                RelativePath = $_.FullName.Replace($Path1, "")
            }
        }

        Write-Host "Getting items from '$Path2'..."
        # Get all items (files and directories) recursively from the destination path
        # Create custom objects with a 'RelativePath' property
        $destinationItems = Get-ChildItem -Path $Path2 -Recurse | ForEach-Object {
            [PSCustomObject]@{
                RelativePath = $_.FullName.Replace($Path2, "")
            }
        }

        Write-Host "--- Differences Found ---" -ForegroundColor Yellow

        # Compare the two collections of custom objects based on their RelativePath
        # Use -IncludeEqual to also get items that are common to both
        Compare-Object -ReferenceObject $sourceItems -DifferenceObject $destinationItems -Property RelativePath -IncludeEqual |
            Select-Object RelativePath, @{
                Name = 'Status';
                Expression = {
                    if ($_.SideIndicator -eq '<=') {
                        'Missing' # Present in SourcePath, not in DestinationPath
                    } elseif ($_.SideIndicator -eq '=>') {
                        'Added'   # Present in DestinationPath, not in SourcePath
                    } elseif ($_.SideIndicator -eq '==') {
                        'Found'   # Present in both SourcePath and DestinationPath
                    } else {
                        $_.SideIndicator # Fallback for any unexpected cases
                    }
                }
            } | Sort-Object RelativePath | Format-Table -AutoSize

        Write-Host "--- Comparison Complete ---" -ForegroundColor Yellow

    } catch {
        Write-Error "An error occurred during comparison: $($_.Exception.Message)"
    }
}

# Call the function with the provided parameters
Compare-DirectoryContents -Path1 $SourcePath -Path2 $DestinationPath
