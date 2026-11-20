# Developer machine setup for the DevOps scripts. Everything installs for the current user only,
# so no elevated (administrator) PowerShell is needed.
#
# Everything that connects to an environment signs in with MSAL:
#   - Power Platform CLI (pac): solution export/import/pack, data export/import, Import.ps1 -ResetEnvironment
#   - Az.Accounts: Import-DocumentTemplates.ps1 and Upload-StagedPortalChanges.ps1
#
# Both are pinned so every machine and the pipeline run the same, tested versions. Bump them here
# (and pac in PipelineTemplate\azure-pipelines.yml) on purpose, after testing.
#
# The ADAL-based modules this script used to install (Microsoft.Xrm.Data.PowerShell,
# Microsoft.Xrm.Tooling.ConfigurationMigration, Microsoft.Xrm.Tooling.PackageDeployment.PowerShell,
# Microsoft.Xrm.DevOps.Data.PowerShell, Microsoft.PowerApps(.Administration).PowerShell and the
# PowerShell Gallery copy of Adoxio.Dynamics.DevOps) are no longer used. The Adoxio functions the
# scripts need are vendored under DevOps\Tools.

$ErrorActionPreference = "Stop"

$pacVersion        = "2.14.1"
$azAccountsVersion = "5.5.5"

# Provision the developer sandbox connection file at the location the DevOps scripts read. It lives
# outside the repo so it is never committed and is shared by every solution repo on this machine. An
# existing file is left alone, so re-running this script does not wipe values a developer already filled in.
$connectionFolder = "C:\CrmConnection"
$connectionFile   = Join-Path $connectionFolder "MyCdsSandboxConnection.ps1"

if (-not (Test-Path $connectionFolder)) {
    New-Item -ItemType Directory -Path $connectionFolder | Out-Null
}

if (Test-Path $connectionFile) {
    Write-Host "Existing connection file left in place: $connectionFile"
}
else {
    Copy-Item "$PSScriptRoot\CdsConnectionParameters\MyCdsSandboxConnection-Template.ps1" -Destination $connectionFile
    Write-Host "Created $connectionFile"
    Write-Host "Edit it with your sandbox details before running Export.ps1 or Import.ps1."
}

if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
}

Install-Module Az.Accounts -RequiredVersion $azAccountsVersion -Scope CurrentUser -Repository PSGallery -Force

# Check the dotnet tool list rather than Get-Command pac: pac from the MSI or the VS Code extension
# is also on PATH, and dotnet tool update fails for a tool it didn't install.
if (dotnet tool list --global | Select-String -Pattern '^microsoft\.powerapps\.cli\.tool\s') {
    dotnet tool update --global Microsoft.PowerApps.CLI.Tool --version $pacVersion --allow-downgrade
}
else {
    dotnet tool install --global Microsoft.PowerApps.CLI.Tool --version $pacVersion
    Write-Host "Installed pac. Open a new terminal (or restart Visual Studio) so it is on PATH."
}
if ($LASTEXITCODE -ne 0) { throw "pac $pacVersion install failed (exit $LASTEXITCODE). It needs the .NET 8 SDK or later." }
