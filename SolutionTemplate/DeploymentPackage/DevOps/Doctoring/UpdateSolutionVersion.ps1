function Set-SolutionVersionNumber {
	param ([string]$CdsSolutionFolder)
	$fileName = $CdsSolutionFolder + "\Other\Solution.xml"
	[xml] $xdoc = get-content $fileName
	$version = $xdoc.SelectSingleNode('//Version')
	$date = Get-Date([datetime]::UtcNow) -UFormat "%Y.%m%d.%H%M"
	# Keep the solution's major version, so a 1.x solution stays 1.x instead of dropping to 0.x, which
	# Package Deployer skips as older. To raise the major, change the version in the maker portal.
	$major = ([version]$version.InnerText).Major
	#Format should look like 1.2021.0415.1159 for example
	$version.InnerText = "$major.$date"
	$xdoc.Save($fileName)
}
