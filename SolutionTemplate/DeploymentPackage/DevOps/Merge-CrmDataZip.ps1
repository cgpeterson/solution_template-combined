# Merges Configuration Migration data zips into one, because Package Deployer imports a single data
# file. Later zips win: a record id that shows up again replaces the earlier copy, so pass dependency
# data first and the project's own data last. Tables, schema fields, relationships and import order
# are combined.
function Merge-CrmDataZip {
    param (
        [Parameter(Mandatory)]
        [string[]]$ZipFiles,

        [Parameter(Mandatory)]
        [string]$OutputZip
    )

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    New-Item -ItemType Directory -Path (Split-Path $OutputZip) -Force | Out-Null
    Copy-Item -Path $ZipFiles[0] -Destination $OutputZip -Force
    if ($ZipFiles.Count -eq 1) { return }

    $output = [IO.Compression.ZipFile]::Open($OutputZip, 'Update')
    try {
        $data = Read-ZipXml -Zip $output -EntryName 'data.xml'
        $schema = Read-ZipXml -Zip $output -EntryName 'data_schema.xml'

        foreach ($file in $ZipFiles[1..($ZipFiles.Count - 1)]) {
            $source = [IO.Compression.ZipFile]::OpenRead($file)
            try {
                Merge-DataXml -Target $data -Source (Read-ZipXml -Zip $source -EntryName 'data.xml')
                Merge-SchemaXml -Target $schema -Source (Read-ZipXml -Zip $source -EntryName 'data_schema.xml')
            }
            finally {
                $source.Dispose()
            }
        }

        Write-ZipXml -Zip $output -EntryName 'data.xml' -Xml $data
        Write-ZipXml -Zip $output -EntryName 'data_schema.xml' -Xml $schema
    }
    finally {
        $output.Dispose()
    }
}

function Merge-DataXml {
    param ([xml]$Target, [xml]$Source)

    foreach ($sourceEntity in $Source.DocumentElement.SelectNodes('entity')) {
        $targetEntity = Find-ChildElement -Parent $Target.DocumentElement -Element $sourceEntity -Key { $_.GetAttribute('name') }
        if (-not $targetEntity) {
            [void]$Target.DocumentElement.AppendChild($Target.ImportNode($sourceEntity, $true))
            continue
        }
        Merge-ChildElements -Target (Get-ChildElement $targetEntity 'records') -Source $sourceEntity.SelectSingleNode('records') -Key { $_.GetAttribute('id') } -Replace
        Merge-ChildElements -Target (Get-ChildElement $targetEntity 'm2mrelationships') -Source $sourceEntity.SelectSingleNode('m2mrelationships') -Key { $_.OuterXml }
    }
}

function Merge-SchemaXml {
    param ([xml]$Target, [xml]$Source)

    foreach ($sourceEntity in $Source.DocumentElement.SelectNodes('entity')) {
        $targetEntity = Find-ChildElement -Parent $Target.DocumentElement -Element $sourceEntity -Key { $_.GetAttribute('name') }
        if (-not $targetEntity) {
            [void]$Target.DocumentElement.AppendChild($Target.ImportNode($sourceEntity, $true))
            continue
        }
        Merge-ChildElements -Target (Get-ChildElement $targetEntity 'fields') -Source $sourceEntity.SelectSingleNode('fields') -Key { $_.GetAttribute('name') }
        Merge-ChildElements -Target (Get-ChildElement $targetEntity 'relationships') -Source $sourceEntity.SelectSingleNode('relationships') -Key { $_.GetAttribute('name') }
    }

    $sourceOrder = $Source.DocumentElement.SelectSingleNode('entityImportOrder')
    if ($sourceOrder) {
        Merge-ChildElements -Target (Get-ChildElement $Target.DocumentElement 'entityImportOrder') -Source $sourceOrder -Key { $_.InnerText }
    }
}

# Appends each child element of $Source that $Target doesn't have yet, matched on $Key. With
# -Replace, a match is replaced by the source copy; otherwise the target's copy is kept.
function Merge-ChildElements {
    param ([System.Xml.XmlElement]$Target, [System.Xml.XmlElement]$Source, [scriptblock]$Key, [switch]$Replace)

    if (-not $Source) { return }
    foreach ($child in @($Source.ChildNodes | Where-Object { $_ -is [System.Xml.XmlElement] })) {
        $imported = $Target.OwnerDocument.ImportNode($child, $true)
        $match = Find-ChildElement -Parent $Target -Element $child -Key $Key
        if (-not $match) { [void]$Target.AppendChild($imported) }
        elseif ($Replace) { [void]$Target.ReplaceChild($imported, $match) }
    }
}

function Find-ChildElement {
    param ([System.Xml.XmlElement]$Parent, [System.Xml.XmlElement]$Element, [scriptblock]$Key)

    # -InputObject, not the pipeline: piping an XmlElement would enumerate its child nodes.
    $wanted = ForEach-Object -InputObject $Element -Process $Key
    $Parent.ChildNodes |
        Where-Object { $_ -is [System.Xml.XmlElement] -and $_.LocalName -eq $Element.LocalName -and (ForEach-Object -InputObject $_ -Process $Key) -eq $wanted } |
        Select-Object -First 1
}

# Returns the named child element, creating it when the file left it out.
function Get-ChildElement {
    param ([System.Xml.XmlElement]$Parent, [string]$Name)

    $child = $Parent.SelectSingleNode($Name)
    if (-not $child) { $child = $Parent.AppendChild($Parent.OwnerDocument.CreateElement($Name)) }
    # Unary comma: return the element itself rather than letting the pipeline unroll its children
    return , $child
}

function Read-ZipXml {
    param ([System.IO.Compression.ZipArchive]$Zip, [string]$EntryName)

    $entry = $Zip.GetEntry($EntryName)
    if (-not $entry) { throw "Data zip has no $EntryName" }
    $stream = $entry.Open()
    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.Load($stream)
        return , $xml
    }
    finally {
        $stream.Dispose()
    }
}

function Write-ZipXml {
    param ([System.IO.Compression.ZipArchive]$Zip, [string]$EntryName, [xml]$Xml)

    $Zip.GetEntry($EntryName).Delete()
    $stream = $Zip.CreateEntry($EntryName).Open()
    try {
        $Xml.Save($stream)
    }
    finally {
        $stream.Dispose()
    }
}
