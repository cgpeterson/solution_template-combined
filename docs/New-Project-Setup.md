# New Project Setup

How to create a new client solution repo from `SolutionTemplate/`. This is one-time, per-**project** setup. Each developer also needs [Developer Machine Setup](Developer-Machine-Setup.md).

## 1. Decide the project values

| Value | Rules | Example |
|---|---|---|
| Solution name | Dataverse solution unique name: letters, digits, underscores; starts with a letter | `ContosoClaims` |
| Publisher prefix | 2–8 lowercase letters/digits, starting with a letter | `cc` |
| Client prefix | Short identifier used in the dependency artifact package id | `Contoso` |
| Client name | Display name used as the artifact package owner | `Contoso Ltd` |
| Plugin assembly name | Assembly name and root namespace (defaults to `<SolutionName>.Plugins`) | `ContosoClaims.Plugins` |

## 2. Run New-Project.ps1

From the root of this repo:

```powershell
.\New-Project.ps1 -Destination C:\Repos\contoso_claims `
    -SolutionName ContosoClaims `
    -PublisherPrefix cc `
    -ClientPrefix Contoso `
    -ClientName "Contoso Ltd"
```

Optional parameters:

| Parameter | Fills in |
|---|---|
| `-PluginAssemblyName` | Plugin assembly/namespace (default `<SolutionName>.Plugins`) |
| `-ProjectFeedId` | `ProjectFeedId` in `azure-pipelines.yml` (`{org-guid}/{feed-guid}`), only when using Azure DevOps Artifacts |
| `-AdoOrganization`, `-AdoProject` | The `azure-devops` MCP server in `.mcp.json`, only when the project is hosted in Azure DevOps |

The script:

- copies only the git-tracked files in `SolutionTemplate/`, so no `bin/`, `obj/`, `packages/` or local settings;
- replaces the tokens (see [Token Reference](#token-reference));
- renames `CdsSolutionTemplate.sln` to `<SolutionName>.sln` and gives it a new `SolutionGuid`;
- generates a new strong-name key (`Plugins\plugin.snk`), so plugin assemblies from different clients never share a key;
- lists any placeholders still left to fill in.

## 3. Create the Dataverse solution

1. Create a Dataverse **sandbox** environment for development. See [Environment and Service Principal Setup](Environment-and-Service-Principal-Setup.md).
2. In that environment, create a **publisher** whose prefix matches `-PublisherPrefix`.
3. Create an **empty solution**:
   - Unique name: the `-SolutionName` value
   - Publisher: the publisher from the previous step
   - Version: `0.0.0.1`

## 4. Initialize the repo and do the first export

```powershell
cd C:\Repos\contoso_claims
git init -b main
git add .
git commit -m "Create ContosoClaims from solution template"
git switch -c dev
```

Then, after [Developer Machine Setup](Developer-Machine-Setup.md), export the empty solution and commit it to `dev`:

```powershell
cd DeploymentPackage\DevOps
.\Export.ps1
```

Commit the new `DeploymentPackage\CdsSolution\` folder, including `Other\solution.xml`.

## 5. Host the repo and protect the branches

Push `main` and `dev` to the client's git host and make `dev` the default branch. The branch strategy is described in the generated repo's `README.md`:

```
feature/*, bugfix/*, issue/*  ->  dev  ->  release/*  ->  main
hotfix/*  ->  release/*  (then back-ported to dev)
```

Configure branch protection with your host's own features (GitHub rulesets, Azure DevOps branch policies, and so on). Recommended settings:

| Branch | Recommended protection |
|---|---|
| `dev` | Pull request required, at least one reviewer from the development team, passing CI build, linked work item if your tracker supports it |
| `release/*` | Pull request required, reviewers from the technical lead or client approver group, passing CI build |
| `main` | Pull request required (from `release/*` or `hotfix/*` only), passing CI build |
| All | Block direct pushes and force pushes |

The included `azure-pipelines.yml` also enforces the allowed source → target branch combinations on PR merge builds. On another CI system, carry that check across or rely on branch protection rules.

## 6. Set up CI

The template ships an **Azure Pipelines** definition (`azure-pipelines.yml`). It builds, runs tests, builds code apps, packs the deployment package, and publishes a dependency artifact package from `dev`.

- **Azure DevOps:** register the pipeline from `azure-pipelines.yml`. Set `ProjectFeedId` to the project's Artifacts feed if the project publishes a dependency artifact package. Change the agent pool if you aren't using Microsoft-hosted agents.
- **Other hosts:** use `azure-pipelines.yml` as the reference for the steps an equivalent pipeline needs.

## 7. Agent configuration

- If the project isn't hosted in Azure DevOps, remove the `azure-devops` server from `.mcp.json`.
- Each developer copies `.claude/settings.local.json.example` to `.claude/settings.local.json` and fills in their own values. See [AI Agent Setup](AI-Agent-Setup.md).

## Token Reference

`New-Project.ps1` replaces these tokens. To set up a project by hand, replace them across the whole template folder with find-and-replace.

| Token | Replaced with | Where |
|---|---|---|
| `[solutionname]` | Solution unique name | `SolutionSettings.ps1`, both `spkl.json` files, `PackageTemplate.cs`, `CdsArtifacts.nuspec`, `README.md`, `AGENTS.md` |
| `PluginAssemblyName` | Plugin assembly/namespace name | `Plugins.csproj`, `Plugins.UnitTest` sources and `.csproj`, `solution.mappings.xml`, `AGENTS.md` |
| `[publisherprefix]` | Publisher prefix | `AGENTS.md` |
| `[clientprefix]` | Client prefix | `CdsArtifacts.nuspec` |
| `[clientname]` | Client name (XML-escaped) | `CdsArtifacts.nuspec` |
| `replace-with-your-org-guid/replace-with-your-feed-guid` | ADO Artifacts feed ID | `azure-pipelines.yml` |
| `replace-with-client-ado-org` | ADO organization | `.mcp.json` |
| `replace-with-client-ado-project` | ADO project | `.mcp.json` |

`[mydev]` and `[mytenant]` in the connection template are per-developer values. They're filled in on each developer's own copy (see [Developer Machine Setup](Developer-Machine-Setup.md)), not by `New-Project.ps1`.

When adding a new token to the template, add it to `New-Project.ps1` (`Get-TokenMap` and `$leftoverTokenPattern`) and to this table.
