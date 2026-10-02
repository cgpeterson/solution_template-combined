# Daily Dev Workflow

How day-to-day work moves between your Dataverse sandbox and the repo. It assumes [Developer Machine Setup](Developer-Machine-Setup.md) is done.

## The loop

1. Branch from `main` (`feature/*`, `bugfix/*`, or `issue/*`). To fix a release in flight, branch `hotfix/*` from that `release/*` branch instead (see the branch strategy in the project's `README.md`).
2. `Import.ps1`: put the branch's solution into your sandbox.
3. Make changes, either in the maker portal or in code (plugins, web resources, code apps).
4. `Export.ps1`: pull the sandbox changes back into `DeploymentPackage\CdsSolution\`.
5. Commit the code and the exported XML together, then open a PR to `main` (or, for a hotfix, to the `release/*` branch, plus a cherry-pick PR to `main`).

The exported XML in `CdsSolution\` is the source of truth for what ships. Anything pushed to the sandbox some other way (spkl, `pac`, the maker portal) only reaches other environments once it has been exported and committed.

All DevOps scripts are run from `DeploymentPackage\DevOps\`. Every script that connects to an environment signs in with MSAL against the URL in your connection file. The first run opens a browser sign-in, and the token is cached after that.

## Export.ps1: environment → repo

```powershell
.\Export.ps1                                         # export + extract the solution (default)
.\Export.ps1 -Actions All                            # solution + config data (+ Stage-PortalChange)
.\Export.ps1 -Actions TestData                       # test data (not part of All)
.\Export.ps1 -Actions PortalPages                    # download the Power Pages site (not part of All)
.\Export.ps1 -Actions PortalPages,Stage-PortalChange
```

| Parameter | Default | Notes |
|---|---|---|
| `-ConnectionName` | `MySandbox` | `MySandbox` reads `C:\CrmConnection\MyCdsSandboxConnection.ps1`. Other values read `CdsConnectionParameters\<name>.ps1`. |
| `-ExportSettings` | `DefaultSettings` | A file under `Settings\` |
| `-Actions` | `Solutions` | One or more of the values below |
| `-SiteFolderName` | *(auto)* | For `Stage-PortalChange`, when the repo has more than one site folder |

| Action | In `All`? | What it does |
|---|---|---|
| `Solutions` | yes | Exports and extracts the solution into `CdsSolution\` |
| `ConfigData` | yes | Exports and extracts configuration data (needs `ConfigData.Schema.xml`) |
| `TestData` | no | Exports and extracts test data (needs `TestData.Schema.xml`) |
| `PortalPages` | no | Downloads the Power Pages site with `pac` (needs `Sites\_site-config\PortalToolkit.Config.psd1`) |
| `Stage-PortalChange` | yes | Local only: stages the solution folders that match your staged portal files |
| `Export-CrmSolutions`, `Expand-CrmSolutions`, `Export-ConfigData`, `Expand-ConfigData`, `Export-TestData`, `Expand-TestData` | — | One half of the actions above, e.g. re-extract an already-exported zip |

## Import.ps1: repo → environment

```powershell
.\Import.ps1                                         # package and import everything (default)
.\Import.ps1 -Actions Solutions                      # solution only
.\Import.ps1 -ResetEnvironment                       # reset the sandbox first (destructive, asks to confirm)
.\Import.ps1 -Actions Upload-StagedPortalChanges -DryRun
```

| Parameter | Default | Notes |
|---|---|---|
| `-ConnectionName` | `MySandbox` | Same as `Export.ps1` |
| `-ImportSettings` | `DefaultSettings` | A file under `Settings\` |
| `-PackageType` | `Unmanaged` | `Managed` or `Unmanaged` for the target solution. Dependency solutions are always managed. |
| `-Actions` | `All` | One or more of the values below |
| `-ResetEnvironment` | off | Resets the environment with `pac admin reset` before importing. **Destructive**: it asks for confirmation. |
| `-SiteFolderName`, `-DryRun`, `-SkipFieldPatcher` | — | Passed to the Power Pages scripts |

| Action | In `All`? | What it does |
|---|---|---|
| `Solutions` | yes | Packs `CdsSolution\` and imports it, after any dependency solutions |
| `ConfigData` | yes | Compresses config data, merges dependency config data, and imports it |
| `TestData` | yes | Same, for test data |
| `Import-DocumentTemplates` | yes | Imports Word/Excel document templates |
| `Stage-PortalChange` | yes | Local only |
| `Upload-StagedPortalChanges` | no | **Live push** of staged Power Pages changes. It has its own Y/N prompt. |
| `Compress-CrmSolution`, `Compress-ConfigData`, `Merge-ConfigData`, `Compress-TestData`, `Merge-TestData`, `New-CrmPackage`, `Invoke-ImportCrmPackage` | — | Individual steps |

Building the `DeploymentPackage` project runs `Import.ps1 -Actions New-CrmPackage` against `DummyConnection`, so a build always produces a deployment package without connecting to anything. Debug builds pack the solution as unmanaged and Release builds as managed.

## Plugins

1. Write the plugin in `Plugins\`, following the project's `docs\Plugin-Development.md` (patterns, registration, testing and a step-by-step checklist).
2. Build, then run the unit tests in `Plugins.UnitTest`.
3. Register or update steps in your sandbox with `Plugins\spkl\deploy-plugins.bat`. It reads `CrmPluginRegistrationAttribute` declarations and `Plugins\spkl.json`.
4. `Export.ps1` so the assembly and step registrations land in `CdsSolution\`.

When importing, `solution.mappings.xml` swaps the exported plugin DLL for the freshly built one, so the deployed assembly always matches the source.

## Early-bound proxies

Add entities to `entitiesToInclude` in `Plugins\proxies.json`, then run `Plugins\codgen\proxybuilder.bat`. It signs in to Dataverse and regenerates the classes in `Shared.Proxies\`. Commit the generated files, and don't edit them by hand.

## Web resources

Edit TypeScript/JavaScript under `WebResources\`, then push to your sandbox with `WebResources\spkl\deploy-webresources.bat` to test. As with plugins, run `Export.ps1` afterwards so the change is in `CdsSolution\`.

## Power Pages

For projects with a Power Pages site (`DeploymentPackage\Sites\`):

```powershell
.\Export.ps1 -Actions PortalPages                        # 1. pull the latest site
# 2. edit the readable files under DeploymentPackage\Sites\<site>\
git add "DeploymentPackage/Sites/<site>/..."              # 3. stage your changes
.\Stage-PortalChange.ps1                                  #    stages the matching powerpagecomponents\{GUID}\ folders too
.\Upload-StagedPortalChanges.ps1 -DryRun                  # 4. preview the push
.\Upload-StagedPortalChanges.ps1                          #    push to your environment to test
git commit -m "..."                                       # 5. commit both halves together
```

`Upload-StagedPortalChanges.ps1` runs in two phases:

1. **Safe overlay:** it re-downloads the current site, overlays only your staged files, and uploads with `pac pages upload`, so other developers' in-progress changes aren't overwritten.
2. **Field patcher:** `pac` drops some fields when translating `adx_*` to `mspp_*` on enhanced-data-model sites. This phase reads each staged YAML file and patches the record through the Web API. Skip it with `-SkipFieldPatcher`.

`pac pages upload` has no gate of its own, so read the confirmation prompt before answering `Y`.

## Code apps

See `CodeApps\README.md` in the project. Run locally with `pa app run`, publish with `npm run build` then `pa app push`. CI builds each app but doesn't publish it.

## Troubleshooting

| Symptom | Fix |
|---|---|
| The first export of the day, or the first after a reset, times out while publishing | Run it again. Idle environments are slow to publish the first time. |
| Import skips the target solution | The solution version isn't higher than the installed one. Bump the revision in `CdsSolution\Other\solution.xml`, or import the zip from `temp\deployment\` by hand. |
| Import fails converting unmanaged customizations to managed | Import that solution by hand from `temp\deployment\` so you can consent to the conversion. |
| Import times out upgrading a large managed solution | Run it again. |
| `PortalToolkit.Config.psd1 not found` | The project hasn't been set up for Power Pages. The file belongs at `DeploymentPackage\Sites\_site-config\PortalToolkit.Config.psd1`. |
| `PowerPagesConnectionParameter.Cloud` (or `ProfileName`/`TenantId`) missing | These are project constants and belong in `PortalToolkit.Config.psd1`, not your personal connection file. |
| `pac` not found | Open a new terminal after running `Install_PowerShell_Dependencies.ps1`, or check `pac --version`. |
