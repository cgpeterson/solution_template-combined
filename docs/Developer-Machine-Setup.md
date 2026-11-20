# Developer Machine Setup

One-time setup for a developer workstation, needed before working on any solution repo created from this template. Each project then needs its own connection file (step 7).

This is per-**developer** setup. For per-**project** setup, see [New Project Setup](New-Project-Setup.md).

## 1. Install Visual Studio 2022

1. Download Visual Studio 2022 (Professional or higher) from https://visualstudio.microsoft.com/.
2. In the installer, select these workloads:
   - **.NET desktop development**: plugin and unit test projects
   - **ASP.NET and web development**: the `WebResources` project is a web application project
3. Under **Individual components**, confirm **.NET Framework 4.8 targeting pack** is selected.

## 2. Install the .NET Framework 4.8 Developer Pack

All projects target .NET Framework 4.8, because Dataverse plugins run on .NET Framework, not .NET Core/5+. Install the **Developer Pack** from https://dotnet.microsoft.com/download/dotnet-framework/net48 if Visual Studio didn't already install it.

## 3. Install command-line tools

| Tool | Why | Install |
|---|---|---|
| Git | Source control | `winget install Git.Git` |
| .NET SDK (8 or later) | Required to install the Power Platform CLI as a dotnet tool | `winget install Microsoft.DotNet.SDK.8` |
| nuget.exe | Command-line restore (legacy `.csproj` files can't use `dotnet restore`) | `winget install Microsoft.NuGet` |
| Node.js LTS | `WebResources` build tooling and Power Apps code apps | `winget install OpenJS.NodeJS.LTS` |

Visual Studio restores NuGet packages on build, so nuget.exe is only needed for command-line builds.

JMCL packages come from public **nuget.org**, so there is no private feed or credential provider to configure.

## 4. Install the Open Command Line extension (optional)

The Visual Studio solution has a `DevOps` solution folder that surfaces `Import.ps1` and `Export.ps1`. With the **Open Command Line** extension installed, you can right-click a script and choose **Execute File** to run it from Visual Studio.

1. In Visual Studio, open **Extensions > Manage Extensions**.
2. Search for **Open Command Line** and click **Install**.
3. Close Visual Studio to finish installing it.

## 5. Allow PowerShell scripts to run

Windows blocks scripts by default. Allow locally created and cloned scripts for your user. This doesn't need administrator rights:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

If a script still fails with a digital-signature error, allow scripts for the current session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## 6. Install the DevOps script dependencies

Clone the project repo, then from its `DeploymentPackage\DevOps\` folder run:

```powershell
.\Install_PowerShell_Dependencies.ps1
```

It installs, for the current user only (no administrator rights needed):

- **Az.Accounts**, used by `Import-DocumentTemplates.ps1` and `Upload-StagedPortalChanges.ps1`
- **Power Platform CLI (`pac`)**, as a dotnet tool, used for solution export/import/pack, data import/export and `-ResetEnvironment`

Both are pinned to tested versions at the top of the script. It also creates your sandbox connection file (next step) if you don't have one yet.

Open a new terminal (or restart Visual Studio) afterwards so `pac` is on your `PATH`, then check it with `pac --version`.

## 7. Fill in your sandbox connection file

Each developer works against their own Dataverse sandbox environment. The connection file lives **outside the repo** and is never committed. It holds no password: everything signs in through MSAL with a browser sign-in, and the token is cached after the first run.

1. `Install_PowerShell_Dependencies.ps1` already created `C:\CrmConnection\MyCdsSandboxConnection.ps1` from `DeploymentPackage\DevOps\CdsConnectionParameters\MyCdsSandboxConnection-Template.ps1`. `Import.ps1` and `Export.ps1` look for the file at this exact path.
2. Edit it:
   - Set `$orgName` to your sandbox's environment name, the part before `.crm*.dynamics.com`.
   - Check the domain suffix in `$environmentUrl` against **Settings > Session details** in the maker portal. Commercial North America is `crm.dynamics.com` and GCC is `crm9.dynamics.com`; GCC High and DoD use different domains.
   - Optionally set `TenantId` to pin the document-template sign-in to one tenant.
   - Leave `AllowTestData = $true`, it lets `Import.ps1` load test data into your sandbox. Connection files for Prod never set it.

## 8. Verify your setup

1. Open the project's `.sln` in Visual Studio and build the **DeploymentPackage** project. The build packs the solution locally, with no environment connection.
2. From `DeploymentPackage\DevOps\`, run:
   ```powershell
   .\Import.ps1
   ```
3. Complete the browser sign-in when prompted.

A successful run confirms your tools, connection file and environment access are set up. Next, see [Daily Dev Workflow](Daily-Dev-Workflow.md). To use an AI coding agent on the project, see [AI Agent Setup](AI-Agent-Setup.md).
