namespace PluginAssemblyName
{
    using JMCL.Core;
    using JMCL.Dataverse.Sdk;
    using System;

    /// <summary>
    /// Base class for every plugin in this assembly. Adds Application Insights telemetry
    /// (enabled by this solution's TelemetryKeyVariableName environment variable; a no-op
    /// without it) and shares one IoC container, and so one cache, across all plugin classes.
    /// </summary>
    public abstract class PluginBase : InstrumentedCDSPlugin
    {
        /// <summary>
        /// Schema name of the environment variable holding this solution's Application Insights
        /// instrumentation key. Solution-specific so solutions sharing an environment can report
        /// to separate Application Insights resources.
        /// </summary>
        public const string TelemetryKeyVariableName = "[publisherprefix]_TelemetryKey";

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

        /// <summary>
        /// Wraps a handler's execution with paired "Entered"/"Exiting" trace statements.
        /// Dispose() always fires the exit trace, even on early returns or thrown
        /// exceptions, so handlers can't forget to log an exit path.
        /// </summary>
        protected readonly struct TraceScope : IDisposable
        {
            private readonly ICDSPluginExecutionContext _context;
            private readonly string _processName;

            private TraceScope(ICDSPluginExecutionContext context, string processName, Guid? targetId)
            {
                _context = context;
                _processName = processName;

                string enteredMessage = targetId.HasValue
                    ? $"Entered {_processName} - target id: {targetId}"
                    : $"Entered {_processName}";

                _context.Trace(enteredMessage);
            }

            public static TraceScope Start(ICDSPluginExecutionContext context, string processName, Guid? targetId = null)
                => new TraceScope(context, processName, targetId);

            public void Dispose()
                => _context.Trace($"Exiting {_processName}");
        }

        protected PluginBase(string unsecureConfig, string secureConfig)
            : base(unsecureConfig, secureConfig)
        {
            InstrumentationVariableName = TelemetryKeyVariableName;
        }
    }
}
