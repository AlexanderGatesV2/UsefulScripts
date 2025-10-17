<# 
.SYNOPSIS
  Creates N folders (file1 … fileN). In each folder, creates fileN.txt, fileN.bin, fileN.exe.
  • Within a single run: all .txt share a hash; all .bin share a hash; all .exe share a hash.
  • Across runs: hashes change (seeded by runtime timestamp + GUID).
#>

$ErrorActionPreference = 'Stop'

function Get-PositiveInt([string]$Prompt) {
    while ($true) {
        $raw = Read-Host $Prompt
        if ([int]::TryParse($raw, [ref]([int]$null))) {
            $n = [int]$raw
            if ($n -gt 0) { return $n }
        }
        Write-Host "Please enter a positive integer." -ForegroundColor Yellow
    }
}

[int]$count = Get-PositiveInt "How many files do you want to create?:"

# Base directory = where you ran the script
$baseDir = $PWD.Path

# ---------- Per-run seed (changes every execution) ----------
$runGuid  = [Guid]::NewGuid().ToString('N')
$runTime  = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffffffK"
$runStamp = "RunStamp=$runTime|GUID=$runGuid"
Write-Host "`nRun seed: $runStamp" -ForegroundColor DarkCyan
Write-Host "Creating nested sets in: $baseDir`n" -ForegroundColor Cyan

# ---------- Utilities ----------
function New-RepeatedBytes([byte[]]$pattern, [int]$length) {
    $out = New-Object byte[] $length
    for ($i = 0; $i -lt $length; $i++) {
        $out[$i] = $pattern[$i % $pattern.Length]
    }
    return $out
}

function Write-IdenticalTextFile([string]$FullPath, [string]$Content) {
    Set-Content -Path $FullPath -Value $Content -Encoding UTF8 -NoNewline -Force
}
function Write-IdenticalBinFile([string]$FullPath, [byte[]]$Bytes) {
    [System.IO.File]::WriteAllBytes($FullPath, $Bytes)
}
function Show-Hash([string]$FullPath, [string]$Algo = 'SHA256') {
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
        throw "Hash error: file not found -> $FullPath"
    }
    (Get-FileHash -Path $FullPath -Algorithm $Algo).Hash
}

# ---------- Per-run contents (derived from runStamp) ----------
# TXT: deterministic string using runStamp (identical across all TXT in this run)
$textContent = "Group=TXT|$runStamp|Note=All TXT files in this run share the same SHA256."

# BIN: 1024 bytes derived from SHA256("BIN|runStamp"), repeated to length (identical in-run, new across runs)
$binSeed   = [Text.Encoding]::UTF8.GetBytes("BIN|$runStamp")
$binHash   = [System.Security.Cryptography.SHA256]::Create().ComputeHash($binSeed)
$binBytes  = New-RepeatedBytes -pattern $binHash -length 1024

# EXE placeholder: 256 bytes starting with 'MZ', body derived from SHA256("EXE|runStamp")
$exeSeed   = [Text.Encoding]::UTF8.GetBytes("EXE|$runStamp")
$exeHash   = [System.Security.Cryptography.SHA256]::Create().ComputeHash($exeSeed)
$exeBytes  = New-Object byte[] 256
$exeBytes[0] = 0x4D; $exeBytes[1] = 0x5A   # 'M' 'Z' signature (not a valid PE)
# copy hash bytes after 'MZ' (keeps identical in-run, new across runs)
for ($i = 0; $i -lt [Math]::Min(254, $exeHash.Length); $i++) { $exeBytes[2 + $i] = $exeHash[$i] }

# ---------- Create structure ----------
for ($i = 1; $i -le $count; $i++) {
    $folderName = "file$($i)"
    $folderPath = Join-Path $baseDir $folderName
    New-Item -ItemType Directory -Force -Path $folderPath | Out-Null

    $txtPath = Join-Path $folderPath "file$($i).txt"
    $binPath = Join-Path $folderPath "file$($i).bin"
    $exePath = Join-Path $folderPath "file$($i).exe"

    Write-IdenticalTextFile -FullPath $txtPath -Content $textContent
    Write-IdenticalBinFile  -FullPath $binPath -Bytes $binBytes
    Write-IdenticalBinFile  -FullPath $exePath -Bytes $exeBytes

    Write-Host ("Created:`n  {0}`n  {1}`n  {2}" -f $txtPath, $binPath, $exePath)
}

# ---------- Verify representative hashes from file1 set ----------
$txtHash = Show-Hash (Join-Path $baseDir 'file1\file1.txt')
$binHashOut = Show-Hash (Join-Path $baseDir 'file1\file1.bin')
$exeHashOut = Show-Hash (Join-Path $baseDir 'file1\file1.exe')

Write-Host "`nVerification (representative files from file1):"
Write-Host ("  file1.txt  SHA256 = {0}" -f $txtHash)
Write-Host ("  file1.bin  SHA256 = {0}" -f $binHashOut)
Write-Host ("  file1.exe  SHA256 = {0}" -f $exeHashOut)

Write-Host "`nNotes:"
Write-Host " • Within this run: all .txt share a hash; all .bin share a hash; all .exe share a hash."
Write-Host " • Next run: hashes will differ because contents are seeded by timestamp+GUID."
