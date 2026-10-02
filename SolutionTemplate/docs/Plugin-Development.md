# Plugin Development

How to write, register and test plugins in this repo, using the JMCL `CDSPlugin` framework through this assembly's `PluginBase`. The patterns come from production plugins; the examples use an illustrative `abc` publisher prefix (`abc_case` → proxy class `AbcCase`). Substitute this project's prefix and tables.

Read the **Do Not** and **Code Standards** sections of `AGENTS.md` first. This guide assumes them.

## Contents

1. [Anatomy of a plugin](#anatomy-of-a-plugin)
2. [Choosing message, stage and mode](#choosing-message-stage-and-mode)
3. [Registration](#registration)
4. [Reading the record: target, images and PreMergedTarget](#reading-the-record)
5. [Patterns](#patterns)
6. [Querying with the fluent API](#querying-with-the-fluent-api)
7. [Configuration, caching, telemetry and secrets](#configuration-caching-telemetry-and-secrets)
8. [Testing](#testing)
9. [Checklist: adding a plugin](#checklist-adding-a-plugin)

## Anatomy of a plugin

```csharp
namespace PluginAssemblyName
{
    using System;
    using JMCL.Dataverse.Sdk;
    using Shared.Proxies;

    [CrmPluginRegistration(
        MessageNameEnum.Update,
        AbcCase.EntityLogicalName,
        StageEnum.PreOperation,
        ExecutionModeEnum.Synchronous,
        AbcCase.Fields.Statuscode,
        "SetCaseClosedOnPlugin: PreOperation Update abc_case",
        1000,
        IsolationModeEnum.Sandbox,
        Id = "00000000-0000-0000-0000-000000000000",   // generate a new GUID per step
        Image1Type = ImageTypeEnum.PreImage,
        Image1Name = "PreImage",
        Image1Attributes = AbcCase.Fields.AbcClosedOn)]
    public class SetCaseClosedOnPlugin : PluginBase
    {
        public SetCaseClosedOnPlugin(string unsecureConfig, string secureConfig)
            : base(unsecureConfig, secureConfig)
        {
            RegisterUpdateHandler<AbcCase>(ePluginStage.PreOperation, OnUpdate);
        }

        private static void OnUpdate(ICDSPluginExecutionContext context, AbcCase target)
        {
            string processName = $"{nameof(SetCaseClosedOnPlugin)}.{nameof(OnUpdate)}";
            context.Trace($"Entered {processName} - caseId: {target.Id}");

            if (target.Statuscode != AbcCase.eStatuscode.Closed)
            {
                context.Trace($"Exiting {processName} - status is not changing to Closed.");
                return;
            }

            var pre = context.PreImage?.ToEntity<AbcCase>();
            if (pre?.AbcClosedOn != null)
            {
                context.Trace($"Exiting {processName} - abc_closedon is already set.");
                return;
            }

            target.AbcClosedOn = DateTime.UtcNow;
            context.Trace($"Exiting {processName} - set abc_closedon.");
        }
    }
}
```

The conventions it shows:

- **Inherit from `PluginBase`** (`Plugins/PluginBase.cs`), never directly from `CDSPlugin`. `PluginBase` adds Application Insights telemetry and shares one IoC container, and so one cache, across every plugin in the assembly.
- **One class per business rule**, named for what it does (`SetCaseClosedOnPlugin`), in `Plugins/`. Custom API classes end in `Api`.
- **Handlers are `private static`.** Plugin instances are cached and shared across threads, so a handler must never touch instance fields. Pass everything it needs as arguments.
- **Typed registration** (`RegisterUpdateHandler<AbcCase>`): the framework converts the target to the proxy type and only dispatches matching messages. Don't switch on `context.MessageName`.
- **Trace on entry and on every exit**, with a `processName` built from `nameof(...)`, so the trace log explains why a plugin did or didn't act.
- **Early returns** for every "nothing to do" case.
- **Pre-operation updates set fields on `target`** rather than calling `Update()`. The change is saved in the same database write, with no extra round trip and no re-triggering.

### Handler signatures

| Registration | Handler signature |
|---|---|
| `RegisterCreateHandler<T>(stage, h)` | `void h(ICDSPluginExecutionContext context, T target, EntityReference createdId)` |
| `RegisterUpdateHandler<T>(stage, h)` | `void h(ICDSPluginExecutionContext context, T target)` |
| `RegisterDeleteHandler<T>(stage, h)` | `void h(ICDSPluginExecutionContext context, EntityReference target)` |
| `RegisterRetrieveHandler<T>(stage, h)` | `void h(ICDSPluginExecutionContext context, EntityReference target, ColumnSet columns, T result)` |
| `RegisterQueryHandler<T>(stage, h)` (RetrieveMultiple) | `void h(ICDSPluginExecutionContext context, QueryExpression query, EntityCollection results)` |
| `RegisterApiHandler<TRequest, TResponse>(h)` (Custom API) | `void h(ICDSPluginExecutionContext context, TRequest request, TResponse response)` |
| `RegisterActionHandler<TRequest, TResponse>(stage, h)` (custom process action) | `void h(ICDSPluginExecutionContext context, TRequest request, TResponse response)` |
| `RegisterEventHandler(entity, message, stage, h)` (anything else) | `void h(ICDSPluginExecutionContext context)` |

Before you add code to a handler, check whether the registration can filter instead. `ExecuteIf` skips the handler entirely when the condition isn't met:

```csharp
RegisterUpdateHandler<AbcCase>(ePluginStage.PreOperation, OnResetKey)
    .ExecuteIf(filter => filter.ContainsAll(AbcCase.Fields.AbcResetKey));
```

The available conditions are `ContainsAll`/`ContainsAny` (fields present in the target), `ChangedAll`/`ChangedAny` (on Update, fields whose value actually changed), `IncomingValue(field).IsEqualTo(...)` / `.IsNull()` / `.IsNotNull()`, and `InitiatingUser()` / `ExecutingUser()`. Update and Delete registrations can also declare `RequirePreImage(...)`, and Create and Update can declare `RequirePostImage(...)`.

## Choosing message, stage and mode

| Need | Stage | Why |
|---|---|---|
| Reject invalid input before any other logic runs | **PreValidation** (10) | Runs outside the transaction, before security checks. Cheapest place to throw. |
| Set or derive fields on the record being saved | **PreOperation** (20) | Set them on `target`; they're saved in the same write. |
| Create or update *other* records as a consequence | **PostOperation** (40) | The record exists and has an ID. Still inside the transaction when synchronous, so a failure rolls everything back. |
| Change what a view or query returns | **PreOperation** RetrieveMultiple | Rewrite the incoming `QueryExpression`. |
| Work that may be slow or call external systems, where the user needn't wait | **PostOperation, Asynchronous** | Runs in the background and doesn't block the save. |

- **Always set filtering attributes** on Update steps (the fifth attribute argument). A step with no filtering attributes fires on every save of the table.
- **Execution order** (`1000` by default) only matters when several steps share a message, table and stage.
- Use **Synchronous** when the user must see the result or the error immediately. Otherwise prefer Asynchronous.

## Registration

Steps are declared with `[CrmPluginRegistration(...)]` on the class, one attribute per message/table/stage combination. `spkl` (`Plugins\spkl\deploy-plugins.bat`) reads the attributes and registers the steps in your sandbox. `Export.ps1` then brings the resulting `SdkMessageProcessingSteps\` XML into `DeploymentPackage\CdsSolution\`. Never hand-edit that XML.

- **`Id`**: give every attribute its own new GUID and never change it afterwards. spkl uses it to update the same step instead of creating a duplicate.
- **Name**: `"<ClassName>: <Stage> <Message> <table>"`, so steps are recognizable in the Plugin Registration Tool and trace logs.
- **Images**: declare only the columns you read (`Image1Attributes`). Use `Image1Name = "PreImage"` for pre-images. That name is what `context.PreImage` reads.
- **Several tables, one rule**: one class can carry several attributes and register several handlers. Use this when the same rule applies to several tables, such as building a record name from its parts:

```csharp
[CrmPluginRegistration(MessageNameEnum.Create, AbcPerson.EntityLogicalName, StageEnum.PreOperation, ExecutionModeEnum.Synchronous,
    "", "SetRecordName: PreOperation Create abc_person", 1000, IsolationModeEnum.Sandbox, Id = "...")]
[CrmPluginRegistration(MessageNameEnum.Update, AbcPerson.EntityLogicalName, StageEnum.PreOperation, ExecutionModeEnum.Synchronous,
    AbcPerson.Fields.AbcFirstName + "," + AbcPerson.Fields.AbcLastName, "SetRecordName: PreOperation Update abc_person", 1000,
    IsolationModeEnum.Sandbox, Id = "...", Image1Type = ImageTypeEnum.PreImage, Image1Name = "PreImage",
    Image1Attributes = AbcPerson.Fields.AbcFirstName + "," + AbcPerson.Fields.AbcLastName)]
// ...one pair per table...
public class SetRecordName : PluginBase
{
    public SetRecordName(string unsecureConfig, string secureConfig) : base(unsecureConfig, secureConfig)
    {
        RegisterCreateHandler<AbcPerson>(ePluginStage.PreOperation, OnCreatePerson);
        RegisterUpdateHandler<AbcPerson>(ePluginStage.PreOperation, OnUpdatePerson);
        // ...
    }
}
```

- **Custom APIs** register by unique name only: `[CrmPluginRegistration(AbcCloseCaseRequest.SchemaName)]`. The API, its parameters and its response properties are defined in Dataverse and exported with the solution (`CdsSolution\customapis\`).

## Reading the record

| Source | What it holds | Use it when |
|---|---|---|
| `target` (handler argument) | Only the columns in **this** request | Deciding whether a column is being changed, and setting values (PreOperation) |
| `context.PreImage` | The record **before** the operation (registered columns only) | Comparing old and new values, or reading columns the request didn't include |
| `context.PostImage` | The record **after** the operation (PostOperation only) | Reading the final state in PostOperation |
| `context.PreMergedTarget` | Pre-image with the incoming values applied on top | Reading the **effective** value of any column, changed or not |

On Update, `target` only contains the columns being changed. Fall back to the pre-image for the rest:

```csharp
var pre = context.PreImage?.ToEntity<AbcCase>();
var postalCode = target.AbcPostalCode ?? pre?.AbcPostalCode;
```

Or read every effective value at once with `context.PreMergedTarget.ToEntity<AbcCase>()`.

To tell "not in the request" apart from "being cleared", check `target.Contains(AbcCase.Fields.AbcPostalCode)`. A null property can mean either.

## Patterns

### Validation (PreValidation)

Throw `InvalidPluginExecutionException` with a message written for the end user. It's the only exception type whose message reaches the user. Put the rule in a `public static` method so it can be unit tested without a pipeline.

```csharp
public class ValidateCaseReferencePlugin : PluginBase
{
    public ValidateCaseReferencePlugin(string unsecureConfig, string secureConfig) : base(unsecureConfig, secureConfig)
    {
        RegisterCreateHandler<AbcCase>(ePluginStage.PreValidation, (context, target, id) => Validate(target.AbcExternalReference));
        RegisterUpdateHandler<AbcCase>(ePluginStage.PreValidation, (context, target) => Validate(target.AbcExternalReference));
    }

    public static void Validate(string reference)
    {
        if (string.IsNullOrWhiteSpace(reference))
        {
            return;
        }

        if (!ReferenceFormat.IsMatch(reference))
        {
            throw new InvalidPluginExecutionException(
                $"External Reference '{reference}' must be two letters followed by six digits, for example AB123456.");
        }
    }

    private static readonly Regex ReferenceFormat = new Regex(@"^[A-Za-z]{2}\d{6}$", RegexOptions.Compiled);
}
```

For anything that isn't a user-facing rule violation, such as missing configuration or a failed external call, throw `InvalidOperationException` (or let the original exception surface) with a message aimed at the support team.

### Deriving fields from other data (PreOperation)

Look up reference data and set the result on `target`. Use the elevated service for reference data the user may not be able to read, and cache it (see [caching](#caching)).

```csharp
private static void ApplyRegion(ICDSPluginExecutionContext context, AbcCase target, string postalCode)
{
    if (string.IsNullOrWhiteSpace(postalCode))
    {
        return;
    }

    var mapping = context.ElevatedOrganizationService
        .Query<AbcPostalCodeMapping>()
        .Select(m => new { m.AbcRegionId })
        .WhereAll(f => f
            .IsActive()
            .Attribute(AbcPostalCodeMapping.Fields.AbcPostalCode).IsEqualTo(postalCode.Trim()))
        .FirstOrDefault();

    if (mapping == null)
    {
        context.Trace($"No region mapping for postal code {postalCode}.");
        return;
    }

    target.AbcRegionId = mapping.AbcRegionId;
}
```

### Updating related records (PostOperation)

Compare the image with the target so the work only happens on the real transition, then update each related record with only the columns that change.

```csharp
private static void CloseOpenTasks(ICDSPluginExecutionContext context, AbcCase target)
{
    var pre = context.PreImage?.ToEntity<AbcCase>();
    if (target.Statuscode != AbcCase.eStatuscode.Closed || pre?.Statuscode == AbcCase.eStatuscode.Closed)
    {
        return;
    }

    var openTaskIds = context.OrganizationService
        .Query<AbcCaseTask>()
        .Select(t => new { t.AbcCaseTaskId })
        .WhereAll(f => f
            .IsActive()
            .Attribute(AbcCaseTask.Fields.AbcCaseId).IsEqualTo(target.Id))
        .RetrieveAll()
        .Select(t => t.Id)
        .ToList();

    foreach (var taskId in openTaskIds)
    {
        context.OrganizationService.Update(new AbcCaseTask
        {
            Id = taskId,
            Statuscode = AbcCaseTask.eStatuscode.Cancelled
        });
    }

    context.Trace($"Cancelled {openTaskIds.Count} open task(s) for case {target.Id}.");
}
```

- Build updates with a **new** proxy instance that has only `Id` plus the changed columns. Never send back a retrieved record: it would rewrite every column it contains and re-trigger other plugins on all of them.
- Use `OrganizationService` (calling user) when the user's permissions should apply, and `ElevatedOrganizationService` only for work the user can't do themselves, such as maintaining system-owned records. Note in the trace why elevation was needed.
- Watch for loops. If your update can trigger another plugin that updates this record, guard with a status/transition check (as above) or filtering attributes. Use `context.Depth` only as a last resort.

### Custom API with a helper

Keep the API class thin: validate the inputs, call a helper, and map the results onto the response. The helper holds the logic, so other plugins can call it directly with the same `context` (and the same cache) instead of going through the API.

```csharp
[CrmPluginRegistration(AbcCloseCaseRequest.SchemaName)]
public class CloseCaseApi : PluginBase
{
    public CloseCaseApi(string unsecureConfig, string secureConfig) : base(unsecureConfig, secureConfig)
    {
        RegisterApiHandler<AbcCloseCaseRequest, AbcCloseCaseResponse>(OnExecute);
    }

    private static void OnExecute(ICDSPluginExecutionContext context, AbcCloseCaseRequest request, AbcCloseCaseResponse response)
    {
        _ = request ?? throw new ArgumentNullException(nameof(request));

        int tasksClosed = CloseCaseHelper.Execute(context, request.Target.Id, request.Resolution);

        response.TasksClosed = tasksClosed;
    }
}
```

```csharp
namespace PluginAssemblyName.Helpers
{
    internal static class CloseCaseHelper
    {
        internal static int Execute(ICDSPluginExecutionContext context, Guid caseId, string resolution)
        {
            string processName = $"{nameof(CloseCaseHelper)}.{nameof(Execute)}";
            context.Trace($"Entered {processName} - caseId: {caseId}");
            // ...small, well-named steps, each in its own method...
        }
    }
}
```

- The typed `...Request`/`...Response` classes are generated by ProxyBuilder. Add the API's unique name to `actionsToInclude` in `Plugins\proxies.json` and regenerate.
- Helpers live in `Plugins\Helpers\`, namespace `PluginAssemblyName.Helpers`, as `internal static` classes.
- Define the API's request parameters and response properties in Dataverse first, then export the solution.

### Filtering views (PreOperation RetrieveMultiple)

To make a view show "records related to the current user" in a way FetchXML can't express, put a **sentinel condition** in the view, such as `name equals #MyTeamCases`. A query plugin then finds the sentinel, removes it, and adds the real criteria:

```csharp
private const string MyTeamCasesFilter = "#MyTeamCases";

public CaseViewFilterPlugin(string unsecureConfig, string secureConfig) : base(unsecureConfig, secureConfig)
{
    RegisterQueryHandler<AbcCase>(ePluginStage.PreOperation, OnRetrieveMultiple);
}

private static void OnRetrieveMultiple(ICDSPluginExecutionContext context, QueryExpression query, EntityCollection results)
{
    if (!RemoveSentinel(query.Criteria, AbcCase.Fields.AbcName, MyTeamCasesFilter))
    {
        return;
    }

    context.Trace(query.ToReadableText());
    AddCurrentUserTeamFilter(context, query);
    context.Trace(query.ToReadableText());
}
```

- Search nested filters recursively (`filter.Filters`) for the sentinel, because views can nest conditions.
- Return immediately when there's no sentinel. This plugin runs on **every** query against the table, so it must be cheap when it does nothing.
- Trace the query before and after (`ToReadableText()`), which makes view problems easy to diagnose.

### Calling external services

Use `context.CreateWebRequest(uri)`, which works in the sandbox, rather than `HttpClient`. Keep the call in a helper, check `response.Success`, and fail with a clear message:

```csharp
using (var request = context.CreateWebRequest(new Uri(config.TokenUrl)))
{
    var response = request.Post(Encoding.UTF8.GetBytes(body), "application/x-www-form-urlencoded");
    if (!response.Success)
    {
        throw new InvalidOperationException($"Token request failed with status {response.StatusCode}.");
    }

    var token = JObject.Parse(response.Content)["access_token"]?.ToString();
    // ...
}
```

- Sandbox plugins have a **2-minute** limit and can only reach HTTP/HTTPS endpoints on standard ports. Move long or unreliable calls to an asynchronous step, or to a cloud flow (see `Developer-Guidelines` in the `solution_template` repo's `docs/`).
- Never log tokens, secrets or response bodies that may contain personal data.

## Querying with the fluent API

Use `Query<T>()` (`JMCL.Dataverse.Data.Sources`) rather than raw `QueryExpression`:

```csharp
var requirements = context.OrganizationService
    .Query<AbcRequirement>()
    .Select(r => new { r.AbcRequirementId, r.AbcName })                 // always name the columns
    .InnerJoin<Account>(AbcRequirement.Fields.AbcAccountId, Account.Fields.Id, account => account
        .With.Alias("acct")
        .WhereAll(f => f.Attribute(Account.Fields.Id).IsEqualTo(accountId)))
    .WhereAll(f =>
    {
        f.IsActive();
        f.WhereAny(any => any                                           // (abc_waived = false OR abc_waived IS NULL)
            .Attribute(AbcRequirement.Fields.AbcWaived).IsEqualTo(false)
            .Attribute(AbcRequirement.Fields.AbcWaived).IsNull());
    })
    .OrderByAsc(AbcRequirement.Fields.AbcName)
    .RetrieveAll();                                                     // pages through every result
```

- `RetrieveAll()` pages through all results. Use `FirstOrDefault()` when you need at most one record.
- Use `.Is<T>(ConditionOperator.X, value)` for operators without a helper method (`BeginsWith`, `Like`, `In`, and so on).
- To read a single record by ID, use `Retrieve` with an explicit `ColumnSet`, never `ColumnSet(true)`.

## Configuration, caching, telemetry and secrets

### Settings

`context.Settings.GetValue<string>("name")` reads Dataverse **environment variables**, matched by schema name or display name. The current value wins over the default. Use environment variables for per-environment values (URLs, feature switches, thresholds), and keep their names as constants in one `PluginSettings` class:

```csharp
public static class PluginSettings
{
    public static class Names
    {
        public const string CacheEnabled = "abc_CacheEnabled";
    }

    public static class CacheTimeouts
    {
        public static readonly TimeSpan RegionMappings = TimeSpan.FromMinutes(30);
    }
}
```

### Caching

`context.Cache` is an in-memory cache. It survives between executions only while Dataverse keeps the same sandbox worker and plugin instance, so treat it as a best-effort optimization for **reference data**, never as storage.

```csharp
string cacheKey = $"{nameof(RegionHelper)}.Mappings.{postalCode}";
bool cacheEnabled = context.Cache != null
    && context.Settings.GetValue<string>(PluginSettings.Names.CacheEnabled) == "yes";

if (cacheEnabled && context.Cache.Exists(cacheKey))
{
    return context.Cache.Get<IEnumerable<Entity>>(cacheKey).Select(e => e.ToEntity<AbcRegionMapping>()).ToList();
}

var records = /* fluent query */;
if (cacheEnabled && records.Count > 0)
{
    context.Cache.Add<IEnumerable<Entity>>(cacheKey, records, PluginSettings.CacheTimeouts.RegionMappings);
}
return records;
```

- Put an environment-variable switch around caching, so it can be turned off in an environment without a deployment.
- Key by class, purpose and input, and cache plain `Entity` collections.
- Never cache user-specific or security-filtered results under a key that doesn't include the user.

`PluginBase` shares one IoC container across every plugin class in the assembly, so all plugins share the same cache. A plugin deriving directly from `CDSPlugin` would get its own container and cache.

### Telemetry

`PluginBase` derives from JMCL's `InstrumentedCDSPlugin`. For every execution it records an Application Insights **request**, with its duration, success, message, table and correlation ID. It also records handler exceptions: validation errors as code 400, anything else as a failure. Telemetry from `context.Trace(...)` and from `context.CreateWebRequest(...)` calls (as dependencies) goes to the same place.

- **To turn it on**, add an environment variable with schema name `[publisherprefix]_TelemetryKey` (type Text) to this solution, and set its value in each environment to that environment's Application Insights instrumentation key. The name is `PluginBase.TelemetryKeyVariableName`. It's specific to this solution, so several solutions in one environment can report to separate Application Insights resources. Give each environment its own value, so dev, test and production telemetry stay separate.
- Add the definition **without a default value** and set the value per environment, as a current value or through the deployment settings. A default would be exported with the solution and carried into every environment.
- **With no key**, telemetry is disabled and plugins run normally. Projects that don't use Application Insights need no setup.
- Telemetry is sent to Application Insights' **commercial** ingestion endpoint by instrumentation key. Sovereign clouds (GCC and other US Government tenants) use different endpoints, so confirm telemetry arrives before relying on it there.
- Never put personal data, tokens or full record contents in traces. Everything traced is also sent to Application Insights.

### Secrets

Never put secrets in code, in plugin step **unsecure** configuration, or in a plain environment variable. Options, best first:

1. **Secret environment variable** (Azure Key Vault-backed), read with the `RetrieveEnvironmentVariableSecretValue` message.
2. **Secure configuration** on the step (`SecureConfiguration` on the attribute or set at registration), available as `SecureConfig` in the constructor. It's not exported with the solution, so it has to be set in each environment.
3. A configuration table that only an integration role can read. Use this only if neither of the above is available.

## Testing

`Plugins.UnitTest` uses MSTest with DLaB XrmUnitTest's in-memory Dataverse (`UseLocalCrmDatabase=true` in `UnitTestSettings.config`), so plugins run end to end with no environment.

### Before the first test run

- **Generate the proxies first** (`Plugins\codgen\proxybuilder.bat`). The in-memory service needs early-bound types for `businessunit` and `systemuser`. Plugin settings, which `PluginBase` reads on every execution, need `environmentvariabledefinition` and `environmentvariablevalue`. All of these are in the default `entitiesToInclude` in `Plugins\proxies.json`, so keep them there.
- The in-memory service finds proxy types through `Shared.Proxies\CrmServiceContext.cs`, which is compiled into the plugin assembly. Tests therefore use exactly the proxy types the plugins use.
- Run the tests from Visual Studio's Test Explorer, or with `vstest.console.exe Plugins.UnitTest\bin\<Configuration>\PluginAssemblyName.UnitTest.dll /InIsolation`. Without `/InIsolation`, XrmUnitTest tries to write settings into `vstest.console.exe.config` under Program Files and fails.

### Structure

One test class per plugin. Each `[TestMethod]` delegates to an inner class deriving `TestMethodClassBase`. That class seeds data in `InitializeTestData` and runs the scenario in `Test`:

```csharp
[TestClass]
public class SetCaseClosedOnPluginTests
{
    [TestMethod]
    public void StatusChangedToClosed_ClosedOnEmpty_SetsClosedOn()
    {
        new Test_StatusChangedToClosed_ClosedOnEmpty_SetsClosedOn().Test();
    }

    private class Test_StatusChangedToClosed_ClosedOnEmpty_SetsClosedOn : TestMethodClassBase
    {
        private static readonly Guid CaseId = Guid.Parse("{00000000-0000-0000-0001-000000000001}");

        protected override void InitializeTestData(IOrganizationService service) { }

        protected override void Test(IOrganizationService service)
        {
            var target = new AbcCase { Id = CaseId, Statuscode = AbcCase.eStatuscode.Closed };
            var context = BuildUpdateContext(target, preImage: new AbcCase());
            var serviceProvider = new ServiceProviderBuilder(service, context, new DebugLogger()).Build();

            new SetCaseClosedOnPlugin(null, null).Execute(serviceProvider);

            Assert.IsNotNull(GetTarget(serviceProvider).AbcClosedOn,
                "abc_closedon should be set when status changes to Closed.");
        }
    }

    private static FakePluginExecutionContext BuildUpdateContext(AbcCase target, AbcCase preImage)
    {
        var context = new FakePluginExecutionContext
        {
            Stage = (int)ePluginStage.PreOperation,
            MessageName = MessageNames.Update,
            PrimaryEntityName = AbcCase.EntityLogicalName,
            PrimaryEntityId = target.Id
        };
        context.InputParameters["Target"] = target;
        context.PreEntityImages["PreImage"] = preImage;
        return context;
    }

    private static AbcCase GetTarget(IServiceProvider serviceProvider)
    {
        var context = (FakePluginExecutionContext)serviceProvider.GetService(typeof(IPluginExecutionContext));
        return (AbcCase)context.InputParameters["Target"];
    }
}
```

### Seeding data with builders

Add one builder per table in `Plugins.UnitTest\Builders\`, with fluent `With...` methods for the columns tests care about:

```csharp
public class AbcCaseTaskBuilder : EntityBuilder<AbcCaseTask>
{
    public AbcCaseTaskBuilder() { }
    public AbcCaseTaskBuilder(Id id) : base(id) { }

    public AbcCaseTaskBuilder WithCase(Id caseId)
    {
        Record.AbcCaseId = caseId.EntityReference;
        return this;
    }
}
```

Then seed with `CrmEnvironmentBuilder`, keeping IDs in a nested `Ids` struct:

```csharp
private readonly struct Ids
{
    public static readonly Id CaseId = new Id<AbcCase>("{00000000-0000-0000-0001-000000000001}");
    public static readonly Id TaskId = new Id<AbcCaseTask>("{00000000-0000-0000-0002-000000000001}");
}

protected override void InitializeTestData(IOrganizationService service)
{
    new CrmEnvironmentBuilder()
        .WithBuilder<AbcCaseTaskBuilder>(Ids.TaskId, b => b.WithCase(Ids.CaseId))
        .WithEntities<Ids>()                 // creates any Ids not created by a builder
        .Create(service);
}
```

Then assert by retrieving from `service` after `Execute`.

### Testing guidance

- **Name tests `Scenario_Condition_ExpectedResult`**, and give every assertion a message that states the rule.
- **Cover the early exits**, not just the happy path: wrong status, value already set, column not in the request.
- **Test pure rules directly** by making them `public static` methods (on the plugin class or a public helper), and call them without a pipeline.
- **Test `internal` helpers through their entry point**: execute the plugin or Custom API that calls the helper. The plugin assembly is strong-named and doesn't expose its internals to the test project.
- **Lookups must exist.** The in-memory service rejects an `EntityReference` to a record that wasn't created, including `systemuser`. Seed it with `WithEntities<Ids>()` or a builder.
- **Use deterministic GUIDs** (`{00000000-0000-0000-00TT-0000000000NN}`, where TT is the table and NN the record) so failures are easy to read. Never use real record IDs.
- **Don't import `Shared.Proxies` into the test project.** Tests use the proxies compiled into the `Plugins` assembly through its project reference. A second compiled copy makes the in-memory service fail with "cannot convert `Shared.Proxies.X` to `Shared.Proxies.X`".

## Checklist: adding a plugin

1. Check the implementation choice: is a plugin the right tool? (See *Choosing an Implementation* in `AGENTS.md`.)
2. Make sure every table and column you use is in `Plugins\proxies.json`, and regenerate the proxies if not. Custom APIs go in `actionsToInclude`.
3. Create `Plugins\<Name>Plugin.cs` (or `<Name>Api.cs`) deriving from `PluginBase` and any `Plugins\Helpers\<Name>Helper.cs`, and **add each new file to `Plugins.csproj`** (`<Compile Include="..." />`). The project file lists files explicitly.
4. Add `[CrmPluginRegistration]` attributes, with new GUIDs, filtering attributes and only the image columns you need.
5. Write tests in `Plugins.UnitTest\Tests\<Name>Tests.cs`, plus builders as needed. Add these files to `Plugins.UnitTest.csproj` too.
6. Build and run the tests.
7. Deploy to your sandbox with `Plugins\spkl\deploy-plugins.bat`, test it there, then run `Export.ps1` and commit the code together with the exported `CdsSolution\` changes.
8. Describe the plugin in the PR: business purpose, trigger (table/message/stage), columns read and written, and how to test.
