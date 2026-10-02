using System;
using System.IO;
using DLaB.Xrm.Test;
using DLaB.Xrm.Client;
using Microsoft.Xrm.Sdk;


namespace PluginAssemblyName.UnitTest
{
    using Builders;
    using Shared.Proxies;

    /// <summary>
    /// Class to Initalize all TestSettings used by the Framework
    /// </summary>
    public class TestInitializer
    {
        /// <summary>
        /// Initializes the test settings.
        /// </summary>
        public static void InitializeTestSettings()
        {
            if (!TestSettings.AssumptionXmlPath.IsConfigured)
            {
               TestSettings.AssumptionXmlPath.Configure(new AssemblyDirectoryPathFinder(typeof(MsTestProvider), @"Assumptions\Entity Xml"));
            }
            if (!TestSettings.UserTestConfigPath.IsConfigured)
            {
                TestSettings.UserTestConfigPath.Configure(new AssemblyDirectoryPathFinder(typeof(MsTestProvider), "UnitTestSettings.user.config"));
            }
            if (!TestSettings.EntityBuilder.IsConfigured)
            {
                TestSettings.EntityBuilder.ConfigureDerivedAssembly<EntityBuilder<Entity>>();
            }
            if (!TestSettings.EarlyBound.IsConfigured)
            {
                TestSettings.EarlyBound.ConfigureDerivedAssembly<CrmServiceContext>();
                CrmServiceUtility.GetEarlyBoundProxyAssembly(TestSettings.EarlyBound.Assembly);
            }
            if (!TestSettings.TestFrameworkProvider.IsConfigured)
            {
                TestSettings.TestFrameworkProvider.Configure(new MsTestProvider());
            }
        }

        /// <summary>
        /// Locates the test project folder two levels up from bin\{Configuration}. DLaB's
        /// PatherFinderProjectOfType assumes the folder is named after the root namespace,
        /// which isn't true here (Plugins.UnitTest vs. {assembly}.UnitTest).
        /// </summary>
        private sealed class AssemblyDirectoryPathFinder : IPathFinder
        {
            private readonly Type _type;
            private readonly string _relativePath;

            public AssemblyDirectoryPathFinder(Type type, string relativePath)
            {
                _type = type;
                _relativePath = relativePath;
            }

            public string GetPath()
            {
                var assemblyDir = Path.GetDirectoryName(_type.Assembly.Location);
                var projectDir = Path.GetFullPath(Path.Combine(assemblyDir, @"..\..\"));
                return Path.Combine(projectDir, _relativePath);
            }
        }
    }
}
