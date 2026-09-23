# CDS Solution Template

This is the base template for JMCL-managed Power Apps/Dataverse solution repos. New client solution repos are created from this template using `New-Project.ps1` in the `deployment_template` repo.

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
DeploymentPackage/              # Dataverse solution deployment package
  CdsSolution/                  # Unpacked solution XML
  DevOps/                       # Import/export scripts and tools
    Tools/
      Adoxio.Dynamics.DevOps/
      CCLLC.Cds.DevOps/
      ConfigurationMigration/
      CoreTools/
  CdsArtifacts.nuspec           # Package manifest for the solution artifact package
azure-pipelines.yml             # CI/CD pipeline
NuGet.config                    # globalPackagesFolder setting (required for tool discovery)
```

## Getting Started (New Project)

New projects are created automatically via `New-Project.ps1` in the `deployment_template` repo. After the script runs, complete these manual steps:

1. **Create a Dataverse sandbox environment** for development.
2. **Create an empty solution** in that sandbox:
   - Unique name: matches the `SolutionName` you passed to `New-Project.ps1`
   - Publisher: with the prefix matching `PublisherPrefix`
   - Version: `0.0.0.1`
3. **Export the solution** (unmanaged) and commit `solution.xml` to the `dev` branch.
4. **Update `ProjectFeedId`** in `azure-pipelines.yml` with the client project's ADO Artifacts feed ID (`{org-guid}/{feed-guid}`).
5. **Update the agent pool** in `azure-pipelines.yml` if not using Microsoft-hosted agents.

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
| `JMCL.Dataverse.Data.Sources` | Fluent query builder and data extensions |
| `JMCL.Core.IocContainer.Sources` | IoC container |
| `JMCL.Core.Net.Sources` | HTTP web request utilities |
| `JMCL.Core.ProcessModel.Sources` | Process model interfaces and caching |
| `JMCL.Dataverse.ProxyBuilder` | Proxy code generation tool (`Plugins\codgen\proxybuilder.bat`); signs in to Dataverse with MSAL |

## Branch Strategy

```
feature/*  \
bugfix/*    +-->  dev  -->  release/*  -->  main
issue/*    /                    ^
hotfix/*  ----------------------+
```

| Branch | Merges into | Notes |
|---|---|---|
| `feature/*`, `bugfix/*`, `issue/*` | `dev` | Normal development work |
| `hotfix/*` | `release/*` (then back-ported to `dev`) | Urgent fixes |
| `dev` | `release/*` | Release candidates |
| `release/*` | `main` | After deployment sign-off |

All PRs require a passing CI build. The CI pipeline enforces source branch rules on every PR merge build — invalid source→target combinations fail the build immediately.

## Token Reference

When creating a new project manually (without `New-Project.ps1`), replace these tokens:

| Token | Replace With |
|---|---|
| `[solutionname]` | Dataverse solution unique name |
| `PluginAssemblyName` | Plugin assembly/namespace name |
| `[publisherprefix]` | Dataverse publisher prefix |
| `replace-with-your-org-guid/replace-with-your-feed-guid` | Client ADO Artifacts feed ID |
