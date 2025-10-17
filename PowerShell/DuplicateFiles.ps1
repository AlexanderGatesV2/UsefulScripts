<#
.SYNOPSIS
    Duplicates a specified file multiple times and optionally modifies each copy to produce unique file hashes (“hash-busting”).

.DESCRIPTION
    This script creates one or more copies of a given file. It verifies that the original file exists,
    then duplicates it into the same directory with sequential numbering. 
    If the -h switch is used, a unique GUID string is appended to each copy’s content to ensure
    each resulting file has a distinct hash (useful for testing or hash-busting scenarios).

.PARAMETER FilePath
    Path to the original file to duplicate.

.PARAMETER n
    Number of copies to create. Defaults to 1.

.PARAMETER h
    Optional switch to enable hash-busting (adds a unique string to each file).

.EXAMPLE
    .\DuplicateFile.ps1 -FilePath "C:\Temp\sample.txt" -n 3
    Creates three copies: sample_1.txt, sample_2.txt, and sample_3.txt.

.EXAMPLE
    .\DuplicateFile.ps1 -FilePath "C:\Temp\sample.txt" -n 3 -h
    Creates three copies with unique hashes (each copy has a different GUID appended).

.NOTES
    Author: Alexander Gates
    Compatible with: PowerShell 5.1+ and PowerShell 7+
#>

param (
    [string]$FilePath,
    [int]$n = 1, # Default number of copies is 1
    [switch]$h # Switch for hash-busting
)

# Check if the file path is valid
if (-not (Test-Path $FilePath)) {
    Write-Error "File path does not exist: $FilePath"
    exit 1
}

# Get the directory and file name from the path
$directory = [System.IO.Path]::GetDirectoryName($FilePath)
$fileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
$fileExt = [System.IO.Path]::GetExtension($FilePath)

for ($i = 1; $i -le $n; $i++) {
    # Create the new file path
    $newFilePath = "$directory\$fileName`_$i$fileExt"

    # Copy the file
    Copy-Item -Path $FilePath -Destination $newFilePath

    if ($h) {
        # Modify the file content to change its hash
        $fileContent = Get-Content -Path $newFilePath -Raw
        $uniqueString = [System.Guid]::NewGuid().ToString()
        $fileContent += $uniqueString # Append a unique string to the file content
        Set-Content -Path $newFilePath -Value $fileContent -Force

        Write-Host "Hash-busted file created: $newFilePath"
    } else {
        Write-Host "File copied: $newFilePath"
    }
}

Write-Output "$n copies of the file have been created."
