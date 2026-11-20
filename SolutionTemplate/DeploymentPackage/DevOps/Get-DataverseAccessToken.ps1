# Signs in with the Az.Accounts module and returns a Dataverse Web API access token. This is the
# sign-in Microsoft documents for calling the Dataverse Web API from PowerShell. It replaces MSAL.PS,
# whose repo was archived in 2023. The first call opens a browser sign-in; Az caches it after that.
function Get-DataverseAccessToken {
    param (
        [Parameter(Mandatory)]
        [string]$EnvironmentUrl,

        # Entra tenant id. Empty uses the signed-in account's home tenant.
        [string]$TenantId,

        # The pac --cloud value. GCC (UsGov) signs in through commercial Entra; GCC High and DoD don't.
        [ValidateSet('Public', 'UsGov', 'UsGovHigh', 'UsGovDod')]
        [string]$Cloud = 'Public'
    )

    Import-Module Az.Accounts -ErrorAction Stop

    $azEnvironment = if ($Cloud -in 'UsGovHigh', 'UsGovDod') { 'AzureUSGovernment' } else { 'AzureCloud' }
    $context = Get-AzContext
    if (-not $context -or $context.Environment.Name -ne $azEnvironment) {
        $connectArgs = @{ Environment = $azEnvironment }
        if ($TenantId) { $connectArgs.Tenant = $TenantId }
        Connect-AzAccount @connectArgs | Out-Null
    }

    $tokenArgs = @{ ResourceUrl = $EnvironmentUrl.TrimEnd('/') }
    if ($TenantId) { $tokenArgs.TenantId = $TenantId }
    $token = (Get-AzAccessToken @tokenArgs).Token

    # Az.Accounts 5 returns the token as a SecureString. NetworkCredential unwraps it on both
    # Windows PowerShell and PowerShell 7.
    if ($token -is [securestring]) { $token = [System.Net.NetworkCredential]::new('', $token).Password }
    if (-not $token) { throw "Failed to acquire an access token for $EnvironmentUrl." }
    return $token
}
