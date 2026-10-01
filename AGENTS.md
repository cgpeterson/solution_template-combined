# Solution Template Repo — Agent Instructions

Instructions for AI coding agents maintaining **this** repo: the template, `New-Project.ps1`, and `docs/`. Working inside a generated project is covered by `SolutionTemplate/AGENTS.md`, which is copied into every new project.

## What gets copied

- `SolutionTemplate/` is copied into each new project by `New-Project.ps1`. Only git-tracked files are copied.
- `docs/`, `README.md`, `AGENTS.md` and `New-Project.ps1` at the root are **not** copied.
- Files under `SolutionTemplate/` must not link to `../docs/...` or other paths outside the folder; those links break in generated projects. Refer to "the `solution_template` repo's `docs/`" instead.

## Tokens

- Placeholder tokens in `SolutionTemplate/` (`[solutionname]`, `PluginAssemblyName`, `[publisherprefix]`, `[clientprefix]`, `[clientname]`, `replace-with-*`) are intentional. Don't replace or "fix" them.
- Template prose must not quote a full token literally unless that sentence should change in the generated project. `New-Project.ps1` replaces every occurrence and reports any `replace-with-*` placeholders left over.
- When adding a token, update `Get-TokenMap` and `$leftoverTokenPattern` in `New-Project.ps1` and the Token Reference table in `docs/New-Project-Setup.md`.
- `[mydev]`, `[myname]` and `[mytenant]` are per-developer values in connection files. `New-Project.ps1` leaves them alone.

## Constraints

- `New-Project.ps1` must run on **Windows PowerShell 5.1**: no `??`, `?.`, ternaries, or `&&`/`||` pipeline chains.
- Don't assume Azure DevOps hosting. Docs and tooling stay host-neutral, and ADO-specific pieces (`azure-pipelines.yml`, the `azure-devops` MCP entry) are presented as optional.
- `SolutionTemplate/DeploymentPackage/DevOps/` is delivered by the `DeploymentTemplate.Sources` package from the `deployment_template` repo. Change scripts there, not here.
- Generated projects target .NET Framework 4.8 / C# 7.3. The rules in `SolutionTemplate/AGENTS.md` apply to template code.

## Verifying changes

1. Run `New-Project.ps1` into a scratch folder outside the repo, with and without the optional parameters. Check that it reports only the expected placeholders.
2. In the generated folder: `nuget.exe restore <SolutionName>.sln -ConfigFile NuGet.config`, then `msbuild <SolutionName>.sln /p:Configuration=Release`.
3. Delete the scratch folder afterwards.

## Docs

`docs/` holds the setup and how-to guides. When a template or script change affects a documented step, update the matching page in the same change.
