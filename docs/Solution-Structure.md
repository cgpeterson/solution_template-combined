# Solution Structure

How a solution repo created from this template is organized, and why. Each Dataverse solution has one Visual Studio solution. That solution contains a **DeploymentPackage** project, plus projects for plugins, web resources, unit tests and code apps as needed.

## Projects

| Project | Purpose |
|---|---|
| `DeploymentPackage` | The Dataverse artifacts that make up the solution, its dependency solutions, its data, and the DevOps scripts. Building it produces a deployment package. |
| `Plugins` | The plugin assembly (.NET Framework 4.8). `DeploymentPackage` depends on it, so a build always packs the latest plugin DLL into the solution. |
| `Plugins.UnitTest` | MSTest unit tests for plugins. By default they run against an in-memory organization service. |
| `Shared.Proxies` | A shared project of generated early-bound proxy classes, compiled into `Plugins`. |
| `WebResources` | TypeScript/JavaScript form and ribbon scripts. |
| `CodeApps/<AppName>` | Power Apps code apps, one folder per app. They aren't Visual Studio projects. See `CodeApps/README.md`. |

The solution also has **shortcut folders**: `DevOps` surfaces `Import.ps1` and `Export.ps1`, and `Pipeline` surfaces `azure-pipelines.yml`, so developers can open or run them from Visual Studio.

## DeploymentPackage

| Item | What it is | Edited by |
|---|---|---|
| `CdsSolution\` | The unpacked solution: a tree of XML files exported from a sandbox by `Export.ps1`. Most of a change's diff is here. It's hidden from the `.csproj` to keep the project file small. | `Export.ps1` |
| `CdsDependencies\` | Managed solutions, plus their config/test data, that this solution depends on. They arrive as NuGet packages published by the dependency solutions' own pipelines (see `CdsArtifacts.nuspec`). | NuGet; don't edit by hand |
| `ConfigData\` | Optional. Configuration data unpacked to XML, defined by `ConfigData.Schema.xml`. It's deployed with the solution. | `Export.ps1 -Actions ConfigData` |
| `TestData\` | Optional. Records for testing, defined by `TestData.Schema.xml`. Not part of the standard deployment. | `Export.ps1 -Actions TestData` |
| `Sites\` | Optional. Readable Power Pages site files, plus `_site-config\PortalToolkit.Config.psd1` for the project-wide site settings. | `Export.ps1 -Actions PortalPages` |
| `DevOps\` | Import/export scripts and their tools. Delivered by the `DeploymentTemplate.Sources` NuGet package. | Change them in `deployment_template` and update the package. Don't edit them here. |
| `SolutionSettings.ps1` | The solution name and the dependency solution order that the scripts use. | By hand |
| `solution.mappings.xml` | Maps the plugin DLL inside the solution to the freshly built one when packing. | Rarely |
| `CdsArtifacts.nuspec` | Defines the dependency artifact package this solution publishes for solutions that depend on it. | Rarely |
| `PackageTemplate.cs`, `JmclImportExtension.cs` | Package Deployer metadata and import extension. `JmclImportExtension.cs` comes from `DeploymentTemplate.Sources`. | `PackageTemplate.cs` by hand |

Building `DeploymentPackage` runs `DevOps\post-build.ps1`, which creates a Package Deployer package in `temp\deployment\`. It packs the target solution as **unmanaged** for Debug builds and **managed** for Release builds, together with every dependency solution and the merged config data. `temp\` is gitignored.

## Why scripts instead of pipeline tasks

The DevOps scripts follow the structure Adoxio created for ADX portal development: repeatable import into an isolated developer sandbox, and repeatable export back into source control. The pipeline calls the same scripts rather than Power Platform Build Tools tasks. The tasks can't merge dependency solutions and their config data into a single package, which the scripts do.

## Pipeline

`azure-pipelines.yml` (Azure Pipelines) runs on `main` and `release/*`:

1. Enforces the allowed PR source → target branches: `feature/*`, `bugfix/*`, `issue/*` and `hotfix/*` into `main`; only `hotfix/*` into `release/*`.
2. Installs pinned tool versions: PAC CLI, PowerShell modules, NuGet, Node.js.
3. On `release/*`, stamps the build number into `solution.xml`.
4. Restores, then builds in Release, which produces the managed deployment package, and runs the unit tests.
5. Builds every code app.
6. On `main`, packs and publishes the dependency artifact package.
7. Publishes `temp\packed` and `temp\deployment` as build artifacts.

Build numbers follow the branch name, so `release/1.2` builds as `1.2.<rev>`.
