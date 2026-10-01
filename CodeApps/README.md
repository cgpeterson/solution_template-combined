# Code Apps

Power Apps **code apps** let you build a standalone web app (React, Vue, etc.) in a code-first IDE, then publish it into Power Platform using the `@microsoft/power-apps` SDK and the `pa` CLI (`@microsoft/power-apps-cli`, which replaces the older `pac code` commands). Unlike `WebResources/` or a PCF control, a code app is **not** a component you can unpack from an exported Dataverse solution — it has no XML/YAML representation, only preview-level source-control integration, and its Dataverse footprint is just a pointer record added to a solution by `pa app push`.

Because of that, code apps don't follow the `Export.ps1`/`Import.ps1`/`DeploymentPackage/CdsSolution` pattern used for the rest of this solution. Treat each app's own git history as its source of truth, and its Dataverse solution membership as something maintained by explicit CLI pushes.

## Prerequisites

- A Power Platform environment with code apps enabled
- [Node.js](https://nodejs.org/) LTS (CI uses the version pinned by `NodeVersion` in `azure-pipelines.yml`)
- Git

## Convention

One subfolder per app:

```
CodeApps/
  <AppName>/
    power.config.json      # commit — connector/metadata config, not a secret
    src/
      generated/           # commit — generated connector models/services
      ...
    package.json           # commit
    package-lock.json      # commit — required by CI (`npm ci`)
    node_modules/          # gitignored
    dist/                  # gitignored
    .env / .env.local      # gitignored — local secrets only
```

## Create a new app

```bash
npx degit github:microsoft/PowerAppsCodeApps/templates/vite CodeApps/<AppName>
cd CodeApps/<AppName>
npm install --global @microsoft/power-apps-cli
npm install --global @microsoft/power-apps
npm install
pa app init --display-name "<Display Name>" --environment-id <environment-id>
```

`pa app init` prompts you to sign in if you aren't already authenticated. Run it without options for interactive prompts.

## Local development

```bash
pa app run
```

Open the printed "Local Play" URL in the same browser profile you use for the Power Platform tenant. Chrome and Edge block requests from public origins to `localhost` by default, so you may need to allow the Local Network Access permission prompt the first time.

## Publish

Interactive (local dev machine, signed in as yourself):

```bash
npm run build
pa app push
```

By default the CLI auto-selects a solution (the environment's preferred solution on first publish, or the Default solution). To target a specific solution explicitly:

```bash
pa app push --solution-id <solution-id>
```

(`--solution-id` requires a GUID, not a solution unique name.)

## CI/CD

`azure-pipelines.yml` builds every `CodeApps/*/` folder that contains a `package.json` (`npm ci` then `npm run build`) so a broken app fails the build. If there are no apps, the step is skipped.

**Publishing is not automated** — `pa app push` is still run manually. When you're ready to automate it, the documented pattern is:

1. One-time: share the app with a service principal that has edit access — `pa app share --principal <enterprise-app-object-id> --access edit` (run once, interactively, by an app maker — never from the pipeline).
2. In the pipeline, after the build step, publish non-interactively with service-principal auth:

```powershell
$env:PA_CLI_USE_SP_AUTH = "true"
$env:PA_CLI_SP_CLIENT_ID = "<application-client-id>"
$env:PA_CLI_SP_CLIENT_SECRET = "<client-secret>"
$env:PA_CLI_SP_TENANT_ID = "<tenant-id>"
$env:PA_CLI_SOLUTION_ID = "<solution-id>"
pa app push --non-interactive
```

Decide the target environment/solution-targeting strategy (dev-only push vs. promoting through a pipeline stage) before wiring this in — see the [ALM for code apps](https://learn.microsoft.com/power-apps/developer/code-apps/how-to/alm) and [service principal](https://learn.microsoft.com/power-apps/developer/code-apps/how-to/use-service-principal) docs.
