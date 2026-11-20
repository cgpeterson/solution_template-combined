#Requires -Version 5.1
<#
.SYNOPSIS
    Stages the Dataverse solution component folders (GUID-named) that correspond
    to the Power Pages readable files currently staged in git.

.DESCRIPTION
    After running Export.ps1, both the readable mirror (pac pages download) and
    the CDS solution GUID-named powerpagecomponent folders are updated. When a
    dev stages specific readable files (e.g., only the ones they care about for
    their PR), the corresponding GUID folders are NOT automatically staged.

    This helper:
      1. Identifies which readable "site" folder the dev is working with
         (prompts if multiple are present, otherwise auto-selects).
      2. Scans currently staged files under that site's readable folder.
         Handles both ADDITIONS/MODIFICATIONS and DELETIONS:
           - For additions/modifications, reads the staged blob from the git
             index to extract the record's own GUID.
           - For deletions, reads the previous version from HEAD to extract
             the GUID before staging the matching component folder for deletion.
      3. Extracts the record's OWN GUID from each staged file:
         - For .yml files: reads the file's primary-key field (e.g.,
           adx_webformstepid) instead of "the first GUID we find" — the latter
           would pick up foreign keys like adx_nextstep that point to OTHER
           components.
         - For sidecar files (.custom_javascript.js, .custom_css.css, .html
           copy/source/value): locates the parent .yml in the same folder and
           reads ITS primary-key field.
      4. Stages the matching CdsSolution\powerpagecomponents\{GUID}\ folder for
         add OR delete depending on the status of the readable file.
      5. Reports any unmatched readable files at the end.

.PARAMETER RepoRoot
    Path to the git repo root. Defaults to walking up from the script location
    to the first folder containing .git.

.PARAMETER SiteFolderName
    Name of the readable site folder under DeploymentPackage\Sites\. If omitted,
    the script will auto-select if there's only one, or prompt if multiple.

.EXAMPLE
    .\Stage-PortalChange.ps1

.EXAMPLE
    .\Stage-PortalChange.ps1 -SiteFolderName "Contoso Customer Portal"

.NOTES
    Run from anywhere; the script resolves paths from its own location.
    Requires git to be on PATH and the current directory (or RepoRoot) to be
    inside a git working tree.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$SiteFolderName
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Resolve repo root
# -----------------------------------------------------------------------------
if (-not $RepoRoot) {
    # Walk up from the script location until we find a .git folder
    $current = $PSScriptRoot
    while ($current -and -not (Test-Path (Join-Path $current '.git'))) {
        $current = Split-Path -Parent $current
    }
    if (-not $current) {
        throw "Could not locate git repo root starting from $PSScriptRoot"
    }
    $RepoRoot = $current
}

Write-Host "Repo root: $RepoRoot" -ForegroundColor Cyan

$deploymentPackage = Join-Path $RepoRoot 'DeploymentPackage'
if (-not (Test-Path $deploymentPackage)) {
    throw "DeploymentPackage folder not found at $deploymentPackage"
}

$guidFolderRoot = Join-Path $deploymentPackage 'CdsSolution\powerpagecomponents'
if (-not (Test-Path $guidFolderRoot)) {
    Write-Warning "CdsSolution\powerpagecomponents not found at $guidFolderRoot. Nothing to correlate."
    return
}

$sitesRoot = Join-Path $deploymentPackage 'Sites'
if (-not (Test-Path $sitesRoot)) {
    Write-Warning "Sites folder not found at $sitesRoot. Did you run Export.ps1 first?"
    return
}

$configPath = Join-Path $deploymentPackage "Sites\_site-config\PortalToolkit.Config.psd1"
if (-not (Test-Path $configPath)) { throw "PortalToolkit.Config.psd1 not found at $configPath" }
$config   = Import-PowerShellDataFile $configPath
$zeroGuid = '00000000-0000-0000-0000-000000000000'
foreach ($field in @('TenantId', 'SiteWebsiteId')) {
    if ($config.$field -eq $zeroGuid) {
        throw "PortalToolkit.Config.psd1: '$field' is still a placeholder (all-zero GUID). Replace it with the real value before running."
    }
}

# -----------------------------------------------------------------------------
# Discover readable site folders and pick one
# -----------------------------------------------------------------------------
# @(...) forces array semantics even when only one folder is returned.
# Without it, PowerShell unwraps the single result to a string and $candidateSites[0]
# returns the first character of the folder name instead of the folder name.
$candidateSites = @(Get-ChildItem -Path $sitesRoot -Directory |
    Select-Object -ExpandProperty Name)

if ($candidateSites.Count -eq 0) {
    throw "No site folders found under $sitesRoot. Did you run Export.ps1?"
}

if ($SiteFolderName) {
    if ($candidateSites -notcontains $SiteFolderName) {
        throw "Specified SiteFolderName '$SiteFolderName' not found under $sitesRoot. Available: $($candidateSites -join ', ')"
    }
    $chosenSite = $SiteFolderName
}
elseif ($candidateSites.Count -eq 1) {
    $chosenSite = $candidateSites[0]
    Write-Host "Using site: $chosenSite (only one present)" -ForegroundColor Cyan
}
elseif ($config.SiteFriendlyName -and ($candidateSites -contains $config.SiteFriendlyName)) {
    $chosenSite = $config.SiteFriendlyName
    Write-Host "Using site from config: $chosenSite" -ForegroundColor Cyan
}
else {
    Write-Host ""
    Write-Host "Multiple site folders found. Choose one:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $candidateSites.Count; $i++) {
        Write-Host "  [$($i + 1)] $($candidateSites[$i])"
    }
    $selection = Read-Host "Enter the number of the site you want to process"
    $idx = 0
    if (-not [int]::TryParse($selection, [ref]$idx) -or $idx -lt 1 -or $idx -gt $candidateSites.Count) {
        throw "Invalid selection."
    }
    $chosenSite = $candidateSites[$idx - 1]
}

$siteFolderPath = Join-Path $sitesRoot $chosenSite
Write-Host "Processing site folder: $siteFolderPath" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# Collect currently-staged files within the chosen site folder
# -----------------------------------------------------------------------------
# We deliberately do NOT pass a git pathspec ("-- some/path") here.
# PowerShell 5.1's native-command argument passing mangles quoted paths with
# embedded spaces before they reach git, which silently returns zero results.
# Instead, grab all staged paths from git and filter in PowerShell.
#
# Use --name-status (not --name-only) so we know which paths are deletions
# and can route them through the HEAD-read path instead of the index-read path.
$sitePathRelative = "DeploymentPackage/Sites/$chosenSite"
$sitePrefix       = "$sitePathRelative/"

Push-Location $RepoRoot
try {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $allStagedEntries = & git diff --cached --name-status 2>$null
    } catch {
        $allStagedEntries = @()
    }
    finally {
        $ErrorActionPreference = $saved
    }
}
finally {
    Pop-Location
}

# Parse the --name-status output into [pscustomobject]s with Status + Path.
# Format is: <STATUS>\t<PATH>  (for renames it's <STATUS>\t<OLD>\t<NEW>;
# we treat the NEW path as the path of interest, and the rename has the same
# practical effect as an addition for our purposes.)
$stagedItems = New-Object System.Collections.Generic.List[object]
foreach ($line in $allStagedEntries) {
    # Guard against $null entries and non-strings (PowerShell can hand back odd
    # values when capturing native command output).
    if ($null -eq $line) { continue }
    $lineStr = [string]$line
    if ($lineStr.Trim() -eq '') { continue }

    $parts = $lineStr -split "`t"
    if ($parts.Count -lt 2) { continue }
    if ([string]::IsNullOrEmpty($parts[0])) { continue }

    $statusLetter = $parts[0].Substring(0, 1)  # 'R100' -> 'R'
    $path = if ($parts.Count -ge 3) { $parts[2] } else { $parts[1] }

    if ([string]::IsNullOrEmpty($path)) { continue }

    # Normalize to forward slashes (git always emits /, but be defensive)
    $normalized = $path -replace '\\', '/'
    if (-not $normalized.StartsWith($sitePrefix)) { continue }

    $stagedItems.Add([pscustomobject]@{
        Status = $statusLetter
        Path   = $normalized
    }) | Out-Null
}

if ($stagedItems.Count -eq 0) {
    Write-Host ""
    Write-Warning "No staged files under '$sitePathRelative'."
    Write-Host "Stage the readable files you want to commit first (e.g., 'git add ""$sitePathRelative/basic-forms/some-form""'), then re-run this script."
    return
}

Write-Host ""
Write-Host "Found $($stagedItems.Count) staged file(s) under '$sitePathRelative'." -ForegroundColor Green
$deleteCount = ($stagedItems | Where-Object { $_.Status -eq 'D' }).Count
if ($deleteCount -gt 0) {
    Write-Host "  ($deleteCount staged as deletion)" -ForegroundColor DarkGray
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
$guidRegex = '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

function Get-FileContentByRef {
    <#
    Read a file by relative-to-repo path using a specific git ref.
      $Ref = ':'    -> staged index
      $Ref = 'HEAD' -> last committed version (used for deletions)
    Returns $null if git can't find the file at that ref.
    #>
    param(
        [string]$RelPath,
        [string]$Ref,
        [string]$RepoRoot
    )

    $gitPath = $RelPath -replace '\\', '/'
    $spec = if ($Ref -eq ':') { ":$gitPath" } else { "${Ref}:$gitPath" }

    Push-Location $RepoRoot
    try {
        # Native commands that write to stderr can be promoted to terminating
        # errors when $ErrorActionPreference = 'Stop'. We want git's "file
        # doesn't exist" messages to be silent so the caller can probe paths
        # without aborting the script. Save/restore the preference and wrap
        # in try/catch to swallow any errant native-command error.
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = & git show $spec 2>$null
            $exit = $LASTEXITCODE
        }
        catch {
            $raw  = $null
            $exit = 1
        }
        finally {
            $ErrorActionPreference = $saved
        }

        if ($exit -eq 0) {
            if ($null -eq $raw) { return '' }
            if ($raw -is [string]) { return $raw }
            return ($raw -join "`n")
        }
        return $null
    }
    finally {
        Pop-Location
    }
}

function Get-FileContentForStatus {
    <#
    For ADDED/MODIFIED files: read the staged version (git index).
    For DELETED files:        read the HEAD version (last committed).
    Falls back to disk only for non-deletes if the index read fails for
    some odd reason. Returns $null if no source has the content.
    #>
    param(
        [string]$RelPath,
        [string]$Status,
        [string]$RepoRoot
    )

    if ($Status -eq 'D') {
        # Deletion: blob is gone from index, but HEAD still has it.
        return Get-FileContentByRef -RelPath $RelPath -Ref 'HEAD' -RepoRoot $RepoRoot
    }

    # Non-deletion: try the index first.
    $content = Get-FileContentByRef -RelPath $RelPath -Ref ':' -RepoRoot $RepoRoot
    if ($null -ne $content) { return $content }

    # Index miss — fall back to disk.
    $diskPath = Join-Path $RepoRoot ($RelPath -replace '/', '\')
    $exists = $false
    try { $exists = Test-Path -LiteralPath $diskPath }
    catch [System.IO.PathTooLongException] { $exists = $true }

    if ($exists) {
        try { return Get-Content -LiteralPath $diskPath -Raw }
        catch { return $null }
    }
    return $null
}

function Get-PrimaryKeyFieldForYaml {
    <#
    Map a Power Pages readable YAML filename to the YAML field holding the
    record's own GUID (its primary key). Used to extract THE step/page/form's
    own ID rather than a foreign-key GUID like adx_nextstep or adx_webform.

    Returns $null if the filename pattern isn't recognized — caller should
    treat that as "I don't know how to resolve this file, skip it."
    #>
    param([string]$YamlRelPath)

    $name = Split-Path -Leaf $YamlRelPath
    switch -Regex ($name) {
        '\.advancedformmetadata\.yml$'  { return 'adx_webformmetadataid' }
        '\.basicformmetadata\.yml$'     { return 'adx_entityformmetadataid' }
        '\.advancedformstep\.yml$'      { return 'adx_webformstepid' }
        '\.advancedform\.yml$'          { return 'adx_webformid' }
        '\.basicform\.yml$'             { return 'adx_entityformid' }
        '\.webpage\.yml$'               { return 'adx_webpageid' }
        '\.webtemplate\.yml$'           { return 'adx_webtemplateid' }
        '\.contentsnippet\.yml$'        { return 'adx_contentsnippetid' }
        '\.tablepermission\.yml$'       { return 'adx_entitypermissionid' }
        '\.pagetemplate\.yml$'          { return 'adx_pagetemplateid' }
        '\.weblinkset\.yml$'            { return 'adx_weblinksetid' }
        '\.list\.yml$'                  { return 'adx_entitylistid' }
        '\.sitemarker\.yml$'            { return 'adx_sitemarkerid' }
        '\.sitesetting\.yml$'           { return 'adx_sitesettingid' }
        '\.webrole\.yml$'               { return 'adx_webroleid' }
        '\.webfile\.yml$'               { return 'adx_webfileid' }
        default                         { return $null }
    }
}

function Get-OwnGuidsFromYaml {
    <#
    Read a Power Pages readable YAML and return the GUID(s) stored in its
    primary-key field (the record's own ID), NOT a foreign-key GUID like
    adx_nextstep.

    Most readable files describe a single record, so this returns one GUID.
    But metadata files (*.basicformmetadata.yml / *.advancedformmetadata.yml)
    aggregate ALL of a form's metadata records into one file as a YAML list,
    so this returns one GUID per record — otherwise only the first record's
    component folder would ever get staged.

    $Status determines whether to read from the index (A/M/R) or HEAD (D).

    Returns an empty array if the file can't be read or the primary-key field
    is missing.
    #>
    param(
        [string]$YamlRelPath,
        [string]$Status,
        [string]$RepoRoot
    )

    $keyField = Get-PrimaryKeyFieldForYaml -YamlRelPath $YamlRelPath
    if (-not $keyField) { return @() }

    $content = Get-FileContentForStatus -RelPath $YamlRelPath -Status $Status -RepoRoot $RepoRoot
    if ($null -eq $content) { return @() }

    # Match "fieldname: <guid>" on its own line. PAC YAML is flat key:value,
    # one per line, with no nesting in these files. A single file may hold many
    # records (metadata lists), so collect EVERY match, not just the first.
    $guidPattern = '(?im)^\s*' + [regex]::Escape($keyField) + '\s*:\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*$'
    $idMatches = [regex]::Matches($content, $guidPattern)
    if ($idMatches.Count -eq 0) { return @() }

    return @($idMatches | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Select-Object -Unique)
}

function Resolve-ParentYamlPath {
    <#
    Given a sidecar relative path, derive the path of the parent .yml that
    sits beside it. Returns $null if the sidecar pattern isn't recognized.

    For deletions, the parent .yml is typically also deleted in the same
    commit, so we accept a sibling .yml that exists in either the index or
    HEAD (not just disk). Caller passes $Status so we can decide which to
    probe.

    Recognized sidecar patterns:
      Pattern 1: <stem>.custom_javascript.js
                 <stem>.custom_css.css
                 -> parent is <stem>.yml

      Pattern 2: <stem>.<ext1>...<extN>.html
                 (.webpage.copy.html, .webpage.en-US.copy.html,
                  .webtemplate.source.html, .contentsnippet.value.html,
                  .contentsnippet.en-US.value.html, etc.)
                 -> walk extensions off one at a time looking for a sibling .yml
    #>
    param(
        [string]$RelPath,
        [string]$Status,
        [string]$RepoRoot
    )

    function Test-SiblingYaml {
        param(
            [string]$YamlRelPath,
            [string]$Status,
            [string]$RepoRoot
        )
        # For deletes, check HEAD. For non-deletes, check index, then disk.
        if ($Status -eq 'D') {
            $head = Get-FileContentByRef -RelPath $YamlRelPath -Ref 'HEAD' -RepoRoot $RepoRoot
            return ($null -ne $head)
        }
        $idx = Get-FileContentByRef -RelPath $YamlRelPath -Ref ':' -RepoRoot $RepoRoot
        if ($null -ne $idx) { return $true }
        $diskPath = Join-Path $RepoRoot ($YamlRelPath -replace '/', '\')
        try { return Test-Path -LiteralPath $diskPath }
        catch [System.IO.PathTooLongException] { return $true }
    }

    # Pattern 1 — exact suffix match for known sidecar types
    if ($RelPath -match '^(?<stem>.+)\.(?:custom_javascript\.js|custom_css\.css)$') {
        return $Matches['stem'] + '.yml'
    }

    # Pattern 2 — .html walk
    if ($RelPath -match '\.html$') {
        $candidate = $RelPath
        # Defensive cap: avoid infinite loop on weird filenames
        for ($i = 0; $i -lt 10; $i++) {
            if ($candidate -match '^(.+)\.[^.\\/]+$') {
                $candidate = $Matches[1]
                $testYaml = "$candidate.yml"
                if (Test-SiblingYaml -YamlRelPath $testYaml -Status $Status -RepoRoot $RepoRoot) {
                    return $testYaml
                }
            }
            else {
                break
            }
        }
    }

    return $null
}

# -----------------------------------------------------------------------------
# Extract own-GUIDs from staged files (YAMLs directly, sidecars via parent YAML)
# -----------------------------------------------------------------------------
# We track adds-vs-deletes separately so we can stage matching component folders
# correctly: `git add` for adds/mods, `git rm -r` for deletes.
$addOrModGuids   = New-Object System.Collections.Generic.HashSet[string]
$deleteGuids     = New-Object System.Collections.Generic.HashSet[string]
$filesWithNoGuid = New-Object System.Collections.Generic.List[string]
$filesSkipped    = New-Object System.Collections.Generic.List[string]

foreach ($item in $stagedItems) {
    $relPath = $item.Path
    $status  = $item.Status
    $isDelete = ($status -eq 'D')

    try {
        # ---- YAML files: extract THE record's own GUID from its primary-key field ----
        # (NOT every GUID in the body — that would include foreign keys like
        # adx_nextstep and adx_webform, which point to OTHER components.)
        if ($relPath -match '\.yml$') {
            $ownGuids = @(Get-OwnGuidsFromYaml -YamlRelPath $relPath -Status $status -RepoRoot $RepoRoot)
            if ($ownGuids.Count -eq 0) {
                $filesWithNoGuid.Add("$relPath [$status] (could not extract own GUID from primary-key field)") | Out-Null
                continue
            }
            foreach ($ownGuid in $ownGuids) {
                if ($isDelete) {
                    [void]$deleteGuids.Add($ownGuid)
                } else {
                    [void]$addOrModGuids.Add($ownGuid)
                }
            }
            continue
        }

        # ---- Sidecar files (.js, .css, .html): resolve parent YAML and pull its own GUID ----
        $parentYamlPath = Resolve-ParentYamlPath -RelPath $relPath -Status $status -RepoRoot $RepoRoot
        if (-not $parentYamlPath) {
            $filesSkipped.Add("$relPath [$status]") | Out-Null
            continue
        }

        $ownGuids = @(Get-OwnGuidsFromYaml -YamlRelPath $parentYamlPath -Status $status -RepoRoot $RepoRoot)
        if ($ownGuids.Count -eq 0) {
            $filesWithNoGuid.Add("$relPath [$status] (could not extract own GUID from parent YAML '$parentYamlPath')") | Out-Null
            continue
        }
        foreach ($ownGuid in $ownGuids) {
            if ($isDelete) {
                [void]$deleteGuids.Add($ownGuid)
            } else {
                [void]$addOrModGuids.Add($ownGuid)
            }
        }
    }
    catch {
        Write-Host ""
        Write-Host "ERROR while processing staged file: $relPath [$status]" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  At: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
        throw
    }
}

# Reconcile: if a GUID appears in both buckets (e.g., a file was modified AND
# a sibling deleted, both reporting the same parent), prefer the add/mod bucket.
# A deletion + modification of the same component is unusual but let's not
# silently drop the modified content in favor of deleting the component.
$deleteGuidArray = @($deleteGuids | ForEach-Object { $_ })
foreach ($g in $deleteGuidArray) {
    if ($addOrModGuids.Contains($g)) {
        [void]$deleteGuids.Remove($g)
    }
}

Write-Host "Add/Modify GUIDs: $($addOrModGuids.Count)" -ForegroundColor Green
Write-Host "Delete GUIDs:     $($deleteGuids.Count)" -ForegroundColor Green
if ($filesSkipped.Count -gt 0) {
    Write-Host "Skipped $($filesSkipped.Count) file(s) with no matchable parent YAML." -ForegroundColor DarkGray
}

# -----------------------------------------------------------------------------
# Stage matching powerpagecomponents folders
# -----------------------------------------------------------------------------
$foldersAdded      = New-Object System.Collections.Generic.List[string]
$foldersDeleted    = New-Object System.Collections.Generic.List[string]
$guidsWithNoFolder = New-Object System.Collections.Generic.List[string]

# -- Adds/Modifications: git add ----------------------------------------------
foreach ($guid in $addOrModGuids) {
    $folderPath    = Join-Path $guidFolderRoot $guid
    $relFolderPath = "DeploymentPackage/CdsSolution/powerpagecomponents/$guid"

    if (Test-Path $folderPath) {
        Push-Location $RepoRoot
        try {
            $saved = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & git add -- $relFolderPath
                $exit = $LASTEXITCODE
            } catch { $exit = 1 }
            finally { $ErrorActionPreference = $saved }

            if ($exit -eq 0) {
                $foldersAdded.Add($relFolderPath) | Out-Null
            }
            else {
                Write-Warning "git add failed for $relFolderPath (exit code $exit)"
            }
        }
        finally {
            Pop-Location
        }
    }
    else {
        $guidsWithNoFolder.Add("$guid (no folder on disk for add/modify)") | Out-Null
    }
}

# -- Deletions: git rm -r -----------------------------------------------------
# For a deletion, the folder may or may not still exist on disk:
#   - If Export.ps1 was run after the env deletion, the folder is already gone
#     from disk. `git rm -r` will still work because git is operating on the
#     index, not the working tree.
#   - If the folder is in the working tree because Export hasn't been run yet,
#     `git rm -r` removes it from both index and working tree.
foreach ($guid in $deleteGuids) {
    $relFolderPath = "DeploymentPackage/CdsSolution/powerpagecomponents/$guid"
    $folderPath    = Join-Path $guidFolderRoot $guid

    # Check whether the path exists in the index (even if not on disk).
    Push-Location $RepoRoot
    try {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $lsOutput = & git ls-files -- $relFolderPath 2>$null
        } catch { $lsOutput = $null }
        finally { $ErrorActionPreference = $saved }

        $inIndex = ($null -ne $lsOutput) -and ([string]::Join("", $lsOutput).Trim() -ne '')

        if ($inIndex) {
            $saved2 = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & git rm -r -f -- $relFolderPath 2>$null | Out-Null
                $exit = $LASTEXITCODE
            } catch { $exit = 1 }
            finally { $ErrorActionPreference = $saved2 }

            if ($exit -eq 0) {
                $foldersDeleted.Add($relFolderPath) | Out-Null
            }
            else {
                Write-Warning "git rm -r failed for $relFolderPath (exit code $exit)"
            }
        }
        else {
            # Component folder isn't tracked in git, so nothing to delete from
            # the index. Could mean the readable file was for a component type
            # that doesn't materialize as a powerpagecomponents folder, OR the
            # GUID was extracted from the wrong key. Record but don't error.
            $guidsWithNoFolder.Add("$guid (no folder in git index for delete)") | Out-Null
        }
    }
    finally {
        Pop-Location
    }
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Staged additions/modifications: $($foldersAdded.Count)"
foreach ($f in $foldersAdded) {
    Write-Host "  + $f" -ForegroundColor Green
}
Write-Host "Staged deletions:               $($foldersDeleted.Count)"
foreach ($f in $foldersDeleted) {
    Write-Host "  - $f" -ForegroundColor Red
}

if ($filesWithNoGuid.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNINGS — staged files with no extractable own-GUID:" -ForegroundColor Yellow
    foreach ($w in $filesWithNoGuid) {
        Write-Host "  ! $w" -ForegroundColor Yellow
    }
}

if ($guidsWithNoFolder.Count -gt 0) {
    Write-Host ""
    Write-Host "INFO — own-GUIDs with no matching powerpagecomponents folder:" -ForegroundColor DarkGray
    Write-Host "(Some component types don't materialize as powerpagecomponents folders.)" -ForegroundColor DarkGray
    foreach ($g in $guidsWithNoFolder) {
        Write-Host "  . $g" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "Done. Review 'git status' to verify what's staged before committing." -ForegroundColor Cyan
