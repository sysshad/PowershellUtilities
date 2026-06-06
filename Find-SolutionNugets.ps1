#Requires -Version 5.1
<#
.SYNOPSIS
    Scans Visual Studio 2022 solution files for specific NuGet dependencies,
    and optionally produces a wave-based upgrade order.

.PARAMETER SearchPath
    Root folder to search. Defaults to the current directory.

.PARAMETER NuGetPrefixes
    Package-name prefixes to match.
    Default: 'Microsoft.Extensions', 'System.Text'

.PARAMETER ShowUpgradeOrder
    Appends a per-solution wave-based upgrade plan after the project listing.

.EXAMPLE
    .\Find-SolutionNugets.ps1 -SearchPath "C:\Source"

.EXAMPLE
    .\Find-SolutionNugets.ps1 -SearchPath "C:\Source" -ShowUpgradeOrder
#>
[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]   $SearchPath    = (Get-Location).Path,

    [Parameter()]
    [string[]] $NuGetPrefixes = @('Microsoft.Extensions', 'System.Text'),

    [Parameter()]
    [switch]   $ShowUpgradeOrder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

function Test-PackagePrefix ([string]$Name) {
    foreach ($px in $NuGetPrefixes) {
        if ($Name.StartsWith($px, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

$script:DetailsCache = [System.Collections.Generic.Dictionary[string,object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

function Get-ProjectDetails ([string]$ProjectPath) {
    $norm = [System.IO.Path]::GetFullPath($ProjectPath)
    if ($script:DetailsCache.ContainsKey($norm)) { return $script:DetailsCache[$norm] }

    $out = [PSCustomObject]@{
        PackageRefs = [System.Collections.Generic.List[PSCustomObject]]::new()
        ProjectRefs = [System.Collections.Generic.List[string]]::new()
    }

    if (-not (Test-Path -LiteralPath $norm -PathType Leaf)) {
        Write-Verbose "Project file not found: $norm"
        $script:DetailsCache[$norm] = $out
        return $out
    }

    $dir = [System.IO.Path]::GetDirectoryName($norm)

    try {
        [xml]$xml = Get-Content -LiteralPath $norm -Raw -Encoding UTF8

        foreach ($node in $xml.SelectNodes('//PackageReference')) {
            $name = $node.GetAttribute('Include')
            if (-not $name) { continue }
            $ver = $node.GetAttribute('Version')
            if (-not $ver) {
                $vn = $node.SelectSingleNode('Version')
                if ($null -ne $vn) { $ver = $vn.InnerText.Trim() }
            }
            $out.PackageRefs.Add([PSCustomObject]@{ Name = $name.Trim(); Version = $ver })
        }

        $pkgCfg = Join-Path $dir 'packages.config'
        if (Test-Path -LiteralPath $pkgCfg -PathType Leaf) {
            try {
                [xml]$cfg = Get-Content -LiteralPath $pkgCfg -Raw -Encoding UTF8
                foreach ($node in $cfg.SelectNodes('//package')) {
                    $name = $node.GetAttribute('id')
                    if (-not $name) { continue }
                    $out.PackageRefs.Add([PSCustomObject]@{
                        Name    = $name.Trim()
                        Version = $node.GetAttribute('version')
                    })
                }
            }
            catch { Write-Verbose "Could not parse packages.config at '$pkgCfg': $_" }
        }

        foreach ($node in $xml.SelectNodes('//ProjectReference')) {
            $rel = $node.GetAttribute('Include')
            if ($rel) {
                $rel = $rel -replace '\\', [System.IO.Path]::DirectorySeparatorChar
                $out.ProjectRefs.Add(
                    [System.IO.Path]::GetFullPath(
                        [System.IO.Path]::Combine($dir, $rel)
                    )
                )
            }
        }
    }
    catch { Write-Warning "Could not parse '$norm': $_" }

    $script:DetailsCache[$norm] = $out
    return $out
}

$script:PkgCache = [System.Collections.Generic.Dictionary[string,object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

function Resolve-Packages {
    param(
        [string] $ProjectPath,
        [System.Collections.Generic.HashSet[string]] $Seen
    )

    $norm = [System.IO.Path]::GetFullPath($ProjectPath)
    if (-not $Seen.Add($norm)) {
        return [System.Collections.Generic.List[PSCustomObject]]::new()
    }
    if ($script:PkgCache.ContainsKey($norm)) { return $script:PkgCache[$norm] }

    $details = Get-ProjectDetails -ProjectPath $norm
    $list    = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($pkg in $details.PackageRefs) {
        $list.Add([PSCustomObject]@{
            Name       = $pkg.Name
            Version    = $pkg.Version
            SourcePath = $norm
        })
    }
    foreach ($ref in $details.ProjectRefs) {
        foreach ($pkg in @(Resolve-Packages -ProjectPath $ref -Seen $Seen)) {
            $list.Add($pkg)
        }
    }

    $script:PkgCache[$norm] = $list
    return $list
}

function Get-SlnProjects ([string]$SlnPath) {
    $slnDir    = [System.IO.Path]::GetDirectoryName($SlnPath)
    $content   = Get-Content -LiteralPath $SlnPath -Raw
    $validExts = @('.csproj', '.vbproj', '.fsproj', '.vcxproj', '.shproj', '.sqlproj')
    $list      = [System.Collections.Generic.List[PSCustomObject]]::new()

    $rxPattern = @'
Project\("\{[^}]+\}"\)\s*=\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"\{[^}]+\}"
'@
    $rx = [regex]$rxPattern.Trim()

    foreach ($m in $rx.Matches($content)) {
        $rel = $m.Groups[2].Value -replace '\\', [System.IO.Path]::DirectorySeparatorChar
        if ([System.IO.Path]::GetExtension($rel) -notin $validExts) { continue }
        $list.Add([PSCustomObject]@{
            Name = $m.Groups[1].Value
            Path = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($slnDir, $rel)
            )
        })
    }
    return $list
}

function Get-UpgradeOrder {
    param ([object[]] $Projects)

    $pathToName = @{}
    $inDegree   = @{}
    $revDeps    = @{}

    foreach ($p in $Projects) {
        if (-not $p.ProjectPath) { continue }
        $norm = [System.IO.Path]::GetFullPath($p.ProjectPath)
        $pathToName[$norm] = $p.ProjectName
        $inDegree[$norm]   = 0
        $revDeps[$norm]    = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($p in $Projects) {
        if (-not $p.ProjectPath) { continue }
        $norm    = [System.IO.Path]::GetFullPath($p.ProjectPath)
        $details = Get-ProjectDetails -ProjectPath $norm

        foreach ($ref in $details.ProjectRefs) {
            $refNorm = [System.IO.Path]::GetFullPath($ref)
            if ($pathToName.ContainsKey($refNorm)) {
                $inDegree[$norm]++
                $revDeps[$refNorm].Add($norm)
            }
        }
    }

    $waves = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()

    foreach ($key in $inDegree.Keys) {
        if ($inDegree[$key] -eq 0) { $queue.Enqueue($key) }
    }

    while ($queue.Count -gt 0) {
        $waveSize = $queue.Count
        $wave     = [System.Collections.Generic.List[string]]::new()

        for ($i = 0; $i -lt $waveSize; $i++) {
            $cur = $queue.Dequeue()
            $wave.Add($cur)
            foreach ($dep in @($revDeps[$cur])) {
                $inDegree[$dep]--
                if ($inDegree[$dep] -eq 0) { $queue.Enqueue($dep) }
            }
        }
        if ($wave.Count -gt 0) { $waves.Add([string[]]$wave) }
    }

    return [PSCustomObject]@{
        Waves        = $waves
        PathToName   = $pathToName
        Unresolvable = @($inDegree.Keys | Where-Object { $inDegree[$_] -gt 0 })
    }
}

# ---------------------------------------------------------------------------
# MAIN  -  Phase 1: collect
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Search root    : $SearchPath"                  -ForegroundColor Cyan
Write-Host "NuGet prefixes : $($NuGetPrefixes -join ', ')" -ForegroundColor Cyan
if ($ShowUpgradeOrder) {
    Write-Host "Upgrade order  : enabled"                  -ForegroundColor Cyan
}
Write-Host ""

$slnFiles = @(
    Get-ChildItem -LiteralPath $SearchPath -Filter '*.sln' -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object FullName
)

if ($slnFiles.Count -eq 0) {
    Write-Host "No .sln files found under '$SearchPath'." -ForegroundColor Yellow
    exit
}

Write-Host "Found $($slnFiles.Count) solution(s). Scanning..." -ForegroundColor Green
Write-Host ""

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

for ($si = 0; $si -lt $slnFiles.Count; $si++) {
    $sln    = $slnFiles[$si]
    $pct    = [int](($si / $slnFiles.Count) * 100)
    $status = "($($si+1)/$($slnFiles.Count)) $($sln.Name)"
    Write-Progress -Activity 'Scanning solutions' -Status $status -PercentComplete $pct

    $projList    = @(Get-SlnProjects -SlnPath $sln.FullName)
    $projResults = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($proj in $projList) {
        $seen     = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $allPkgs  = @(Resolve-Packages -ProjectPath $proj.Path -Seen $seen)
        $projNorm = [System.IO.Path]::GetFullPath($proj.Path)

        $matching = @(
            $allPkgs |
            Where-Object { Test-PackagePrefix $_.Name } |
            Group-Object -Property Name |
            ForEach-Object {
                $direct  = $_.Group |
                    Where-Object { $_.SourcePath -eq $projNorm } |
                    Select-Object -First 1
                $chosen  = if ($null -ne $direct) { $direct } else { $_.Group | Select-Object -First 1 }
                $srcName = [System.IO.Path]::GetFileNameWithoutExtension($chosen.SourcePath)
                [PSCustomObject]@{
                    Name    = $chosen.Name
                    Version = if ($chosen.Version) { $chosen.Version } else { '(unknown)' }
                    Source  = if ($null -ne $direct) { 'Direct' } else { "via $srcName" }
                }
            } |
            Sort-Object Name
        )

        $projResults.Add([PSCustomObject]@{
            ProjectName = $proj.Name
            ProjectPath = $proj.Path
            Exists      = Test-Path -LiteralPath $proj.Path -PathType Leaf
            NuGets      = $matching
        })
    }

    $results.Add([PSCustomObject]@{
        SolutionName = $sln.Name
        SolutionPath = $sln.FullName
        Projects     = $projResults
    })
}

Write-Progress -Activity 'Scanning solutions' -Completed

# ---------------------------------------------------------------------------
# Phase 2: display
# ---------------------------------------------------------------------------

$divOuter = '=' * 90
$divInner = '-' * 70
$pkgFmt   = "           {0,-50} {1,-15} {2}"
$pkgSep   = "           " + ("-" * 50) + "  " + ("-" * 15) + "  " + ("-" * 20)

$printedCount = 0

foreach ($sol in $results) {

    # FIX: @() ensures .Count is always valid under Set-StrictMode -Version Latest
    $affectedCount = @($sol.Projects | Where-Object { $_.NuGets.Count -gt 0 }).Count
    if ($affectedCount -eq 0) { continue }

    $printedCount++
    $projCount = $sol.Projects.Count

    # --- Solution header (printed exactly once per matching solution) ------
    Write-Host ""
    Write-Host $divOuter                                 -ForegroundColor Cyan
    Write-Host "  SOLUTION  : $($sol.SolutionName)"     -ForegroundColor Green
    Write-Host "  PATH      : $($sol.SolutionPath)"     -ForegroundColor DarkGreen
    Write-Host "  PROJECTS  : $projCount total, $affectedCount with matching NuGets" `
                                                         -ForegroundColor DarkGreen
    Write-Host $divOuter                                 -ForegroundColor Cyan

    # --- One block per project, indented under the solution ----------------
    for ($pi = 0; $pi -lt $projCount; $pi++) {
        $proj  = $sol.Projects[$pi]
        $index = "[$($pi+1)/$projCount]"
        $flag  = if (-not $proj.Exists) { '  [FILE NOT FOUND]' } else { '' }

        Write-Host ""
        Write-Host ("  $index $($proj.ProjectName)$flag") -ForegroundColor Yellow
        Write-Host ("         Path : $($proj.ProjectPath)") -ForegroundColor DarkYellow

        if ($proj.NuGets.Count -eq 0) {
            Write-Host "         NuGets : (none matching filter)" -ForegroundColor Gray
        }
        else {
            Write-Host $pkgSep -ForegroundColor DarkGray
            Write-Host ($pkgFmt -f 'Package', 'Version', 'Source') -ForegroundColor Cyan
            Write-Host $pkgSep -ForegroundColor DarkGray

            foreach ($pkg in $proj.NuGets) {
                $tag = if ($pkg.Source -eq 'Direct') { '[+]' } else { '[~]' }
                $col = if ($pkg.Source -eq 'Direct') { 'White' } else { 'DarkCyan' }
                Write-Host ($pkgFmt -f "$tag $($pkg.Name)", $pkg.Version, $pkg.Source) -ForegroundColor $col
            }
        }

        if ($pi -lt ($projCount - 1)) {
            Write-Host ("  " + ("-" * 86)) -ForegroundColor DarkGray
        }
    }

    # --- Upgrade order (optional) ------------------------------------------
    if ($ShowUpgradeOrder) {

        $affected = @($sol.Projects | Where-Object { $_.NuGets.Count -gt 0 })

        Write-Host ""
        Write-Host $divInner                                                             -ForegroundColor Magenta
        Write-Host "  UPGRADE ORDER"                                                     -ForegroundColor Magenta
        Write-Host "  [+] Direct = edit <PackageReference> in this .csproj"             -ForegroundColor DarkGray
        Write-Host "  [~] via X  = inherited via ProjectReference; no file change here" -ForegroundColor DarkGray
        Write-Host "  Projects within the same wave are independent (any order)."        -ForegroundColor DarkGray
        Write-Host $divInner                                                             -ForegroundColor Magenta

        $order = Get-UpgradeOrder -Projects @($sol.Projects)

        $affectedPaths = @{}
        foreach ($ap in $affected) {
            $affectedPaths[[System.IO.Path]::GetFullPath($ap.ProjectPath)] = $true
        }

        $waveNum = 0

        foreach ($wave in $order.Waves) {
            $filtered = @($wave | Where-Object { $affectedPaths.ContainsKey($_) })
            if ($filtered.Count -eq 0) { continue }

            $waveNum++
            $plural = if ($filtered.Count -eq 1) { '' } else { 's' }
            Write-Host ""
            Write-Host ("  -- Wave $waveNum  ($($filtered.Count) project$plural)") -ForegroundColor Magenta

            foreach ($projPath in ($filtered | Sort-Object { $order.PathToName[$_] })) {
                $pName = if ($order.PathToName.ContainsKey($projPath)) {
                    $order.PathToName[$projPath]
                } else { $projPath }

                $projData = $sol.Projects |
                    Where-Object { [System.IO.Path]::GetFullPath($_.ProjectPath) -eq $projPath } |
                    Select-Object -First 1

                Write-Host "     $pName" -ForegroundColor Yellow

                foreach ($pkg in $projData.NuGets) {
                    $tag  = if ($pkg.Source -eq 'Direct') { '[+]' } else { '[~]' }
                    $col  = if ($pkg.Source -eq 'Direct') { 'White' } else { 'DarkCyan' }
                    $line = "         $tag {0,-50} {1,-15} {2}" -f $pkg.Name, $pkg.Version, $pkg.Source
                    Write-Host $line -ForegroundColor $col
                }
            }
        }

        if ($order.Unresolvable.Count -gt 0) {
            $cycleAffected = @($order.Unresolvable | Where-Object { $affectedPaths.ContainsKey($_) })
            if ($cycleAffected.Count -gt 0) {
                Write-Host ""
                Write-Host "  [!] WARNING: Circular ProjectReference chain detected:" -ForegroundColor Red
                foreach ($p in $cycleAffected) {
                    $label = if ($order.PathToName.ContainsKey($p)) { $order.PathToName[$p] } else { $p }
                    Write-Host "      - $label" -ForegroundColor Red
                }
                Write-Host "      Fix the circular references before upgrading." -ForegroundColor Red
            }
        }
    }

    Write-Host ""
    Write-Host $divOuter -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
$skipped = $results.Count - $printedCount
Write-Host "Scan complete." -ForegroundColor Green
Write-Host "  Solutions scanned : $($results.Count)"  -ForegroundColor Cyan
Write-Host "  Solutions matched : $printedCount"       -ForegroundColor Cyan
if ($skipped -gt 0) {
    Write-Host "  Solutions skipped : $skipped (no matching NuGets found)" -ForegroundColor DarkGray
}
Write-Host ""