param (
    # The connection parameters for the target organization    
    [ValidateSet("Debug","Release")] 
    [string]
    $Configuration = "Release"
)

$global:ErrorActionPreference = "Stop"

Write-Host("Running post-build.ps1")
try{
    if($Configuration -eq "Release"){
        & "$PSScriptRoot\Import.ps1" -ConnectionName DummyConnection -PackageType Managed -Actions New-CrmPackage
    }
    else{
        & "$PSScriptRoot\Import.ps1" -ConnectionName DummyConnection -PackageType Unmanaged -Actions New-CrmPackage
    }
    # Skipped until the solution is first exported (new projects have no CdsSolution yet).
    $solutionFolder = "$(Split-Path $PSScriptRoot)\CdsSolution"
    if(Test-Path "$solutionFolder\Other\solution.xml"){
        & "$PSScriptRoot\Doctoring\Remove-KeysFromMissingDependencies.ps1" -SolutionFolderPath $solutionFolder
    }
}
catch{
	$_
    exit 1
}

