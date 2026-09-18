#Requires -Version 5.1
<#
.SYNOPSIS
    Pushes staged Power Pages changes to the configured environment in two
    phases: a safe pac-based file upload, then a Web API field-fallback
    patcher to backfill values that pac silently drops.

.DESCRIPTION
    Run this after staging portal changes and it performs a complete deploy:
    the file upload and the field backfill pac leaves behind.

    Phase 1 — pac upload (safe overlay)
      Where a raw `pac pages upload` pushes the entire local Sites/<site>
      folder (potentially overwriting another dev's env-side work with stale
      local files), this helper does:
        1. Re-pulls the current state of the env into a temp folder.
        2. Overlays ONLY the git-staged readable files onto that snapshot.
        3. Uploads the temp folder via `pac pages upload`.
      Result: other devs' in-env changes to files you didn't touch are
      preserved; your staged changes land on top.

    Phase 2 — Web API field patcher (pac fallback)
      pac's adx_*-to-mspp_* schema translation in Enhanced model sites
      silently drops some fields. This phase reads each staged YAML (from
      the git index, NOT the working directory) and PATCHes the relevant
      Dataverse record directly to backfill anything pac missed. Both
      phases share the same source of truth — the git index — so fields
      you've intentionally staged are guaranteed to land in env regardless
      of pac's translation gaps.

    Known limitation: if two devs edit the SAME file (one in env, one
    locally), the overlay wins. That's a real conflict and shows up as a
    visible diff in the PR.

.PARAMETER ConnectionName
    Connection file name under DeploymentPackage\DevOps\CdsConnectionParameters\,
    or the 'MySandbox' shortcut (mirrors Export.ps1). The connection file's
    PowerPagesConnectionParameter section drives both pac auth (Phase 1)
    and Dataverse Web API auth (Phase 2).

.PARAMETER RepoRoot
    Path to the git repo root. Auto-detected if omitted.

.PARAMETER SiteFolderName
    Name of the readable site folder under DeploymentPackage\Sites\.
    Auto-selected if only one is present, prompts if multiple.

.PARAMETER DryRun
    Do everything except the final pac upload AND the field patcher.
    Leaves the temp folder on disk so you can inspect exactly what would
    be pushed.

.PARAMETER SkipFieldPatcher
    Run only the pac upload phase, skipping the Web API field patcher.
    Useful for debugging or when you know your edits don't touch any
    fields pac drops. Almost no one should need this.

.EXAMPLE
    .\Upload-StagedPortalChanges.ps1

.EXAMPLE
    .\Upload-StagedPortalChanges.ps1 -DryRun

.NOTES
    Run AFTER staging your intended changes (git add + Stage-PortalChange.ps1).
    `pac pages upload` pushes to the live site with no gate — the
    confirmation prompt in this script is the only buffer.

    Phase 2 requires the MSAL.PS PowerShell module. Install with:
      Install-Module MSAL.PS -Scope CurrentUser
#>
[CmdletBinding()]
param(
    [ValidateSet("MySandbox","MyTest")] # mirror Export.ps1's list
    [string]$ConnectionName = "MySandbox",

    [string]$RepoRoot,
    [string]$SiteFolderName,
    [switch]$DryRun,
    [switch]$SkipFieldPatcher
)

$ErrorActionPreference = 'Stop'

# =============================================================================
# Folder-to-table mapping (used by Phase 2)
# =============================================================================
$TableMap = @{
    'basic-forms' = @{
        EntitySet           = 'mspp_entityforms'
        LogicalName         = 'mspp_entityform'
        PrimaryKeyYamlField = 'adx_entityformid'
    }
    'advanced-forms' = @{
        EntitySet           = 'mspp_webforms'
        LogicalName         = 'mspp_webform'
        PrimaryKeyYamlField = 'adx_webformid'
    }
    'web-pages' = @{
        EntitySet           = 'mspp_webpages'
        LogicalName         = 'mspp_webpage'
        PrimaryKeyYamlField = 'adx_webpageid'
    }
    'table-permissions' = @{
        EntitySet           = 'mspp_entitypermissions'
        LogicalName         = 'mspp_entitypermission'
        PrimaryKeyYamlField = 'adx_entitypermissionid'
    }
}
# Advanced form steps live nested under advanced-forms/<form>/advanced-form-steps/<step>/
$AdvancedFormStepsTable = @{
    EntitySet           = 'mspp_webformsteps'
    LogicalName         = 'mspp_webformstep'
    PrimaryKeyYamlField = 'adx_webformstepid'
}

# =============================================================================
# Resolve repo root
# =============================================================================
if (-not $RepoRoot) {
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

$sitesRoot = Join-Path $deploymentPackage 'Sites'
if (-not (Test-Path $sitesRoot)) {
    throw "Sites folder not found at $sitesRoot. Run Export.ps1 first."
}

# =============================================================================
# Load project config — Cloud/ProfileName/TenantId are project constants
# (same for every developer on this project), not per-developer values, so
# they live here rather than in the personal connection file.
# =============================================================================
$configPath = Join-Path $deploymentPackage "Sites\_site-config\PortalToolkit.Config.psd1"
if (-not (Test-Path $configPath)) { throw "PortalToolkit.Config.psd1 not found at $configPath" }
$config   = Import-PowerShellDataFile $configPath
$zeroGuid = '00000000-0000-0000-0000-000000000000'

if (-not $config.TenantId -or $config.TenantId -eq $zeroGuid) {
    throw "PortalToolkit.Config.psd1: 'TenantId' is missing or still a placeholder (all-zero GUID). Replace it with the real value before running."
}
foreach ($field in @('Cloud', 'ProfileName')) {
    if (-not $config.$field) {
        throw "PortalToolkit.Config.psd1: '$field' is missing. Set it before running."
    }
}

# =============================================================================
# Load the connection file — only EnvironmentUrl is genuinely per-developer
# (each dev has their own assigned sandbox environment).
# =============================================================================
$devOpsRoot = Split-Path -Parent $PSCommandPath
$ConnectionParameters = switch ($ConnectionName) {
    "MySandbox" { & "C:\\CrmConnection\MyCdsSandboxConnection.ps1" }
    default     { & "$devOpsRoot\CdsConnectionParameters\$ConnectionName.ps1" }
}

$pagesParams = $ConnectionParameters.PowerPagesConnectionParameter
if (-not $pagesParams) {
    throw "Connection file has no PowerPagesConnectionParameter section. Add one (see Export.ps1 for reference)."
}
if (-not $pagesParams.EnvironmentUrl) {
    throw "PowerPagesConnectionParameter.EnvironmentUrl is missing from the connection file."
}

$environmentUrl = $pagesParams.EnvironmentUrl
$pacCloud       = $config.Cloud
$pacProfileName = $config.ProfileName
$tenantId       = $config.TenantId

# Microsoft's "Power Platform admin tools" public client ID
$msftClientId = "51f81489-12ee-4a9e-aaae-a2591f45987d"

Write-Host "pac target: $environmentUrl (cloud: $pacCloud, profile: $pacProfileName)" -ForegroundColor Cyan

# =============================================================================
# Ensure pac auth profile is active
# =============================================================================
pac auth create --url $environmentUrl --cloud $pacCloud --name $pacProfileName 2>&1 | Out-Null
pac auth select --name $pacProfileName 2>&1 | Out-Null

# =============================================================================
# Discover readable site folders locally and pick one
# =============================================================================
$candidateSites = @(Get-ChildItem -Path $sitesRoot -Directory |
    Select-Object -ExpandProperty Name)

if ($candidateSites.Count -eq 0) {
    throw "No site folders found under $sitesRoot. Run Export.ps1 first."
}

if ($SiteFolderName) {
    if ($candidateSites -notcontains $SiteFolderName) {
        throw "Specified SiteFolderName '$SiteFolderName' not found. Available: $($candidateSites -join ', ')"
    }
    $chosenSite = $SiteFolderName
}
elseif ($candidateSites.Count -eq 1) {
    $chosenSite = $candidateSites[0]
    Write-Host "Using local site folder: $chosenSite (only one present)" -ForegroundColor Cyan
}
else {
    Write-Host ""
    Write-Host "Multiple site folders found. Choose one:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $candidateSites.Count; $i++) {
        Write-Host "  [$($i + 1)] $($candidateSites[$i])"
    }
    $selection = Read-Host "Enter the number of the site"
    $idx = 0
    if (-not [int]::TryParse($selection, [ref]$idx) -or $idx -lt 1 -or $idx -gt $candidateSites.Count) {
        throw "Invalid selection."
    }
    $chosenSite = $candidateSites[$idx - 1]
}

$siteReadablePath = Join-Path $sitesRoot $chosenSite
$sitePathRelative = "DeploymentPackage/Sites/$chosenSite"
$sitePrefix       = "$sitePathRelative/"

Write-Host "Local site folder: $siteReadablePath" -ForegroundColor Cyan

# =============================================================================
# Collect staged files under the chosen site folder
# =============================================================================
# Same pattern as Stage-PortalChange: filter in PowerShell, not via git pathspec,
# because PS 5.1 mangles quoted paths with spaces when passed to native binaries.
Push-Location $RepoRoot
try {
    $allStagedPaths = & git diff --cached --name-only
}
finally {
    Pop-Location
}

$stagedPortalPaths = @(
    $allStagedPaths |
        Where-Object { $_ -and $_.Trim() -ne '' } |
        Where-Object {
            $normalized = $_ -replace '\\', '/'
            $normalized.StartsWith($sitePrefix)
        }
)

if ($stagedPortalPaths.Count -eq 0) {
    Write-Warning "No staged files under '$sitePathRelative'."
    Write-Host "Stage your intended portal changes first (git add + Stage-PortalChange.ps1 if needed), then re-run." -ForegroundColor Yellow
    return
}

# Subset of staged files that Phase 2 cares about (.yml only)
$stagedYamlPaths = @(
    $stagedPortalPaths | Where-Object { $_ -match '\.yml$' }
)

Write-Host ""
Write-Host "Staged portal files ($($stagedPortalPaths.Count)):" -ForegroundColor Green
foreach ($p in $stagedPortalPaths) {
    Write-Host "  + $p" -ForegroundColor Green
}

# =============================================================================
# Discover target website from env so we can re-pull the same site
# =============================================================================
Write-Host ""
Write-Host "Listing Power Pages sites in environment..."
$listOutput = pac pages list 2>&1 | Out-String

$guidPattern = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
$linePattern = "^\s*\[(?<idx>\d+)\]\s+(?<id>$guidPattern)\s+(?<n>.+?)\s*$"

$sites = @()
foreach ($line in ($listOutput -split "`r?`n")) {
    if ($line -match $linePattern) {
        $sites += [PSCustomObject]@{
            Index        = [int]$Matches['idx']
            WebSiteId    = $Matches['id']
            FriendlyName = $Matches['n'].Trim()
        }
    }
}

if ($sites.Count -eq 0) {
    Write-Warning "No sites discovered in env. Cannot re-pull. Aborting."
    Write-Warning "Raw 'pac pages list' output for diagnosis:"
    Write-Host "----- begin raw output -----" -ForegroundColor DarkGray
    Write-Host $listOutput -ForegroundColor DarkGray
    Write-Host "----- end raw output -----" -ForegroundColor DarkGray
    Write-Warning "If this contains sites that this script didn't pick up, the parse regex may need updating (see linePattern above)."
    throw "No sites discovered."
}

# Try to auto-match env site to chosen local folder by stripping " - envsuffix"
# from env friendly names. If unambiguous, use it. Otherwise prompt.
$matchedSite = $null
foreach ($s in $sites) {
    $envStripped = $s.FriendlyName
    $lastDash = $envStripped.LastIndexOf(" - ")
    if ($lastDash -gt 0) {
        $envStripped = $envStripped.Substring(0, $lastDash).Trim()
    }
    if ($envStripped -eq $chosenSite) {
        if ($matchedSite) {
            $matchedSite = $null
            break
        }
        $matchedSite = $s
    }
}

if (-not $matchedSite) {
    Write-Host ""
    Write-Host "Could not auto-match local folder '$chosenSite' to an env site. Choose:" -ForegroundColor Yellow
    foreach ($s in $sites) {
        Write-Host ("  [{0}] {1,-40}  ({2})" -f $s.Index, $s.FriendlyName, $s.WebSiteId)
    }
    $selection = Read-Host "Enter the number of the site in the env"
    $idx = 0
    if (-not [int]::TryParse($selection, [ref]$idx)) {
        throw "Invalid selection."
    }
    $matchedSite = $sites | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
    if (-not $matchedSite) {
        throw "Selection $idx not in the list."
    }
}

Write-Host "Matched env site: $($matchedSite.FriendlyName) ($($matchedSite.WebSiteId))" -ForegroundColor Cyan

# =============================================================================
# Confirmation gate — last chance to back out
# =============================================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "About to push staged changes to LIVE env:" -ForegroundColor Yellow
Write-Host "  Env URL: $environmentUrl" -ForegroundColor Yellow
Write-Host "  Site:    $($matchedSite.FriendlyName)" -ForegroundColor Yellow
Write-Host "  Files:   $($stagedPortalPaths.Count) staged file(s)" -ForegroundColor Yellow
if ($DryRun) {
    Write-Host "  Mode:    DRY RUN (no upload, no patcher)" -ForegroundColor Yellow
}
elseif ($SkipFieldPatcher) {
    Write-Host "  Mode:    Phase 1 only (field patcher skipped)" -ForegroundColor Yellow
}
else {
    Write-Host "  Phases:  pac upload + field patcher" -ForegroundColor Yellow
}
Write-Host "================================================================" -ForegroundColor Yellow

$confirm = Read-Host "Continue? (Y/N)"
if ($confirm -ne 'Y' -and $confirm -ne 'y') {
    Write-Host "Cancelled." -ForegroundColor Yellow
    return
}

# =============================================================================
# PHASE 1 — pac upload (safe overlay)
# =============================================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "PHASE 1 — pac upload" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# Re-pull current env state into a temp folder
# -----------------------------------------------------------------------------
$timestamp = (Get-Date -Format 'yyyyMMddHHmmss')
$tempRoot  = Join-Path $env:TEMP "portal-upload-$timestamp"
$tempSite  = Join-Path $tempRoot $chosenSite

New-Item -ItemType Directory -Path $tempRoot | Out-Null

Write-Host ""
Write-Host "Downloading current env state to $tempSite..." -ForegroundColor Cyan
pac pages download `
    --path $tempSite `
    --webSiteId $matchedSite.WebSiteId `
    --modelVersion "Enhanced" `
    --overwrite

if ($LASTEXITCODE -ne 0) {
    throw "pac pages download failed (exit $LASTEXITCODE). Aborting — refusing to upload without a fresh env snapshot."
}

# pac pages download creates a nested subfolder named after the site's technical
# name. The actual content lives there, not directly under $tempSite. Find the
# one subfolder.
$tempSubfolders = @(Get-ChildItem -Path $tempSite -Directory)
if ($tempSubfolders.Count -ne 1) {
    throw "Expected one subfolder under $tempSite after pac pages download, found $($tempSubfolders.Count). Aborting."
}
$tempSiteContent = $tempSubfolders[0].FullName

# The local readable folder has the same nested structure — find its content root
$localSubfolders = @(Get-ChildItem -Path $siteReadablePath -Directory)
if ($localSubfolders.Count -ne 1) {
    throw "Expected one subfolder under $siteReadablePath, found $($localSubfolders.Count). Aborting."
}
$localSiteContent = $localSubfolders[0].FullName

Write-Host "Env snapshot content: $tempSiteContent" -ForegroundColor DarkGray
Write-Host "Local content root:   $localSiteContent" -ForegroundColor DarkGray

# -----------------------------------------------------------------------------
# Extract staged file content from the git index
# -----------------------------------------------------------------------------
# The overlay must use the staged (index) version of each file, NOT the working
# tree file. These diverge whenever Export.ps1 is re-run after staging — the
# export overwrites the working tree with the env's current state while the staged
# changes remain only in the git index. Reading from the working tree path would
# silently push the un-modified exported content back to the env.
$tempIndexRoot   = Join-Path $tempRoot "staged-index"
$tempIndexPrefix = ($tempIndexRoot -replace '\\', '/') + '/'   # git requires forward-slash prefix
New-Item -ItemType Directory $tempIndexRoot | Out-Null

Write-Host ""
Write-Host "Extracting staged file content from git index..." -ForegroundColor Cyan
Push-Location $RepoRoot
try {
    foreach ($relPath in $stagedPortalPaths) {
        $normalizedPath = $relPath -replace '\\', '/'
        & git checkout-index --force --prefix $tempIndexPrefix -- $normalizedPath 2>&1 | Out-Null
        # Non-zero exit code here means the path is a staged deletion (no blob in
        # the index). The overlay loop handles that case via Test-Path below.
    }
}
finally {
    Pop-Location
}

# -----------------------------------------------------------------------------
# Overlay staged files onto the fresh snapshot
# -----------------------------------------------------------------------------
# Each staged path is relative to repo root, shaped like
#   DeploymentPackage/Sites/<chosenSite>/<sub>/<rest>
# We need to map that to
#   $tempSiteContent/<rest>  (stripping the first level under the site folder,
#                             because $tempSiteContent already IS that first level)
$localSiteContentRelativeToSite = (Resolve-Path $localSiteContent).Path.Substring(
    (Resolve-Path $siteReadablePath).Path.Length
).TrimStart('\','/') -replace '\\','/'

Write-Host ""
Write-Host "Overlaying $($stagedPortalPaths.Count) staged file(s)..." -ForegroundColor Cyan
$overlaidCount = 0
$skippedCount  = 0

foreach ($relPath in $stagedPortalPaths) {
    $normalized = $relPath -replace '\\', '/'

    # Strip the "DeploymentPackage/Sites/<chosenSite>/" prefix -> rest-of-path
    $underSite = $normalized.Substring($sitePrefix.Length)

    # Strip the nested-site-content prefix
    $expectedPrefix = "$localSiteContentRelativeToSite/"
    if (-not $underSite.StartsWith($expectedPrefix)) {
        Write-Warning "Staged file '$relPath' does not sit under expected site content subfolder. Skipping."
        $skippedCount++
        continue
    }
    $underContent = $underSite.Substring($expectedPrefix.Length)

    # Source is the index-extracted copy, not the working tree file.
    $sourceFile = Join-Path $tempIndexRoot $relPath
    $targetFile = Join-Path $tempSiteContent ($underContent -replace '/','\')

    # PS 5.1 Test-Path throws PathTooLongException for paths > 260 chars, even
    # though Windows itself supports them. Wrap in try/catch and treat a
    # "too long" error as "file exists" — only an existing path can have a
    # length in the first place. A non-existent path would return false cleanly.
    $sourceExists = $false
    try { $sourceExists = Test-Path -LiteralPath $sourceFile }
    catch [System.IO.PathTooLongException] { $sourceExists = $true }

    if (-not $sourceExists) {
        # Staged deletion — remove from the overlay too
        $targetExists = $false
        try { $targetExists = Test-Path -LiteralPath $targetFile }
        catch [System.IO.PathTooLongException] { $targetExists = $true }

        if ($targetExists) {
            cmd /c "del /f /q `"$targetFile`"" 2>&1 | Out-Null
            Write-Host "  - $underContent (deleted)" -ForegroundColor Yellow
            $overlaidCount++
        }
        else {
            Write-Host "  . $underContent (staged delete, already absent from env)" -ForegroundColor DarkGray
            $skippedCount++
        }
        continue
    }

    # Ensure target directory exists (staged file might be in a new subfolder)
    $targetDir = Split-Path -Parent $targetFile
    $targetDirExists = $false
    try { $targetDirExists = Test-Path -LiteralPath $targetDir }
    catch [System.IO.PathTooLongException] { $targetDirExists = $true }
    if (-not $targetDirExists) {
        cmd /c "mkdir `"$targetDir`"" 2>&1 | Out-Null
    }

    # Use robocopy for the copy itself — most reliable tool for long paths.
    $sourceDir  = Split-Path -Parent $sourceFile
    $sourceName = Split-Path -Leaf   $sourceFile
    $targetName = Split-Path -Leaf   $targetFile

    # /NFL /NDL /NJH /NJS /NC /NS /NP: silence robocopy's chatty output.
    # /IS: include same files (overwrite even if identical by timestamp/size).
    $robocopyOutput = robocopy $sourceDir $targetDir $sourceName /IS /NFL /NDL /NJH /NJS /NC /NS /NP 2>&1
    # Robocopy exit codes: 0-7 are success variants, 8+ are failures.
    if ($LASTEXITCODE -ge 8) {
        Write-Warning "robocopy failed for $underContent (exit $LASTEXITCODE)"
        Write-Warning ($robocopyOutput -join "`n")
        $skippedCount++
        continue
    }

    # If source filename differs from target filename (defensive), rename.
    if ($sourceName -ne $targetName) {
        $copiedPath = Join-Path $targetDir $sourceName
        $finalPath  = Join-Path $targetDir $targetName
        cmd /c "move /y `"$copiedPath`" `"$finalPath`"" 2>&1 | Out-Null
    }

    Write-Host "  + $underContent" -ForegroundColor Green
    $overlaidCount++
}

Write-Host ""
Write-Host "Overlaid $overlaidCount file(s); skipped $skippedCount." -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# Upload (or bail out for dry run)
# -----------------------------------------------------------------------------
if ($DryRun) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "DRY RUN — no upload performed, no field patcher run." -ForegroundColor Yellow
    Write-Host "Inspect the merged site at:" -ForegroundColor Yellow
    Write-Host "  $tempSiteContent" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "When you are satisfied, re-run without -DryRun." -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    return
}

Write-Host ""
Write-Host "Uploading merged site to env..." -ForegroundColor Cyan
# --path must point to the folder that directly contains website.yml. After
# pac pages download, that's $tempSiteContent (the inner site-technical-name
# subfolder), not $tempSite (the parent we passed to download).
#
# --forceUploadAll is REQUIRED because of how this script's overlay approach works.
# After pac pages download, pac's internal manifest considers all files "synced".
# Our overlay modifies file content but doesn't update the manifest. Without
# --forceUploadAll, pac compares files against the manifest, sees nothing changed,
# and uploads zero records (silent no-op). With the flag, pac re-uploads all
# records — which is exactly what we want, because the temp folder content IS
# env-current-state + our staged changes.
#
# IMPORTANT: pac pages upload does NOT support a --webSiteId argument — the site
# is implicit from the .portalconfig inside the path.
pac pages upload `
    --path $tempSiteContent `
    --modelVersion "Enhanced" `
    --forceUploadAll

if ($LASTEXITCODE -ne 0) {
    Write-Warning "pac pages upload failed (exit $LASTEXITCODE)."
    Write-Warning "Temp folder left in place for debugging: $tempSite"
    throw "Upload failed."
}

Write-Host ""
Write-Host "Phase 1 complete: pac upload succeeded." -ForegroundColor Green

# =============================================================================
# PHASE 2 — Web API field patcher
# =============================================================================

# Resolve which Dataverse table a staged YAML path belongs to.
# Files of types Phase 2 doesn't know about (e.g., .js sidecars, web files,
# anything outside $TableMap) are silently skipped — they were handled by pac
# in Phase 1 and don't have a known translation gap.
function Resolve-TargetTable {
    param([string]$RelativeYamlPath)
    $afterSite = $RelativeYamlPath.Substring($sitePrefix.Length) -replace '\\','/'
    $segments  = $afterSite -split '/'
    if ($segments.Count -lt 3) { return $null }

    $folderType = $segments[1]

    if ($folderType -eq 'advanced-forms' -and $segments.Count -ge 5 -and $segments[3] -eq 'advanced-form-steps') {
        return $AdvancedFormStepsTable
    }
    if ($TableMap.ContainsKey($folderType)) {
        return $TableMap[$folderType]
    }
    return $null
}

# Which staged YAMLs Phase 2 will actually patch — used to decide whether
# to bother authenticating MSAL at all.
$patchableYamls = @()
$unsupportedYamls = @()
foreach ($p in $stagedYamlPaths) {
    if (Resolve-TargetTable -RelativeYamlPath $p) {
        $patchableYamls += $p
    }
    else {
        $unsupportedYamls += $p
    }
}

if ($SkipFieldPatcher) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "Phase 2 SKIPPED via -SkipFieldPatcher" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
}
elseif ($patchableYamls.Count -eq 0) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "Phase 2 SKIPPED: no staged YAMLs in patchable folder types" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
}
else {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "PHASE 2 — Web API field patcher" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan

    # -------------------------------------------------------------------------
    # Auth (MSAL.PS — interactive on first run, cached after)
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Host "Acquiring access token..." -ForegroundColor Cyan
    Import-Module MSAL.PS -ErrorAction Stop

    $token = Get-MsalToken `
        -ClientId $msftClientId `
        -TenantId $tenantId `
        -Scopes @("$environmentUrl/.default") `
        -RedirectUri "http://localhost"

    if (-not $token -or -not $token.AccessToken) { throw "Failed to acquire access token." }

    Write-Host "Token acquired (expires $($token.ExpiresOn))" -ForegroundColor Green

    $readHeaders = @{
        Authorization      = "Bearer $($token.AccessToken)"
        Accept             = "application/json"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
    }
    $writeHeaders = $readHeaders.Clone()
    $writeHeaders["Content-Type"] = "application/json"
    $writeHeaders["If-Match"]     = "*"

    # -------------------------------------------------------------------------
    # Helpers (Phase 2)
    # -------------------------------------------------------------------------

    # Read the STAGED (git-index) version of a file as an array of lines.
    # This is the same source of truth pac sees in Phase 1 (via the overlay).
    function Get-StagedFileLines {
        param([string]$RelativePath)
        $gitPath = $RelativePath -replace '\\', '/'
        Push-Location $RepoRoot
        try {
            $output = & git show ":$gitPath" 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            if ($output -is [string]) { return $output -split "`r?`n" }
            return $output
        }
        finally { Pop-Location }
    }

    # Parse YAML lines into an ordered hashtable. Power Pages YAML files we
    # touch are flat key:value with no nesting — a line-based parser is enough.
    function ConvertFrom-PortalYamlLines {
        param($Lines)
        $fields = [ordered]@{}
        if (-not $Lines) { return $fields }
        foreach ($line in $Lines) {
            if ($null -eq $line) { continue }
            if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*?)\s*$') {
                $key   = $Matches[1]
                $value = $Matches[2]
                if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") {
                    $value = $Matches[1]
                }
                if ($value -eq '') { $value = $null }
                $fields[$key] = $value
            }
        }
        return $fields
    }

    # Coerce string YAML values to typed JSON values (booleans, ints).
    function Convert-YamlValueToTyped {
        param($Value)
        if ($null -eq $Value) { return $null }
        if ($Value -is [string]) {
            if ($Value -match '^(?i)true$')  { return $true }
            if ($Value -match '^(?i)false$') { return $false }
            if ($Value -match '^-?\d+$') {
                $intVal = 0
                if ([int]::TryParse($Value, [ref]$intVal)) { return $intVal }
            }
        }
        return $Value
    }

    # Fetch and cache the schema for a table — column names, lookup targets,
    # and which columns are read-only (computed). Used to drive the field
    # translation and lookup-bind formatting.
    function Get-TableSchema {
        param(
            [string]$LogicalName,
            [hashtable]$Cache
        )
        if ($Cache.ContainsKey($LogicalName)) { return $Cache[$LogicalName] }

        $columns         = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $computedColumns = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $lookupAttrs     = @()
        $lookupTargets   = @{}

        try {
            $metaUrl = "$environmentUrl/api/data/v9.2/EntityDefinitions(LogicalName='$LogicalName')/Attributes?`$select=LogicalName,AttributeType,IsValidForUpdate"
            $metaResp = Invoke-RestMethod -Uri $metaUrl -Method Get -Headers $readHeaders
            foreach ($attr in $metaResp.value) {
                [void]$columns.Add($attr.LogicalName)
                if ($attr.IsValidForUpdate -eq $false) {
                    [void]$computedColumns.Add($attr.LogicalName)
                }
                if ($attr.AttributeType -eq 'Lookup' -or $attr.AttributeType -eq 'Customer' -or $attr.AttributeType -eq 'Owner') {
                    $lookupAttrs += $attr.LogicalName
                }
            }
        }
        catch {
            Write-Warning "Failed to fetch column metadata for $LogicalName : $($_.Exception.Message)"
        }

        foreach ($lookup in $lookupAttrs) {
            try {
                $lookupUrl = "$environmentUrl/api/data/v9.2/EntityDefinitions(LogicalName='$LogicalName')/Attributes(LogicalName='$lookup')/Microsoft.Dynamics.CRM.LookupAttributeMetadata?`$select=Targets"
                $lookupResp = Invoke-RestMethod -Uri $lookupUrl -Method Get -Headers $readHeaders
                if ($lookupResp.Targets -and $lookupResp.Targets.Count -gt 0) {
                    $targetLogicalName = $lookupResp.Targets[0]
                    $entityDefUrl = "$environmentUrl/api/data/v9.2/EntityDefinitions(LogicalName='$targetLogicalName')?`$select=EntitySetName"
                    $entityDefResp = Invoke-RestMethod -Uri $entityDefUrl -Method Get -Headers $readHeaders
                    $lookupTargets[$lookup] = $entityDefResp.EntitySetName
                }
            }
            catch {
                Write-Warning "  Could not resolve lookup target for $LogicalName.$lookup : $($_.Exception.Message)"
            }
        }

        $schema = [PSCustomObject]@{
            Columns         = $columns
            LookupTargets   = $lookupTargets
            ComputedColumns = $computedColumns
        }
        $Cache[$LogicalName] = $schema
        return $schema
    }

    # Build the JSON payload and PATCH the record.
    function Invoke-RecordPatch {
        param(
            [hashtable]$TableInfo,
            [string]$RecordId,
            $YamlFields,
            [hashtable]$SchemaCache
        )

        $entitySet   = $TableInfo.EntitySet
        $logicalName = $TableInfo.LogicalName
        $primaryKey  = $TableInfo.PrimaryKeyYamlField

        $schema = Get-TableSchema -LogicalName $logicalName -Cache $SchemaCache

        $payload    = [ordered]@{}
        $skipped    = @()
        $translated = 0

        foreach ($key in $YamlFields.Keys) {
            if ($key -ieq $primaryKey) { continue }

            $msppKey = if ($key -match '^adx_(.+)$') { "mspp_$($Matches[1])" } else { $key }

            if (-not $schema.Columns.Contains($msppKey)) {
                $skipped += "$key -> $msppKey (no such column on $logicalName)"
                continue
            }
            if ($schema.ComputedColumns.Contains($msppKey)) {
                $skipped += "$key -> $msppKey (read-only / computed column)"
                continue
            }

            $rawValue = $YamlFields[$key]

            # Lookup field — needs @odata.bind syntax with target entity set
            if ($schema.LookupTargets.ContainsKey($msppKey)) {
                if ($null -eq $rawValue -or $rawValue -eq '') {
                    $payload["$msppKey@odata.bind"] = $null
                }
                else {
                    $targetSet = $schema.LookupTargets[$msppKey]
                    $payload["$msppKey@odata.bind"] = "/$targetSet($rawValue)"
                }
                $translated++
                continue
            }

            $payload[$msppKey] = Convert-YamlValueToTyped -Value $rawValue
            $translated++
        }

        if ($payload.Count -eq 0) {
            return [PSCustomObject]@{ Patched = 0; Skipped = $skipped; Error = $null }
        }

        $url  = "$environmentUrl/api/data/v9.2/$entitySet($RecordId)"
        $body = $payload | ConvertTo-Json -Compress -Depth 5

        try {
            Invoke-RestMethod -Uri $url -Method Patch -Headers $writeHeaders -Body $body | Out-Null
            return [PSCustomObject]@{ Patched = $translated; Skipped = $skipped; Error = $null }
        }
        catch {
            $errMsg = $_.Exception.Message
            try {
                if ($_.Exception.Response) {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $reader.BaseStream.Position = 0
                    $errBody = $reader.ReadToEnd()
                    if ($errBody) { $errMsg = "$errMsg :: $errBody" }
                }
            } catch { }
            return [PSCustomObject]@{ Patched = 0; Skipped = $skipped; Error = $errMsg }
        }
    }

    # -------------------------------------------------------------------------
    # Patch loop
    # -------------------------------------------------------------------------
    $schemaCache  = @{}
    $totalFiles   = 0
    $totalPatched = 0
    $totalSkipped = 0
    $totalErrors  = 0
    $errorDetails = @()

    foreach ($relPath in $patchableYamls) {
        $totalFiles++
        $tableInfo = Resolve-TargetTable -RelativeYamlPath $relPath

        $stagedLines = Get-StagedFileLines -RelativePath $relPath
        if ($null -eq $stagedLines) {
            Write-Warning "Could not read staged content for: $relPath"
            $totalErrors++
            $errorDetails += "$relPath`: failed to read from git index"
            continue
        }

        $yamlFields = ConvertFrom-PortalYamlLines -Lines $stagedLines
        $primaryKey = $tableInfo.PrimaryKeyYamlField
        $recordId   = $yamlFields[$primaryKey]

        if (-not $recordId) {
            Write-Warning "Could not extract record ID ($primaryKey) from $relPath"
            $totalErrors++
            continue
        }

        Write-Host ""
        Write-Host "  $relPath" -ForegroundColor White
        Write-Host "    -> $($tableInfo.LogicalName)($recordId)" -ForegroundColor DarkGray

        $result = Invoke-RecordPatch -TableInfo $tableInfo -RecordId $recordId -YamlFields $yamlFields -SchemaCache $schemaCache

        if ($result.Error) {
            Write-Host "    ERROR: $($result.Error)" -ForegroundColor Red
            $totalErrors++
            $errorDetails += "$relPath`: $($result.Error)"
        }
        else {
            Write-Host "    Patched $($result.Patched) field(s); skipped $($result.Skipped.Count) field(s)" -ForegroundColor Green
            $totalPatched += $result.Patched
            $totalSkipped += $result.Skipped.Count
            if ($result.Skipped.Count -gt 0) {
                foreach ($s in $result.Skipped) {
                    Write-Host "      ! $s" -ForegroundColor Yellow
                }
            }
        }
    }

    Write-Host ""
    Write-Host "Phase 2 summary:" -ForegroundColor Cyan
    Write-Host "  Files processed:   $totalFiles"
    Write-Host "  Fields patched:    $totalPatched" -ForegroundColor Green
    Write-Host "  Fields skipped:    $totalSkipped" -ForegroundColor Yellow
    Write-Host "  Files with errors: $totalErrors" -ForegroundColor $(if ($totalErrors -gt 0) { 'Red' } else { 'Green' })
    if ($unsupportedYamls.Count -gt 0) {
        Write-Host "  Unsupported YAMLs: $($unsupportedYamls.Count) (passed through Phase 1 only)" -ForegroundColor DarkGray
    }
    if ($errorDetails.Count -gt 0) {
        Write-Host ""
        Write-Host "Errors:" -ForegroundColor Red
        foreach ($e in $errorDetails) { Write-Host "  - $e" -ForegroundColor Red }
    }
}

# =============================================================================
# Cleanup and final reminder
# =============================================================================
try {
    cmd /c "rd /s /q `"$tempRoot`"" | Out-Null
}
catch {
    Write-Warning "Could not clean up $tempRoot — safe to delete manually."
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "Push complete. Dataverse records have been updated." -ForegroundColor Green
Write-Host ""
Write-Host "IMPORTANT — verify your changes in the portal:" -ForegroundColor Yellow
Write-Host "  pac pages upload updates Dataverse records but does NOT" -ForegroundColor Yellow
Write-Host "  automatically refresh the portal runtime cache. If the change" -ForegroundColor Yellow
Write-Host "  is not visible on the live site yet, open Power Pages Studio" -ForegroundColor Yellow
Write-Host "  and click Sync (or Publish) to push the updated records to" -ForegroundColor Yellow
Write-Host "  the portal's cache." -ForegroundColor Yellow
Write-Host ""
Write-Host "To confirm a change hit Dataverse before syncing, open the" -ForegroundColor Cyan
Write-Host "Power Pages Management App and look up the record directly." -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Green
