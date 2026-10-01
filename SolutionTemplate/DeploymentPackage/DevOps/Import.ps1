param (
    # The connection parameters for the target organization    
    [ValidateSet("MySandbox","MyTest","DummyConnection")] # update this list based on files in the CdsConnectionParameters folder
    [string]
    $ConnectionName = "MySandbox",

    # The settings for the actions performed during the export
    [ValidateSet("DefaultSettings")] # update this list based on files in the Settings folder
    [string]
    $ImportSettings = "DefaultSettings",

    [ValidateSet("Managed","Unmanaged")]
    [string]
    $PackageType = "Unmanaged",   

    # The available actions to perform during the import
    [ValidateSet("All","Solutions","ConfigData","TestData","Compress-CrmSolution","Compress-ConfigData","Merge-ConfigData","Compress-TestData","Merge-TestData","New-CrmPackage","Invoke-ImportCrmPackage","Import-DocumentTemplates","Stage-PortalChange","Upload-StagedPortalChanges")]
    [string[]]
    $Actions = "All",

	[switch]
	$ResetEnvironment,

	# Passed through to Stage-PortalChange.ps1 / Upload-StagedPortalChanges.ps1
	[string]
	$SiteFolderName,

	# Passed through to Upload-StagedPortalChanges.ps1. Not included under 'All' --
	# see the 'Upload-StagedPortalChanges' action block below.
	[switch]
	$DryRun,

	# Passed through to Upload-StagedPortalChanges.ps1
	[switch]
	$SkipFieldPatcher
)

$global:ErrorActionPreference = "Stop"

Write-Host("Running Import.ps1")

# Setup CRM_SDK_PATH variable and load required supporting modules
$Env:CRM_SDK_PATH = "$PSScriptRoot\Tools"
# Adoxio.Dynamics.DevOps stays for Compress-CrmData / New-CrmPackage (local, no connection).
# Everything that connects to an environment authenticates with MSAL: pac for solutions, data and
# environment reset; MSAL.PS for Import-DocumentTemplates.ps1.
Import-Module "$env:CRM_SDK_PATH\Adoxio.Dynamics.DevOps\Adoxio.Dynamics.DevOps.psd1" -Force

$ConnectionParameters = switch ($ConnectionName) {
	"MySandbox" {& "C:\\CrmConnection\MyCdsSandboxConnection.ps1"}
	default {& "$PSScriptRoot\CdsConnectionParameters\$ConnectionName.ps1"}
}

$settings = & "$PSScriptRoot\Settings\$ImportSettings.ps1" -ConnectionParameters $ConnectionParameters -PackageType $PackageType


# If directed, configured, and solution data exists then  compress the solution into a zip file.
if($settings.ExtractedSolutions `
    -and $settings.ExtractedSolutions.Exists `
    -and ("All" -in $Actions -or "New-CrmPackage" -in $Actions -or 'Solutions' -in $Actions -or 'Compress-CrmSolution' -in $Actions )) {
    Write-Host("Compressing Solution")
    & "$PSScriptRoot\Doctoring\Add-KeysToMissingDependencies.ps1" -SolutionFolderPath "$(Split-Path $PSScriptRoot)\CdsSolution"
    pac solution pack -f $settings.ExtractedSolutions.Folder -z $settings.ExtractedSolutions.ZipFile -m $settings.ExtractedSolutions.MappingXmlFile -p $settings.ExtractedSolutions.PackageType --useUnmanagedFileForMissingManaged -e Verbose
}


# Compress configuration data into a zip file
if($settings.ExtractedConfigData `
    -and $settings.ExtractedConfigData.Exists `
    -and ("All" -in $Actions -or "ConfigData" -in $Actions -or 'Compress-ConfigData' -in $Actions)) {
        Write-Host("Compressing configuration data")
        $settings.ExtractedConfigData | Compress-CrmData -Verbose
}

# Compress test data into a zip file
if($settings.ExtractedTestData `
    -and $settings.ExtractedTestData.Exists `
    -and ("All" -in $Actions -or "TestData" -in $Actions -or 'Compress-TestData' -in $Actions)) {
        Write-Host("Compressing Test Data")
        $settings.ExtractedTestData | Compress-CrmData
}

if($settings.ResetEnvironmentDefinition -and ("All" -in $Actions -or 'Invoke-ImportCrmPackage' -in $Actions -or 'Solutions' -in $Actions -or 'ConfigData' -in $Actions -or 'TestData' -in $Actions) -and $ResetEnvironment) {

    # pac admin reset signs in through the pac auth profile (MSAL). It replaces Add-PowerAppsAccount /
    # Reset-PowerAppEnvironment, which needed a stored username and password, and it waits for the
    # reset to finish itself, so the old LastModifiedTime / Get-CrmOrganizations polling is gone.
    $environmentUrl = $settings.ResetEnvironmentDefinition.EnvironmentUrl
    if (-not $environmentUrl) {
        throw "Connection file '$ConnectionName' has no PacConnectionParameter.EnvironmentUrl; -ResetEnvironment needs it."
    }

    $pacProfileName = $settings.SolutionName
    pac auth create --url $environmentUrl --name $pacProfileName | Out-Null
    pac auth select --name $pacProfileName | Out-Null

    # Keep the environment's URL and display name across the reset, as the old script did.
    $domainName = ([Uri]$environmentUrl).Host.Split('.')[0]
    $friendlyName = $null
    $whoAmI = pac org who --environment $environmentUrl 2>$null
    if ($LASTEXITCODE -eq 0) {
        $friendlyName = ($whoAmI | Select-String -Pattern '^\s*Friendly Name:\s*(.+?)\s*$' | Select-Object -First 1 |
            ForEach-Object { $_.Matches[0].Groups[1].Value })
    }
    $displayName = if ($friendlyName) { "$friendlyName ($domainName)" } else { $environmentUrl }

    $title = 'Confirm Environment Reset'
    $prompt = "Select Reset to reset '" + $displayName + "'. Select Cancel to abort operation."
    $cancel = New-Object System.Management.Automation.Host.ChoiceDescription '&Cancel','Aborts the operation'
    $reset = New-Object System.Management.Automation.Host.ChoiceDescription '&Reset','Resets the environment'
    $options = [System.Management.Automation.Host.ChoiceDescription[]] ($cancel,$reset)

    $choice = $host.ui.PromptForChoice($title,$prompt,$options,0)

    if($choice -ne 1){
        break
    }
    Write-Host("Resetting " + $displayName + " (waits until the reset completes)...")

    # Language and currency are left at pac's defaults (English, USD), which is what the old script set.
    $resetArgs = @('admin', 'reset', '--environment', $environmentUrl, '--domain', $domainName, '--purpose', 'Developer sandbox')
    if ($friendlyName) { $resetArgs += @('--name', $friendlyName) }
    pac @resetArgs
    if ($LASTEXITCODE -ne 0) { throw "pac admin reset failed for '$environmentUrl' (exit $LASTEXITCODE)" }

    Write-Host "Reset completed."
}

# Assemble the Package Deployer package folder -- local file copy only, no Dataverse
# connection. DeploymentPackage.csproj's PostBuildEvent calls this via -Actions New-CrmPackage
# to produce temp\deployment\<PackageFolder>, which CI publishes as a build artifact and the
# release pipeline's "Power Platform Deploy Package" task consumes.
if($settings.CrmPackageDefinition -and ("All" -in $Actions -or 'New-CrmPackage' -in $Actions -or 'Solutions' -in $Actions -or 'ConfigData' -in $Actions -or 'TestData' -in $Actions)) {
    if($settings.CrmPackageDefinition.DataZipFile -and -not (Test-Path -Path $settings.CrmPackageDefinition.DataZipFile)) {
        For ($i=0; $i -lt $settings.CrmPackageDefinition.Length; $i++) {
            $settings.CrmPackageDefinition[$i].PSObject.Properties.Remove("DataZipFile")
        }
    }

    # A new project has no CdsSolution folder until its solution is first exported, and so
    # nothing to package. Skip rather than fail, or every build of a fresh project fails in
    # this post-build step.
    $solutionZipFiles = @($settings.CrmPackageDefinition | ForEach-Object { $_.SolutionZipFiles } | Where-Object { $_ })
    if($solutionZipFiles.Count -eq 0) {
        Write-Host("No solutions to package (DeploymentPackage\CdsSolution has not been exported yet); skipping deployment package creation")
    }
    else {
        Write-Host("Creating Deployment Package")
        $settings.CrmPackageDefinition | New-CrmPackage
    }
}

# pac auth, then solution import (dependency solutions first), then data import.
if ("All" -in $Actions -or 'Solutions' -in $Actions -or 'ConfigData' -in $Actions -or 'TestData' -in $Actions -or 'Invoke-ImportCrmPackage' -in $Actions) {

    $pacParams = $ConnectionParameters.PacConnectionParameter
    if (-not $pacParams -or -not $pacParams.EnvironmentUrl) {
        throw "Connection file '$ConnectionName' has no PacConnectionParameter.EnvironmentUrl. Add one (e.g. https://<org>.crm9.dynamics.com) before running Import.ps1."
    }

    $pacProfileName = $settings.SolutionName
    Write-Host "pac auth: $($pacParams.EnvironmentUrl) (profile: $pacProfileName)"
    pac auth create --url $pacParams.EnvironmentUrl --name $pacProfileName | Out-Null
    pac auth select --name $pacProfileName | Out-Null

    if ("All" -in $Actions -or 'Solutions' -in $Actions -or 'Invoke-ImportCrmPackage' -in $Actions) {
        foreach ($solutionZip in ($settings.CrmPackageDefinition.SolutionZipFiles | Where-Object { $_ -and (Test-Path -Path $_) })) {
            Write-Host "pac solution import: $solutionZip"
            pac solution import --path $solutionZip --publish-changes --async
            if ($LASTEXITCODE -ne 0) { throw "pac solution import failed for '$solutionZip' (exit $LASTEXITCODE)" }
        }
    }

    $dataZipsToImport = @()
    if ("All" -in $Actions -or 'ConfigData' -in $Actions -or 'Invoke-ImportCrmPackage' -in $Actions) {
        $dataZipsToImport += $settings.ExtractedConfigData.DependencyDataFiles
        if ($settings.ExtractedConfigData.Exists) { $dataZipsToImport += $settings.ExtractedConfigData.ZipFile }
    }
    if ("All" -in $Actions -or 'TestData' -in $Actions -or 'Invoke-ImportCrmPackage' -in $Actions) {
        $dataZipsToImport += $settings.ExtractedTestData.DependencyDataFiles
        if ($settings.ExtractedTestData.Exists) { $dataZipsToImport += $settings.ExtractedTestData.ZipFile }
    }

    foreach ($dataZip in ($dataZipsToImport | Where-Object { $_ -and (Test-Path -Path $_) })) {
        Write-Host "pac data import: $dataZip"
        pac data import --data $dataZip
        if ($LASTEXITCODE -ne 0) { throw "pac data import failed for '$dataZip' (exit $LASTEXITCODE)" }
    }
}

if($settings.DocumentTemplates `
    -and $settings.DocumentTemplates.Exists `
    -and $settings.DocumentTemplates.Files.Count -ge 1 `
    -and ("All" -in $Actions -or "Import-DocumentTemplates" -in $Actions)){
        if (-not $settings.DocumentTemplates.EnvironmentUrl) {
            throw "Connection file '$ConnectionName' has no PacConnectionParameter.EnvironmentUrl; Import-DocumentTemplates needs it."
        }
        [string]$path = $settings.DocumentTemplates.Folder

        Write-Host("Importing Document Templates from $path")

        $templateArgs = @{
            EnvironmentUrl    = $settings.DocumentTemplates.EnvironmentUrl
            TemplateDirectory = $path
        }
        if ($settings.DocumentTemplates.TenantId) { $templateArgs.TenantId = $settings.DocumentTemplates.TenantId }
        & "$PSScriptRoot\Import-DocumentTemplates.ps1" @templateArgs
}

# ---------------------------------------------------------------------------
# Stage Portal Change — local git-index helper, no environment connection
# needed. Included under 'All', same as the Compress-*/Merge-* actions above,
# since it only touches files already on disk / staged in git.
# ---------------------------------------------------------------------------

if ("All" -in $Actions -or "Stage-PortalChange" -in $Actions) {
    Write-Host ""
    Write-Host "================================================================"
    Write-Host "Stage Portal Change"
    Write-Host "================================================================"
    & "$PSScriptRoot\Stage-PortalChange.ps1" -SiteFolderName $SiteFolderName
}


# ---------------------------------------------------------------------------
# Upload Staged Portal Changes — pushes staged Power Pages changes to the
# live environment. NOT included under 'All' (unlike Stage-PortalChange
# above) since this is a real push to a live environment, not a local-only
# operation — requires explicit -Actions Upload-StagedPortalChanges. It has
# its own Y/N confirmation gate as a second line of defense.
# ---------------------------------------------------------------------------

if ("Upload-StagedPortalChanges" -in $Actions) {
    Write-Host ""
    Write-Host "================================================================"
    Write-Host "Upload Staged Portal Changes"
    Write-Host "================================================================"
    & "$PSScriptRoot\Upload-StagedPortalChanges.ps1" -ConnectionName $ConnectionName -SiteFolderName $SiteFolderName -DryRun:$DryRun -SkipFieldPatcher:$SkipFieldPatcher
}
