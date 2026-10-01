<#
.SYNOPSIS
    Creates a new client solution repo from SolutionTemplate\.

.DESCRIPTION
    Copies the git-tracked files under SolutionTemplate\ to -Destination and replaces the template
    tokens. It also renames CdsSolutionTemplate.sln to <SolutionName>.sln and gives the solution a
    new SolutionGuid. Each project gets its own plugin strong-name key (Plugins\plugin.snk), so
    assemblies from different clients never share a key.

    Per-developer placeholders ([mydev], [mytenant]) in the connection templates are left alone.
    The optional ADO values stay as replace-with-* placeholders when omitted, and they are listed
    at the end as follow-ups.

    See docs\New-Project-Setup.md for the steps that come before and after running this script.

.EXAMPLE
    .\New-Project.ps1 -Destination C:\Repos\contoso_claims -SolutionName ContosoClaims `
        -PublisherPrefix cc -ClientPrefix Contoso -ClientName "Contoso Ltd"
#>
[CmdletBinding()]
param (
    # Folder to create. It must not exist yet, or must be empty.
    [Parameter(Mandatory)]
    [string]
    $Destination,

    # Dataverse solution unique name. Replaces [solutionname].
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')]
    [string]
    $SolutionName,

    # Dataverse publisher prefix: 2-8 lowercase letters/digits, starting with a letter. Replaces [publisherprefix].
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9]{1,7}$')]
    [string]
    $PublisherPrefix,

    # Short client identifier used in the artifact package id (<ClientPrefix>.Cds.<SolutionName>.Sources). Replaces [clientprefix].
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')]
    [string]
    $ClientPrefix,

    # Client display name, used as the artifact package owner. Replaces [clientname].
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $ClientName,

    # Plugin assembly name and root namespace. Replaces PluginAssemblyName. Defaults to <SolutionName>.Plugins.
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$')]
    [string]
    $PluginAssemblyName,

    # Client ADO organization (.mcp.json). Optional.
    [string]
    $AdoOrganization,

    # Client ADO project (.mcp.json). Optional.
    [string]
    $AdoProject,

    # ADO Artifacts feed ID as {org-guid}/{feed-guid} (azure-pipelines.yml). Optional.
    [ValidatePattern('^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}$')]
    [string]
    $ProjectFeedId
)

$ErrorActionPreference = 'Stop'

$templateRoot = Join-Path $PSScriptRoot 'SolutionTemplate'
$binaryExtensions = '.dll', '.exe', '.pdb', '.snk', '.png', '.jpg', '.jpeg', '.gif', '.ico', '.zip', '.nupkg'
$xmlExtensions = '.xml', '.nuspec', '.csproj', '.config', '.props', '.targets'
$leftoverTokenPattern = '\[(solutionname|publisherprefix|clientprefix|clientname)\]|PluginAssemblyName|replace-with-[a-z]'

function Get-TokenMap {
    param ([bool] $EscapeForXml)

    $clientNameValue = if ($EscapeForXml) { [System.Security.SecurityElement]::Escape($ClientName) } else { $ClientName }
    $map = [ordered]@{
        '[solutionname]'     = $SolutionName
        '[publisherprefix]'  = $PublisherPrefix
        '[clientprefix]'     = $ClientPrefix
        '[clientname]'       = $clientNameValue
        'PluginAssemblyName' = $PluginAssemblyName
    }
    if ($ProjectFeedId)   { $map['replace-with-your-org-guid/replace-with-your-feed-guid'] = $ProjectFeedId }
    if ($AdoOrganization) { $map['replace-with-client-ado-org'] = $AdoOrganization }
    if ($AdoProject)      { $map['replace-with-client-ado-project'] = $AdoProject }
    return $map
}

function Get-FileEncoding {
    param ([byte[]] $Bytes)

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return New-Object System.Text.UTF8Encoding $true
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return New-Object System.Text.UnicodeEncoding $false, $true
    }
    return New-Object System.Text.UTF8Encoding $false
}

function Update-Tokens {
    param ([string] $Path)

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($binaryExtensions -contains $extension) {
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $encoding = Get-FileEncoding -Bytes $bytes
    $preambleLength = $encoding.GetPreamble().Length
    $content = $encoding.GetString($bytes, $preambleLength, $bytes.Length - $preambleLength)

    $updated = $content
    $tokenMap = Get-TokenMap -EscapeForXml ($xmlExtensions -contains $extension)
    foreach ($token in $tokenMap.Keys) {
        $updated = $updated.Replace($token, $tokenMap[$token])
    }

    if ($updated -ne $content) {
        [System.IO.File]::WriteAllText($Path, $updated, $encoding)
    }
}

function New-StrongNameKey {
    param ([string] $Path)

    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 1024
    try {
        [System.IO.File]::WriteAllBytes($Path, $rsa.ExportCspBlob($true))
    }
    finally {
        $rsa.Dispose()
    }
}

if (-not $PluginAssemblyName) {
    $PluginAssemblyName = "$SolutionName.Plugins"
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is required: New-Project.ps1 copies only the git-tracked files in SolutionTemplate\.'
}

if ((Test-Path $Destination) -and (Get-ChildItem $Destination -Force | Select-Object -First 1)) {
    throw "Destination '$Destination' already exists and is not empty."
}

$pendingTemplateChanges = git -C $PSScriptRoot status --porcelain -- SolutionTemplate
if ($pendingTemplateChanges) {
    Write-Warning 'SolutionTemplate\ has uncommitted changes. Their working-copy versions are copied as-is.'
}

$trackedFiles = git -C $templateRoot -c core.quotepath=off ls-files
if ($LASTEXITCODE -ne 0) {
    throw "git ls-files failed for '$templateRoot'."
}

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$destinationRoot = (Resolve-Path $Destination).Path

Write-Host "Copying $($trackedFiles.Count) template files to $destinationRoot"
foreach ($relativePath in $trackedFiles) {
    $source = Join-Path $templateRoot $relativePath
    $target = Join-Path $destinationRoot $relativePath
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $target
    Update-Tokens -Path $target
}

$solutionFile = Join-Path $destinationRoot "$SolutionName.sln"
Move-Item -LiteralPath (Join-Path $destinationRoot 'CdsSolutionTemplate.sln') -Destination $solutionFile
$solutionText = [System.IO.File]::ReadAllText($solutionFile)
$solutionText = $solutionText -replace 'SolutionGuid = \{[0-9A-Fa-f-]+\}', ('SolutionGuid = {' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}')
[System.IO.File]::WriteAllText($solutionFile, $solutionText, (New-Object System.Text.UTF8Encoding $true))

New-StrongNameKey -Path (Join-Path $destinationRoot 'Plugins\plugin.snk')

$leftovers = foreach ($relativePath in $trackedFiles) {
    $relativePath = $relativePath -replace '^CdsSolutionTemplate\.sln$', "$SolutionName.sln"
    if ($binaryExtensions -contains [System.IO.Path]::GetExtension($relativePath).ToLowerInvariant()) {
        continue
    }
    Select-String -LiteralPath (Join-Path $destinationRoot $relativePath) -Pattern $leftoverTokenPattern -CaseSensitive |
        ForEach-Object { '{0}:{1}  {2}' -f $relativePath, $_.LineNumber, $_.Line.Trim() }
}

Write-Host ''
Write-Host "Created $SolutionName at $destinationRoot" -ForegroundColor Green
Write-Host "  Solution file:    $SolutionName.sln"
Write-Host "  Plugin assembly:  $PluginAssemblyName"
Write-Host "  Publisher prefix: $PublisherPrefix"

if ($leftovers) {
    Write-Host ''
    Write-Host 'Placeholders still to fill in:' -ForegroundColor Yellow
    $leftovers | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-Host 'Next: follow docs\New-Project-Setup.md (git init, sandbox + empty solution, first export).'
