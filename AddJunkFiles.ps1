<# 
.SYNOPSIS
Generates randomized junk files inside current-user browser cache directories for QA cleanup testing, and can remove them later.

.DESCRIPTION
Creates realistically distributed junk files (Edge, Chrome, Firefox profile cache2 directories) with:
 - Controlled total size (MB) split by distribution
 - Random file sizes within bounds
 - Optional subdirectory fan-out
 - Optional aged timestamps (backdated)
 - Deterministic mode via -Seed
 - Dry-run planning
 - Robust handling of missing paths, permissions, and disk space constraints

In add mode, no existing files are modified or deleted (only new files are added). In remove mode, only files with the configured Prefix are deleted. Missing cache roots are skipped (never created).

.PARAMETER TotalSizeMB
Approximate total size (in MB) to add across all target cache locations (before disk-space scaling).

.PARAMETER MinFileKB
Minimum per-file size in KB (default 8).

.PARAMETER MaxFileKB
Maximum per-file size in KB (default 4096).

.PARAMETER Distribution
Hashtable with keys Edge, Chrome, Firefox (values are fractional weights). Normalized automatically.
Firefox weight is split evenly across all discovered Firefox cache2 paths.

.PARAMETER Extensions
Array of file extensions to choose from randomly.

.PARAMETER FilesPerSubdir
If > 0, creates this many random subdirectories in each location and distributes files among them.

.PARAMETER TimestampAgesDaysMin
Minimum age in days to backdate timestamps (0 = now). Default 0.

.PARAMETER TimestampAgesDaysMax
Maximum age in days to backdate timestamps. If 0, no backdating. Default 120.

.PARAMETER Prefix
Filename prefix to make later cleanup easier (default ~junk_).

.PARAMETER DryRun
Compute and display plan only; do not create files.

.PARAMETER Seed
Deterministic run seed (affects sizes, names, extension choices, aging; file content still cryptographically random).

.PARAMETER Remove
Switches to removal mode: deletes files previously created by this script (identified by Prefix) in supported cache paths.

.PARAMETER RemoveEmptyDirs
When used with -Remove, attempts to prune now-empty subdirectories created during junk addition.

.EXAMPLE
.\New-BrowserJunk.ps1 -TotalSizeMB 250

.EXAMPLE
.\New-BrowserJunk.ps1 -TotalSizeMB 100 -Distribution @{ Edge=0.1; Chrome=0.7; Firefox=0.2 } -DryRun

.EXAMPLE
.\New-BrowserJunk.ps1 -TotalSizeMB 50 -MinFileKB 4 -MaxFileKB 256 -TimestampAgesDaysMin 30 -TimestampAgesDaysMax 365

.EXAMPLE
.\New-BrowserJunk.ps1 -TotalSizeMB 75 -Seed 12345 -Verbose

.NOTES
Intended for sandbox QA only. Generates real allocated bytes (no sparse/compressed tricks).
Requires PowerShell 5.1+. Run within the same user context whose caches you want to populate.
#>

#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Add')]
param(
    [Parameter(Mandatory=$true, ParameterSetName='Add')]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$TotalSizeMB,

    [ValidateRange(1, 1024*16)]
    [int]$MinFileKB = 8,

    [ValidateRange(1, 1024*1024)]
    [int]$MaxFileKB = 4096,

    [hashtable]$Distribution = @{ Edge = 0.34; Chrome = 0.33; Firefox = 0.33 },

    [string[]]$Extensions = @('.tmp','.dat','.bin','.cache','.part'),

    [ValidateRange(0,4096)]
    [int]$FilesPerSubdir = 0,

    [ValidateRange(0,5000)]
    [int]$TimestampAgesDaysMin = 0,

    [ValidateRange(0,5000)]
    [int]$TimestampAgesDaysMax = 120,

    [string]$Prefix = '~junk_',

    [switch]$DryRun,

    [int]$Seed,

    [Parameter(Mandatory=$true, ParameterSetName='Remove')]
    [switch]$Remove,

    [Parameter(ParameterSetName='Remove')]
    [switch]$RemoveEmptyDirs
)

Set-StrictMode -Version Latest

# Global deterministic random (structure decisions). Crypt RNG still for file bytes.
if ($PSBoundParameters.ContainsKey('Seed')) {
    Write-Verbose "Deterministic mode enabled with seed $Seed"
    $Global:__DetRand = New-Object System.Random($Seed)
} else {
    $Global:__DetRand = New-Object System.Random
}

function New-DeterministicGuid {
    # Generates deterministic GUID-like string (32 hex chars) using seeded Random
    $bytes = New-Object byte[] 16
    [void]$Global:__DetRand.NextBytes($bytes)
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Get-FirefoxCachePaths {
    [CmdletBinding()]
    param(
        [switch]$UseEntries
    )
    $paths = @()
    $local = Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'
    $roam  = Join-Path $env:APPDATA      'Mozilla\Firefox\Profiles'

    foreach ($root in @($local,$roam)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $c2 = Join-Path $_.FullName 'cache2'
            if (Test-Path -LiteralPath $c2) {
                if ($UseEntries) {
                    $entries = Join-Path $c2 'entries'
                    if (Test-Path -LiteralPath $entries) {
                        $paths += (Get-Item -LiteralPath $entries).FullName
                    } else {
                        Write-Verbose "Firefox 'entries' missing under $c2; using cache2 root"
                        $paths += (Get-Item -LiteralPath $c2).FullName
                    }
                } else {
                    $paths += (Get-Item -LiteralPath $c2).FullName
                }
            }
        }
    }
    # Ensure an array is always returned (even for 0 or 1 entries)
    return @($paths | Sort-Object -Unique)
}

function Get-Targets {
    [CmdletBinding()]
    param()
    $targets = [ordered]@{}
    # Determine OS architecture (not process arch)
    $is64 = [Environment]::Is64BitOperatingSystem

    # Base cache roots
    $edgeBase   = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache'
    $chromeBase = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache'

    # On x86 Windows, Chrome/Edge caches typically live under Cache\Cache_Data
    $edgeCandidates = if ($is64) { @($edgeBase) } else { @((Join-Path $edgeBase 'Cache_Data'), $edgeBase) }
    $chromeCandidates = if ($is64) { @($chromeBase) } else { @((Join-Path $chromeBase 'Cache_Data'), $chromeBase) }

    $edge = $null
    foreach ($c in $edgeCandidates) { if (Test-Path -LiteralPath $c) { $edge = $c; break } }
    $chrome = $null
    foreach ($c in $chromeCandidates) { if (Test-Path -LiteralPath $c) { $chrome = $c; break } }

    # Firefox: on x86 prefer cache2\entries if present
    if ($is64) {
        $ff = @(Get-FirefoxCachePaths)   # Force array to safely use .Count
    } else {
        $ff = @(Get-FirefoxCachePaths -UseEntries)
    }

    if ($edge)   { $targets['Edge']   = ,$edge } else { Write-Verbose "Edge cache missing: $edgeBase" }
    if ($chrome) { $targets['Chrome'] = ,$chrome } else { Write-Verbose "Chrome cache missing: $chromeBase" }
    if ($ff.Count -gt 0) { $targets['Firefox']=  $ff } else { Write-Verbose "No Firefox cache directories found." }

    if ($targets.Count -eq 0) {
        throw "No target cache directories found for current user."
    }
    return $targets
}

function Get-SizePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Targets,
        [Parameter(Mandatory)] [hashtable]$Distribution,
        [Parameter(Mandatory)] [int]$TotalSizeMB
    )

    # Normalize incoming distribution (only keys present in Targets)
    $relevantKeys = $Distribution.Keys | Where-Object { $Targets.Contains($_) }
    if (-not $relevantKeys) { throw "No overlapping distribution keys with discovered targets." }
    $sum = ($relevantKeys | ForEach-Object { [double]$Distribution[$_] }) | Measure-Object -Sum | Select-Object -ExpandProperty Sum
    if ($sum -le 0) { throw "Distribution weights sum to zero." }

    $normalized = @{}
    foreach ($k in $relevantKeys) {
        $normalized[$k] = [double]$Distribution[$k] / $sum
    }

    # Build per-location plan
    $oneMB = 1MB
    $totalBytes = [double]$TotalSizeMB * $oneMB
    $plan = @()
    foreach ($k in $Targets.Keys) {
        if (-not $normalized.ContainsKey($k)) { continue }
        $weight = $normalized[$k]
        $categoryBytes = $totalBytes * $weight
        $paths = $Targets[$k]

        if ($k -eq 'Firefox' -and $paths.Count -gt 0) {
            $perPath = $categoryBytes / $paths.Count
            foreach ($p in $paths) {
                $plan += [pscustomobject]@{
                    Category     = $k
                    Location     = $p
                    TargetBytes  = [long][math]::Round($perPath)
                    AdjustedBytes= 0L
                }
            }
        } else {
            foreach ($p in $paths) {
                $plan += [pscustomobject]@{
                    Category     = $k
                    Location     = $p
                    TargetBytes  = [long][math]::Round($categoryBytes)
                    AdjustedBytes= 0L
                }
            }
        }
    }

    # Disk space feasibility & scaling per drive
    $driveGroups = $plan | Group-Object {
        ([IO.Path]::GetPathRoot($_.Location)).TrimEnd('\')
    }

    $scalingFactor = 1.0
    foreach ($g in $driveGroups) {
        $drive = $g.Name
        $psd = Get-PSDrive -Name $drive.TrimEnd(':') -ErrorAction SilentlyContinue
        if (-not $psd) { Write-Warning "Drive $drive not found; skipping scaling check."; continue }
        $planned = ($g.Group | Measure-Object -Property TargetBytes -Sum).Sum
        if ($planned -le 0) { continue }
        $requiredWithBuffer = $planned * 1.05
        if ($requiredWithBuffer -gt $psd.Free) {
            $possibleFactor = ($psd.Free / 1.05) / $planned
            if ($possibleFactor -lt $scalingFactor) {
                $scalingFactor = [math]::Min($scalingFactor, $possibleFactor)
            }
        }
    }

    if ($scalingFactor -lt 1) {
        $pct = [math]::Round($scalingFactor*100,2)
        Write-Warning "Insufficient free space. Scaling total target to $pct% of requested."
        foreach ($row in $plan) {
            $row.TargetBytes = [long][math]::Floor($row.TargetBytes * $scalingFactor)
        }
    }

    return $plan
}

function Set-RandomTimestamps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo]$File,
        [int]$MinDays,
        [int]$MaxDays,
        [System.Random]$Rand
    )
    if ($MaxDays -le 0) { return }
    if ($MinDays -gt $MaxDays) { $tmp=$MinDays; $MinDays=$MaxDays; $MaxDays=$tmp }
    $span = $MaxDays - $MinDays
    $offsetDays = $MinDays + $Rand.NextDouble() * $span
    $dt = (Get-Date).AddDays(-$offsetDays)
    $File.CreationTimeUtc   = $dt.ToUniversalTime()
    $File.LastWriteTimeUtc  = $dt.ToUniversalTime()
    $File.LastAccessTimeUtc = $dt.ToUniversalTime()
}

function New-JunkFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][long]$SizeBytes,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string[]]$Extensions,
        [Parameter(Mandatory)][System.Random]$Rand,
        [switch]$Deterministic
    )
    if (-not (Test-Path -LiteralPath $Directory)) {
        throw "Target directory disappeared: $Directory"
    }

    # Pick extension
    $countExt = $Extensions.Length
    if ($countExt -le 0) { throw "No extensions provided." }
    $ext = $Extensions[ $Rand.Next(0, $countExt) ]

    # Name parts (deterministic GUID if requested)
    $guidPart = if ($Deterministic) { 
        New-DeterministicGuid 
    } else { 
        [guid]::NewGuid().ToString('N') 
    }
    $randNum  = $Rand.Next(0,10000)
    $name = "$Prefix$guidPart`_$randNum$ext"
    $full = Join-Path $Directory $name

    # Ensure uniqueness (few retries)
    for ($attempt=0; $attempt -lt 5 -and (Test-Path -LiteralPath $full); $attempt++) {
        $randNum  = $Rand.Next(0,10000)
        $name = "$Prefix$guidPart`_$randNum$ext"
        $full = Join-Path $Directory $name
    }

    $bufferSize = 8192
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $fs = [System.IO.File]::Open($full,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
        try {
            $remaining = $SizeBytes
            $buffer = New-Object byte[] $bufferSize
            while ($remaining -gt 0) {
                $chunk = [int][math]::Min($bufferSize, $remaining)
                if ($chunk -ne $buffer.Length) {
                    $buffer = New-Object byte[] $chunk
                }
                $rng.GetBytes($buffer)
                $fs.Write($buffer,0,$chunk)
                $remaining -= $chunk
            }
        } finally {
            $fs.Dispose()
        }
    } finally {
        $rng.Dispose()
    }
    return Get-Item -LiteralPath $full
}

function Write-Summary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Data,
        [switch]$PlanOnly
    )
    $label = if ($PlanOnly) { "PLAN (no files created)" } else { "RESULTS" }
    Write-Host ""
    Write-Host "=== $label ===" -ForegroundColor Cyan
    $display = $Data | Select-Object Location, FilesCreated, BytesAdded, @{n='MBAdded';e={[math]::Round($_.BytesAdded/1MB,2)}}

    $padLoc = [Math]::Max(8, ($display | ForEach-Object { $_.Location.Length } | Measure-Object -Maximum).Maximum)
    $header = "{0}  {1,8}  {2,12}  {3,8}" -f ("Location".PadRight($padLoc)), "Files", "BytesAdded", "MBAdded"
    Write-Host $header
    Write-Host ("-" * $header.Length)

    foreach ($row in $display) {
        $line = "{0}  {1,8}  {2,12}  {3,8:N2}" -f ($row.Location.PadRight($padLoc)), $row.FilesCreated, $row.BytesAdded, $row.MBAdded
        Write-Host $line
    }

    $totFiles = ($display | Measure-Object -Property FilesCreated -Sum).Sum
    $totBytes = ($display | Measure-Object -Property BytesAdded -Sum).Sum
    $totMB = [math]::Round($totBytes/1MB,2)
    Write-Host ("-" * $header.Length)
    Write-Host ("TOTAL".PadRight($padLoc) + ("  {0,8}  {1,12}  {2,8:N2}" -f $totFiles, $totBytes, $totMB)) -ForegroundColor Yellow
}

# Removal helpers defined before main execution so they are available when called
function Write-RemovalSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Data,
        [switch]$PlanOnly
    )
    $label = if ($PlanOnly) { "PLAN (no deletions)" } else { "REMOVAL RESULTS" }
    Write-Host ""
    Write-Host "=== $label ===" -ForegroundColor Cyan

    if ($PlanOnly) {
        $display = $Data | Select-Object Location, @{n='FilesRemoved';e={$_.PlanFiles}}, @{n='BytesReclaimed';e={$_.PlanBytes}}, @{n='MBReclaimed';e={[math]::Round($_.PlanBytes/1MB,2)}}
    } else {
        $display = $Data | Select-Object Location, FilesRemoved, BytesReclaimed, @{n='MBReclaimed';e={[math]::Round($_.BytesReclaimed/1MB,2)}}
    }

    $padLoc = [Math]::Max(8, ($display | ForEach-Object { $_.Location.Length } | Measure-Object -Maximum).Maximum)
    $header = "{0}  {1,12}  {2,14}  {3,11}" -f ("Location".PadRight($padLoc)), "FilesRemoved", "BytesReclaimed", "MBReclaimed"
    Write-Host $header
    Write-Host ("-" * $header.Length)

    foreach ($row in $display) {
        $line = "{0}  {1,12}  {2,14}  {3,11:N2}" -f ($row.Location.PadRight($padLoc)), $row.FilesRemoved, $row.BytesReclaimed, $row.MBReclaimed
        Write-Host $line
    }

    $totFiles = ($display | Measure-Object -Property FilesRemoved -Sum).Sum
    $totBytes = ($display | Measure-Object -Property BytesReclaimed -Sum).Sum
    $totMB = [math]::Round($totBytes/1MB,2)
    Write-Host ("-" * $header.Length)
    Write-Host ("TOTAL".PadRight($padLoc) + ("  {0,12}  {1,14}  {2,11:N2}" -f $totFiles, $totBytes, $totMB)) -ForegroundColor Yellow
}

function Remove-JunkFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Locations,
        [Parameter(Mandatory)][string]$Prefix,
        [switch]$DryRun,
        [switch]$RemoveEmptyDirs
    )

    $results = @()
    foreach ($loc in $Locations) {
        if (-not (Test-Path -LiteralPath $loc)) {
            Write-Verbose "Removal: location missing, skipping: $loc"
            $results += [pscustomobject]@{ Location=$loc; FilesRemoved=0; BytesReclaimed=0 }
            continue
        }

        $files = @(Get-ChildItem -LiteralPath $loc -Recurse -File -ErrorAction SilentlyContinue -Filter ("{0}*" -f $Prefix))
        if ($files.Count -eq 0) {
            $results += [pscustomobject]@{ Location=$loc; FilesRemoved=0; BytesReclaimed=0 }
            continue
        }

        $m = $files | Measure-Object -Property Length -Sum
    $bytes = if ($m -and $null -ne $m.Sum) { [long]$m.Sum } else { 0L }
        $removed = 0
        $reclaimed = 0L

        if ($DryRun) {
            $results += [pscustomobject]@{ Location=$loc; FilesRemoved=0; BytesReclaimed=0; PlanFiles=$files.Count; PlanBytes=[long]$bytes }
            continue
        }

        foreach ($f in $files) {
            try {
                $size = $f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $removed++
                $reclaimed += $size
            } catch [System.UnauthorizedAccessException] {
                Write-Warning "Permission denied deleting: $($f.FullName)"
            } catch {
                Write-Warning "Error deleting $($f.FullName): $($_.Exception.Message)"
            }
        }

        if ($RemoveEmptyDirs) {
            try {
                # Remove empty directories bottom-up
                Get-ChildItem -LiteralPath $loc -Recurse -Directory -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending |
                    ForEach-Object {
                        try {
                            if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                            }
                        } catch { }
                    }
            } catch { }
        }

        $results += [pscustomobject]@{ Location=$loc; FilesRemoved=$removed; BytesReclaimed=$reclaimed }
    }

    return $results
}
# MAIN EXECUTION
try {
    $targets = Get-Targets

    if ($MinFileKB -gt $MaxFileKB) {
        $swap=$MinFileKB; $MinFileKB=$MaxFileKB; $MaxFileKB=$swap
    }

    if ($TimestampAgesDaysMax -lt $TimestampAgesDaysMin) {
        $tmp=$TimestampAgesDaysMin; $TimestampAgesDaysMin=$TimestampAgesDaysMax; $TimestampAgesDaysMax=$tmp
    }

    # Removal mode: delete previously added junk files by Prefix across known locations
    if ($PSCmdlet.ParameterSetName -eq 'Remove') {
        # Build candidate locations from discovered targets, plus alternative subpaths to catch prior runs
        $edgeBase   = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache'
        $chromeBase = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache'
        $ffRoots    = @(Get-FirefoxCachePaths)
        $ffEntries  = @(Get-FirefoxCachePaths -UseEntries)

        $locations = @()
        foreach ($kv in $targets.GetEnumerator()) { $locations += $kv.Value }
        foreach ($cand in @($edgeBase, (Join-Path $edgeBase 'Cache_Data'), $chromeBase, (Join-Path $chromeBase 'Cache_Data'))) {
            if ($cand -and (Test-Path -LiteralPath $cand)) { $locations += (Get-Item -LiteralPath $cand).FullName }
        }
        $locations += $ffRoots
        $locations += $ffEntries
        $locList = @($locations | Where-Object { $_ } | Sort-Object -Unique)

        if ($DryRun) {
            $preview = @()
            foreach ($loc in $locList) {
                if (-not (Test-Path -LiteralPath $loc)) { continue }
                $files = @(Get-ChildItem -LiteralPath $loc -Recurse -File -ErrorAction SilentlyContinue -Filter ("{0}*" -f $Prefix))
                $m = $files | Measure-Object -Property Length -Sum
                $sum = if ($m -and $null -ne $m.Sum) { [long]$m.Sum } else { 0L }
                $preview += [pscustomobject]@{
                    Location       = $loc
                    PlanFiles      = $files.Count
                    PlanBytes      = [long]$sum
                }
            }
            Write-RemovalSummary -Data $preview -PlanOnly
            return $preview
        }

        $remResults = Remove-JunkFiles -Locations $locList -Prefix $Prefix -RemoveEmptyDirs:$RemoveEmptyDirs -DryRun:$false
        Write-RemovalSummary -Data $remResults
        return $remResults
    }

    $plan = Get-SizePlan -Targets $targets -Distribution $Distribution -TotalSizeMB $TotalSizeMB

    # Prepare subdirectories if requested
    $subdirMaps = @{}
    if ($FilesPerSubdir -gt 0) {
        foreach ($row in $plan) {
            $loc = $row.Location
            $subs = @()
            for ($i=0; $i -lt $FilesPerSubdir; $i++) {
                $subName = "{0:x}" -f $Global:__DetRand.Next(0,0xFFFF)
                $subPath = Join-Path $loc $subName
                if (-not (Test-Path -LiteralPath $subPath)) {
                    try {
                        New-Item -ItemType Directory -LiteralPath $subPath -ErrorAction Stop | Out-Null
                    } catch {
                        Write-Warning "Failed to create subdirectory $subPath : $_"
                        continue
                    }
                }
                $subs += $subPath
            }
            if ($subs.Count -gt 0) { $subdirMaps[$loc] = $subs }
        }
    }

    if ($DryRun) {
        # Produce zero file summary as a plan preview (include TargetMB)
        $preview = foreach ($row in $plan) {
            [pscustomobject]@{
                Location     = $row.Location
                FilesCreated = 0
                BytesAdded   = 0
                TargetMB     = [math]::Round($row.TargetBytes/1MB,2)
            }
        }
        Write-Summary -Data $preview -PlanOnly
        return $preview
    }

    $results = @()
    $deterministicRun = $PSBoundParameters.ContainsKey('Seed')
    foreach ($row in $plan) {
        $location = $row.Location
        $targetBytes = $row.TargetBytes
        if ($targetBytes -le 0) {
            Write-Verbose "Skipping $location (0 target bytes after scaling)."
            $results += [pscustomobject]@{ Location=$location; FilesCreated=0; BytesAdded=0 }
            continue
        }
        if (-not (Test-Path -LiteralPath $location)) {
            Write-Warning "Location missing at execution time, skipping: $location"
            $results += [pscustomobject]@{ Location=$location; FilesCreated=0; BytesAdded=0 }
            continue
        }

        $bytesWritten = 0L
        $files = 0
        $oneMB = 1MB
        Write-Verbose ("Starting writes for {0} target {1:N2} MB" -f $location, ($targetBytes/$oneMB))
        while ($bytesWritten -lt $targetBytes) {
            $sizeKB = $MinFileKB + [int]($Global:__DetRand.NextDouble() * (($MaxFileKB - $MinFileKB)+1))
            if ($sizeKB -lt $MinFileKB) { $sizeKB = $MinFileKB }
            if ($sizeKB -gt $MaxFileKB) { $sizeKB = $MaxFileKB }
            $sizeBytes = [long]$sizeKB * 1KB

            $destDir = $location
            if ($subdirMaps.ContainsKey($location) -and $subdirMaps[$location].Count -gt 0) {
                $dirs = $subdirMaps[$location]
                $destDir = $dirs[ $Global:__DetRand.Next(0,$dirs.Count) ]
            }

            try {
                if ($deterministicRun) {
                    $file = New-JunkFile -Directory $destDir -SizeBytes $sizeBytes -Prefix $Prefix -Extensions $Extensions -Rand $Global:__DetRand -Deterministic
                } else {
                    $file = New-JunkFile -Directory $destDir -SizeBytes $sizeBytes -Prefix $Prefix -Extensions $Extensions -Rand $Global:__DetRand
                }

                if ($TimestampAgesDaysMax -gt 0) {
                    Set-RandomTimestamps -File $file -MinDays $TimestampAgesDaysMin -MaxDays $TimestampAgesDaysMax -Rand $Global:__DetRand
                }
                $bytesWritten += $file.Length
                $files++
            } catch [System.UnauthorizedAccessException] {
                Write-Warning "Permission denied writing in $destDir. Skipping further attempts in this location."
                break
            } catch {
                Write-Warning "Error creating file in ${destDir}: $($_.Exception.Message)"
                if ($files -eq 0) { break }
            }

            if ($files % 25 -eq 0) {
                Write-Verbose ("{0:u} {1} Files={2} MBWritten={3:N2}/{4:N2}" -f (Get-Date), $location, $files, ($bytesWritten/1MB), ($targetBytes/1MB))
            }
        }

        $results += [pscustomobject]@{
            Location     = $location
            FilesCreated = $files
            BytesAdded   = $bytesWritten
        }
    }

    Write-Summary -Data $results
    $results

} catch {
    Write-Error $_
    throw
}

function Write-RemovalSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Data,
        [switch]$PlanOnly
    )
    $label = if ($PlanOnly) { "PLAN (no deletions)" } else { "REMOVAL RESULTS" }
    Write-Host ""
    Write-Host "=== $label ===" -ForegroundColor Cyan

    if ($PlanOnly) {
        $display = $Data | Select-Object Location, @{n='FilesRemoved';e={$_.PlanFiles}}, @{n='BytesReclaimed';e={$_.PlanBytes}}, @{n='MBReclaimed';e={[math]::Round($_.PlanBytes/1MB,2)}}
    } else {
        $display = $Data | Select-Object Location, FilesRemoved, BytesReclaimed, @{n='MBReclaimed';e={[math]::Round($_.BytesReclaimed/1MB,2)}}
    }

    $padLoc = [Math]::Max(8, ($display | ForEach-Object { $_.Location.Length } | Measure-Object -Maximum).Maximum)
    $header = "{0}  {1,12}  {2,14}  {3,11}" -f ("Location".PadRight($padLoc)), "FilesRemoved", "BytesReclaimed", "MBReclaimed"
    Write-Host $header
    Write-Host ("-" * $header.Length)

    foreach ($row in $display) {
        $line = "{0}  {1,12}  {2,14}  {3,11:N2}" -f ($row.Location.PadRight($padLoc)), $row.FilesRemoved, $row.BytesReclaimed, $row.MBReclaimed
        Write-Host $line
    }

    $totFiles = ($display | Measure-Object -Property FilesRemoved -Sum).Sum
    $totBytes = ($display | Measure-Object -Property BytesReclaimed -Sum).Sum
    $totMB = [math]::Round($totBytes/1MB,2)
    Write-Host ("-" * $header.Length)
    Write-Host ("TOTAL".PadRight($padLoc) + ("  {0,12}  {1,14}  {2,11:N2}" -f $totFiles, $totBytes, $totMB)) -ForegroundColor Yellow
}

function Remove-JunkFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Locations,
        [Parameter(Mandatory)][string]$Prefix,
        [switch]$DryRun,
        [switch]$RemoveEmptyDirs
    )

    $results = @()
    foreach ($loc in $Locations) {
        if (-not (Test-Path -LiteralPath $loc)) {
            Write-Verbose "Removal: location missing, skipping: $loc"
            $results += [pscustomobject]@{ Location=$loc; FilesRemoved=0; BytesReclaimed=0 }
            continue
        }

        $files = @(Get-ChildItem -LiteralPath $loc -Recurse -File -ErrorAction SilentlyContinue -Filter ("{0}*" -f $Prefix))
        if ($files.Count -eq 0) {
            $results += [pscustomobject]@{ Location=$loc; FilesRemoved=0; BytesReclaimed=0 }
            continue
        }

    $m = $files | Measure-Object -Property Length -Sum
    $bytes = if ($m -and $null -ne $m.Sum) { [long]$m.Sum } else { 0L }
        $removed = 0
        $reclaimed = 0L

        if ($DryRun) {
            $results += [pscustomobject]@{ Location=$loc; FilesRemoved=0; BytesReclaimed=0; PlanFiles=$files.Count; PlanBytes=[long]$bytes }
            continue
        }

        foreach ($f in $files) {
            try {
                $size = $f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $removed++
                $reclaimed += $size
            } catch [System.UnauthorizedAccessException] {
                Write-Warning "Permission denied deleting: $($f.FullName)"
            } catch {
                Write-Warning "Error deleting $($f.FullName): $($_.Exception.Message)"
            }
        }

        if ($RemoveEmptyDirs) {
            try {
                # Remove empty directories bottom-up
                Get-ChildItem -LiteralPath $loc -Recurse -Directory -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending |
                    ForEach-Object {
                        try {
                            if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                            }
                        } catch { }
                    }
            } catch { }
        }

        $results += [pscustomobject]@{ Location=$loc; FilesRemoved=$removed; BytesReclaimed=$reclaimed }
    }

    return $results
}