using DLaB.Xrm.Test;
using JMCL.Dataverse.Sdk;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Client;
using System;
using System.Linq;
using System.Reflection;

namespace PluginAssemblyName.UnitTest.Tests
{
    using Builders;

    [TestClass]
    public class PluginBaseTests
    {
        private const string TableName = "account";
        private const string HandledAttribute = "description";
        private const string HandledValue = "handled";
        private const string ValidationMessage = "Rejected by test plugin.";

        private static readonly string[] RequiredProxies = { "businessunit", "systemuser", "environmentvariabledefinition", "environmentvariablevalue" };

        [TestMethod]
        public void Execute_NoInstrumentationKey_RunsHandler()
        {
            RequireGeneratedProxies();
            new Test_Execute_NoInstrumentationKey_RunsHandler().Test();
        }

        [TestMethod]
        public void Execute_HandlerThrowsValidationError_PropagatesSameException()
        {
            RequireGeneratedProxies();
            new Test_Execute_HandlerThrowsValidationError_PropagatesSameException().Test();
        }

        private static void RequireGeneratedProxies()
        {
            var generated = typeof(PluginBase).Assembly.GetTypes()
                .Select(t => t.GetCustomAttribute<EntityLogicalNameAttribute>()?.LogicalName)
                .Where(name => name != null);
            var missing = RequiredProxies.Except(generated).ToList();
            if (missing.Count > 0)
            {
                Assert.Inconclusive($"Generate the early-bound proxies first (Plugins\\codgen\\proxybuilder.bat). Missing: {string.Join(", ", missing)}.");
            }
        }

        private class Test_Execute_NoInstrumentationKey_RunsHandler : TestMethodClassBase
        {
            protected override void InitializeTestData(IOrganizationService service) { }

            protected override void Test(IOrganizationService service)
            {
                var target = new Entity(TableName, Guid.NewGuid());
                var serviceProvider = BuildServiceProvider(service, target);

                new MarkTargetPlugin(null, null).Execute(serviceProvider);

                Assert.AreEqual(HandledValue, target.GetAttributeValue<string>(HandledAttribute),
                    "A PluginBase plugin should run its handler when telemetry isn't configured.");
            }
        }

        private class Test_Execute_HandlerThrowsValidationError_PropagatesSameException : TestMethodClassBase
        {
            protected override void InitializeTestData(IOrganizationService service) { }

            protected override void Test(IOrganizationService service)
            {
                var serviceProvider = BuildServiceProvider(service, new Entity(TableName, Guid.NewGuid()));

                var ex = Assert.ThrowsException<InvalidPluginExecutionException>(
                    () => new RejectPlugin(null, null).Execute(serviceProvider),
                    "The telemetry wrapper should rethrow validation errors unchanged.");
                Assert.AreEqual(ValidationMessage, ex.Message);
            }
        }

        private static IServiceProvider BuildServiceProvider(IOrganizationService service, Entity target)
        {
            var context = new FakePluginExecutionContext
            {
                Stage = (int)ePluginStage.PreOperation,
                MessageName = MessageNames.Create,
                PrimaryEntityName = TableName,
                PrimaryEntityId = target.Id
            };
            context.InputParameters["Target"] = target;
            return new ServiceProviderBuilder(service, context, new DebugLogger()).Build();
        }

        private class MarkTargetPlugin : PluginBase
        {
            public MarkTargetPlugin(string unsecureConfig, string secureConfig) : base(unsecureConfig, secureConfig)
            {
                RegisterEventHandler(TableName, MessageNames.Create, ePluginStage.PreOperation, MarkTarget);
            }

            private static void MarkTarget(ICDSPluginExecutionContext context)
            {
                context.TargetEntity[HandledAttribute] = HandledValue;
            }
        }

        private class RejectPlugin : PluginBase
        {
            public RejectPlugin(string unsecureConfig, string secureConfig) : base(unsecureConfig, secureConfig)
            {
                RegisterEventHandler(TableName, MessageNames.Create, ePluginStage.PreOperation, Reject);
            }

            private static void Reject(ICDSPluginExecutionContext context)
            {
                throw new InvalidPluginExecutionException(ValidationMessage);
            }
        }
    }
}
