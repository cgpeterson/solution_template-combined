param (
    # The connection parameters for the target organization
    [ValidateSet("MySandbox","MyTest")] # update this list based on files in the CdsConnectionParameters folder
    [string]
    $ConnectionName = "MySandbox",

    # The settings for the actions performed during the export
    [ValidateSet("DefaultSettings")] # update this list based on files in the Settings folder
    [string]
    $ExportSettings = "DefaultSettings",

    # The available actions to perform during the export
    [ValidateSet("All","Solutions","ConfigData","TestData","PortalPages","Export-CrmSolutions","Expand-CrmSolutions","Export-ConfigData","Expand-ConfigData","Export-TestData","Expand-TestData","Stage-PortalChange")]
    [string[]]
    $Actions = "Solutions",

    # Passed through to Stage-PortalChange.ps1 when 'Stage-PortalChange' is requested.
    [string]
    $SiteFolderName
)

$global:ErrorActionPreference = "Stop"
$Env:CRM_SDK_PATH = "$PSScriptRoot\Tools"

# Adoxio.Dynamics.DevOps is kept only for Expand-CrmData (local, no connection).
Import-Module "$env:CRM_SDK_PATH\Adoxio.Dynamics.DevOps\Adoxio.Dynamics.DevOps.psd1" -Force

$ConnectionParameters = switch ($ConnectionName) {
    "MySandbox" {& "C:\\CrmConnection\MyCdsSandboxConnection.ps1"}
    default     {& "$PSScriptRoot\CdsConnectionParameters\$ConnectionName.ps1"}
}

$settings = & "$PSScriptRoot\Settings\$ExportSettings.ps1" -ConnectionParameters $ConnectionParameters
$cdsSolutionFolder = "$($PSScriptRoot | Split-Path)\CdsSolution"

. "$PSScriptRoot\Doctoring\UpdateSolutionVersion.ps1"


# pac auth -- only set up when a requested action actually needs a live connection.
$needsPacAuth = 'All' -in $Actions -or 'Solutions' -in $Actions -or 'ConfigData' -in $Actions -or 'TestData' -in $Actions `
    -or 'Export-CrmSolutions' -in $Actions -or 'Export-ConfigData' -in $Actions -or 'Export-TestData' -in $Actions

if ($needsPacAuth) {
    $pacParams = $ConnectionParameters.PacConnectionParameter
    if (-not $pacParams -or -not $pacParams.EnvironmentUrl) {
        throw "Connection file '$ConnectionName' has no PacConnectionParameter.EnvironmentUrl. Add one (e.g. https://<org>.crm9.dynamics.com) before running Export.ps1."
    }

    $pacProfileName = $settings.SolutionName
    Write-Host "pac auth: $($pacParams.EnvironmentUrl) (profile: $pacProfileName)"
    pac auth create --url $pacParams.EnvironmentUrl --name $pacProfileName | Out-Null
    pac auth select --name $pacProfileName | Out-Null
}


# ---------------------------------------------------------------------------
# CDS Solutions — export and extract
# ---------------------------------------------------------------------------

if ($settings.ExportSolutions -and ('All' -in $Actions -or 'Solutions' -in $Actions -or 'Export-CrmSolutions' -in $Actions)) {
    foreach ($solution in $settings.ExportSolutions.Solutions) {
        $managedFlag = if ($solution.Managed) { "true" } else { "false" }
        Write-Host "pac solution export: $($solution.SolutionName) (managed=$managedFlag) -> $($solution.ZipFile)"
        if (Test-Path -Path $solution.ZipFile) { Remove-Item -Path $solution.ZipFile -Force }
        pac solution export --name $solution.SolutionName --path $solution.ZipFile --managed $managedFlag --async --max-async-wait-time 90 --overwrite
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -Path $solution.ZipFile)) { throw "pac solution export failed for '$($solution.SolutionName)' (exit $LASTEXITCODE) -- zip file was not produced" }
    }
}

if ($settings.ExtractSolutions -and ('All' -in $Actions -or 'Solutions' -in $Actions -or 'Expand-CrmSolutions' -in $Actions)) {
    foreach ($extract in $settings.ExtractSolutions) {
        # pac can exit 0 on a failed unpack, so check the zips before clearing the folder and the output after.
        $managedZipFile = $extract.ZipFile -replace '\.zip$', '_managed.zip'
        if (-not (Test-Path -Path $extract.ZipFile) -or ($extract.PackageType -eq 'Both' -and -not (Test-Path -Path $managedZipFile))) { throw "Solution zip not found for '$($extract.ZipFile)' -- export the solution before expanding it" }
        # Unpack into an empty folder so components removed from the environment don't linger in the repo.
        Remove-Item -Path $extract.Folder -Force -Recurse -ErrorAction SilentlyContinue
        pac solution unpack -z $extract.ZipFile -f $extract.Folder -p $extract.PackageType -m $extract.MappingXmlFile -e Verbose
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -Path "$($extract.Folder)\Other\Solution.xml")) { throw "pac solution unpack failed for '$($extract.ZipFile)' (exit $LASTEXITCODE)" }
    }
    Set-SolutionVersionNumber -CdsSolutionFolder $cdsSolutionFolder
    & "$PSScriptRoot\Doctoring\Remove-KeysFromMissingDependencies.ps1" -SolutionFolderPath "$(Split-Path $PSScriptRoot)\CdsSolution"
    & "$PSScriptRoot\Doctoring\Sort-SolutionXmlFolder.ps1" -Path "$(Split-Path $PSScriptRoot)\CdsSolution\other"
}


# ---------------------------------------------------------------------------
# Config Data — export and extract
# ---------------------------------------------------------------------------

if ($settings.ExportConfigData -and ('All' -in $Actions -or 'ConfigData' -in $Actions -or 'Export-ConfigData' -in $Actions) -and (Test-Path -Path $settings.ExportConfigData.SchemaFile)) {
    Write-Host "pac data export (config): $($settings.ExportConfigData.SchemaFile) -> $($settings.ExportConfigData.ZipFile)"
    pac data export --schemaFile $settings.ExportConfigData.SchemaFile --dataFile $settings.ExportConfigData.ZipFile --overwrite
    if ($LASTEXITCODE -ne 0) { throw "pac data export failed for config data (exit $LASTEXITCODE)" }
}

if ($settings.ExtractConfigData -and ('All' -in $Actions -or 'ConfigData' -in $Actions -or 'Expand-ConfigData' -in $Actions) -and (Test-Path -Path $settings.ExtractConfigData.ZipFile)) {
    $settings.ExtractConfigData | Expand-CrmData
}


# ---------------------------------------------------------------------------
# Test Data — export and extract
# ---------------------------------------------------------------------------

if ($settings.ExportTestData -and ('TestData' -in $Actions -or 'Export-TestData' -in $Actions) -and (Test-Path -Path $settings.ExportTestData.SchemaFile)) {
    Write-Host "pac data export (test): $($settings.ExportTestData.SchemaFile) -> $($settings.ExportTestData.ZipFile)"
    pac data export --schemaFile $settings.ExportTestData.SchemaFile --dataFile $settings.ExportTestData.ZipFile --overwrite
    if ($LASTEXITCODE -ne 0) { throw "pac data export failed for test data (exit $LASTEXITCODE)" }
}

if ($settings.ExtractTestData -and ('TestData' -in $Actions -or 'Expand-TestData' -in $Actions) -and (Test-Path -Path $settings.ExtractTestData.ZipFile)) {
    $settings.ExtractTestData | Expand-CrmData
}


# ---------------------------------------------------------------------------
# Power Pages site download via pac CLI
# Only runs when 'PortalPages' is explicitly requested — not included under
# 'All', same as TestData above, since it needs its own pac auth and a fully
# filled-in PortalToolkit.Config.psd1.
# ---------------------------------------------------------------------------

if ('PortalPages' -in $Actions) {
    Write-Host ""
    Write-Host "================================================================"
    Write-Host "Power Pages Download"
    Write-Host "================================================================"

    $deploymentPackageRoot = Split-Path -Parent $PSScriptRoot
    $configPath = Join-Path $deploymentPackageRoot "Sites\_site-config\PortalToolkit.Config.psd1"

    if (-not (Test-Path $configPath)) {
        Write-Warning "PortalToolkit.Config.psd1 not found at $configPath. Skipping pages download."
    }
    else {
        $config   = Import-PowerShellDataFile $configPath
        $zeroGuid = '00000000-0000-0000-0000-000000000000'

        foreach ($field in @('TenantId', 'SiteWebsiteId')) {
            if ($config.$field -eq $zeroGuid) {
                throw "PortalToolkit.Config.psd1: '$field' is still a placeholder (all-zero GUID). Replace it with the real value before running."
            }
        }

        $pagesParams = $ConnectionParameters.PowerPagesConnectionParameter

        if (-not $pagesParams) {
            Write-Warning "Connection file has no PowerPagesConnectionParameter section. Skipping pages download."
            Write-Warning "Add one with EnvironmentUrl to enable this step."
        }
        elseif (-not $pagesParams.EnvironmentUrl) {
            Write-Warning "PowerPagesConnectionParameter.EnvironmentUrl is missing from the connection file. Skipping pages download."
        }
        elseif (-not $config.ProfileName) {
            Write-Warning "PortalToolkit.Config.psd1: 'ProfileName' is missing. Skipping pages download."
        }
        else {
            $environmentUrl = $pagesParams.EnvironmentUrl
            $pacCloud       = $config.Cloud
            $pacProfileName = $config.ProfileName

                $sitesRoot = Join-Path $deploymentPackageRoot "Sites"

                Write-Host "pac target: $environmentUrl (cloud: $pacCloud, profile: $pacProfileName)"

                pac auth create --url $environmentUrl --cloud $pacCloud --name $pacProfileName 2>&1 | Out-Null
                pac auth select --name $pacProfileName 2>&1 | Out-Null

                Write-Host ""
                Write-Host "Listing Power Pages sites in environment..."
                $listOutput = pac pages list 2>&1 | Out-String

                $guidPattern = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
                $linePattern = "^\s*\[(?<idx>\d+)\]\s+(?<id>$guidPattern)\s+(?<name>.+?)\s*$"

                $sites = @()
                foreach ($line in ($listOutput -split "`r?`n")) {
                    if ($line -match $linePattern) {
                        $sites += [PSCustomObject]@{
                            Index        = [int]$Matches['idx']
                            WebSiteId    = $Matches['id']
                            FriendlyName = $Matches['name'].Trim()
                        }
                    }
                }

                if ($sites.Count -eq 0) {
                    Write-Warning "No Power Pages sites discovered in the environment. Skipping pages download."
                }
                else {
                    Write-Host ""
                    Write-Host "Available sites:"
                    foreach ($s in $sites) {
                        Write-Host ("  [{0}] {1,-40}  ({2})" -f $s.Index, $s.FriendlyName, $s.WebSiteId)
                    }

                    Write-Host ""
                    $selection = Read-Host "Enter the number of the site to download"
                    $idx = 0

                    if (-not [int]::TryParse($selection, [ref]$idx)) {
                        Write-Warning "Invalid selection '$selection'. Skipping pages download."
                    }
                    else {
                        $chosen = $sites | Where-Object { $_.Index -eq $idx } | Select-Object -First 1

                        if (-not $chosen) {
                            Write-Warning "Selection $idx not in the list. Skipping pages download."
                        }
                        else {
                            $folderName = $chosen.FriendlyName
                            $lastDash = $folderName.LastIndexOf(" - ")
                            if ($lastDash -gt 0) {
                                $folderName = $folderName.Substring(0, $lastDash).Trim()
                            }

                            if (-not (Test-Path $sitesRoot)) {
                                New-Item -ItemType Directory -Path $sitesRoot | Out-Null
                            }

                            $sitePath = Join-Path $sitesRoot $folderName

                            Write-Host ""
                            Write-Host "Downloading site: $($chosen.FriendlyName)"
                            Write-Host "Destination:      $sitePath"

                            if (Test-Path $sitePath) {
                                cmd /c "rd /s /q `"$sitePath`"" | Out-Null
                            }

                            pac pages download `
                                --path $sitePath `
                                --webSiteId $chosen.WebSiteId `
                                --modelVersion "Enhanced" `
                                --overwrite

                            if ($LASTEXITCODE -ne 0) {
                                Write-Warning "pac pages download failed for $($chosen.FriendlyName) (exit code $LASTEXITCODE)"
                            }
                        }
                    }
                }

                Write-Host ""
                Write-Host "Power Pages download complete."
            }
    }
}


# ---------------------------------------------------------------------------
# Stage Portal Change — local git-index helper, no environment connection
# needed. Included under 'All', same as the Expand-* actions above, since it
# only touches files already on disk / staged in git.
# ---------------------------------------------------------------------------

if ('All' -in $Actions -or 'Stage-PortalChange' -in $Actions) {
    Write-Host ""
    Write-Host "================================================================"
    Write-Host "Stage Portal Change"
    Write-Host "================================================================"
    & "$PSScriptRoot\Stage-PortalChange.ps1" -SiteFolderName $SiteFolderName
}
