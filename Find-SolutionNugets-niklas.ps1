#Requires -Version 5.1
<#
.SYNOPSIS
    Scans Visual Studio solution files (.sln) for specific NuGet package
    dependencies and optionally reports upgrade order or circular references.

.DESCRIPTION
    Recursively searches a directory tree for .sln files, enumerates every
    project they reference, and reports NuGet packages whose names begin with
    any of the specified prefixes.

    Compatible with:
      - Visual Studio 2010 and later (the .sln Project() line format is
        unchanged across all versions)
      - SDK-style .csproj/.vbproj/.fsproj files (no XML namespace, used by
        .NET Core, .NET 5+, .NET Standard and modern .NET Framework projects)
      - Legacy MSBuild .csproj/.vbproj files (xmlns="…/msbuild/2003", used
        by .NET Framework projects created before VS 2017)
      - packages.config NuGet format (legacy .NET Framework projects)
      - <PackageReference> NuGet format (SDK-style and modern projects)

    Project types scanned:
      .csproj  .vbproj  .fsproj  .vcxproj  .shproj  .sqlproj

    Package resolution is fully transitive: if ProjectA references ProjectB
    which references ProjectC which owns a matching NuGet package, that
    package is reported on ProjectA with source "via ProjectC". Diamond
    dependency graphs (multiple projects sharing a common dependency) and
    circular ProjectReference chains are both handled safely.

    Limitation: NuGet Central Package Management (Directory.Packages.props)
    is not parsed. Projects using CPM will have their package versions shown
    as '(unknown)'. Package names are still detected and matched by prefix.

    Optional features (activated by switches):

      -ShowUpgradeOrder
          Uses Kahn's BFS topological sort on the ProjectReference graph to
          produce a wave-based upgrade plan. Projects in Wave 1 have no
          in-solution dependencies and should be upgraded first; each later
          wave depends only on projects completed in earlier waves.
          Note: wave ordering is calculated per solution independently.
          Cross-solution dependencies (e.g. a project in Solution A that is
          also listed in Solution B) are not tracked. If you need to order
          upgrades across solutions, use -ShowGlobalUpgradeOrder instead.

      -ShowGlobalUpgradeOrder
          Builds ONE upgrade plan across the union of every project found in
          every scanned solution and topologically sorts it in a single pass.
          The ProjectReference graph does not care about .sln boundaries, so
          this is the true whole-estate view: a project that is referenced by
          projects living in different solutions is placed in a wave that
          respects ALL of its dependents. A project listed in several
          solutions appears once; the solutions it belongs to are shown in
          brackets. Cross-solution cycles (only visible globally) are
          surfaced here too.

      -IncludeReferencedProjects
          Only meaningful together with -ShowGlobalUpgradeOrder. Expands the
          global node set to the full reachable closure of ProjectReferences,
          pulling in shared/"orphan" projects that are referenced but not
          listed in any .sln. Without this switch the global plan contains
          only projects that appear in at least one solution, which can omit
          a shared library that several solutions depend on. Turning it on
          gives a complete plan at the cost of more noise in large trees.

      -CheckCircularDependencies
          Runs a full iterative DFS over every solution's ProjectReference
          graph regardless of NuGet prefix matches. Reports the exact cycle
          path (e.g. A -> B -> C -> A) for every distinct cycle found.
          Solutions that contain cycles but have no NuGet prefix matches are
          still printed so the cycles are not silently hidden. When combined
          with -ShowGlobalUpgradeOrder, a global cycle pass is also run that
          can reveal cycles spanning multiple solutions.

      -HideProjectsWithNoMatches
          Omits projects with no matching packages from the listing. Useful
          for large solutions where only a handful of projects use the
          packages you are searching for. Projects that are missing from disk
          are always shown regardless of this switch. Projects are still
          scanned and included in transitive resolution; this switch only
          affects display.

      -OutputFile
          Writes a plain-text (UTF-8, no BOM) copy of all console output to
          the specified file. The parent directory must already exist.

    Output legend:
      [+] Direct  = this project's file owns the <PackageReference>; edit
                    this .csproj (or packages.config) to change the version.
      [~] via X   = the package is inherited transitively through a
                    <ProjectReference> to project X; no file change needed
                    here — re-test after X is upgraded.

.PARAMETER SearchPath
    Root folder to search recursively for .sln files.
    Defaults to the current working directory.

.PARAMETER NuGetPrefixes
    One or more package-name prefixes to match (case-insensitive).
    A project is included in the output only when at least one of its direct
    or transitive NuGet packages starts with one of these prefixes.
    Blank or whitespace-only entries are ignored.
    Default: 'Microsoft.Extensions', 'System.Text'

.PARAMETER ShowUpgradeOrder
    After the per-project NuGet listing, appends a wave-based upgrade plan
    for each solution showing which projects can be upgraded in parallel and
    which must wait for earlier waves to complete.
    Wave ordering is per-solution only — for cross-solution ordering use
    -ShowGlobalUpgradeOrder.

.PARAMETER ShowGlobalUpgradeOrder
    After the per-solution output, appends a single upgrade plan computed
    over the union of all projects across all solutions, so waves respect
    cross-solution ProjectReference dependencies.

.PARAMETER IncludeReferencedProjects
    Only used with -ShowGlobalUpgradeOrder. Expands the global node set to
    the full reachable ProjectReference closure, including projects that are
    referenced but listed in no .sln.

.PARAMETER CheckCircularDependencies
    Performs a full DFS cycle-detection pass over every solution's
    ProjectReference graph and prints any circular chains found.
    Runs independently of NuGet prefix matching — a solution with no
    matching packages is still printed if it contains cycles. When combined
    with -ShowGlobalUpgradeOrder a global cycle pass is also performed.

.PARAMETER HideProjectsWithNoMatches
    When set, projects that have no packages matching the -NuGetPrefixes
    filter are omitted from the per-solution listing. Projects missing from
    disk are always shown regardless of this switch. Projects are still
    fully scanned and participate in transitive resolution and upgrade
    ordering; this switch only affects what is printed.

.PARAMETER OutputFile
    Optional file path. All console output is written to this file as
    UTF-8 without BOM. The file is created if it does not exist and
    overwritten if it does. The parent directory must already exist.

.EXAMPLE
    .\Find-SolutionNugets.ps1
    Scans the current directory with the default NuGet prefixes.

.EXAMPLE
    .\Find-SolutionNugets.ps1 -SearchPath "C:\Source"
    Scans all solutions under C:\Source for Microsoft.Extensions.* and
    System.Text.* packages.

.EXAMPLE
    .\Find-SolutionNugets.ps1 -SearchPath "C:\Source" `
        -NuGetPrefixes "Newtonsoft","Serilog"
    Scans for packages whose names start with Newtonsoft or Serilog.

.EXAMPLE
    .\Find-SolutionNugets.ps1 -SearchPath "C:\Source" -ShowUpgradeOrder
    Includes a wave-based upgrade plan for each matching solution.

.EXAMPLE
    .\Find-SolutionNugets.ps1 -SearchPath "C:\Source" -ShowGlobalUpgradeOrder
    Includes a single whole-estate upgrade plan whose waves cross solution
    boundaries.

.EXAMPLE
    .\Find-SolutionNugets.ps1 -SearchPath "C:\Source" `
        -ShowGlobalUpgradeOrder -IncludeReferencedProjects
    Whole-estate upgrade plan that also includes shared projects referenced
    but not listed in any .sln.

.EXAMPLE
    .\Find-SolutionNugets.ps1 -SearchPath "C:\Source" `
        -HideProjectsWithNoMatches
    Lists only projects that actually reference matching packages,
    hiding the noise of projects with no matches in large solutions.

.EXAMPLE
    .\Find-SolutionNugets.ps1 -SearchPath "C:\Source" `
        -CheckCircularDependencies
    Reports any circular ProjectReference chains across all solutions,
    regardless of NuGet prefix matches.

.EXAMPLE
    .\Find-SolutionNugets.ps1 -SearchPath "C:\Source" `
        -ShowUpgradeOrder -ShowGlobalUpgradeOrder -CheckCircularDependencies `
        -IncludeReferencedProjects -HideProjectsWithNoMatches `
        -OutputFile "C:\Temp\nuget-report.txt"
    Full report with per-solution and global upgrade order, circular
    dependency checks, closure expansion, and non-matching projects hidden,
    saved to a file.
#>
[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [ValidateScript({
        if (Test-Path $_ -PathType Container) { return $true }
        throw "Path '$_' does not exist or is not a directory."
    })]
    [string]   $SearchPath             = (Get-Location).Path,

    [Parameter()]
    [string[]] $NuGetPrefixes          = @('Microsoft.Extensions', 'System.Text'),

    [Parameter()]
    [switch]   $ShowUpgradeOrder,

    [Parameter()]
    [switch]   $ShowGlobalUpgradeOrder,

    [Parameter()]
    [switch]   $IncludeReferencedProjects,

    [Parameter()]
    [switch]   $CheckCircularDependencies,

    [Parameter()]
    [switch]   $HideProjectsWithNoMatches,

    [Parameter()]
    [string]   $OutputFile             = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Validate -OutputFile upfront so a bad path does not waste the entire scan.
# $resolvedOutputFile is used at the end when writing the file.
# ---------------------------------------------------------------------------
$resolvedOutputFile = ''
if ($OutputFile) {
    try {
        $resolvedOutputFile = [System.IO.Path]::GetFullPath($OutputFile)
        $outDir = [System.IO.Path]::GetDirectoryName($resolvedOutputFile)
        if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
            Write-Warning "Output directory does not exist: '$outDir'"
            return
        }
    }
    catch {
        Write-Warning "Invalid -OutputFile path '$OutputFile': $_"
        return
    }
}

# ---------------------------------------------------------------------------
# OUTPUT HELPER — mirrors every line to $script:OutLines for optional file output
# ---------------------------------------------------------------------------

$script:OutLines = [System.Collections.Generic.List[string]]::new()

function Write-Out {
    param(
        [string] $Message         = '',
        [string] $ForegroundColor = 'White'
    )
    Write-Host $Message -ForegroundColor $ForegroundColor
    $script:OutLines.Add($Message)
}

# ---------------------------------------------------------------------------
# Script-level caches — reset at startup so dot-sourcing never returns stale data
# ---------------------------------------------------------------------------

$script:DetailsCache = [System.Collections.Generic.Dictionary[string,object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

$script:PkgCache = [System.Collections.Generic.Dictionary[string,object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# Tracks projects involved in a cycle so their incomplete package lists are
# never stored in PkgCache. Reset per solution in the main loop.
$script:CycleTainted = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# HashSet so each failing path is recorded at most once even when the same
# file is referenced by multiple solutions.
$script:ParseErrors = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

function Test-PackagePrefix {
    param([string]$Name, [string[]]$Prefixes)
    foreach ($px in $Prefixes) {
        # Skip blank/whitespace prefixes — StartsWith("") matches everything.
        if ([string]::IsNullOrWhiteSpace($px)) { continue }
        if ($Name.StartsWith($px, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

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

        # Build a namespace manager so SelectNodes works for both project styles:
        #   SDK-style     : no xmlns attribute  -> $ns is empty -> plain xpath used
        #   Legacy MSBuild: xmlns="http://schemas.microsoft.com/developer/msbuild/2003"
        #                   -> prefix 'ms' registered -> ms:* xpath used
        $nsManager = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
        $ns        = $xml.DocumentElement.NamespaceURI
        if ($ns) { $nsManager.AddNamespace('ms', $ns) }

        $xpathPkg  = if ($ns) { '//ms:PackageReference' } else { '//PackageReference' }
        $xpathProj = if ($ns) { '//ms:ProjectReference' } else { '//ProjectReference' }
        # <Version> child element must also be namespace-qualified for legacy projects
        $xpathVer  = if ($ns) { 'ms:Version'            } else { 'Version'            }

        foreach ($node in $xml.SelectNodes($xpathPkg, $nsManager)) {
            $name = $node.GetAttribute('Include')
            if (-not $name) { continue }
            $ver = $node.GetAttribute('Version')
            if (-not $ver) {
                # Version may be a child element rather than an attribute
                $vn = $node.SelectSingleNode($xpathVer, $nsManager)
                if ($null -ne $vn) { $ver = $vn.InnerText.Trim() }
            }
            $out.PackageRefs.Add([PSCustomObject]@{ Name = $name.Trim(); Version = $ver })
        }

        # packages.config — legacy NuGet format used by .NET Framework projects.
        # These files never carry the MSBuild namespace so '//package' is always correct.
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
            catch {
                Write-Verbose "Could not parse packages.config at '$pkgCfg': $_"
                $null = $script:ParseErrors.Add($pkgCfg)
            }
        }

        # Each ProjectReference is wrapped in its own try-catch so a single
        # malformed Include attribute does not discard the PackageReference
        # entries already successfully parsed above it.
        foreach ($node in $xml.SelectNodes($xpathProj, $nsManager)) {
            $rel = $node.GetAttribute('Include')
            if (-not $rel) { continue }
            try {
                $out.ProjectRefs.Add(
                    [System.IO.Path]::GetFullPath(
                        [System.IO.Path]::Combine($dir, $rel)
                    )
                )
            }
            catch {
                # The .csproj itself was read correctly — only this attribute
                # value is malformed, so do not add $norm to ParseErrors.
                Write-Warning "Invalid ProjectReference path '$rel' in '$norm': $_"
            }
        }

        # Store in cache only after a fully successful parse so a mid-parse
        # exception never permanently caches partial data.
        $script:DetailsCache[$norm] = $out
    }
    catch {
        Write-Warning "Could not parse '$norm': $_"
        $null = $script:ParseErrors.Add($norm)
        # Cache the (possibly partial) result so this known-bad file is not
        # re-read from disk for every solution that references it.
        $script:DetailsCache[$norm] = $out
    }

    return $out
}

function Resolve-Packages {
    param(
        [string] $ProjectPath,
        [System.Collections.Generic.HashSet[string]] $Seen
    )

    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        return [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    $norm = [System.IO.Path]::GetFullPath($ProjectPath)

    # PkgCache MUST be checked before $Seen.
	 
    # A project in PkgCache was fully resolved with no cycle involvement;
    # return it immediately without consulting $Seen. This is critical for
    # diamond dependency graphs:
    #
    #   Main -> A -> Shared
    #   Main -> B -> Shared
    #
    # When B's branch visits Shared it is already in $Seen from A's branch.
    # Checking $Seen first would falsely treat that as a cycle, taint Shared,
    # and return [] — so B would receive none of Shared's packages.
													 
	 
																			 
													
    #
    # True cycles are still detected: a mid-resolution project is NEVER in
    # PkgCache (it is only stored there after returning successfully), so the
    # $Seen branch below still fires correctly for genuine circular references.
    if ($script:PkgCache.ContainsKey($norm)) { return $script:PkgCache[$norm] }

    if (-not $Seen.Add($norm)) {
        # $norm is currently on the resolution stack — genuine cycle detected.
        $null = $script:CycleTainted.Add($norm)
        return [System.Collections.Generic.List[PSCustomObject]]::new()
    }

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

																			   
    if (-not $script:CycleTainted.Contains($norm)) {
        $script:PkgCache[$norm] = $list
    }
    return $list
}

# ---------------------------------------------------------------------------
# Resolve a project's matching NuGets (direct + transitive), grouped by name.
# Extracted from the main loop so the per-solution listing and the global
# upgrade plan use exactly the same matching/grouping rules — they can never
# drift apart. Returns an array of { Name; Version; Source } objects.
# ---------------------------------------------------------------------------
function Get-MatchingNuGets {
    param(
        [string]   $ProjectPath,
        [string[]] $Prefixes
    )

    $seen     = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $allPkgs  = @(Resolve-Packages -ProjectPath $ProjectPath -Seen $seen)
    $projNorm = [System.IO.Path]::GetFullPath($ProjectPath)

    return @(
        $allPkgs |
        Where-Object { Test-PackagePrefix $_.Name $Prefixes } |
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
}

function Get-SlnProjects ([string]$SlnPath) {
    $slnDir    = [System.IO.Path]::GetDirectoryName($SlnPath)
    $content   = Get-Content -LiteralPath $SlnPath -Raw -Encoding UTF8
    $validExts = @('.csproj', '.vbproj', '.fsproj', '.vcxproj', '.shproj', '.sqlproj')
    $list      = [System.Collections.Generic.List[PSCustomObject]]::new()

    # The Project() line format in .sln files has been consistent across all
    # Visual Studio versions since VS 2005 so this regex handles any version.
    $rxPattern = @'
Project\("\{[^}]+\}"\)\s*=\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"\{[^}]+\}"
'@
    $rx = [regex]$rxPattern.Trim()

    foreach ($m in $rx.Matches($content)) {
        $rel = $m.Groups[2].Value
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
    # Kahn's BFS topological sort, batched into waves.
    #
    # Graph model:
    #   Node  = project in this solution
    #   Edge  A -> B means A has a <ProjectReference> to B (A depends on B)
    #   Wave 1 = nodes with in-degree 0 (no in-solution deps) -> upgrade first
    #   Wave N = nodes whose every dependency was resolved in earlier waves
    #
    # NOTE: only ProjectReferences within the supplied node set are considered.
    # When called with a single solution's projects this is per-solution;
    # when called with the global union it spans solutions.
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
        # Projects still in the graph after BFS are involved in a cycle and
        # could not be assigned to any wave.
        Unresolvable = @($inDegree.Keys | Where-Object { $inDegree[$_] -gt 0 })
    }
}

# ---------------------------------------------------------------------------
# CIRCULAR DEPENDENCY DETECTION  (iterative DFS with gray/black colouring)
#
# Colors: 0 = unvisited   1 = on current DFS stack (gray)   2 = done (black)
# A back-edge to a gray node means a cycle exists.
# Each cycle is canonicalised (rotated to its lexicographically smallest node)
# so that the same cycle discovered via different start nodes is only recorded
# once.
#
# Implemented iteratively to avoid PowerShell's call-stack limit (~500 frames)
# on deep project graphs. List<T>.GetEnumerator() returns a VALUE TYPE
# (struct); reading it through a PSCustomObject property in PS 5.1 unboxes a
# fresh copy each time, so MoveNext() would never advance the stored enumerator
# and the loop would spin forever. Fix: pre-materialise neighbour lists via
# .ToArray() and track position with a plain [int] Index instead.
# ---------------------------------------------------------------------------

function Find-CircularDependencies {
    param ([object[]] $Projects)

    $pathToName = @{}
    $adj        = @{}

    foreach ($p in $Projects) {
        if (-not $p.ProjectPath) { continue }
        $norm = [System.IO.Path]::GetFullPath($p.ProjectPath)
        $pathToName[$norm] = $p.ProjectName
        $adj[$norm]        = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($p in $Projects) {
        if (-not $p.ProjectPath) { continue }
        $norm    = [System.IO.Path]::GetFullPath($p.ProjectPath)
        $details = Get-ProjectDetails -ProjectPath $norm   # uses cache — no extra I/O

        foreach ($ref in $details.ProjectRefs) {
            $refNorm = [System.IO.Path]::GetFullPath($ref)
            if ($pathToName.ContainsKey($refNorm)) {
                $adj[$norm].Add($refNorm)
            }
        }
    }

    $color    = @{}
    foreach ($key in $pathToName.Keys) { $color[$key] = 0 }

    $cycles   = [System.Collections.Generic.List[object]]::new()
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($startNode in ($pathToName.Keys | Sort-Object)) {
        if ($color[$startNode] -ne 0) { continue }

																				 
        $path     = [System.Collections.Generic.List[string]]::new()
        $dfsStack = [System.Collections.Generic.Stack[PSCustomObject]]::new()

        $dfsStack.Push([PSCustomObject]@{
            Node      = $startNode
            Neighbors = $adj[$startNode].ToArray()
            Index     = [int]-1
        })
        $color[$startNode] = 1
        $path.Add($startNode)

        while ($dfsStack.Count -gt 0) {
            $frame = $dfsStack.Peek()
            $frame.Index++

            if ($frame.Index -ge $frame.Neighbors.Length) {
																		
                $color[$frame.Node] = 2
                $null = $path.RemoveAt($path.Count - 1)
                $null = $dfsStack.Pop()
                continue
            }

            $neighbor = $frame.Neighbors[$frame.Index]

            if ($color[$neighbor] -eq 1) {
																					
                $startIdx  = $path.IndexOf($neighbor)
                $bodyCount = $path.Count - $startIdx

																				 
                $minIdx = $startIdx
                for ($i = $startIdx + 1; $i -lt $path.Count; $i++) {
                    if ([string]::Compare($path[$i], $path[$minIdx], $true) -lt 0) {
                        $minIdx = $i
                    }
                }

                $canonParts = [System.Collections.Generic.List[string]]::new()
                for ($i = 0; $i -lt $bodyCount; $i++) {
                    $canonParts.Add($path[$startIdx + (($minIdx - $startIdx + $i) % $bodyCount)])
                }
                $canonKey = [string]::Join('|', [string[]]$canonParts)

                if ($seenKeys.Add($canonKey)) {
                    $displayCycle = [System.Collections.Generic.List[string]]::new()
                    for ($i = 0; $i -lt $bodyCount; $i++) {
                        $displayCycle.Add($path[$startIdx + (($minIdx - $startIdx + $i) % $bodyCount)])
                    }
                    $displayCycle.Add($displayCycle[0])
                    $cycles.Add([string[]]$displayCycle)
                }
            }
            elseif ($color[$neighbor] -eq 0) {
                $color[$neighbor] = 1
                $path.Add($neighbor)
                $dfsStack.Push([PSCustomObject]@{
                    Node      = $neighbor
                    Neighbors = $adj[$neighbor].ToArray()
                    Index     = [int]-1
                })
            }
														
        }
    }

    return [PSCustomObject]@{
        Cycles     = $cycles
        PathToName = $pathToName
    }
}

# ---------------------------------------------------------------------------
# MAIN  —  Phase 1: collect
# ---------------------------------------------------------------------------

Write-Out ""
Write-Out "Search root    : $SearchPath"                  -ForegroundColor Cyan
Write-Out "NuGet prefixes : $($NuGetPrefixes -join ', ')" -ForegroundColor Cyan
if ($ShowUpgradeOrder)          { Write-Out "Upgrade order  : enabled"             -ForegroundColor Cyan }
if ($ShowGlobalUpgradeOrder)    { Write-Out "Global order   : enabled"             -ForegroundColor Cyan }
if ($IncludeReferencedProjects) { Write-Out "Incl. ref proj : enabled"             -ForegroundColor Cyan }
if ($CheckCircularDependencies) { Write-Out "Circular deps  : enabled"             -ForegroundColor Cyan }
if ($HideProjectsWithNoMatches) { Write-Out "Hide no-matches: enabled"             -ForegroundColor Cyan }
if ($resolvedOutputFile)        { Write-Out "Output file    : $resolvedOutputFile" -ForegroundColor Cyan }
Write-Out ""

if ($IncludeReferencedProjects -and -not $ShowGlobalUpgradeOrder) {
    Write-Warning "-IncludeReferencedProjects has no effect without -ShowGlobalUpgradeOrder."
}

$slnFiles = @(
    Get-ChildItem -LiteralPath $SearchPath -Filter '*.sln' -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object FullName
)

if ($slnFiles.Count -eq 0) {
    Write-Out "No .sln files found under '$SearchPath'." -ForegroundColor Yellow
    return
}

Write-Out "Found $($slnFiles.Count) solution(s). Scanning..." -ForegroundColor Green
Write-Out ""

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

for ($si = 0; $si -lt $slnFiles.Count; $si++) {
    $sln    = $slnFiles[$si]
    $pct    = [int](($si / [Math]::Max($slnFiles.Count, 1)) * 100)
    $status = "($($si+1)/$($slnFiles.Count)) $($sln.Name)"
    Write-Progress -Activity 'Scanning solutions' -Status $status -PercentComplete $pct

    $projList    = @(Get-SlnProjects -SlnPath $sln.FullName)
    $projResults = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Reset per solution so a taint from solution N does not bleed into N+1
    $script:CycleTainted.Clear()

    foreach ($proj in $projList) {
        if (-not (Test-Path -LiteralPath $proj.Path -PathType Leaf)) {
            $projResults.Add([PSCustomObject]@{
                ProjectName = $proj.Name
                ProjectPath = $proj.Path
                Exists      = $false
                NuGets      = @()
            })
            continue
        }

        $matching = @(Get-MatchingNuGets -ProjectPath $proj.Path -Prefixes $NuGetPrefixes)

        $projResults.Add([PSCustomObject]@{
            ProjectName = $proj.Name
            ProjectPath = $proj.Path
            Exists      = $true
            NuGets      = $matching
        })
    }

    $cycleResult = $null
    if ($CheckCircularDependencies) {
        $cycleResult = Find-CircularDependencies -Projects @($projResults)
    }

    $results.Add([PSCustomObject]@{
        SolutionName = $sln.Name
        SolutionPath = $sln.FullName
        Projects     = $projResults
        CycleResult  = $cycleResult
    })
}

Write-Progress -Activity 'Scanning solutions' -Completed

# ---------------------------------------------------------------------------
# Phase 2: display
# ---------------------------------------------------------------------------

$divOuter = '=' * 90
$divInner = '-' * 70
$pkgFmt   = "           {0,-62} {1,-15} {2}"
$pkgSep   = "           " + ("-" * 62) + "  " + ("-" * 15) + "  " + ("-" * 20)

$printedCount = 0

foreach ($sol in $results) {

    $affectedCount = @($sol.Projects | Where-Object { $_.NuGets.Count -gt 0 }).Count

    $cycleCount = 0
    if ($null -ne $sol.CycleResult) {
        $cycleCount = $sol.CycleResult.Cycles.Count
    }

    if ($affectedCount -eq 0 -and $cycleCount -eq 0) { continue }

    $printedCount++
    $projCount = $sol.Projects.Count

    $hdrParts = [System.Collections.Generic.List[string]]::new()
    $hdrParts.Add("$projCount total")
    $hdrParts.Add("$affectedCount with matching NuGets")
    if ($CheckCircularDependencies) {
        if ($cycleCount -eq 0) {
            $hdrParts.Add("no circular dependencies")
        }
        else {
            $plural = if ($cycleCount -eq 1) { 'cycle' } else { 'cycles' }
            $hdrParts.Add("[!] $cycleCount circular $plural found")
        }
    }

    # --- Solution header ---------------------------------------------------
    Write-Out ""
    Write-Out $divOuter -ForegroundColor Cyan
    Write-Out "  SOLUTION  : $($sol.SolutionName)" -ForegroundColor Green
    Write-Out "  PATH      : $($sol.SolutionPath)"  -ForegroundColor DarkGreen
    Write-Out ("  PROJECTS  : " + ([string]::Join(', ', [string[]]$hdrParts))) -ForegroundColor DarkGreen
    Write-Out $divOuter -ForegroundColor Cyan

    # --- Project listing ---------------------------------------------------
    if ($affectedCount -gt 0) {

																		  
        $projByPath = @{}
        foreach ($p in $sol.Projects) {
            $projByPath[[System.IO.Path]::GetFullPath($p.ProjectPath)] = $p
        }

        $printedProjCount = 0
        for ($pi = 0; $pi -lt $projCount; $pi++) {
            $proj = $sol.Projects[$pi]

            # FIX — only hide projects that exist AND have no matches.
            # Missing projects (Exists = $false) are always shown so the user
            # knows a referenced file is absent from disk.
            if ($HideProjectsWithNoMatches -and $proj.NuGets.Count -eq 0 -and $proj.Exists) { continue }

            if ($printedProjCount -gt 0) {
                Write-Out ("  " + ("-" * 86)) -ForegroundColor DarkGray
            }
            $printedProjCount++

            $index = "[$($pi+1)/$projCount]"
            $flag  = if (-not $proj.Exists) { '  [FILE NOT FOUND]' } else { '' }

            Write-Out ""
            Write-Out ("  $index $($proj.ProjectName)$flag") -ForegroundColor Yellow
            Write-Out ("         Path : $($proj.ProjectPath)") -ForegroundColor DarkYellow

            if ($proj.NuGets.Count -eq 0) {
                Write-Out "         NuGets : (none matching filter)" -ForegroundColor Gray
            }
            else {
                Write-Out $pkgSep -ForegroundColor DarkGray
                Write-Out ($pkgFmt -f 'Package', 'Version', 'Source') -ForegroundColor Cyan
                Write-Out $pkgSep -ForegroundColor DarkGray

                foreach ($pkg in $proj.NuGets) {
                    $tag = if ($pkg.Source -eq 'Direct') { '[+]' } else { '[~]' }
                    $col = if ($pkg.Source -eq 'Direct') { 'White' } else { 'DarkCyan' }
                    Write-Out ($pkgFmt -f "$tag $($pkg.Name)", $pkg.Version, $pkg.Source) -ForegroundColor $col
                }
			 

										   
																	   
            }
        }
    }
    else {
        Write-Out ""
        Write-Out "  (no projects matched NuGet filter)" -ForegroundColor Gray
    }

    # --- Upgrade order (optional) ------------------------------------------
    if ($ShowUpgradeOrder -and $affectedCount -gt 0) {

        $affected = @($sol.Projects | Where-Object { $_.NuGets.Count -gt 0 })

        Write-Out ""
        Write-Out $divInner -ForegroundColor Magenta
        Write-Out "  UPGRADE ORDER  (within this solution only)" -ForegroundColor Magenta
        Write-Out "  [+] Direct = edit <PackageReference> in this .csproj"             -ForegroundColor DarkGray
        Write-Out "  [~] via X  = inherited via ProjectReference; no file change here" -ForegroundColor DarkGray
        Write-Out "  Projects within the same wave are independent (any order)."        -ForegroundColor DarkGray
        Write-Out "  Cross-solution ordering is not computed - use -ShowGlobalUpgradeOrder." -ForegroundColor DarkGray
        Write-Out $divInner -ForegroundColor Magenta

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
            Write-Out ""
            Write-Out ("  -- Wave $waveNum  ($($filtered.Count) project$plural)") -ForegroundColor Magenta

            foreach ($projPath in ($filtered | Sort-Object { $order.PathToName[$_] })) {
                $pName = if ($order.PathToName.ContainsKey($projPath)) {
                    $order.PathToName[$projPath]
                } else { $projPath }

                $projData = $projByPath[$projPath]
                if ($null -eq $projData) { continue }

                Write-Out "     $pName" -ForegroundColor Yellow

                foreach ($pkg in $projData.NuGets) {
                    $tag  = if ($pkg.Source -eq 'Direct') { '[+]' } else { '[~]' }
                    $col  = if ($pkg.Source -eq 'Direct') { 'White' } else { 'DarkCyan' }
                    $line = "         $tag {0,-62} {1,-15} {2}" -f $pkg.Name, $pkg.Version, $pkg.Source
                    Write-Out $line -ForegroundColor $col
                }
            }
        }

        if ($order.Unresolvable.Count -gt 0) {
            $cycleAffected = @($order.Unresolvable | Where-Object { $affectedPaths.ContainsKey($_) })
            if ($cycleAffected.Count -gt 0) {
                Write-Out ""
                Write-Out "  [!] WARNING: Circular chain detected in upgrade ordering:" -ForegroundColor Red
                foreach ($p in $cycleAffected) {
                    $label = if ($order.PathToName.ContainsKey($p)) { $order.PathToName[$p] } else { $p }
                    Write-Out "      - $label" -ForegroundColor Red
                }
                Write-Out "      Tip: run with -CheckCircularDependencies for the full cycle path." -ForegroundColor DarkGray
            }
        }
    }

    # --- Circular dependency report (optional) -----------------------------
    if ($CheckCircularDependencies) {
        Write-Out ""
        Write-Out $divInner -ForegroundColor Red
        Write-Out "  CIRCULAR DEPENDENCY CHECK" -ForegroundColor Red
        Write-Out $divInner -ForegroundColor Red

        if ($cycleCount -eq 0) {
            Write-Out "  No circular ProjectReference chains found." -ForegroundColor Green
        }
        else {
            $plural = if ($cycleCount -eq 1) { 'cycle' } else { 'cycles' }
            Write-Out "  $cycleCount $plural found  (fix before attempting upgrades):" -ForegroundColor Red

            $cycleNum = 0
            foreach ($cycle in $sol.CycleResult.Cycles) {
                $cycleNum++
                $nodeCount = $cycle.Count - 1

                Write-Out ""
                Write-Out ("  [!] Cycle $cycleNum  ($nodeCount projects involved)") -ForegroundColor Red

                $nameChain = [System.Collections.Generic.List[string]]::new()
                foreach ($nodePath in $cycle) {
                    $n = if ($sol.CycleResult.PathToName.ContainsKey($nodePath)) {
                        $sol.CycleResult.PathToName[$nodePath]
                    } else {
                        [System.IO.Path]::GetFileNameWithoutExtension($nodePath)
                    }
                    $nameChain.Add($n)
                }
                Write-Out ("      " + [string]::Join(' -> ', [string[]]$nameChain)) -ForegroundColor Yellow

                Write-Out ""
                $shownPaths = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)

                foreach ($nodePath in $cycle) {
                    if (-not $shownPaths.Add($nodePath)) { continue }
                    $n = if ($sol.CycleResult.PathToName.ContainsKey($nodePath)) {
                        $sol.CycleResult.PathToName[$nodePath]
                    } else {
                        [System.IO.Path]::GetFileNameWithoutExtension($nodePath)
                    }
                    Write-Out ("      {0,-40} {1}" -f $n, $nodePath) -ForegroundColor DarkYellow
                }
            }
        }
    }

    Write-Out ""
}

# ---------------------------------------------------------------------------
# Global deduplicated package summary (all solutions combined)
# ---------------------------------------------------------------------------

$allMatchedPkgs = @(
    $results |
    ForEach-Object { $_.Projects } |
    ForEach-Object { $_.NuGets  } |
    Group-Object -Property Name |
    Sort-Object  -Property Name
)

if ($allMatchedPkgs.Count -gt 0) {
    Write-Out $divInner -ForegroundColor Cyan
    Write-Out "  MATCHED PACKAGES SUMMARY  (all solutions combined)" -ForegroundColor Cyan
    Write-Out $divInner -ForegroundColor Cyan
    Write-Out ($pkgFmt -f 'Package', 'Version(s) found', 'In N projects') -ForegroundColor Cyan
    Write-Out $pkgSep  -ForegroundColor DarkGray

    foreach ($g in $allMatchedPkgs) {
        $versions = (
            $g.Group |
            Select-Object -ExpandProperty Version |
            Where-Object  { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
        ) -join ', '
        if (-not $versions) { $versions = '(unknown)' }

        $matchCount = $g.Group.Count
        $col = if (@($g.Group | Where-Object { $_.Source -eq 'Direct' }).Count -gt 0) { 'White' } else { 'DarkCyan' }
        Write-Out ($pkgFmt -f $g.Name, $versions, "$matchCount project(s)") -ForegroundColor $col
    }

    Write-Out ""
}

# ---------------------------------------------------------------------------
# GLOBAL UPGRADE ORDER  (optional) — the whole-estate view
#
# The ProjectReference graph is not bounded by .sln files: a single project
# can be listed in several solutions, but it is still ONE node in the real
# graph. This block builds the union of every project across every solution
# and runs a single topological sort so the waves respect dependencies that
# cross solution boundaries.
#
# Each unique project is keyed by its normalised full path. NuGets come from
# Phase 1 (transitive resolution is independent of which solution a project is
# viewed through, so they are identical and safe to reuse). The wave/cycle
# engines only consult DetailsCache (ProjectReference edges), so no extra
# package resolution is needed here.
# ---------------------------------------------------------------------------

if ($ShowGlobalUpgradeOrder) {

    Write-Out $divOuter -ForegroundColor Cyan
    Write-Out "  GLOBAL UPGRADE ORDER  (all solutions combined)" -ForegroundColor Magenta
    Write-Out "  One plan over the union of every project. Waves cross solution"   -ForegroundColor DarkGray
    Write-Out "  boundaries. A project appears once; its solutions are in [ ]."    -ForegroundColor DarkGray
    Write-Out "  [+] Direct = edit <PackageReference> here   [~] via X = inherited" -ForegroundColor DarkGray
    if ($IncludeReferencedProjects) {
        Write-Out "  Closure mode: referenced projects not in any .sln are included." -ForegroundColor DarkGray
    }
    else {
        Write-Out "  Tip: add -IncludeReferencedProjects to pull in shared projects"  -ForegroundColor DarkGray
        Write-Out "       that are referenced but listed in no .sln."                  -ForegroundColor DarkGray
    }
    Write-Out $divOuter -ForegroundColor Cyan

    # --- Build the global node union, keyed by normalised path -------------
    $globalNodes = @{}
    foreach ($sol in $results) {
        foreach ($p in $sol.Projects) {
            $norm = [System.IO.Path]::GetFullPath($p.ProjectPath)
            if (-not $globalNodes.ContainsKey($norm)) {
                $globalNodes[$norm] = [PSCustomObject]@{
                    ProjectName = $p.ProjectName   # canonical = first .sln display name seen
                    ProjectPath = $norm
                    Exists      = $p.Exists
                    NuGets      = @($p.NuGets)
                    Solutions   = [System.Collections.Generic.List[string]]::new()
                }
            }
            if (-not $globalNodes[$norm].Solutions.Contains($sol.SolutionName)) {
                $globalNodes[$norm].Solutions.Add($sol.SolutionName)
            }
        }
    }

    # --- Optionally expand to the full reachable ProjectReference closure ---
    if ($IncludeReferencedProjects) {
        # Fresh taint state for this resolution pass so it is self-consistent
        # and independent of whatever the last solution left behind.
        $script:CycleTainted.Clear()

        $stack = [System.Collections.Generic.Stack[string]]::new()
        foreach ($k in @($globalNodes.Keys)) { $stack.Push($k) }

        while ($stack.Count -gt 0) {
            $cur = $stack.Pop()
            foreach ($ref in (Get-ProjectDetails -ProjectPath $cur).ProjectRefs) {
                $refNorm = [System.IO.Path]::GetFullPath($ref)
                if (-not $globalNodes.ContainsKey($refNorm)) {
                    $exists = Test-Path -LiteralPath $refNorm -PathType Leaf
                    $globalNodes[$refNorm] = [PSCustomObject]@{
                        ProjectName = [System.IO.Path]::GetFileNameWithoutExtension($refNorm)
                        ProjectPath = $refNorm
                        Exists      = $exists
                        NuGets      = if ($exists) {
                            @(Get-MatchingNuGets -ProjectPath $refNorm -Prefixes $NuGetPrefixes)
                        } else { @() }
                        # Empty list = referenced but not present in any .sln
                        Solutions   = [System.Collections.Generic.List[string]]::new()
                    }
                    $stack.Push($refNorm)
                }
            }
        }
    }

    $globalProjects = @($globalNodes.Values)
    $gOrder         = Get-UpgradeOrder -Projects $globalProjects

    # Only projects that actually have matching NuGets are worth listing.
    $gAffectedPaths = @{}
    foreach ($n in $globalProjects) {
        if (@($n.NuGets).Count -gt 0) {
            $gAffectedPaths[[System.IO.Path]::GetFullPath($n.ProjectPath)] = $true
        }
    }

    if ($gAffectedPaths.Count -eq 0) {
        Write-Out ""
        Write-Out "  (no projects across any solution matched the NuGet filter)" -ForegroundColor Gray
    }
    else {
        $gWaveNum = 0
        foreach ($wave in $gOrder.Waves) {
            $filtered = @($wave | Where-Object { $gAffectedPaths.ContainsKey($_) })
            if ($filtered.Count -eq 0) { continue }

            $gWaveNum++
            $plural = if ($filtered.Count -eq 1) { '' } else { 's' }
            Write-Out ""
            Write-Out ("  -- Wave $gWaveNum  ($($filtered.Count) project$plural)") -ForegroundColor Magenta

            foreach ($projPath in ($filtered | Sort-Object { $gOrder.PathToName[$_] })) {
                $node = $globalNodes[$projPath]
                if ($null -eq $node) { continue }

                $slns = if ($node.Solutions.Count -gt 0) {
                    $node.Solutions -join ', '
                } else { 'not in any .sln' }

                Write-Out ("     $($node.ProjectName)  [$slns]") -ForegroundColor Yellow

                foreach ($pkg in @($node.NuGets)) {
                    $tag  = if ($pkg.Source -eq 'Direct') { '[+]' } else { '[~]' }
                    $col  = if ($pkg.Source -eq 'Direct') { 'White' } else { 'DarkCyan' }
                    $line = "         $tag {0,-62} {1,-15} {2}" -f $pkg.Name, $pkg.Version, $pkg.Source
                    Write-Out $line -ForegroundColor $col
                }
            }
        }
    }

    # --- Cycle members that broke wave assignment (in-degree never hit 0) ---
    if ($gOrder.Unresolvable.Count -gt 0) {
        $gCycleAffected = @($gOrder.Unresolvable | Where-Object { $gAffectedPaths.ContainsKey($_) })
        if ($gCycleAffected.Count -gt 0) {
            Write-Out ""
            Write-Out "  [!] WARNING: circular chain in the global graph - these projects" -ForegroundColor Red
            Write-Out "      could not be placed in any wave (may span solutions):"        -ForegroundColor Red
            foreach ($p in ($gCycleAffected | Sort-Object { $gOrder.PathToName[$_] })) {
                $label = if ($gOrder.PathToName.ContainsKey($p)) { $gOrder.PathToName[$p] } else { $p }
                Write-Out "      - $label" -ForegroundColor Red
            }
            Write-Out "      Tip: run with -CheckCircularDependencies for full cycle paths." -ForegroundColor DarkGray
        }
    }

    # --- Full global cycle paths (incl. cross-solution cycles) -------------
    if ($CheckCircularDependencies) {
        $gCycles = Find-CircularDependencies -Projects $globalProjects
        Write-Out ""
        if ($gCycles.Cycles.Count -eq 0) {
            Write-Out "  No global circular ProjectReference chains found." -ForegroundColor Green
        }
        else {
            $plural = if ($gCycles.Cycles.Count -eq 1) { 'cycle' } else { 'cycles' }
            Write-Out "  $($gCycles.Cycles.Count) global $plural found (may span solutions):" -ForegroundColor Red

            $gcn = 0
            foreach ($cycle in $gCycles.Cycles) {
                $gcn++
                $nameChain = [System.Collections.Generic.List[string]]::new()
                foreach ($np in $cycle) {
                    $nm = if ($gCycles.PathToName.ContainsKey($np)) {
                        $gCycles.PathToName[$np]
                    } else {
                        [System.IO.Path]::GetFileNameWithoutExtension($np)
                    }
                    $nameChain.Add($nm)
                }
                Write-Out ("  [!] Cycle $gcn : " + [string]::Join(' -> ', [string[]]$nameChain)) -ForegroundColor Yellow
            }
        }
    }

    Write-Out ""
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$skipped     = $results.Count - $printedCount
$totalCycles = 0
if ($CheckCircularDependencies) {
    foreach ($r in $results) {
        if ($null -ne $r.CycleResult) {
            $totalCycles += $r.CycleResult.Cycles.Count
        }
    }
}

Write-Out $divOuter -ForegroundColor Cyan
Write-Out "  SCAN COMPLETE" -ForegroundColor Green
Write-Out "  Solutions scanned  : $($results.Count)" -ForegroundColor Cyan
Write-Out "  Solutions matched  : $printedCount"      -ForegroundColor Cyan

if ($skipped -gt 0) {
    Write-Out "  Solutions skipped  : $skipped (no matching NuGets or circular deps)" -ForegroundColor DarkGray
}

if ($script:ParseErrors.Count -gt 0) {
    Write-Out "  Parse errors       : $($script:ParseErrors.Count) file(s) could not be read" -ForegroundColor Red
    foreach ($pe in $script:ParseErrors) {
        Write-Out "    - $pe" -ForegroundColor Red
    }
}

if ($CheckCircularDependencies) {
    if ($totalCycles -eq 0) {
        Write-Out "  Circular deps      : none found" -ForegroundColor Green
    }
    else {
        $plural = if ($totalCycles -eq 1) { 'cycle' } else { 'cycles' }
        Write-Out "  Circular deps      : $totalCycles $plural found -- fix before upgrading" -ForegroundColor Red
    }
}

Write-Out $divOuter -ForegroundColor Cyan
Write-Out ""

# ---------------------------------------------------------------------------
# Optional file output — BOM-free UTF-8 via .NET directly.
# PS 5.1's Set-Content -Encoding UTF8 silently emits a BOM on Windows.
# ---------------------------------------------------------------------------
if ($resolvedOutputFile) {
    try {
        [System.IO.File]::WriteAllLines(
            $resolvedOutputFile,
            [string[]]$script:OutLines,
            [System.Text.UTF8Encoding]::new($false)
        )
        Write-Host "Output written to: $resolvedOutputFile" -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not write output file '$resolvedOutputFile': $_"
    }
}