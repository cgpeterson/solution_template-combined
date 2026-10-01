# This script is used by DevOps import and export scripts to establish a connection to a developers
# assigned CDS Sandbox Environment.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$orgName = "[mydev]"

# Your environment's URL. $orgName supplies the host name; the suffix varies by region and
# cloud, so set it once against what the maker portal shows under Settings > Session details.
# Commercial North America is crm.dynamics.com and GCC is crm9.dynamics.com; GCC High and DoD
# are different domains entirely.
$environmentUrl = "https://$orgName.crm.dynamics.com"

@{
    # Used by Export.ps1 / Import.ps1 for everything that connects to the environment, all
    # signed in with MSAL: pac for solutions, data and -ResetEnvironment, MSAL.PS for
    # Import-DocumentTemplates. No password is stored or prompted for here. First run opens an
    # interactive browser sign-in and the token is cached after that.
    PacConnectionParameter = @{
        EnvironmentUrl = $environmentUrl
        # Optional: pin Import-DocumentTemplates' sign-in to one tenant (id or domain).
        # TenantId = "[mytenant].onmicrosoft.com"
    }

    # Only EnvironmentUrl is per-developer here. Cloud, ProfileName, TenantId and the site
    # identity are project constants and live in Sites\_site-config\PortalToolkit.Config.psd1.
    PowerPagesConnectionParameter = @{
        EnvironmentUrl = $environmentUrl
    }
}
