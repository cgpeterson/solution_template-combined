# This script is used by DevOps import and export scripts to establish a connection to a developers
# assigned CDS Sandbox Environment.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$credential = (Get-Credential -UserName [myname]@[mydomain].com -Message "Enter credentials")
$orgName = "[mydev]"

# Your environment's URL. $orgName supplies the host name; the suffix varies by region and
# cloud, so set it once against what the maker portal shows under Settings > Session details.
# Commercial North America is crm.dynamics.com and GCC is crm9.dynamics.com; GCC High and DoD
# are different domains entirely. This must agree with DeploymentRegion below.
$environmentUrl = "https://$orgName.crm.dynamics.com"

@{
    CrmConnectionParameter = @{    
        OrganizationName = $orgName
        OnlineType = "Office365"
        DeploymentRegion = "NorthAmerica2"
        Credential = $credential
    }
    PowerAppsConnectionParamter = @{
        EnvironmentName = $orgName
        Username = $credential.UserName
        SecurePassword = $credential.Password
    }

    # Used by Export.ps1 / Import.ps1 for pac CLI auth (MSAL). Solution export/unpack and
    # config/test data export/import no longer use the Credential above; that is now only
    # read by Import-DocumentTemplates. First run opens an interactive browser sign-in and
    # pac caches the profile after that.
    PacConnectionParameter = @{
        EnvironmentUrl = $environmentUrl
    }

    # Only EnvironmentUrl is per-developer here. Cloud, ProfileName, TenantId and the site
    # identity are project constants and live in Sites\_site-config\PortalToolkit.Config.psd1.
    PowerPagesConnectionParameter = @{
        EnvironmentUrl = $environmentUrl
    }
}
