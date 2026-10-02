# [solutionname]

Power Apps/Dataverse solution repo for `[solutionname]`, created from the JMCL solution template (the `SolutionTemplate/` folder of the `solution_template` repo) by its `New-Project.ps1`.

## Project Structure

```
Plugins/                        # C# plugin assembly
  codgen/                       # Generated entity proxy files
  Shared.Proxies -> ../Shared.Proxies (shared project reference)
  ProxyTemplate.t4              # T4 template driving proxy code generation
  spkl.json                     # spkl plugin deployment configuration
  Plugins.csproj                # NuGet PackageReference (JMCL .Sources packages)
Shared.Proxies/                 # Shared project for proxies referenced by Plugins and WebResources
WebResources/                   # TypeScript/JavaScript web resources
Plugins.UnitTest/               # Unit test project
CodeApps/                       # Power Apps code apps (one subfolder per app) - see CodeApps/README.md
DeploymentPackage/              # Dataverse solution deployment package
  CdsSolution/                  # Unpacked solution XML
  DevOps/                       # Import/export scripts and tools
    Tools/
      Adoxio.Dynamics.DevOps/
      ConfigurationMigration/
      CoreTools/
      PackageDeployment.PowerShell/
  CdsArtifacts.nuspec           # Package manifest for the solution artifact package
azure-pipelines.yml             # CI/CD pipeline
NuGet.config                    # globalPackagesFolder setting (required for tool discovery)
AGENTS.md                       # Instructions for AI coding agents (Claude Code, Codex, Copilot, etc.)
docs/
  Plugin-Development.md         # Plugin patterns, registration, and testing guide
.claude/                        # Claude Code permissions + settings.local.json.example
.mcp.json                       # MCP servers (Azure DevOps, Dataverse) for AI agents
```

## Getting Started (New Project)

After `New-Project.ps1` creates the repo, complete these one-time steps. `docs/New-Project-Setup.md` in the `solution_template` repo covers them in detail.

1. **Create a Dataverse sandbox environment** for development.
2. **Create an empty solution** in that sandbox:
   - Unique name: matches the `SolutionName` you passed to `New-Project.ps1`
   - Publisher: with the prefix matching `PublisherPrefix`
   - Version: `0.0.0.1`
3. **Export the solution** (unmanaged) and commit `solution.xml` to `main`.
4. **Update `ProjectFeedId`** in `azure-pipelines.yml` with the client project's ADO Artifacts feed ID (`{org-guid}/{feed-guid}`).
5. **Update the agent pool** in `azure-pipelines.yml` if not using Microsoft-hosted agents.
6. **Update `.mcp.json`** with the client's ADO organization/project, and copy `.claude/settings.local.json.example` to `.claude/settings.local.json` (gitignored) to supply local secrets.

## Code Apps

Power Apps code apps (standalone Vite/React SPAs) live under `CodeApps/<AppName>/`, one subfolder per app. See `CodeApps/README.md` for scaffolding, local dev, and publishing. Unlike web resources, code apps have no source-control-friendly XML/YAML representation to unpack from a solution. CI builds each app (`npm ci && npm run build`) to catch breakage, but publishing to an environment (`pa app push`) is still a manual step.

## Building Locally

This solution uses `PackageReference`-style NuGet references. Use `nuget.exe restore` rather than `dotnet restore` (the project is a legacy-format `.csproj`, not SDK-style):

```powershell
& "C:\Users\<you>\AppData\Local\Microsoft\PowerAppsCLI\nuget.exe" restore "<solution>.sln" -ConfigFile NuGet.config
```

After restore, build the solution normally via Visual Studio or MSBuild. JMCL `.Sources` packages deliver source files via NuGet `contentFiles` — no manual copy step is needed.

> **Important**: Do not remove `globalPackagesFolder` from `NuGet.config`. The `spkl` and `JMCL.Dataverse.ProxyBuilder` tools are found by their batch scripts (`Plugins\spkl\deploy-plugins.bat`, `Plugins\codgen\proxybuilder.bat`), which recursively search the solution-local `packages\` folder. Removing this setting, or renaming it to `restorePackagesPath` (not a NuGet.config key, so NuGet ignores it), silently breaks those tools.

## NuGet Packages

JMCL framework packages are consumed from the public **nuget.org** feed — no private feed credentials are required for local restore.

| Package | Purpose |
|---|---|
| `JMCL.Dataverse.Sdk.Sources` | Core plugin base classes |
| `JMCL.Dataverse.Sdk.Instrumented.Sources` | `InstrumentedCDSPlugin`, the base of `Plugins\PluginBase.cs` (Application Insights telemetry) |
| `JMCL.Telemetry.Sources` | Sandbox-safe Application Insights client |
| `JMCL.Core.Net.Instrumented.Sources` | Web requests with dependency telemetry |
| `JMCL.Dataverse.Data.Sources` | Fluent query builder and data extensions |
| `JMCL.Core.IocContainer.Sources` | IoC container |
| `JMCL.Core.Net.Sources` | HTTP web request utilities |
| `JMCL.Core.ProcessModel.Sources` | Process model interfaces and caching |
| `JMCL.Dataverse.ProxyBuilder` | Proxy code generation tool (`Plugins\codgen\proxybuilder.bat`); signs in to Dataverse with MSAL |

## Branch Strategy

`main` is the only long-lived branch. Releases are governed by `release/*` branches cut from it.

```
feature/*  \
bugfix/*    +--PR-->  main  --(branch)-->  release/1.2  <--PR--  hotfix/*
issue/*    /           ^                                            |
                       +------------PR (cherry-pick)----------------+
```

| Branch | Created from | Merges into | Notes |
|---|---|---|---|
| `feature/*`, `bugfix/*`, `issue/*` | `main` | `main` | Normal development work |
| `release/*` (e.g. `release/1.2`) | `main` | — never merged back | Cut from `main` when a release is ready. Its builds are versioned (`1.2.<rev>`) and deployed through test, UAT and production. |
| `hotfix/*` | `release/*` | `release/*`, then cherry-picked to `main` | Fixes to a release in flight. Every hotfix also reaches `main` through its own PR, so the next release includes it. |

All PRs require a passing CI build. The CI pipeline enforces these rules on every PR merge build: only `feature/*`, `bugfix/*`, `issue/*` and `hotfix/*` may merge into `main`, and only `hotfix/*` into `release/*`. Invalid combinations fail the build immediately.
