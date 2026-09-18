# Azure bootstrap

`scripts/bootstrap-azure.sh` establishes the Azure and GitHub control plane that the existing production workflow requires. It does **not** deploy AKS, ACR, PostgreSQL, API Management, Container Apps, or CatCar workloads. It creates only resource groups, the Terraform state account/container, Microsoft Entra workload identities, RBAC assignments, and GitHub Actions configuration; it imports the existing `CatCar` foundation resource group into the Kubernetes Terraform state so Terraform remains its owner.

## Prerequisites

Run from this repository with authenticated `az`, `gh`, `terraform`, and `sha256sum`. The bootstrap operator needs permission to create resource groups and the state storage account, create Microsoft Entra applications and federated credentials, assign roles, and administer the repository environment/variables/secrets. A non-user operator must provide its Microsoft Entra object ID and principal type.

`CatCar` is the default foundation resource group. Set `FOUNDATION_RESOURCE_GROUP` only to use an explicitly different existing foundation group. When `AZURE_LOCATION` is unset, the script derives it from that group; an explicit `AZURE_LOCATION` controls resource deployment location and does not reject a reused resource group whose metadata location differs.

The existing production job runs on a self-hosted runner. It must be connected to the CatCar virtual network (or a connected network with private DNS) because the existing workflow pushes to private ACR and accesses the private Key Vault endpoint. The workflow derives `snet-private-endpoints` from the Kubernetes Terraform output and passes it to the database Terraform so the Key Vault private endpoint and `privatelink.vaultcore.azure.net` DNS link are created as part of that existing deployment workflow.

The bootstrap runner preflight queries GitHub Actions runners and emits a warning when no online runner has `self-hosted`, `linux`, and `x64` labels. It never provisions a runner.

Before applying, obtain these values from the approved secret/contact source and export them only for the command environment:

- `APIM_PUBLISHER_NAME`, `APIM_PUBLISHER_EMAIL`
- `POSTGRES_ADMIN_PASSWORD`, `POSTGRES_AUTH_READONLY_PASSWORD`
- `JWT_SECRET`, `CUSTOMER_JWT_SIGNING_KEY`

Start with the non-mutating plan:

```bash
./scripts/bootstrap-azure.sh --dry-run
```

After supplying the required environment variables, make changes explicitly:

```bash
./scripts/bootstrap-azure.sh --apply
```

For a non-user Azure login, add `--bootstrap-principal-object-id <object-id> --bootstrap-principal-type ServicePrincipal` (or the applicable `Group`/`ForeignGroup` type). The script never prints secret values.

## Resulting configuration

The script derives the production names already used by Terraform and the AppHost workflow:

- Foundation resource group: `CatCar` by default (or `FOUNDATION_RESOURCE_GROUP`); it is imported as `azurerm_resource_group.this` if absent from `catcar-kubernetes.tfstate`, preventing a duplicate-ownership failure. `AZURE_LOCATION` is derived from the existing group unless explicitly set.
- Aspire workload resource group: `rg-catcar-workloads-prod`.
- State resource group: `rg-catcar-tfstate-prod`; the globally unique storage account name is deterministically derived from the current subscription and its single `tfstate` container is used by `catcar-kubernetes.tfstate`, `catcar-database.tfstate`, and reserved `catcar-alerts.tfstate`.
- State access is Microsoft Entra-only: HTTPS/TLS 1.2, no public blob access, no shared keys, and `Storage Blob Data Contributor` only for the bootstrap operator and production deployment identity. The production workflow initializes Terraform with `use_azuread_auth=true`.

It creates or reuses two Microsoft Entra applications without client secrets:

| GitHub variable | Trust subjects | Role assignments |
| --- | --- | --- |
| Repository `AZURE_CLIENT_ID` | `main` and `pull_request` | `Reader` at the subscription for Terraform plans only |
| Production environment `AZURE_DEPLOY_CLIENT_ID` | `environment:production` | `Contributor`, `User Access Administrator`, `Azure Kubernetes Service RBAC Cluster Admin`, `AcrPush`, and `Key Vault Secrets Officer` on the configured foundation group; `Contributor` on `rg-catcar-workloads-prod`; state blob access |

The plan identity is deliberately not trusted for arbitrary manual-dispatch branches: infrastructure workflow Azure login/plan steps run only for pull requests and `main`; a manual dispatch from another ref still performs local format/validation without Azure access.

`User Access Administrator` is limited to the configured foundation resource group because the existing database Terraform creates the Key Vault `Key Vault Secrets Officer` assignment. The cluster-admin role is also foundation-group-scoped and enables the existing Azure RBAC AKS `kubelogin`, migration, Helm, and rollout commands. `AcrPush` and `Key Vault Secrets Officer` permit the existing private-registry image push and Key Vault secret synchronization. The deployment identity needs `Contributor` on the workload resource group for the AppHost-native Aspire deployment; the script does not replace that deployment with ad-hoc Azure provisioning.

The script creates the GitHub `production` environment and configures repository variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_LOCATION`, `CATCAR_FOUNDATION_RESOURCE_GROUP`, `APIM_PUBLISHER_NAME`, and `APIM_PUBLISHER_EMAIL`. Kubernetes, database, alert plan, and production deployment workflows pass `CATCAR_FOUNDATION_RESOURCE_GROUP` through `TF_VAR_resource_group_name`; Kubernetes, alert, and production workflows pass `AZURE_LOCATION` through `TF_VAR_location`. Production environment variables remain `AZURE_DEPLOY_CLIENT_ID`, `TF_BACKEND_RESOURCE_GROUP`, `TF_BACKEND_STORAGE_ACCOUNT`, `TF_BACKEND_CONTAINER`, `AZURE_LOCATION`, and `ASPIRE_WORKLOAD_RESOURCE_GROUP`; secrets are environment-scoped: `POSTGRES_ADMIN_PASSWORD`, `POSTGRES_AUTH_READONLY_PASSWORD`, `JWT_SECRET`, and `CUSTOMER_JWT_SIGNING_KEY`.

The alert workflow always performs format and Terraform validation. Its Azure plan runs only when repository variables `CATCAR_AKS_CLUSTER_ID`, `CATCAR_APPLICATION_INSIGHTS_ID`, `CATCAR_LOG_ANALYTICS_WORKSPACE_ID`, `CATCAR_HEALTH_PROBE_URL`, and `CATCAR_ALERT_EMAIL` are configured. Populate the first three from the Kubernetes Terraform outputs after foundation provisioning; set the readiness URL and operations email from approved production configuration. This prevents an invented alert target or a misleading plan.

Configure required GitHub Environment reviewers and deployment-branch protection in repository settings before enabling production deployments; reviewer identities and protection policy are intentionally not guessed by automation.
