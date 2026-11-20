# Azure control-plane bootstrap

`scripts/bootstrap-azure.sh` prepares the single Azure release environment; it does not deploy workloads. It only configures `RiseOn-CatCar/catcar-platform`, never the component repositories. No Azure or GitHub changes occur without `--apply`.

## Preflight

Authenticate Azure CLI and GitHub CLI with permissions to administer the selected subscription's resource groups, Entra applications, role assignments, and the meta-repository's environments, variables and secrets. The script also requires `jq` and `sha256sum`. Check the selected subscription and tenant, region, existing resources and **all existing Terraform state blobs** and their ownership before applying. Do not create a fresh state for infrastructure already managed elsewhere; adopt or migrate state deliberately. The following are defaults, not proof that a resource exists or is safe to adopt:

| Coordinate | Default | Override |
|---|---|---|
| Foundation and workload resource group | `rg-catcar` | Fixed by release deployment |
| State resource group | `rg-catcar-tfstate` | `AZURE_TF_STATE_RG` |
| State storage account | `stcatcartf3c4128ef` | `AZURE_TF_STATE_STORAGE_ACCOUNT` |
| State container | `tfstate` | `TF_BACKEND_CONTAINER` |
| Region | `brazilsouth` | `AZURE_LOCATION` |

The release deployment targets `rg-catcar`. State uses Azure AD authentication; Terraform state and plans can contain secrets and must not be published. Existing storage accounts must meet the script's security checks. The bootstrap operator needs Blob Data Contributor on the state account to create the container; the script assigns it using the signed-in user or the explicit `--bootstrap-principal-object-id` and `--bootstrap-principal-type`.

Apply also checks the subscription's required Azure resource providers and registers missing ones, waiting for registration. The bootstrap identity therefore needs permission to read and register those providers at subscription scope; the deploy identity's resource-group grants do not provide that bootstrap permission. The default dry-run only previews this step.

Supply the following values from a secure environment or protected `--env-file`; they are required for apply and are never generated or printed:

* Variables: `APIM_PUBLISHER_NAME`, `APIM_PUBLISHER_EMAIL`, `CATCAR_ALERT_EMAIL`.
* Secrets: `POSTGRES_ADMIN_PASSWORD`, `POSTGRES_AUTH_READONLY_PASSWORD`, `JWT_SECRET`, `CUSTOMER_JWT_SIGNING_KEY`, `BOOTSTRAP_ADMIN_EMAIL`, `BOOTSTRAP_ADMIN_PASSWORD`, `SMOKE_CUSTOMER_EMAIL`.

Use existing credentials where resources already exist; do not silently rotate them, commit them, or use real customer data for smoke tests. PostgreSQL passwords need at least 12 characters and signing keys at least 32. The script writes these secrets only to the `azure` environment, not to the configuration file.

```bash
./scripts/bootstrap-azure.sh
# Only after reviewing state, ownership, permissions and the printed preview:
STATE_PREFLIGHT_CONFIRMED=true ./scripts/bootstrap-azure.sh --apply
```

## Identity and environment

Before any mutation, the script checks owner ID `330941078` and repository ID `1376139605`, then queries the GitHub repository OIDC customization API for `sub_claim_prefix`. It fails unless the prefix is `repo:RiseOn-CatCar@330941078/catcar-platform@1376139605`; the deploy application's federated subject is exactly that prefix plus `:environment:azure`. Issuer is `https://token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange`. The script does not delete existing federated credentials or role assignments: audit and retire old component-repository credentials and overbroad grants separately.

The deploy principal receives Contributor, User Access Administrator, Azure Kubernetes Service RBAC Cluster Admin, AcrPush and Key Vault Secrets Officer at the foundation resource group. Storage Blob Data Contributor is scoped to the state storage account. No subscription-wide role is granted. These grants support Terraform role assignments, AKS access, image pushes, and Key Vault secret operations; verify their scopes against adopted resources and remove obsolete broader access separately.

The intended academic configuration uses ACR Basic and a standard Key Vault with **public network endpoints**. Access is authenticated: the deploy identity needs `AcrPush` and Key Vault Secrets Officer, while workload identities need their respective pull or secret-read permissions. Public reachability increases exposure to credential theft and attacks against the endpoints; it is not equivalent to private networking. Restrict and audit RBAC, protect OIDC and GitHub environment access, and review the trade-off before use. PostgreSQL remains private.

The release currently runs on a GitHub-hosted `ubuntu-latest` runner. `azure/login` exchanges the environment-scoped GitHub OIDC token for short-lived Azure credentials; do not configure a client secret, registry admin password, or long-lived runner credential. The runner also receives the environment secrets listed above, writes temporary deployment material locally, and requires network access to the Azure control plane, public ACR and Key Vault data planes, AKS API and APIM gateway. Protect the runner and environment, avoid printing or publishing credentials and sensitive Terraform state/plans, and account for RBAC propagation when diagnosing access failures. A private gateway or restricted network requires a suitably connected runner; the current hosted runner has no private-network connectivity configured.

Only the meta-repository's GitHub environment `azure` is configured. Environment variables are `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_DEPLOY_CLIENT_ID`, `AZURE_LOCATION`, `AZURE_TF_STATE_RG`, `AZURE_TF_STATE_STORAGE_ACCOUNT`, `TF_BACKEND_CONTAINER`, `APIM_PUBLISHER_NAME`, `APIM_PUBLISHER_EMAIL`, and `CATCAR_ALERT_EMAIL`; the seven secrets listed above are environment-scoped. Existing environment reviewers and other protection rules are not overwritten. If an existing environment does not already use custom deployment policies, or contains policies other than the `v*` tag policy, bootstrap stops for manual review rather than weakening protection.

The environment permits only the custom tag pattern `v*`; GitHub's glob is deliberately complemented by the release workflow's stricter tag syntax check. Set any required reviewers and other protections according to repository policy. Bootstrap does not modify branch protection or create branches.

Before creating a release tag, follow the [release process](release-process.md): component PR-head checks are review-only, so merge the component PRs and repin their successful push-to-`main` commits in the platform. Platform CI must pass `Component Checks`, `Pinned Integration`, and `Release Images`, including E2E and Trivy. Kind is local-only and supplies no release evidence.

## Cost and migration

AKS Free removes the cluster management tier charge, not the cost of its nodes, disks, load balancer, networking or other services. APIM Developer remains a significant always-on cost; PostgreSQL, ACR Basic, Log Analytics/Application Insights, Container Apps/Function execution, storage, traffic and other resources can also incur charges. Scaling the Function to zero and limiting workspace ingestion do not make the environment free or cap the entire Azure bill. Check current regional prices, usage and budgets.

Changing an existing installation can require removal or replacement of private endpoints, DNS resources or other infrastructure. The release script rejects any Terraform plan containing deletes or replacements, so an existing Premium/private configuration cannot necessarily migrate through the normal release. Review state ownership, dependencies, downtime and security implications and perform a separately authorized migration; do not bypass the release guard or assume a SKU change is nondisruptive. No cloud change is made by this documentation.

