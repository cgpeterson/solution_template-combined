namespace PluginAssemblyName
{
    using JMCL.Core;
    using JMCL.Dataverse.Sdk;

    /// <summary>
    /// Base class for every plugin in this assembly. Adds Application Insights telemetry
    /// (enabled by the Telemetry.InstrumentationKey environment variable; a no-op without it)
    /// and shares one IoC container, and so one cache, across all plugin classes.
    /// </summary>
    public abstract class PluginBase : InstrumentedCDSPlugin
    {
        private static IIocContainer _container;
        private static readonly object _containerLock = new object();

        public override IIocContainer Container
        {
            get
            {
                if (_container is null)
                {
                    lock (_containerLock)
                    {
                        if (_container is null)
                        {
                            _container = new IocContainer();
                        }
                    }
                }
                return _container;
            }
        }

        protected PluginBase(string unsecureConfig, string secureConfig)
            : base(unsecureConfig, secureConfig) { }
    }
}
