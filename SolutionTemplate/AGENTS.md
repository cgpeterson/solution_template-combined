# [solutionname] — Agent Instructions

Instructions for AI coding agents (Claude Code, Codex, GitHub Copilot, Cursor, etc.) working in this repository.

## Project Overview

Client Dataverse/Dynamics 365 solution built from the JMCL solution template (the `SolutionTemplate/` folder of the `solution_template` repo, copied by its `New-Project.ps1`). See `README.md` for the full project structure and branch strategy.

- **Solution:** `[solutionname]`
- **Plugin assembly:** `PluginAssemblyName`
- **Root namespace:** `PluginAssemblyName`
- **Publisher prefix:** `[publisherprefix]`

> Some projects split schema and plugins/web resources across a Base + Layer2 pair of repos (Base owns tables/columns with no external dependencies and deploys first; Layer2 owns plugins/web resources/Power Pages and depends on Base). If this project is split that way, document the layering and deploy order here.

## Build Commands

The `.csproj` files are legacy (non-SDK) format — **use `nuget.exe restore`, NOT `dotnet restore`**.

```powershell
# Restore — always use nuget.exe, never dotnet restore
& "C:\Users\<you>\AppData\Local\Microsoft\PowerAppsCLI\nuget.exe" restore "[solutionname].sln" -ConfigFile NuGet.config

# Build
msbuild "[solutionname].sln" /p:Configuration=Release /p:Platform="Any CPU"

# Run tests (MSTest)
vstest.console.exe Plugins.UnitTest/bin/Release/PluginAssemblyName.UnitTest.dll
```

JMCL `.Sources` packages deliver their source files into the Plugins project via NuGet `contentFiles` — there is no manual copy step and no generated folder to commit.

**Do not remove or rename `globalPackagesFolder` in `NuGet.config`.** `Plugins\spkl\deploy-plugins.bat` and `Plugins\codgen\proxybuilder.bat` find their tools by searching the solution-local `packages\` folder; restoring to the global cache silently breaks them.

## Key Constraints

- **Target framework: .NET Framework 4.8, C# 7.3 — do not upgrade.** Dataverse plugins run on .NET Framework.
- **Do not use C# 8+ syntax** (nullable reference types, switch expressions, using declarations, default interface members).
- **Do not add NuGet packages** beyond the JMCL and Microsoft packages already referenced without asking first. JMCL packages come from public nuget.org.

## Do Not

- Do NOT use `dotnet build` or `dotnet restore` — use `msbuild` and `nuget.exe`
- Do NOT use `async/await` in plugins — the Dataverse plugin sandbox does not support it
- Do NOT store instance state in plugin classes — plugins must be stateless
- Do NOT use late-bound `entity["fieldname"]` when an early-bound proxy exists in `Shared.Proxies/`
- Do NOT use `ColumnSet(true)` — always specify the exact columns needed
- Do NOT throw base `Exception` in plugins — use `InvalidPluginExecutionException` for user-facing validation errors (it's the only type that shows a message to the user)
- Do NOT use `Console.WriteLine` in plugins — use `context.Trace()`
- Do NOT leave magic numbers or hardcoded strings — extract to named constants
- Do NOT write methods longer than ~30 lines — extract sub-operations into well-named helpers

## Entity Proxies & Naming Conventions

Early-bound proxies are generated into `Shared.Proxies/` (namespace `Shared.Proxies`) by `Plugins\codgen\proxybuilder.bat` (`JMCL.Dataverse.ProxyBuilder`), driven by `Plugins/proxies.json` and `Plugins/ProxyTemplate.t4`. Add entities to `entitiesToInclude` in `proxies.json` and regenerate — do not hand-edit generated proxies.

- Entity logical names use the publisher prefix: `[publisherprefix]_case`
- Entity proxy classes use a pascal-cased version of the prefix: e.g. prefix `abc` → proxy class `AbcCase`
- Fields use the prefix on the proxy: `AbcCase.Fields.AbcCaseNumber`
- Access fields via the `EntityName.Fields.FieldName` constant pattern
- Option sets via the `EntityName.eFieldName` enum pattern

## Schema Naming

When creating or proposing tables, columns or relationships:

- Schema names are `[publisherprefix]_` plus PascalCase (`[publisherprefix]_PolicyExpirationDate`). Logical names are the same in lowercase. Schema and logical names can't be changed after creation.
- Column suffixes by type: date and time `...On`, date-only `...Date`, choice `...Code`/`...Type`, lookup `...Id` (qualify duplicates: `EmployerAccountId`), identifier numbers `...Number`, image `...Image`, phone `...Phone`, URL `...Url`, email `...EmailAddress`, duration `...Minutes`, time zone `...Offset`. Yes/No columns start with `Is` (`IsStockItem`).
- One-to-many relationship names: `[publisherprefix]_<referencing table>_<LookupSchemaName>_<referenced table>`, e.g. `[publisherprefix]_project_VendorAccountId_account`.

## Choosing an Implementation

- Logic that must hold however the data changes (forms, imports, API, integrations), or that needs complex calculation or data manipulation: **plugin**.
- Form-only field behavior before save: **business rule**, or a **JavaScript web resource** when it involves multi-select columns or related-record data. Never rely on form logic alone for data integrity.
- Long-running, scheduled, or integration work: **Power Automate cloud flow**.
- Simple synchronous no-code logic on a data change: a classic real-time **workflow**.
- If none of these fit, question whether the automation is needed before building something else.

## Plugin Pattern (JMCL `CDSPlugin`)

All plugin classes inherit from `CDSPlugin` (`JMCL.Dataverse.Sdk`). The constructor declares which events the plugin handles and the framework dispatches to the handler — do not switch on `context.MessageName`.

```csharp
public class AccountPreCreate : CDSPlugin
{
    public AccountPreCreate(string unsecureConfig, string secureConfig)
        : base(unsecureConfig, secureConfig)
    {
        RegisterEventHandler(
            entityName: Account.EntityLogicalName,
            messageName: MessageNames.Create,
            stage: ePluginStage.PreOperation,
            handler: OnAccountPreCreate);
    }

    private void OnAccountPreCreate(ICDSPluginExecutionContext context)
    {
        var target = context.TargetEntity.ToEntity<Account>();
        // ...
    }
}
```

Useful `ICDSPluginExecutionContext` members:

- `TargetEntity` — the incoming target
- `PreMergedTarget` — the pre-image merged with the incoming target, so every field reflects the post-update value. Use it to read fields that the current operation didn't change. It is **not** the raw pre-image.
- `PreImage` / `PostImage` — the raw registered images
- `OrganizationService` / `ElevatedOrganizationService` — calling-user vs. system-user service
- `Trace(...)` — write to the plugin trace log

Plugin step registration for `spkl` deployment is declared with `CrmPluginRegistrationAttribute` (`Plugins/CrmPluginRegistrationAttribute.cs`) and configured in `Plugins/spkl.json`.

## Code Standards

- Explicit curly braces on all `if` statements
- Minimal comments — code should be self-documenting; prefer expressive method names over inline comments
- No dead code — delete commented-out code and unused methods
- Early returns to reduce nesting
- Use the JMCL fluent query API (`organizationService.Query<TEntity>()` from `JMCL.Dataverse.Data.Sources`) rather than raw `QueryExpression`

## Web Resources

`WebResources/` is a TypeScript/JavaScript project deployed via `spkl` (`WebResources\spkl\deploy-webresources.bat`) for fast local iteration against a dev sandbox. That push is a local convenience only — it is not part of CI. The source of truth for what ships is whatever gets exported from Dataverse into `DeploymentPackage/CdsSolution` via `Export.ps1`, so after testing changes locally, re-export and commit the resulting XML.

## Code Apps

Power Apps code apps (standalone Vite/React SPAs using the `@microsoft/power-apps` SDK) live under `CodeApps/<AppName>/`, one subfolder per app. See `CodeApps/README.md` for scaffolding, local dev (`pa app run`), and publishing (`pa app push`).

Code apps have no XML/YAML representation to unpack from an exported Dataverse solution, so they don't go through `Export.ps1`. CI runs `npm ci && npm run build` for each app to catch breakage, but **publishing is manual** (`pa app push`) — there is no automated deployment of code apps yet. Commit `package-lock.json`; never commit `node_modules/`, `dist/`, or `.env*` files.

## Documentation

When creating or significantly modifying a plugin or feature, also draft:
- A brief wiki-style summary: business purpose, trigger (entity/message/stage), entities/fields touched, known constraints
- A PR description with "How to Test" steps

If this project has an ADO project wiki, consider mirroring it as Markdown under `docs/wiki/` in this repo so agents can read and update it directly.

## Deployment / Credentials

Connection files live in `DeploymentPackage/DevOps/CdsConnectionParameters/`. Copy the `*-Template.ps1` file and fill in credentials locally — **never commit credentials**.

`ProjectFeedId` in `azure-pipelines.yml` must be this project's own ADO Artifacts feed ID (`{org-guid}/{feed-guid}`) before the pipeline will publish successfully. If it still contains a `replace-with-` placeholder, it hasn't been set yet. Tool versions (PAC CLI, Node.js, PowerShell modules) are pinned in `azure-pipelines.yml` — bump them deliberately, not as a side effect of other work.

## Credentials & Secrets

Never include in prompts, code, or any file an agent reads:
- Connection strings or environment URLs (`*.dynamics.com`)
- OAuth tokens, client secrets, or API keys
- Real record GUIDs from a live Dataverse environment, unless the task explicitly requires looking up specific records

Everything in the git repository (source code, proxies, solution XML, pipeline config) is safe to share. Runtime data is not.

> If this project deploys to a regulated environment (e.g. a government/GCC tenant), add project-specific PII and data-hygiene rules here.

## MCP Setup

`.mcp.json` defines `azure-devops` and `dataverse-dev` server entries. `AZURE_DEVOPS_COLLECTION` / `AZURE_DEVOPS_PROJECT` must be this client's ADO org/project. If they still contain `replace-with-` placeholders, fill them in.

For Claude Code: copy `.claude/settings.local.json.example` to `.claude/settings.local.json` (gitignored) and fill in `AZURE_DEVOPS_PAT` / `DATAVERSE_DEV_URL`. `.claude/settings.json` holds the shared permission allow/deny list. Other agents should supply the same environment variables through their own local configuration.
