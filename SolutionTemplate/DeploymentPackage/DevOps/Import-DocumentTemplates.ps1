<#
.SYNOPSIS
    Imports Word (.docx) and Excel (.xlsx) document templates into a Dataverse environment.

.DESCRIPTION
    Replaces the CCLLC.Cds.DevOps Import-DocumentTemplates cmdlet, which connected through
    Get-CrmConnection (Microsoft.Xrm.Data.Powershell, ADAL). This script signs in with MSAL
    (MSAL.PS) and uses the Dataverse Web API, with the same behavior:

    - Each file is matched to an existing documenttemplate record by name (file name without
      extension). A match is updated in place; otherwise a new record is created.
    - documenttype is 1 for Excel, 2 for Word. content is the file, base64 encoded.
    - A Word template embeds its target table as urn:microsoft-crm/document-template/<table>/<code>/.
      Custom tables get a different object type code in each environment, so the code is looked up
      in the target environment and rewritten throughout the document (body, headers, footers and
      custom XML parts) before upload. associatedentitytypecode is set from the same urn.
    - Excel templates carry no such urn: new ones are created without associatedentitytypecode and
      existing ones keep theirs.

    Requires the MSAL.PS module:  Install-Module MSAL.PS -Scope CurrentUser

.PARAMETER EnvironmentUrl
    The environment's URL, e.g. https://org.crm.dynamics.com

.PARAMETER TemplateDirectory
    Folder containing the .docx / .xlsx templates to import.

.PARAMETER TenantId
    Optional Entra tenant id or domain. Defaults to 'organizations' (any work or school account).

.PARAMETER ClientId
    Public client application id. Defaults to Microsoft's published sample client, the same one
    Upload-StagedPortalChanges.ps1 and the pac-free tooling use.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentUrl,

    [Parameter(Mandatory = $true)]
    [string]$TemplateDirectory,

    [string]$TenantId = "organizations",

    [string]$ClientId = "51f81489-12ee-4a9e-aaae-a2591f45987d"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression

$TemplateUrnPrefix = "urn:microsoft-crm/document-template/"

# Parts of a .docx that can carry the table's object type code: the body, headers, footers and the
# custom XML properties parts. Same set the CCLLC cmdlet rewrote.
$ObjectTypeCodePartPattern = '^(word/document\.xml|word/header\d*\.xml|word/footer\d*\.xml|customXml/itemProps\d*\.xml)$'

function Get-WordTemplateTarget {
    <#
    .SYNOPSIS
        Returns @{ Table; ObjectTypeCode } from a .docx template's custom XML, or $null if it has none.
    #>
    param([byte[]]$Content)

    $stream = New-Object System.IO.MemoryStream(, $Content)
    $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        foreach ($entry in $zip.Entries | Where-Object { $_.FullName -match '^customXml/itemProps\d*\.xml$' }) {
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }

            $match = [regex]::Match($xml, [regex]::Escape($TemplateUrnPrefix) + '([^/"]+)/(\d+)/')
            if ($match.Success) {
                return @{ Table = $match.Groups[1].Value; ObjectTypeCode = [int]$match.Groups[2].Value }
            }
        }
        return $null
    }
    finally {
        $zip.Dispose()
    }
}

function Set-WordTemplateObjectTypeCode {
    <#
    .SYNOPSIS
        Returns a copy of a .docx with every "<table>/<old code>/" rewritten to "<table>/<new code>/".
    #>
    param(
        [byte[]]$Content,
        [string]$Table,
        [int]$OldObjectTypeCode,
        [int]$NewObjectTypeCode
    )

    $find = "$Table/$OldObjectTypeCode/"
    $replace = "$Table/$NewObjectTypeCode/"

    $stream = New-Object System.IO.MemoryStream
    $stream.Write($Content, 0, $Content.Length)
    $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Update, $true)
    try {
        foreach ($entry in @($zip.Entries | Where-Object { $_.FullName -match $ObjectTypeCodePartPattern })) {
            $partStream = $entry.Open()
            try {
                $buffer = New-Object System.IO.MemoryStream
                $partStream.CopyTo($buffer)
                $bytes = $buffer.ToArray()

                # Keep the part's encoding: UTF-8, with a BOM only if it already had one.
                $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
                $encoding = New-Object System.Text.UTF8Encoding($hasBom)
                $text = $encoding.GetString($bytes, $(if ($hasBom) { 3 } else { 0 }), $bytes.Length - $(if ($hasBom) { 3 } else { 0 }))

                if ($text.Contains($find)) {
                    [byte[]]$newBytes = $encoding.GetPreamble() + $encoding.GetBytes($text.Replace($find, $replace))
                    # Truncate before writing: the new code can be shorter than the old one.
                    $partStream.SetLength(0)
                    $partStream.Write($newBytes, 0, $newBytes.Length)
                }
            }
            finally {
                $partStream.Dispose()
            }
        }
    }
    finally {
        $zip.Dispose()
    }
    # Unary comma: return the byte[] itself rather than letting the pipeline unroll it into object[]
    return , $stream.ToArray()
}

function Invoke-ImportDocumentTemplates {
    $apiUrl = $EnvironmentUrl.TrimEnd('/') + "/api/data/v9.2"

    Import-Module MSAL.PS -ErrorAction Stop
    Write-Host "Acquiring access token for $EnvironmentUrl..."
    $token = Get-MsalToken `
        -ClientId $ClientId `
        -TenantId $TenantId `
        -Scopes @("$($EnvironmentUrl.TrimEnd('/'))/.default") `
        -RedirectUri "http://localhost"
    if (-not $token -or -not $token.AccessToken) { throw "Failed to acquire an access token for $EnvironmentUrl." }

    $headers = @{
        Authorization      = "Bearer $($token.AccessToken)"
        Accept             = "application/json"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
    }
    $writeHeaders = $headers.Clone()
    $writeHeaders["Content-Type"] = "application/json; charset=utf-8"

    # Existing templates, by name
    $existing = @{}
    $url = "$apiUrl/documenttemplates?`$select=documenttemplateid,name"
    while ($url) {
        $page = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
        foreach ($record in $page.value) { $existing[$record.name] = $record.documenttemplateid }
        $url = $page.'@odata.nextLink'
    }
    Write-Host "Found $($existing.Count) existing templates in target environment."

    $objectTypeCodes = @{}
    $files = @(Get-ChildItem -Path $TemplateDirectory -File | Where-Object { $_.Extension -in '.docx', '.xlsx' } | Sort-Object Extension, Name)
    Write-Host "Found $($files.Count) templates in $TemplateDirectory."

    foreach ($file in $files) {
        $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $content = [IO.File]::ReadAllBytes($file.FullName)
        $body = [ordered]@{ name = $name }

        if ($file.Extension -eq '.docx') {
            $body.documenttype = 2
            $target = Get-WordTemplateTarget -Content $content
            if ($target) {
                if (-not $objectTypeCodes.ContainsKey($target.Table)) {
                    $definition = Invoke-RestMethod -Method Get -Headers $headers `
                        -Uri "$apiUrl/EntityDefinitions(LogicalName='$($target.Table)')?`$select=ObjectTypeCode"
                    $objectTypeCodes[$target.Table] = [int]$definition.ObjectTypeCode
                }
                $environmentCode = $objectTypeCodes[$target.Table]
                if ($environmentCode -ne $target.ObjectTypeCode) {
                    Write-Host "  $($file.Name): updating $($target.Table) object type code $($target.ObjectTypeCode) -> $environmentCode"
                    $content = Set-WordTemplateObjectTypeCode -Content $content -Table $target.Table `
                        -OldObjectTypeCode $target.ObjectTypeCode -NewObjectTypeCode $environmentCode
                }
                $body.associatedentitytypecode = $target.Table
            }
        }
        else {
            $body.documenttype = 1
        }
        $body.content = [Convert]::ToBase64String($content)
        $json = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress))

        if ($existing.ContainsKey($name)) {
            Write-Host "Updating existing template '$name' from $($file.Name)."
            $patchHeaders = $writeHeaders.Clone()
            $patchHeaders["If-Match"] = "*"
            Invoke-RestMethod -Method Patch -Headers $patchHeaders -Body $json `
                -Uri "$apiUrl/documenttemplates($($existing[$name]))" | Out-Null
        }
        else {
            Write-Host "Adding $($file.Name) as a new template."
            Invoke-RestMethod -Method Post -Headers $writeHeaders -Body $json -Uri "$apiUrl/documenttemplates" | Out-Null
        }
    }
}

# Dot-sourcing (". .\Import-DocumentTemplates.ps1 ...") only defines the functions, for testing.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ImportDocumentTemplates
}
