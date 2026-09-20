# Azure Control-Plane Bootstrap Runbook

`scripts/bootstrap-azure.sh` establishes the foundational Azure resources, Microsoft Entra ID (Azure AD) workload identities, RBAC role assignments, and GitHub Actions environment required by the CatCar CI/CD pipelines under the **academic cloud consolidation model**.

It provisions control-plane prerequisites for the **single Production environment (`main` / `catcar-prod`)** across all four segregated repositories (`catcar-app`, `catcar-auth-function`, `catcar-database-infra`, `catcar-kubernetes-infra`, plus `catcar-platform`). Local pre-production (homologation) is served entirely by the .NET Aspire AppHost (`make dev`).

---

## 1. Prerequisites

Before running the bootstrap script, ensure the operator environment has:

1. **CLI Tools Installed & Authenticated**:
   - `az` (Azure CLI): Authenticated to the target Azure subscription (`az login`).
   - `gh` (GitHub CLI): Authenticated with permissions to manage variables, secrets, environment, and branch protection across the target repositories (`gh auth login`).
   - `terraform` (`>= 1.5.0`): Used for foundation state validation and import.
   - `sha256sum`: Standard utility to compute deterministic subscription hashes for resource naming.
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
scripts/bootstrap-azure.sh [--dry-run | --apply]
                           [--env-file PATH] [--skip-branch-protection]
                           [--bootstrap-principal-object-id OBJECT_ID] [--bootstrap-principal-type TYPE]
```

### CLI Parameters:

| Flag | Shorthand | Default | Description |
|---|---|---|---|
| `--dry-run` | `-` | *Default* | Simulates actions, displays planned configurations and federated credentials without mutating Azure or GitHub. |
| `--apply` | `-` | | Applies resource creation, federated credential generation, GitHub secret/variable injection, and branch protection. |
| `--env-file` | `-f` | `.env` (if present) | Path to local environment file containing variables and secrets. |
| `--skip-branch-protection` | `-` | `false` | Skips applying branch protection rules on `main`. |
| `--bootstrap-principal-object-id` | `-` | *Signed-in user* | Microsoft Entra Object ID of the operator running the script to grant state storage access. |
| `--bootstrap-principal-type` | `-` | `User` | Principal type: `User`, `ServicePrincipal`, `Group`, or `ForeignGroup`. |
| `--help` | `-h` | | Displays the usage menu and required environment variables. |

---

## 3. Configuration & Secrets Management (.env & Auto-Generation)

The bootstrap script supports multiple convenient ways to provide required configuration:
1. **Automatic Secret Generation**: If database passwords, JWT signing keys, or the Gateway Backend Key are omitted, the script automatically generates cryptographically secure passwords (meeting Azure PostgreSQL complexity rules) and 256-bit hex keys, persisting them to your local `.env` file with permissions `0600`.
2. **Environment File (`.env`)**: You can create a local `.env` file from the provided [`.env-sample`](../.env-sample) template (`cp .env-sample .env`).
3. **Shell Environment Variables**: You can export variables directly in your terminal session before execution.

### Core Variables:
```bash
APIM_PUBLISHER_NAME="CatCar Operations"
APIM_PUBLISHER_EMAIL="operations@catcar.com"
POSTGRES_ADMIN_PASSWORD=""          # Leave empty to auto-generate (min 12 chars)
POSTGRES_AUTH_READONLY_PASSWORD="" # Leave empty to auto-generate (min 12 chars)
JWT_SECRET=""                      # Leave empty to auto-generate 256-bit key (min 32 chars)
CUSTOMER_JWT_SIGNING_KEY=""        # Leave empty to auto-generate 256-bit key (min 32 chars)
GATEWAY_BACKEND_KEY=""             # Leave empty to auto-generate 256-bit key (min 32 chars)
```

---

## 4. Resulting Infrastructure & Architecture Topology

Under the academic consolidation model, `bootstrap-azure.sh` provisions and binds the following control-plane components:

### 4.1 Resource Groups & Storage Backends

```
+-------------------------------------------------------------------------------------------------------+
|                                    Azure Subscription & Tenant                                        |
+-------------------------------------------------------------------------------------------------------+
|                                        PRODUCTION (prod)                                              |
+-------------------------------------------------------------------------------------------------------+
| Resource Group: catcar-prod                                                                          |
| State Resource Group: catcar-tfstate                                                                  |
| Storage Account: stcatcartf<sub_suffix>                                                               |
| State Container: tfstate (private, Entra-only, TLS 1.2+)                                              |
+-------------------------------------------------------------------------------------------------------+
```

* **State Isolation**: Storage account `stcatcartf<sub_suffix>` lives in `catcar-tfstate`, outside `catcar-prod`, ensuring that teardown or re-creation of production workloads never deletes state storage.
* **Canonical Naming**:
  - ACR: `catcarprod<sub_suffix>` (Basic SKU)
  - Key Vault: `kv-catcar-prod-<sub_suffix>` (Standard SKU)
  - APIM: `apim-catcar-prod-<sub_suffix>` (Consumption SKU)
  - Auth Function: `func-catcar-prod-<sub_suffix>` (Flex Consumption FC1)
  - API Public IP DNS: `catcar-api-prod-<sub_suffix>`
  - AKS Cluster: `aks-catcar-prod` (Free SKU, Standard_B2s, 1-2 nodes)
  - PostgreSQL: `psql-catcar-prod` (B_Standard_B1ms, 32 GiB, private VNet)

---

### 4.2 Microsoft Entra ID Workload Identities & OIDC Federated Credentials

`bootstrap-azure.sh` sets up two dedicated Entra ID Workload Identities:

1. **Shared Plan Identity (`catcar-github-terraform-plan`)**:
   - **Role Assignments**: `Reader` on Subscription level, `Storage Blob Data Contributor` on `catcar-tfstate`.
   - **Federated Credentials**:
     - `gh-<repo_slug>-pr`: `repo:<owner>/<repo>:pull_request`
     - `gh-<repo_slug>-main`: `repo:<owner>/<repo>:ref:refs/heads/main`
2. **Production Deploy Identity (`catcar-github-production-deploy`)**:
   - **Role Assignments**: `Contributor`, `User Access Administrator`, `Azure Kubernetes Service RBAC Cluster Admin`, `AcrPush`, and `Key Vault Secrets Officer` on `catcar-prod`; `Storage Blob Data Contributor` on `catcar-tfstate`.
   - **Federated Credentials**:
     - `gh-<repo_slug>-prod-env`: `repo:<owner>/<repo>:environment:production`

---

## 5. Security & Public/Private Endpoint Trade-Offs

To operate strictly within a **USD 100 total Azure student credit**:
- **PostgreSQL Flexible Server** remains private inside `snet-postgresql` (`10.20.2.0/24`) with `public_network_access_enabled = false` and private DNS `private.postgres.database.azure.com`.
- **Key Vault, ACR, and API Ingress** use public service endpoints + Entra ID OIDC / RBAC / Gateway Key authentication because student budget constraints reject Premium/private-endpoint SKUs.
- **Gateway Key Protection**: APIM injects `X-CatCar-Gateway-Key` on all backend calls. Origin workloads (API and Auth Function) return 403 Forbidden in Production for any POST request missing or carrying an invalid key. Health probes and static GET pages are exempt.
- **Cold-by-Default Infrastructure**: Compute resources (AKS and PostgreSQL) are stopped nightly at 02:00 UTC via `.github/workflows/cloud-runtime.yml` and started on demand via `workflow_dispatch` or deployment workflows.

---

## 6. Dated Pricing Basis (Azure Retail Prices API)

*Pricing query date: September 2026 (East US)*:
- **AKS (Free Tier)**: USD 0.00/month cluster management fee. Node compute: 1–2 x `Standard_B2s` (Linux) @ USD 0.0416/hour.
- **PostgreSQL Flexible Server (`B_Standard_B1ms`)**: USD 0.017/hour + 32 GiB storage @ USD 0.115/GB/month (~USD 16.00/month if 24/7; < USD 4.00/month with scheduled suspension).
- **ACR (Basic SKU)**: USD 0.1666/day (~USD 5.00/month).
- **APIM (Consumption SKU)**: USD 0.00 for first 1,000,000 requests/month.
- **Azure Function (Flex Consumption FC1)**: USD 0.00 for first 250,000 GB-s execution/month (scales to zero).
- **Scheduled Suspension**: Nightly stop via `cloud-runtime.yml` preserves the USD 100 student credit for academic evaluation.
