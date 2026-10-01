# AI Agent Setup

How AI coding agents are configured in solution repos created from this template, and how to connect them to Dataverse and your work tracker. The examples use Claude Code. Other agents read the same `AGENTS.md` and need equivalent MCP configuration in their own format.

## What the template provides

| File | Committed | Purpose |
|---|---|---|
| `AGENTS.md` | yes | Project instructions: build commands, constraints, plugin patterns, naming conventions. Claude Code, Codex, GitHub Copilot and Cursor all read it. |
| `.claude/settings.json` | yes | Shared Claude Code permissions. It allows build, test and read-only git commands, and **denies** `git push`, `--force`, `git reset --hard`, `git clean`, and anything mentioning passwords, secrets, tokens or connection strings. Developers push themselves. |
| `.claude/settings.local.json.example` | yes | Template for each developer's local secrets and MCP approvals |
| `.claude/settings.local.json` | **no** (gitignored) | Your copy of the example, with real values |
| `.mcp.json` | yes | Project-scoped MCP servers: `dataverse-dev`, plus `azure-devops` for projects hosted in Azure DevOps |

Keep `AGENTS.md` current. When a convention changes, update it in the same PR.

## First-time setup in a project

1. Copy `.claude/settings.local.json.example` to `.claude/settings.local.json`.
2. Fill in the `env` values:
   - `DATAVERSE_DEV_URL`: your sandbox URL, e.g. `https://myorg.crm.dynamics.com`
   - `AZURE_DEVOPS_PAT`: only if the project uses the `azure-devops` server. Use a PAT with the narrowest scopes you need.
3. Start Claude Code in the repo and approve the project's MCP servers when prompted. Approvals are stored in `settings.local.json` under `enabledMcpjsonServers`.
4. Check with `claude mcp list`, or `/mcp` inside Claude Code.

Claude Code adds the `env` block from `settings.local.json` to its environment, and MCP servers inherit it. `.mcp.json` can also reference variables directly with `${VAR}` or `${VAR:-default}` in `command`, `args`, `env`, `url` and `headers`. **Never put secrets in `.mcp.json`**, because it's committed.

If the project isn't hosted in Azure DevOps, delete the `azure-devops` entry from `.mcp.json`, and from `enabledMcpjsonServers` in the example file. Add an MCP server for your actual host or tracker if you want one.

## Project scope or user scope?

| Server | Put it in | Why |
|---|---|---|
| The client's Dataverse dev environment | `.mcp.json` (project) | Specific to this project |
| The client's work tracker / repo host | `.mcp.json` (project) | Specific to this project |
| PAC CLI MCP | User scope (`~/.claude.json`) | Useful in every project |
| Personal or internal environments and orgs | User scope | Not shared with the client team |

Add user-scope servers with `claude mcp add --scope user ...`, which writes to `~/.claude.json`. MCP servers don't belong in `~/.claude/settings.json`. To turn off a user-scope server for one project, use `/mcp` inside Claude Code.

## Connecting to Dataverse

> Connect only to environments appropriate for the work: normally your own dev sandbox. Don't connect an agent to production without explicit approval. You need at least the **System Customizer** role in the environment.

### Option A: `@microsoft/dataverse` (the template's `dataverse-dev` server)

This uses Microsoft's Dataverse MCP endpoint with an interactive browser sign-in. No secret is stored. It needs two **one-time admin steps** first:

1. **Tenant admin consent** (once per tenant). A tenant admin opens the following link and accepts the permissions prompt:
   ```
   https://login.microsoftonline.com/{tenant-id}/adminconsent?client_id=0c412cc3-0dd6-449b-987f-05b053db9457
   ```
   This consents to the **Dataverse CLI** app.
2. **Enable the client** (once per environment). In the Power Platform admin center:
   1. Go to **Environments**, select the environment, then **Settings > Product > Features**.
   2. Under **Dataverse Model Context Protocol**, open **Advanced Settings**.
   3. Set the **Dataverse CLI** client (app ID `0c412cc3-0dd6-449b-987f-05b053db9457`) to **Is Enabled = Yes**. If it isn't listed, add it with that app ID.

   The setting only exists on **Managed Environments**.

After that, set `DATAVERSE_DEV_URL` (see above) and restart Claude Code. The first use opens a browser sign-in, which is cached afterwards.

### Option B: PAC CLI MCP server (user scope)

This uses your `pac` auth profile, with no admin consent needed.

```powershell
pac auth create --environment https://<env>.crm.dynamics.com --name dev
pac org who                      # confirm the right environment
claude mcp add --scope user pac-cli -- pac copilot mcp --run
```

Restart Claude Code, then ask *"What tables are in the current Dataverse environment?"* to confirm it works.

If `pac copilot mcp` errors, your `pac` is an older MSI install. Point the server at the dotnet tool (`C:/Users/<you>/.dotnet/tools/pac`) instead, or run it through `dnx Microsoft.PowerApps.CLI.Tool --yes copilot mcp --run`.

### Reconnecting

PAC tokens expire after inactivity. If Dataverse calls start failing:

```powershell
pac auth list                     # profile exists and is selected?
pac auth refresh --name dev       # refresh the token
# if that fails:
pac auth clear --name dev
pac auth create --environment https://<env>.crm.dynamics.com --name dev
```

Restart Claude Code afterwards. The MCP registration persists.

## Windows gotchas

- **`npx` needs `cmd /c`.** On Windows, stdio servers launched through `npx` need `"command": "cmd", "args": ["/c", "npx", ...]`, as in the template's `.mcp.json`.
- **Git Bash mangles `/c`.** Running `claude mcp add ... -- cmd /c npx ...` from Git Bash saves `C:/` instead of `/c`. Run it from PowerShell, or fix the args in `~/.claude.json` afterwards.
- **Duplicate servers shadow each other.** If a project server and a user server use the same package (e.g. two `azure-devops-mcp` instances for different orgs), only the project server's tools are exposed. Reach the other org through its CLI instead.

## Troubleshooting

| Symptom | Fix |
|---|---|
| A server shows as pending | Approve it when prompted, or add it to `enabledMcpjsonServers` in `.claude/settings.local.json` |
| A server isn't listed | `claude mcp list`. Check that the server's JSON is valid, then restart Claude Code. |
| 401/403 from Dataverse | Check your role in the environment (System Customizer or higher) and, for option A, both admin steps |
| `pac org who` shows the wrong environment | `pac auth select --name <profile>`, or recreate the profile |
| The browser doesn't open during `pac auth create` | Add `--tenant <tenant-id>` |
