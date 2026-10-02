using Microsoft.Xrm.Sdk;

namespace Shared.Proxies
{
    /// <summary>
    /// Anchors the early-bound proxies to the assembly that compiles Shared.Proxies (the plugin
    /// assembly; [ProxyTypesAssembly] comes from JMCL's EntityProxy source). Plugins.UnitTest
    /// points XrmUnitTest at this type, so the in-memory organization service resolves the same
    /// proxy types the plugins use.
    /// </summary>
    public partial class CrmServiceContext : Microsoft.Xrm.Sdk.Client.OrganizationServiceContext
    {
        public CrmServiceContext(IOrganizationService service) : base(service)
        {
        }
    }
}
