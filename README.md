# JMCL Solution Template

The starting point for JMCL-managed Power Apps/Dataverse solution repos, plus the documentation for setting up and working in them.

`SolutionTemplate/` is the part that gets copied for each new project. Everything else here (this README, `docs/`, `New-Project.ps1`) is about creating and maintaining projects, and isn't copied.

## Layout

```
New-Project.ps1        # Creates a new solution repo from SolutionTemplate/
docs/                  # Setup and how-to guides (not copied into projects)
SolutionTemplate/      # The template copied for each new project
  <solution>.sln, Plugins/, Plugins.UnitTest/, Shared.Proxies/, WebResources/,
  CodeApps/, DeploymentPackage/, azure-pipelines.yml, AGENTS.md, README.md, ...
AGENTS.md              # Instructions for agents maintaining this repo
```

## Start a new project

```powershell
.\New-Project.ps1 -Destination C:\Repos\contoso_claims `
    -SolutionName ContosoClaims -PublisherPrefix cc -ClientPrefix Contoso -ClientName "Contoso Ltd"
```

Then follow [New Project Setup](docs/New-Project-Setup.md).

## Documentation

| Guide | For |
|---|---|
| [Developer Machine Setup](docs/Developer-Machine-Setup.md) | Each developer, once per machine |
| [New Project Setup](docs/New-Project-Setup.md) | Whoever creates a new solution repo |
| [Environment and Service Principal Setup](docs/Environment-and-Service-Principal-Setup.md) | Setting up environments and deployment identities for a project |
| [Daily Dev Workflow](docs/Daily-Dev-Workflow.md) | Import/export, plugins, proxies, web resources, Power Pages, code apps |
| [Solution Structure](docs/Solution-Structure.md) | What each project and folder is for, and what the pipeline does |
| [Developer Guidelines](docs/Developer-Guidelines.md) | Implementation decision tree and naming conventions |
| [AI Agent Setup](docs/AI-Agent-Setup.md) | `AGENTS.md`, Claude Code settings, Dataverse and work-tracker MCP servers |
| [Plugin Development](SolutionTemplate/docs/Plugin-Development.md) | Plugin patterns, registration and testing. Copied into every project as `docs/Plugin-Development.md`. |

## Maintaining the template

- Change the template under `SolutionTemplate/`, keeping the tokens (`[solutionname]`, `PluginAssemblyName`, `[publisherprefix]`, ...) intact. The token list is in [New Project Setup](docs/New-Project-Setup.md#token-reference).
- The DevOps scripts under `SolutionTemplate/DeploymentPackage/DevOps/` come from the `DeploymentTemplate.Sources` package built in the `deployment_template` repo. Change them there.
- To test a change, run `New-Project.ps1` into a scratch folder, restore, and build the generated solution.
- JMCL framework packages (`JMCL.*.Sources`, `JMCL.Dataverse.ProxyBuilder`) are built in the `JMCL` repo and published to nuget.org.
