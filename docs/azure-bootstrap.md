# Azure Control-Plane Bootstrap Runbook

`scripts/bootstrap-azure.sh` establishes the foundational Azure resources, Microsoft Entra ID (Azure AD) workload identities, RBAC role assignments, and GitHub Actions environments required by the CatCar CI/CD pipelines.

It provisions control-plane prerequisites for **both Homologation (`develop`) and Production (`main`)** environments across all four segregated repositories (`catcar-app`, `catcar-auth-function`, `catcar-database-infra`, `catcar-kubernetes-infra`, plus `catcar-platform`). It does **not** deploy application workloads, clusters, databases, or API gateways directly; those are managed by Terraform and Aspire in the CI/CD pipelines.

---

## 1. Prerequisites

Before running the bootstrap script, ensure the operator environment has:

1. **CLI Tools Installed & Authenticated**:
   - `az` (Azure CLI): Authenticated to the target Azure subscription (`az login`).
   - `gh` (GitHub CLI): Authenticated with permissions to manage variables, secrets, environments, and branch protection across the target repositories (`gh auth login`).
   - `terraform` (`>= 1.5.0`): Used for foundation state validation and import.
   - `sha256sum`: Standard utility to compute deterministic subscription hashes for storage account naming.
2. **Operator Permissions**:
   - Azure: `Owner` or `User Access Administrator` + `Contributor` on the subscription (required to create resource groups, storage accounts, and assign RBAC roles).
   - Microsoft Entra ID: Permission to register applications and configure federated identity credentials (`Application Administrator` or `Cloud Application Administrator`).
   - GitHub: Administrator access on the target repositories in the organization (`RiseOn-CatCar`).
3. **Operator Identity**:
   - By default, the script detects the signed-in Entra user ID (`az ad signed-in-user show`).
   - For automation or service principal execution, pass `--bootstrap-principal-object-id <id> --bootstrap-principal-type ServicePrincipal`.

---

## 2. Execution Flags & Syntax

```bash
scripts/bootstrap-azure.sh [--dry-run | --apply] [--environment homologation|production|all]
                           [--env-file PATH] [--skip-branch-protection]
                           [--bootstrap-principal-object-id OBJECT_ID] [--bootstrap-principal-type TYPE]
```

### CLI Parameters:

| Flag | Shorthand | Default | Description |
|---|---|---|---|
| `--dry-run` | `-` | *Default* | Simulates actions, displays planned configurations and federated credentials without mutating Azure or GitHub. |
| `--apply` | `-` | | Applies resource creation, federated credential generation, GitHub secret/variable injection, and branch protection. |
| `--environment` | `-e` | `all` | Target environment to configure: `homologation`, `production`, or `all`. |
| `--env-file` | `-f` | `.env` (if present) | Path to local environment file containing variables and secrets. |
| `--skip-branch-protection` | `-` | `false` | Skips applying branch protection rules on `main` and `develop`. |
| `--bootstrap-principal-object-id` | `-` | *Signed-in user* | Microsoft Entra Object ID of the operator running the script to grant state storage access. |
| `--bootstrap-principal-type` | `-` | `User` | Principal type: `User`, `ServicePrincipal`, `Group`, or `ForeignGroup`. |
| `--help` | `-h` | | Displays the usage menu and required environment variables. |

---

## 3. Configuration & Secrets Management (.env & Auto-Generation)

The bootstrap script supports multiple convenient ways to provide required configuration:
1. **Automatic Secret Generation (Recommended for initial setup)**: If database passwords or JWT signing keys are omitted, the script automatically generates cryptographically secure passwords (meeting Azure PostgreSQL complexity rules) and 256-bit hex keys, persisting them to your local `.env` file with permissions `0600`.
2. **Environment File (`.env`)**: You can create a local `.env` file from the provided [`.env-sample`](../.env-sample) template (`cp .env-sample .env`). The `.env` file is excluded from Git via `.gitignore`.
3. **Shell Environment Variables**: You can export variables directly in your terminal session before execution.

### Sample Configuration Template (`.env-sample`):
```bash
# Copy template:
cp .env-sample .env

# Edit APIM publisher metadata and optional overrides:
# APIM_PUBLISHER_NAME="CatCar Operations"
# APIM_PUBLISHER_EMAIL="operations@catcar.com"
```

### Core Variables:
```bash
APIM_PUBLISHER_NAME="CatCar Workshop Operations"
APIM_PUBLISHER_EMAIL="operations@catcar.com"
POSTGRES_ADMIN_PASSWORD=""          # Leave empty to auto-generate (min 12 chars)
POSTGRES_AUTH_READONLY_PASSWORD="" # Leave empty to auto-generate (min 12 chars)
JWT_SECRET=""                      # Leave empty to auto-generate 256-bit key (min 32 chars)
CUSTOMER_JWT_SIGNING_KEY=""        # Leave empty to auto-generate 256-bit key (min 32 chars)
```
If distinct credentials are used between Homologation and Production, provide environment-specific overrides:
```bash
# Homologation overrides:
export POSTGRES_ADMIN_PASSWORD_HOMOLOG="HomologAdminPassword123!"
export POSTGRES_AUTH_READONLY_PASSWORD_HOMOLOG="HomologReadonlyPassword123!"
export JWT_SECRET_HOMOLOG="HomologJwtSecretKeyHere32CharactersMin!"
export CUSTOMER_JWT_SIGNING_KEY_HOMOLOG="HomologCustomerJwtSigningKeyHere32Min!"
export FOUNDATION_RESOURCE_GROUP_HOMOLOG="rg-catcar-homolog"

# Production overrides:
export POSTGRES_ADMIN_PASSWORD_PROD="ProdAdminPassword123!"
export POSTGRES_AUTH_READONLY_PASSWORD_PROD="ProdReadonlyPassword123!"
export JWT_SECRET_PROD="ProdJwtSecretKeyHere32CharactersMin!"
export CUSTOMER_JWT_SIGNING_KEY_PROD="ProdCustomerJwtSigningKeyHere32Min!"
export FOUNDATION_RESOURCE_GROUP_PROD="CatCar"

# Target repositories (defaults to all 4 submodules):
# export REPOSITORIES="catcar-app catcar-auth-function catcar-database-infra catcar-kubernetes-infra"
```

---

## 4. Resulting Infrastructure & Architecture Topology

For each targeted environment, `bootstrap-azure.sh` provisions and binds the following cloud components:

### 4.1 Resource Groups & Storage Backends

```
+-------------------------------------------------------------------------------------------------------+
|                                    Azure Subscription & Tenant                                        |
+---------------------------------------------------+---------------------------------------------------+
|               HOMOLOGATION (homolog)              |                PRODUCTION (prod)                  |
+---------------------------------------------------+---------------------------------------------------+
| Foundation RG:  rg-catcar-homolog                 | Foundation RG:  CatCar                            |
| Workloads RG:   rg-catcar-workloads-homolog       | Workloads RG:   rg-catcar-workloads-prod          |
| State RG:       rg-catcar-tfstate-homolog         | State RG:       rg-catcar-tfstate-prod            |
| Storage Account:stcatcarhomolog<hash:0:8>         | Storage Account:stcatcarprod<hash:0:8>            |
| Blob Container: tfstate (private, Entra-only)     | Blob Container: tfstate (private, Entra-only)     |
+---------------------------------------------------+---------------------------------------------------+
```

* **State Security**: Storage accounts enforce HTTPS-only (TLS 1.2+), disabled public blob access, disabled shared keys, and Entra ID RBAC authorization (`use_azuread_auth=true`).

---

### 4.2 Microsoft Entra ID Workload Identity & Federated Credentials (OIDC)

The script establishes passwordless, keyless OpenID Connect (OIDC) integration between GitHub Actions and Microsoft Entra ID:

| App Registration | Roles & Scopes | Federated Credentials (Subjects) Configured |
|---|---|---|
| **`catcar-github-terraform-plan`** (Shared Plan Identity) | `Reader` on `/subscriptions/<id>`<br>`Storage Blob Data Contributor` on state storage accounts | For each repository (`catcar-app`, `catcar-auth-function`, `catcar-database-infra`, `catcar-kubernetes-infra`):<br>• `repo:<org>/<repo>:pull_request`<br>• `repo:<org>/<repo>:ref:refs/heads/main`<br>• `repo:<org>/<repo>:ref:refs/heads/develop` |
| **`catcar-github-homolog-deploy`** (Homologation Deploy) | `Contributor` on `rg-catcar-homolog`<br>`User Access Administrator` on `rg-catcar-homolog`<br>`AKS RBAC Cluster Admin` on `rg-catcar-homolog`<br>`Contributor` on `rg-catcar-workloads-homolog`<br>`AcrPush` on `rg-catcar-homolog`<br>`Key Vault Secrets Officer` on `rg-catcar-homolog`<br>`Storage Blob Data Contributor` on homolog state | For each repository:<br>• `repo:<org>/<repo>:environment:homologation`<br>• `repo:<org>/<repo>:ref:refs/heads/develop` |
| **`catcar-github-production-deploy`** (Production Deploy) | `Contributor` on `CatCar`<br>`User Access Administrator` on `CatCar`<br>`AKS RBAC Cluster Admin` on `CatCar`<br>`Contributor` on `rg-catcar-workloads-prod`<br>`AcrPush` on `CatCar`<br>`Key Vault Secrets Officer` on `CatCar`<br>`Storage Blob Data Contributor` on prod state | For each repository:<br>• `repo:<org>/<repo>:environment:production`<br>• `repo:<org>/<repo>:ref:refs/heads/main` |

---

### 4.3 Multi-Repository GitHub Configurations

The script iterates through all target repositories and populates variables, secrets, and branch policies:

#### 1. Repository-Level Variables:
* `AZURE_CLIENT_ID`: Application ID for `catcar-github-terraform-plan`.
* `AZURE_TENANT_ID`: Microsoft Entra tenant ID.
* `AZURE_SUBSCRIPTION_ID`: Azure subscription ID.
* `AZURE_LOCATION`: Azure deployment region (e.g. `brazilsouth`).
* `CATCAR_FOUNDATION_RESOURCE_GROUP`: Default foundation resource group name (`CatCar` or `rg-catcar-homolog`).
* `APIM_PUBLISHER_NAME`: Organization name for API Management.
* `APIM_PUBLISHER_EMAIL`: Operations contact email.
* `AZURE_TF_STATE_RG`: Default state backend resource group.
* `AZURE_TF_STATE_STORAGE_ACCOUNT`: Default state storage account name.

#### 2. Automated Branch Protection Rules (`main` and `develop`):
Unless `--skip-branch-protection` is specified, the script automatically configures branch protection via GitHub REST API (`PUT /repos/{owner}/{repo}/branches/{branch}/protection`):
* **Required Pull Request Reviews**: At least 1 approving review required before merge.
* **Dismiss Stale Approvals**: New commits dismiss previous approvals.
* **Direct Pushes Prohibited**: All changes must merge through Pull Requests.
* **Force Pushes Prohibited**: `allow_force_pushes = false`.
* **Branch Deletion Prohibited**: `allow_deletions = false`.

#### 3. Environment-Scoped Configurations (`homologation` & `production`):
* **Environment Variables**:
  * `AZURE_DEPLOY_CLIENT_ID`: Dedicated deploy application ID (`catcar-github-homolog-deploy` or `catcar-github-production-deploy`).
  * `CATCAR_FOUNDATION_RESOURCE_GROUP`: `rg-catcar-homolog` or `CatCar`.
  * `ASPIRE_WORKLOAD_RESOURCE_GROUP`: `rg-catcar-workloads-homolog` or `rg-catcar-workloads-prod`.
  * `TF_BACKEND_RESOURCE_GROUP`: State resource group.
  * `TF_BACKEND_STORAGE_ACCOUNT`: State storage account name.
  * `TF_BACKEND_CONTAINER`: `tfstate`.
  * `AZURE_TF_STATE_RG`: State resource group for Terraform init.
  * `AZURE_TF_STATE_STORAGE_ACCOUNT`: State storage account name for Terraform init.
  * `AZURE_LOCATION`: Azure region.
  * `APIM_PUBLISHER_NAME` & `APIM_PUBLISHER_EMAIL`.
  * `CATCAR_AKS_CLUSTER_NAME`: `aks-catcar-homolog` or `aks-catcar-prod`.
  * `ACR_NAME`: `crccarhomolog` or `crccarprod`.
  * `KEY_VAULT_NAME`: `kv-catcar-homolog` or `kv-catcar-prod`.
  * `CATCAR_LOG_ANALYTICS_WORKSPACE_NAME`: `log-catcar-homolog` or `log-catcar-prod`.
  * `CATCAR_APPLICATION_INSIGHTS_NAME`: `appi-catcar-homolog` or `appi-catcar-prod`.
* **Environment Secrets**:
  * `POSTGRES_ADMIN_PASSWORD`
  * `POSTGRES_AUTH_READONLY_PASSWORD`
  * `JWT_SECRET`
  * `CUSTOMER_JWT_SIGNING_KEY`

---

## 5. Step-by-Step Execution Examples

### Scenario A: Dry-run preview of both environments
```bash
./scripts/bootstrap-azure.sh --dry-run
```
Outputs the planned resources, storage accounts, Entra applications, federated credential subjects, GitHub variables, and branch protection rules without making changes.

### Scenario B: Provision Homologation only
```bash
export APIM_PUBLISHER_NAME="CatCar Operations"
export APIM_PUBLISHER_EMAIL="ops@catcar.com"
export POSTGRES_ADMIN_PASSWORD="HomologPassword123!"
export POSTGRES_AUTH_READONLY_PASSWORD="HomologReadonly123!"
export JWT_SECRET="HomologSecretKey32CharsMinRequirement!"
export CUSTOMER_JWT_SIGNING_KEY="HomologCustomerSigningKey32CharsMin!"

./scripts/bootstrap-azure.sh --apply --environment homologation
```

### Scenario C: Provision Production only
```bash
export APIM_PUBLISHER_NAME="CatCar Operations"
export APIM_PUBLISHER_EMAIL="ops@catcar.com"
export POSTGRES_ADMIN_PASSWORD="ProductionSecurePassword123!"
export POSTGRES_AUTH_READONLY_PASSWORD="ProductionReadonly123!"
export JWT_SECRET="ProductionSecretKey32CharsMinRequirement!"
export CUSTOMER_JWT_SIGNING_KEY="ProductionCustomerSigningKey32CharsMin!"

./scripts/bootstrap-azure.sh --apply --environment production
```

### Scenario D: Provision both Homologation and Production in one pass
```bash
export APIM_PUBLISHER_NAME="CatCar Operations"
export APIM_PUBLISHER_EMAIL="ops@catcar.com"
export POSTGRES_ADMIN_PASSWORD="DefaultSecurePassword123!"
export POSTGRES_AUTH_READONLY_PASSWORD="DefaultReadonly123!"
export JWT_SECRET="DefaultSecretKey32CharsMinRequirement!"
export CUSTOMER_JWT_SIGNING_KEY="DefaultCustomerSigningKey32CharsMin!"

./scripts/bootstrap-azure.sh --apply --environment all
```

---

## 6. Post-Bootstrap Governance Checklist

After running `--apply`:

1. **Branch Protection Rules (Configured Automatically)**:
   - Verified that `main` and `develop` require Pull Request review with at least 1 approval.
   - Verified that direct pushes to `main` and `develop` are blocked.
2. **GitHub Environment Reviewers**:
   - In GitHub repository settings (`Settings -> Environments -> production`), configure:
     - **Required reviewers**: Add designated leads to approve production deployments before rollout.
     - **Deployment branches**: Ensure restricted to `refs/heads/main`.
   - In `Settings -> Environments -> homologation`:
     - **Deployment branches**: Ensure restricted to `refs/heads/develop`.
3. **Trigger Pipelines**:
   - Pushing to `develop` executes automatic deployment to Homologation.
   - Merging a PR into `main` executes automatic deployment to Production.
