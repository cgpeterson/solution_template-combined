# Environment and Service Principal Setup

Per-project setup of the Power Platform environments a solution moves through, and the service principal that automated deployments use.

## Environment strategy

| Environment | Type | Purpose |
|---|---|---|
| Developer sandboxes | Sandbox (or Developer) | One per developer. `Import.ps1`/`Export.ps1` target these. They can be reset freely. |
| Integration / Test | Sandbox | Managed builds from `main`, to check that changes deploy together cleanly |
| UAT | Sandbox | Versioned builds from `release/*`, for client acceptance |
| Production | Production | Managed releases only. Never customized directly. |

Guidelines:

- Use **unmanaged** solutions only in developer sandboxes. Every other environment gets **managed** solutions from a CI build.
- Use a consistent naming convention, e.g. `<client>-<solution>-dev-<initials>`, `<client>-<solution>-uat`.
- Restrict environment creation to admins in the Power Platform admin center.
- Consider making the environments **Managed Environments**. Some features need it, including the Dataverse MCP server used by AI agents (see [AI Agent Setup](AI-Agent-Setup.md)).
- Set up data loss prevention (DLP) policies for connectors before makers start building flows.

## Create an environment

1. Open the Power Platform admin center:
   - Commercial: https://admin.powerplatform.microsoft.com/
   - GCC: https://gcc.admin.powerplatform.microsoft.us/
2. Go to **Environments > + New**.
3. Fill in the name, region, type (Sandbox or Production) and purpose, and choose **Add a Dataverse data store: Yes**.
4. Save, and wait for provisioning to finish.

For a developer sandbox, give the developer the **System Customizer** role (or System Administrator) so the DevOps scripts and agents can import and export.

## Service principal for deployments

Automated deployments sign in as an app registration, not as a person.

### 1. Register the app

1. In the Azure portal, go to **Microsoft Entra ID > App registrations > New registration**.
2. Name it after the client and solution, e.g. `Contoso.Claims.Deployment`.
3. Supported account types: **Single tenant**. Only choose multitenant if one registration really must deploy into several tenants.
4. Leave the redirect URI empty; client-credential sign-in doesn't use one.
5. Record the **Application (client) ID** and **Directory (tenant) ID**.

### 2. Give it a credential

Use the strongest option your CI system supports:

1. **Workload identity federation** (federated credentials): no secret to store or rotate. Supported by Azure DevOps service connections and GitHub Actions OIDC.
2. **Certificate**.
3. **Client secret**: if you use one, set an expiry, record the date, and plan the rotation.

Store credentials only in the CI system's secret store (an Azure DevOps service connection or secret variable, GitHub Actions secrets, Azure Key Vault). Never in the repo, and never in a connection file.

### 3. Add it as an application user in each target environment

Do this for every environment the pipeline deploys to (Test, UAT, Production):

1. In the Power Platform admin center, go to **Environments**, select the environment, then **Settings > Users + permissions > Application users**.
2. Click **+ New app user** and add the app registration.
3. Choose the business unit and assign a security role. Solution import normally needs **System Administrator**; scope it down where your deployment allows.
4. Click **Create**.

### 4. Use it from a pipeline

Any CI system can authenticate the Power Platform CLI as the service principal:

```powershell
pac auth create --name deploy --environment https://<env>.crm.dynamics.com `
    --applicationId $env:PP_CLIENT_ID --clientSecret $env:PP_CLIENT_SECRET --tenant $env:PP_TENANT_ID
pac solution import --path <solution>_managed.zip --publish-changes
```

The template's `azure-pipelines.yml` only **builds** the managed deployment package and publishes it as a build artifact. Deployment stages (Test, UAT, Production, with approval gates) are set up per project in your CI system, using this service principal.

Code apps publish with their own service-principal flow. See the CI/CD section of `CodeApps/README.md` in the project.
