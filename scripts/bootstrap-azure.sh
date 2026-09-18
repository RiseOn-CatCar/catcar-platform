#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

readonly APPLICATION_NAME="catcar"
readonly STATE_CONTAINER="tfstate"
readonly PLAN_APPLICATION_NAME="catcar-github-terraform-plan"
readonly OIDC_ISSUER="https://token.actions.githubusercontent.com"
readonly OIDC_AUDIENCE="api://AzureADTokenExchange"

# Target repositories across the organization
DEFAULT_REPOSITORIES=("catcar-app" "catcar-auth-function" "catcar-database-infra" "catcar-kubernetes-infra")

mode="dry-run"
target_environment="all"
skip_branch_protection="false"
env_file=".env"
bootstrap_principal_object_id="${BOOTSTRAP_PRINCIPAL_OBJECT_ID:-}"
bootstrap_principal_type="${BOOTSTRAP_PRINCIPAL_TYPE:-User}"
AZURE_LOCATION="${AZURE_LOCATION:-}"
usage() {
    cat <<'EOF'
Usage: scripts/bootstrap-azure.sh [--dry-run | --apply] [--environment homologation|production|all]
                                  [--env-file PATH] [--skip-branch-protection]
                                  [--bootstrap-principal-object-id OBJECT_ID] [--bootstrap-principal-type TYPE]
Creates or reuses CatCar Azure and GitHub control-plane prerequisites for Homologation, Production, or both.
Default mode is --dry-run. Default environment is all.

Options:
  --environment, -e ENV   Target environment: homologation, production, or all (default: all)
  --dry-run               Preview actions without mutating Azure or GitHub (default)
  --apply                 Apply changes to Azure and GitHub
  --env-file, -f PATH     Path to .env file to load/save variables (default: .env if present)
  --skip-branch-protection Skip configuring branch protection rules on GitHub repositories
  --bootstrap-principal-object-id OBJECT_ID
                          Microsoft Entra object ID of the operator running bootstrap
  --bootstrap-principal-type TYPE
                          Type of bootstrap principal (User, ServicePrincipal, Group; default: User)
  --help, -h              Show this help message

What this script configures:
1. Azure Control Plane:
   - Resource Groups for State, Foundation, and Workloads (Homologation & Production)
   - Encrypted, private Terraform State Storage Accounts and 'tfstate' container
   - Microsoft Entra ID (Azure AD) Workload Identities with OIDC Federated Credentials
   - Role-Based Access Control (RBAC) assignments for plan and deployment identities
2. GitHub Repositories (catcar-app, catcar-auth-function, catcar-database-infra, catcar-kubernetes-infra, catcar-platform):
   - Repository-level variables (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, AZURE_LOCATION, etc.)
   - Environments ('homologation' and 'production')
   - Environment-scoped variables (AZURE_DEPLOY_CLIENT_ID, AKS cluster, ACR, Key Vault, Log Analytics, App Insights)
   - Environment-scoped secrets (POSTGRES_ADMIN_PASSWORD, POSTGRES_AUTH_READONLY_PASSWORD, JWT_SECRET, CUSTOMER_JWT_SIGNING_KEY)
   - Branch Protection Rules for 'main' and 'develop' (pull request reviews required, no direct push, force push disabled)

Configuration and Secrets:
  Variables can be set in shell, in a .env file, or auto-generated.
  If omitted, database passwords and JWT signing keys are automatically generated
  securely and saved to the .env file with permissions 0600.
Optional environment-specific overrides:
  POSTGRES_ADMIN_PASSWORD_HOMOLOG, POSTGRES_ADMIN_PASSWORD_PROD
  POSTGRES_AUTH_READONLY_PASSWORD_HOMOLOG, POSTGRES_AUTH_READONLY_PASSWORD_PROD
  JWT_SECRET_HOMOLOG, JWT_SECRET_PROD
  CUSTOMER_JWT_SIGNING_KEY_HOMOLOG, CUSTOMER_JWT_SIGNING_KEY_PROD
  FOUNDATION_RESOURCE_GROUP_HOMOLOG, FOUNDATION_RESOURCE_GROUP_PROD
  REPOSITORIES (space-separated list of repository names to configure)
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

load_env_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    printf 'Loading configuration from %s...\n' "$file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            if [[ -z "${!key:-}" ]]; then
                export "$key=$val"
            fi
        fi
    done < "$file"
}
is_auto_generated() {
    local target="$1"
    local s
    for s in "${generated_secrets[@]}"; do
        [[ "$s" == "$target" ]] && return 0
    done
    return 1
}


generate_password() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import secrets, string; print("Aa1!" + "".join(secrets.choice(string.ascii_letters + string.digits + "!#%&*-_=+") for _ in range(16)))'
    elif command -v openssl >/dev/null 2>&1; then
        printf 'Aa1!%s' "$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9!#%&*-_=+' | head -c 16)"
    else
        printf 'Aa1!%s' "$(LC_ALL=C tr -dc 'A-Za-z0-9!#%&*-_=+' < /dev/urandom | head -c 16)"
    fi
}

generate_jwt_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import secrets; print(secrets.token_hex(32))'
    else
        LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 64
    fi
}

save_env_file() {
    local target_file="${1:-.env}"
    if [[ -f "$target_file" ]]; then
        printf 'Ensuring %s contains all effective configuration and secrets...\n' "$target_file"
    else
        printf 'Creating %s (mode 0600) with configuration and generated secrets...\n' "$target_file"
        touch "$target_file"
        chmod 600 "$target_file"
        cat > "$target_file" <<EOF
# CatCar Platform Environment Configuration
# Generated/updated by scripts/bootstrap-azure.sh
# KEEP THIS FILE SECURE AND NEVER COMMIT TO GIT

APIM_PUBLISHER_NAME="${APIM_PUBLISHER_NAME}"
APIM_PUBLISHER_EMAIL="${APIM_PUBLISHER_EMAIL}"

# Database Passwords
POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD}"
POSTGRES_AUTH_READONLY_PASSWORD="${POSTGRES_AUTH_READONLY_PASSWORD}"

# Cryptographic JWT Signing Keys (HMAC-SHA256 256-bit keys)
JWT_SECRET="${JWT_SECRET}"
CUSTOMER_JWT_SIGNING_KEY="${CUSTOMER_JWT_SIGNING_KEY}"
EOF
        return 0
    fi

    declare -A vars_to_persist=(
        ["APIM_PUBLISHER_NAME"]="$APIM_PUBLISHER_NAME"
        ["APIM_PUBLISHER_EMAIL"]="$APIM_PUBLISHER_EMAIL"
        ["POSTGRES_ADMIN_PASSWORD"]="$POSTGRES_ADMIN_PASSWORD"
        ["POSTGRES_AUTH_READONLY_PASSWORD"]="$POSTGRES_AUTH_READONLY_PASSWORD"
        ["JWT_SECRET"]="$JWT_SECRET"
        ["CUSTOMER_JWT_SIGNING_KEY"]="$CUSTOMER_JWT_SIGNING_KEY"
    )

    for key in "APIM_PUBLISHER_NAME" "APIM_PUBLISHER_EMAIL" "POSTGRES_ADMIN_PASSWORD" "POSTGRES_AUTH_READONLY_PASSWORD" "JWT_SECRET" "CUSTOMER_JWT_SIGNING_KEY"; do
        local val="${vars_to_persist[$key]}"
        if ! grep -q "^[[:space:]]*${key}=" "$target_file" 2>/dev/null; then
            printf '%s="%s"\n' "$key" "$val" >> "$target_file"
        fi
    done
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_nonempty_environment() {
    local name="$1"
    [[ -n "${!name:-}" ]] || fail "--apply requires environment variable $name"
}

preflight_self_hosted_runner() {
    local repo="$1"
    local compatible_runner_names

    if ! compatible_runner_names="$(gh api --method GET --paginate "repos/$repo/actions/runners?per_page=100" 2>/dev/null \
        --jq '.runners[] | select((.status | ascii_downcase) == "online" and ([.labels[].name | ascii_downcase] | index("self-hosted") != null) and ([.labels[].name | ascii_downcase] | index("linux") != null) and ([.labels[].name | ascii_downcase] | index("x64") != null)) | .name')"; then
        return
    fi

    if [[ -z "$compatible_runner_names" ]]; then
        printf 'note: no online self-hosted runner found for %s (hosted ubuntu-latest runners are supported by current workflows).\n' "$repo"
    fi
}

ensure_resource_group() {
    local name="$1"
    local env_name="$2"
    local exists

    exists="$(az group exists --name "$name" --subscription "$subscription_id" --output tsv)"
    if [[ "$exists" == "true" ]]; then
        printf 'Reusing resource group %s.\n' "$name"
        return
    fi

    [[ "$exists" == "false" ]] || fail "Azure returned an unexpected existence value for resource group $name: $exists"
    printf 'Creating resource group %s.\n' "$name"
    az group create \
        --name "$name" \
        --location "$AZURE_LOCATION" \
        --subscription "$subscription_id" \
        --tags "application=$APPLICATION_NAME" "environment=$env_name" "managed_by=bootstrap" \
        --only-show-errors \
        --output none
}

ensure_storage_account() {
    local storage_account="$1"
    local resource_group="$2"
    local env_name="$3"
    local existing_name

    existing_name="$(az storage account list \
        --resource-group "$resource_group" \
        --subscription "$subscription_id" \
        --query "[?name=='$storage_account'].name | [0]" \
        --output tsv)"

    if [[ -z "$existing_name" ]]; then
        printf 'Creating Terraform state storage account %s in %s.\n' "$storage_account" "$resource_group"
        az storage account create \
            --name "$storage_account" \
            --resource-group "$resource_group" \
            --location "$AZURE_LOCATION" \
            --subscription "$subscription_id" \
            --sku Standard_LRS \
            --kind StorageV2 \
            --https-only true \
            --min-tls-version TLS1_2 \
            --allow-blob-public-access false \
            --allow-shared-key-access false \
            --public-network-access Enabled \
            --tags "application=$APPLICATION_NAME" "environment=$env_name" "managed_by=bootstrap" \
            --only-show-errors \
            --output none
    elif [[ "$existing_name" == "$storage_account" ]]; then
        printf 'Reusing Terraform state storage account %s.\n' "$storage_account"
    else
        fail "Azure returned an unexpected storage account name: $existing_name"
    fi

    state_storage_account_id="$(az storage account show \
        --name "$storage_account" \
        --resource-group "$resource_group" \
        --subscription "$subscription_id" \
        --query id \
        --output tsv)"

    assert_storage_property "$storage_account" "$resource_group" "allowSharedKeyAccess" "false"
    assert_storage_property "$storage_account" "$resource_group" "allowBlobPublicAccess" "false"
    assert_storage_property "$storage_account" "$resource_group" "enableHttpsTrafficOnly" "true"
    assert_storage_property "$storage_account" "$resource_group" "minimumTlsVersion" "TLS1_2"
    assert_storage_property "$storage_account" "$resource_group" "publicNetworkAccess" "Enabled"
}

assert_storage_property() {
    local storage_account="$1"
    local resource_group="$2"
    local property="$3"
    local expected="$4"
    local actual

    actual="$(az storage account show \
        --name "$storage_account" \
        --resource-group "$resource_group" \
        --subscription "$subscription_id" \
        --query "$property" \
        --output tsv)"
    [[ "${actual,,}" == "${expected,,}" ]] || fail "existing state storage account $storage_account has $property=$actual; expected $expected"
}

ensure_application() {
    local display_name="$1"
    local application_count

    application_count="$(az ad app list --display-name "$display_name" --query 'length(@)' --output tsv)"
    case "$application_count" in
        0)
            printf 'Creating Microsoft Entra application %s.\n' "$display_name"
            application_client_id="$(az ad app create \
                --display-name "$display_name" \
                --sign-in-audience AzureADMyOrg \
                --query appId \
                --output tsv)"
            ;;
        1)
            application_client_id="$(az ad app list \
                --display-name "$display_name" \
                --query '[0].appId' \
                --output tsv)"
            printf 'Reusing Microsoft Entra application %s.\n' "$display_name"
            ;;
        *)
            fail "found $application_count Microsoft Entra applications named $display_name; resolve duplicates before bootstrapping"
            ;;
    esac

    application_object_id="$(az ad app show --id "$application_client_id" --query id --output tsv)"
}

ensure_service_principal() {
    local existing_count
    local attempt

    existing_count="$(az ad sp list \
        --filter "appId eq '$application_client_id'" \
        --query 'length(@)' \
        --output tsv)"
    case "$existing_count" in
        0)
            printf 'Creating service principal for %s.\n' "$application_client_id"
            az ad sp create --id "$application_client_id" --only-show-errors --output none
            ;;
        1)
            ;;
        *)
            fail "found $existing_count service principals for application $application_client_id"
            ;;
    esac

    for ((attempt = 1; attempt <= 12; attempt++)); do
        service_principal_object_id="$(az ad sp list \
            --filter "appId eq '$application_client_id'" \
            --query '[0].id' \
            --output tsv)"
        if [[ -n "$service_principal_object_id" ]]; then
            return
        fi
        sleep 5
    done

    fail "service principal for $application_client_id was not available after 60 seconds"
}

ensure_federated_credential() {
    local credential_name="$1"
    local subject="$2"
    local existing_subject
    local existing_issuer
    local existing_audience
    local parameters_file

    existing_subject="$(az ad app federated-credential list \
        --id "$application_object_id" \
        --query "[?name=='$credential_name'].subject | [0]" \
        --output tsv)"

    if [[ -n "$existing_subject" ]]; then
        existing_issuer="$(az ad app federated-credential list \
            --id "$application_object_id" \
            --query "[?name=='$credential_name'].issuer | [0]" \
            --output tsv)"
        existing_audience="$(az ad app federated-credential list \
            --id "$application_object_id" \
            --query "[?name=='$credential_name'].audiences[0] | [0]" \
            --output tsv)"
        [[ "$existing_subject" == "$subject" && "$existing_issuer" == "$OIDC_ISSUER" && "$existing_audience" == "$OIDC_AUDIENCE" ]] \
            || fail "federated credential $credential_name exists with a different trust configuration"
        printf 'Reusing federated credential %s.\n' "$credential_name"
        return
    fi

    parameters_file="$(mktemp)"
    trap 'rm -f "$parameters_file"' RETURN
    cat >"$parameters_file" <<EOF
{
  "name": "$credential_name",
  "issuer": "$OIDC_ISSUER",
  "subject": "$subject",
  "description": "CatCar GitHub Actions workload identity",
  "audiences": ["$OIDC_AUDIENCE"]
}
EOF

    printf 'Creating federated credential %s.\n' "$credential_name"
    az ad app federated-credential create \
        --id "$application_object_id" \
        --parameters "$parameters_file" \
        --only-show-errors \
        --output none
    rm -f "$parameters_file"
    trap - RETURN
}

ensure_role_assignment() {
    local principal_id="$1"
    local principal_type="$2"
    local role_name="$3"
    local scope="$4"
    local assignment_count

    assignment_count="$(az role assignment list \
        --scope "$scope" \
        --query "[?principalId=='$principal_id' && roleDefinitionName=='$role_name'] | length(@)" \
        --output tsv)"
    case "$assignment_count" in
        0)
            printf 'Assigning %s at %s.\n' "$role_name" "$scope"
            az role assignment create \
                --assignee-object-id "$principal_id" \
                --assignee-principal-type "$principal_type" \
                --role "$role_name" \
                --scope "$scope" \
                --only-show-errors \
                --output none
            ;;
        1)
            printf 'Reusing %s at %s.\n' "$role_name" "$scope"
            ;;
        *)
            fail "found $assignment_count $role_name assignments for $principal_id at $scope"
            ;;
    esac
}

create_state_container() {
    local storage_account="$1"
    local attempt

    for ((attempt = 1; attempt <= 12; attempt++)); do
        if az storage container create \
            --account-name "$storage_account" \
            --name "$STATE_CONTAINER" \
            --auth-mode login \
            --public-access off \
            --only-show-errors \
            --output none; then
            return
        fi
        if (( attempt == 12 )); then
            fail "could not create or access state container $STATE_CONTAINER in $storage_account after waiting for Azure RBAC propagation"
        fi
        printf 'Waiting for state-blob RBAC propagation on %s (%d/12).\n' "$storage_account" "$attempt"
        sleep 5
    done
}

set_repo_variable() {
    local repo="$1"
    local name="$2"
    local value="$3"
    gh variable set "$name" --repo "$repo" --body "$value"
}

set_env_variable() {
    local repo="$1"
    local env="$2"
    local name="$3"
    local value="$4"
    gh variable set "$name" --repo "$repo" --env "$env" --body "$value"
}

set_env_secret() {
    local repo="$1"
    local env="$2"
    local name="$3"
    local value="$4"
    printf '%s' "$value" | gh secret set "$name" --repo "$repo" --env "$env"
}

ensure_branch_exists() {
    local target_repo="$1"
    local branch_name="$2"

    if gh api --method GET "repos/$target_repo/branches/$branch_name" --silent >/dev/null 2>&1; then
        return 0
    fi

    printf 'Creating branch %s from main on %s...\n' "$branch_name" "$target_repo"
    local main_sha
    main_sha="$(gh api "repos/$target_repo/git/ref/heads/main" --jq .object.sha 2>/dev/null || true)"
    if [[ -n "$main_sha" ]]; then
        if gh api --method POST "repos/$target_repo/git/refs" \
            --field ref="refs/heads/$branch_name" \
            --field sha="$main_sha" --silent >/dev/null 2>&1; then
            printf 'Branch %s created successfully on %s.\n' "$branch_name" "$target_repo"
        else
            printf 'warning: failed to create branch %s on %s via GitHub API.\n' "$branch_name" "$target_repo" >&2
        fi
    else
        printf 'warning: could not determine main branch SHA on %s.\n' "$target_repo" >&2
    fi
}

ensure_branch_protection() {
    local target_repo="$1"
    local branch_name="$2"

    ensure_branch_exists "$target_repo" "$branch_name"

    if ! gh api --method GET "repos/$target_repo/branches/$branch_name" --silent >/dev/null 2>&1; then
        printf 'note: branch %s does not exist in %s; skipping branch protection.\n' "$branch_name" "$target_repo"
        return 0
    fi

    printf 'Applying branch protection to %s (branch: %s)...\n' "$target_repo" "$branch_name"
    local api_error
    if ! api_error="$(gh api --method PUT "repos/$target_repo/branches/$branch_name/protection" \
        --header "Accept: application/vnd.github+json" \
        --input - <<EOF 2>&1
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
)"; then
        local is_private
        is_private="$(gh repo view "$target_repo" --json isPrivate --jq .isPrivate 2>/dev/null || true)"
        if [[ "$is_private" == "true" && "$api_error" == *"Upgrade to GitHub Pro or make this repository public"* ]]; then
            printf 'note: repository %s is private; on GitHub Free tier, branch protection requires GitHub Pro/Team or making the repository public (gh repo edit %s --visibility public).\n' "$target_repo" "$target_repo"
        else
            printf 'warning: could not update branch protection for %s on %s: %s\n' "$branch_name" "$target_repo" "$api_error" >&2
        fi
    else
        printf 'Branch protection enabled on %s (%s).\n' "$target_repo" "$branch_name"
    fi
}

get_env_config() {
    local env="$1"
    case "$env" in
        homologation)
            ENV_NAME="homolog"
            GH_ENV="homologation"
            FOUNDATION_RG="${FOUNDATION_RESOURCE_GROUP_HOMOLOG:-rg-catcar-homolog}"
            WORKLOAD_RG="${WORKLOAD_RESOURCE_GROUP_HOMOLOG:-rg-catcar-workloads-homolog}"
            STATE_RG="${STATE_RESOURCE_GROUP_HOMOLOG:-rg-catcar-tfstate-homolog}"
            DEPLOY_APP_NAME="catcar-github-homolog-deploy"
            AKS_CLUSTER_NAME="aks-catcar-homolog"
            ACR_NAME="crccarhomolog"
            KEY_VAULT_NAME="kv-catcar-homolog"
            LOG_ANALYTICS_NAME="log-catcar-homolog"
            APP_INSIGHTS_NAME="appi-catcar-homolog"
            STATE_KEY="homolog-catcar-kubernetes.tfstate"
            ENV_POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD_HOMOLOG:-${POSTGRES_ADMIN_PASSWORD:-}}"
            ENV_POSTGRES_AUTH_READONLY_PASSWORD="${POSTGRES_AUTH_READONLY_PASSWORD_HOMOLOG:-${POSTGRES_AUTH_READONLY_PASSWORD:-}}"
            ENV_JWT_SECRET="${JWT_SECRET_HOMOLOG:-${JWT_SECRET:-}}"
            ENV_CUSTOMER_JWT_SIGNING_KEY="${CUSTOMER_JWT_SIGNING_KEY_HOMOLOG:-${CUSTOMER_JWT_SIGNING_KEY:-}}"
            ;;
        production)
            ENV_NAME="prod"
            GH_ENV="production"
            FOUNDATION_RG="${FOUNDATION_RESOURCE_GROUP_PROD:-${FOUNDATION_RESOURCE_GROUP:-CatCar}}"
            WORKLOAD_RG="${WORKLOAD_RESOURCE_GROUP_PROD:-rg-catcar-workloads-prod}"
            STATE_RG="${STATE_RESOURCE_GROUP_PROD:-rg-catcar-tfstate-prod}"
            DEPLOY_APP_NAME="catcar-github-production-deploy"
            AKS_CLUSTER_NAME="aks-catcar-prod"
            ACR_NAME="crccarprod"
            KEY_VAULT_NAME="kv-catcar-prod"
            LOG_ANALYTICS_NAME="log-catcar-prod"
            APP_INSIGHTS_NAME="appi-catcar-prod"
            STATE_KEY="catcar-kubernetes.tfstate"
            ENV_POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD_PROD:-${POSTGRES_ADMIN_PASSWORD:-}}"
            ENV_POSTGRES_AUTH_READONLY_PASSWORD="${POSTGRES_AUTH_READONLY_PASSWORD_PROD:-${POSTGRES_AUTH_READONLY_PASSWORD:-}}"
            ENV_JWT_SECRET="${JWT_SECRET_PROD:-${JWT_SECRET:-}}"
            ENV_CUSTOMER_JWT_SIGNING_KEY="${CUSTOMER_JWT_SIGNING_KEY_PROD:-${CUSTOMER_JWT_SIGNING_KEY:-}}"
            ;;
        *)
            fail "unsupported environment: $env"
            ;;
    esac
    STATE_STORAGE_ACCOUNT="st${APPLICATION_NAME}${ENV_NAME}${subscription_hash:0:8}"
}

while (($# > 0)); do
    case "$1" in
        --dry-run)
            mode="dry-run"
            ;;
        --apply)
            mode="apply"
            ;;
        --env-file|-f)
            (($# >= 2)) || fail "--env-file requires a file path"
            env_file="$2"
            shift
            ;;
        --env-file=*)
            env_file="${1#*=}"
            ;;
        --environment|-e)
            (($# >= 2)) || fail "--environment requires an environment argument (homologation, production, or all)"
            target_environment="${2,,}"
            shift
            ;;
        --environment=*)
            target_environment="${1#*=}"
            target_environment="${target_environment,,}"
            ;;
        --skip-branch-protection)
            skip_branch_protection="true"
            ;;
        --bootstrap-principal-object-id)
            (($# >= 2)) || fail "--bootstrap-principal-object-id requires an object ID"
            bootstrap_principal_object_id="$2"
            shift
            ;;
        --bootstrap-principal-type)
            (($# >= 2)) || fail "--bootstrap-principal-type requires a type"
            bootstrap_principal_type="$2"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
    shift
done

case "$target_environment" in
    homologation|production|all)
        ;;
    *)
        fail "unknown environment '$target_environment'; allowed values: homologation, production, all"
        ;;
esac

environments=()
if [[ "$target_environment" == "homologation" || "$target_environment" == "all" ]]; then
    environments+=("homologation")
fi
if [[ "$target_environment" == "production" || "$target_environment" == "all" ]]; then
    environments+=("production")
fi

# Load environment file if present
load_env_file "$env_file"

# Auto-detect or default APIM metadata
if [[ -z "${APIM_PUBLISHER_NAME:-}" ]]; then
    APIM_PUBLISHER_NAME="CatCar Operations"
fi
if [[ -z "${APIM_PUBLISHER_EMAIL:-}" ]]; then
    auto_email="$(az account show --query user.name -o tsv 2>/dev/null || true)"
    if [[ "$auto_email" == *"@"* ]]; then
        APIM_PUBLISHER_EMAIL="$auto_email"
    else
        APIM_PUBLISHER_EMAIL="operations@catcar.com"
    fi
fi

# Auto-generate secure database passwords and JWT signing keys if not provided
generated_secrets=()
if [[ -z "${POSTGRES_ADMIN_PASSWORD:-}" ]]; then
    POSTGRES_ADMIN_PASSWORD="$(generate_password)"
    generated_secrets+=("POSTGRES_ADMIN_PASSWORD")
fi
if [[ -z "${POSTGRES_AUTH_READONLY_PASSWORD:-}" ]]; then
    POSTGRES_AUTH_READONLY_PASSWORD="$(generate_password)"
    generated_secrets+=("POSTGRES_AUTH_READONLY_PASSWORD")
fi
if [[ -z "${JWT_SECRET:-}" ]]; then
    JWT_SECRET="$(generate_jwt_key)"
    generated_secrets+=("JWT_SECRET")
fi
if [[ -z "${CUSTOMER_JWT_SIGNING_KEY:-}" ]]; then
    CUSTOMER_JWT_SIGNING_KEY="$(generate_jwt_key)"
    generated_secrets+=("CUSTOMER_JWT_SIGNING_KEY")
fi
export APIM_PUBLISHER_NAME APIM_PUBLISHER_EMAIL POSTGRES_ADMIN_PASSWORD POSTGRES_AUTH_READONLY_PASSWORD JWT_SECRET CUSTOMER_JWT_SIGNING_KEY

require_command az
require_command gh
require_command sha256sum

subscription_id="$(az account show --query id --output tsv)"
tenant_id="$(az account show --query tenantId --output tsv)"
github_repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
[[ -n "$subscription_id" ]] || fail "Azure CLI did not return a subscription ID"
[[ -n "$tenant_id" ]] || fail "Azure CLI did not return a tenant ID"
[[ "$github_repository" =~ ^[[:alnum:]_.-]+/[[:alnum:]_.-]+$ ]] || fail "GitHub CLI returned an invalid repository name: $github_repository"

github_owner="${GITHUB_ORG:-${github_repository%%/*}}"

if [[ -n "${REPOSITORIES:-}" ]]; then
    IFS=' ' read -r -a target_repos <<< "$REPOSITORIES"
else
    target_repos=("${DEFAULT_REPOSITORIES[@]}")
fi

all_target_repos=()
for repo in "${target_repos[@]}"; do
    [[ -z "$repo" ]] && continue
    if [[ "$repo" == *"/"* ]]; then
        all_target_repos+=("$repo")
    else
        all_target_repos+=("${github_owner}/${repo}")
    fi
done
repo_already_present=false
for r in "${all_target_repos[@]}"; do
    if [[ "$r" == "$github_repository" ]]; then
        repo_already_present=true
        break
    fi
done
if [[ "$repo_already_present" == "false" ]]; then
    all_target_repos+=("${github_repository}")
fi

if [[ -z "$AZURE_LOCATION" ]]; then
    if az group exists --name "CatCar" --subscription "$subscription_id" --output tsv 2>/dev/null | grep -q true; then
        AZURE_LOCATION="$(az group show --name "CatCar" --subscription "$subscription_id" --query location --output tsv)"
    elif az group exists --name "rg-catcar-homolog" --subscription "$subscription_id" --query exists --output tsv 2>/dev/null | grep -q true; then
        AZURE_LOCATION="$(az group show --name "rg-catcar-homolog" --subscription "$subscription_id" --query location --output tsv)"
    else
        AZURE_LOCATION="brazilsouth"
    fi
fi
[[ -n "$AZURE_LOCATION" ]] || fail "AZURE_LOCATION must not be empty"

subscription_hash="$(printf '%s' "$subscription_id" | sha256sum)"
subscription_hash="${subscription_hash%% *}"

printf '==============================================================================\n'
printf 'CatCar Azure & GitHub Bootstrap: mode=%s, target_environment=%s\n' "$mode" "$target_environment"
printf 'Subscription: %s | Tenant: %s | Location: %s\n' "$subscription_id" "$tenant_id" "$AZURE_LOCATION"
printf 'Target GitHub Repositories:\n'
for r in "${all_target_repos[@]}"; do
    printf '  - %s\n' "$r"
done
printf '\nPlanned Azure Infrastructure & Workload Identities:\n'
printf '  - Shared Plan App: %s (Reader at subscription, Storage Blob Contributor on state)\n' "$PLAN_APPLICATION_NAME"
for env in "${environments[@]}"; do
    get_env_config "$env"
    printf '  [%s]\n' "$env"
    printf '    Foundation RG: %s\n' "$FOUNDATION_RG"
    printf '    Workload RG:   %s\n' "$WORKLOAD_RG"
    printf '    State Backend: %s / %s / %s\n' "$STATE_RG" "$STATE_STORAGE_ACCOUNT" "$STATE_CONTAINER"
    printf '    Deploy App:    %s\n' "$DEPLOY_APP_NAME"
    printf '    AKS Cluster:   %s | ACR: %s | Key Vault: %s\n' "$AKS_CLUSTER_NAME" "$ACR_NAME" "$KEY_VAULT_NAME"
done

printf '\nPlanned GitHub Actions Configurations (across all target repositories):\n'
printf '  1. Repository-level Variables:\n'
printf '     - AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, AZURE_LOCATION\n'
printf '     - CATCAR_FOUNDATION_RESOURCE_GROUP, APIM_PUBLISHER_NAME, APIM_PUBLISHER_EMAIL\n'
printf '     - AZURE_TF_STATE_RG, AZURE_TF_STATE_STORAGE_ACCOUNT\n'

if [[ "$skip_branch_protection" == "true" ]]; then
    printf '  2. Branch Protection Rules: SKIPPED (--skip-branch-protection specified)\n'
else
    printf '  2. Branch Protection Rules:\n'
    printf '     - main:    Require PR review (1 approver), dismiss stale reviews, disallow force push/deletion\n'
    printf '     - develop: Require PR review (1 approver), dismiss stale reviews, disallow force push/deletion\n'
fi

printf '  3. GitHub Environments & Configurations:\n'
for env in "${environments[@]}"; do
    get_env_config "$env"
    printf '     - %s:\n' "$GH_ENV"
    printf '         Variables: AZURE_DEPLOY_CLIENT_ID, CATCAR_FOUNDATION_RESOURCE_GROUP, ASPIRE_WORKLOAD_RESOURCE_GROUP,\n'
    printf '                    TF_BACKEND_RESOURCE_GROUP, TF_BACKEND_STORAGE_ACCOUNT, TF_BACKEND_CONTAINER,\n'
    printf '                    AZURE_TF_STATE_RG, AZURE_TF_STATE_STORAGE_ACCOUNT, AZURE_LOCATION,\n'
    printf '                    APIM_PUBLISHER_NAME, APIM_PUBLISHER_EMAIL, CATCAR_AKS_CLUSTER_NAME,\n'
    printf '                    ACR_NAME, KEY_VAULT_NAME, CATCAR_LOG_ANALYTICS_WORKSPACE_NAME,\n'
    printf '                    CATCAR_APPLICATION_INSIGHTS_NAME\n'
    printf '         Secrets:   POSTGRES_ADMIN_PASSWORD, POSTGRES_AUTH_READONLY_PASSWORD,\n'
    printf '                    JWT_SECRET, CUSTOMER_JWT_SIGNING_KEY\n'
done

printf '\nSecrets & Configuration Source:\n'
printf '  APIM_PUBLISHER_NAME:             %s\n' "$APIM_PUBLISHER_NAME"
printf '  APIM_PUBLISHER_EMAIL:            %s\n' "$APIM_PUBLISHER_EMAIL"
if is_auto_generated "POSTGRES_ADMIN_PASSWORD"; then
    printf '  POSTGRES_ADMIN_PASSWORD:         [AUTO-GENERATED: will save to %s on --apply]\n' "$env_file"
else
    printf '  POSTGRES_ADMIN_PASSWORD:         [CONFIGURED via environment/%s]\n' "$env_file"
fi
if is_auto_generated "POSTGRES_AUTH_READONLY_PASSWORD"; then
    printf '  POSTGRES_AUTH_READONLY_PASSWORD: [AUTO-GENERATED: will save to %s on --apply]\n' "$env_file"
else
    printf '  POSTGRES_AUTH_READONLY_PASSWORD: [CONFIGURED via environment/%s]\n' "$env_file"
fi
if is_auto_generated "JWT_SECRET"; then
    printf '  JWT_SECRET:                      [AUTO-GENERATED: will save to %s on --apply]\n' "$env_file"
else
    printf '  JWT_SECRET:                      [CONFIGURED via environment/%s]\n' "$env_file"
fi
if is_auto_generated "CUSTOMER_JWT_SIGNING_KEY"; then
    printf '  CUSTOMER_JWT_SIGNING_KEY:        [AUTO-GENERATED: will save to %s on --apply]\n' "$env_file"
else
    printf '  CUSTOMER_JWT_SIGNING_KEY:        [CONFIGURED via environment/%s]\n' "$env_file"
fi

if [[ "$mode" == "dry-run" ]]; then
    cat <<EOF
DRY-RUN completed. No Azure, Microsoft Entra, or GitHub configuration was changed.
Re-run with --apply to apply all changes.
(Any auto-generated secrets will be saved to $env_file with permissions 0600 on --apply).
EOF
    exit 0
fi

# Apply Mode Validations
require_nonempty_environment APIM_PUBLISHER_NAME
require_nonempty_environment APIM_PUBLISHER_EMAIL
[[ "$APIM_PUBLISHER_EMAIL" == *"@"* ]] || fail "APIM_PUBLISHER_EMAIL must contain @"
require_command terraform

# Persist effective secrets and configuration to .env file
save_env_file "$env_file"

for env in "${environments[@]}"; do
    get_env_config "$env"
    [[ -n "$ENV_POSTGRES_ADMIN_PASSWORD" && ${#ENV_POSTGRES_ADMIN_PASSWORD} -ge 12 ]] \
        || fail "Environment $env requires POSTGRES_ADMIN_PASSWORD (or POSTGRES_ADMIN_PASSWORD_${ENV_NAME^^}) with at least 12 characters"
    [[ -n "$ENV_POSTGRES_AUTH_READONLY_PASSWORD" && ${#ENV_POSTGRES_AUTH_READONLY_PASSWORD} -ge 12 ]] \
        || fail "Environment $env requires POSTGRES_AUTH_READONLY_PASSWORD (or POSTGRES_AUTH_READONLY_PASSWORD_${ENV_NAME^^}) with at least 12 characters"
    [[ -n "$ENV_JWT_SECRET" && ${#ENV_JWT_SECRET} -ge 32 ]] \
        || fail "Environment $env requires JWT_SECRET (or JWT_SECRET_${ENV_NAME^^}) with at least 32 characters"
    [[ -n "$ENV_CUSTOMER_JWT_SIGNING_KEY" && ${#ENV_CUSTOMER_JWT_SIGNING_KEY} -ge 32 ]] \
        || fail "Environment $env requires CUSTOMER_JWT_SIGNING_KEY (or CUSTOMER_JWT_SIGNING_KEY_${ENV_NAME^^}) with at least 32 characters"
done

if [[ -z "$bootstrap_principal_object_id" ]]; then
    bootstrap_principal_object_id="$(az ad signed-in-user show --query id --output tsv)"
fi
[[ "$bootstrap_principal_object_id" =~ ^[0-9a-fA-F-]{36}$ ]] \
    || fail "bootstrap principal object ID must be a Microsoft Entra object ID"
case "$bootstrap_principal_type" in
    User|ServicePrincipal|Group|ForeignGroup)
        ;;
    *)
        fail "bootstrap principal type must be User, ServicePrincipal, Group, or ForeignGroup"
        ;;
esac

# 1. Ensure Shared Plan Application (catcar-github-terraform-plan)
printf '\n--- Setting up Plan Identity: %s ---\n' "$PLAN_APPLICATION_NAME"
ensure_application "$PLAN_APPLICATION_NAME"
plan_client_id="$application_client_id"
ensure_service_principal
plan_service_principal_object_id="$service_principal_object_id"
ensure_role_assignment "$plan_service_principal_object_id" "ServicePrincipal" "Reader" "/subscriptions/$subscription_id"

for target_repo in "${all_target_repos[@]}"; do
    repo_slug="${target_repo##*/}"
    clean_slug="${repo_slug//[^a-zA-Z0-9_-]/-}"
    ensure_federated_credential "gh-${clean_slug}-pr" "repo:${target_repo}:pull_request"
    ensure_federated_credential "gh-${clean_slug}-main" "repo:${target_repo}:ref:refs/heads/main"
    ensure_federated_credential "gh-${clean_slug}-develop" "repo:${target_repo}:ref:refs/heads/develop"
done

# Detect Kubernetes Terraform directory if present locally
k8s_tf_dir=""
if [[ -d "catcar-kubernetes-infra" && -f "catcar-kubernetes-infra/main.tf" ]]; then
    k8s_tf_dir="catcar-kubernetes-infra"
elif [[ -f "main.tf" && -f "variables.tf" && -f "apim-policy.xml" ]]; then
    k8s_tf_dir="."
elif [[ -d "infra/kubernetes" && -f "infra/kubernetes/main.tf" ]]; then
    k8s_tf_dir="infra/kubernetes"
fi

# 2. Iterate and Provision Environments in Azure
for env in "${environments[@]}"; do
    get_env_config "$env"
    printf '\n==============================================================================\n'
    printf 'Provisioning Azure Control Plane: %s (%s)\n' "$env" "$ENV_NAME"
    printf '==============================================================================\n'

    ensure_resource_group "$STATE_RG" "$ENV_NAME"
    ensure_resource_group "$FOUNDATION_RG" "$ENV_NAME"
    ensure_resource_group "$WORKLOAD_RG" "$ENV_NAME"

    ensure_storage_account "$STATE_STORAGE_ACCOUNT" "$STATE_RG" "$ENV_NAME"
    ensure_role_assignment "$bootstrap_principal_object_id" "$bootstrap_principal_type" "Storage Blob Data Contributor" "$state_storage_account_id"
    ensure_role_assignment "$plan_service_principal_object_id" "ServicePrincipal" "Storage Blob Data Contributor" "$state_storage_account_id"
    create_state_container "$STATE_STORAGE_ACCOUNT"

    printf '\n--- Setting up Deploy Identity: %s ---\n' "$DEPLOY_APP_NAME"
    ensure_application "$DEPLOY_APP_NAME"
    deploy_client_id="$application_client_id"
    ensure_service_principal
    deploy_service_principal_object_id="$service_principal_object_id"

    for target_repo in "${all_target_repos[@]}"; do
        repo_slug="${target_repo##*/}"
        clean_slug="${repo_slug//[^a-zA-Z0-9_-]/-}"
        if [[ "$env" == "homologation" ]]; then
            ensure_federated_credential "gh-${clean_slug}-homolog-env" "repo:${target_repo}:environment:homologation"
            ensure_federated_credential "gh-${clean_slug}-develop" "repo:${target_repo}:ref:refs/heads/develop"
        else
            ensure_federated_credential "gh-${clean_slug}-prod-env" "repo:${target_repo}:environment:production"
            ensure_federated_credential "gh-${clean_slug}-main" "repo:${target_repo}:ref:refs/heads/main"
        fi
    done

    foundation_resource_group_id="$(az group show --name "$FOUNDATION_RG" --subscription "$subscription_id" --query id --output tsv)"
    workload_resource_group_id="$(az group show --name "$WORKLOAD_RG" --subscription "$subscription_id" --query id --output tsv)"
    ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "Contributor" "$foundation_resource_group_id"
    ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "User Access Administrator" "$foundation_resource_group_id"
    ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "Azure Kubernetes Service RBAC Cluster Admin" "$foundation_resource_group_id"
    ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "Contributor" "$workload_resource_group_id"
    ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "Storage Blob Data Contributor" "$state_storage_account_id"
    ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "AcrPush" "$foundation_resource_group_id"
    ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "Key Vault Secrets Officer" "$foundation_resource_group_id"

    # Optional local Terraform import
    if [[ -n "$k8s_tf_dir" ]]; then
        printf '\n--- Checking local Kubernetes Terraform state for %s ---\n' "$STATE_KEY"
        export TF_VAR_resource_group_name="$FOUNDATION_RG"
        export TF_VAR_location="$AZURE_LOCATION"
        export TF_VAR_apim_publisher_name="$APIM_PUBLISHER_NAME"
        export TF_VAR_apim_publisher_email="$APIM_PUBLISHER_EMAIL"
        export TF_VAR_customer_jwt_signing_key="$ENV_CUSTOMER_JWT_SIGNING_KEY"

        if terraform -chdir="$k8s_tf_dir" init -input=false -reconfigure \
            -backend-config="resource_group_name=$STATE_RG" \
            -backend-config="storage_account_name=$STATE_STORAGE_ACCOUNT" \
            -backend-config="container_name=$STATE_CONTAINER" \
            -backend-config="key=$STATE_KEY" \
            -backend-config="use_azuread_auth=true" 2>/dev/null; then

            terraform_state_addresses="$(terraform -chdir="$k8s_tf_dir" state list 2>/dev/null || true)"
            if [[ $'\n'"$terraform_state_addresses"$'\n' == *$'\nazurerm_resource_group.this\n'* ]]; then
                printf 'Terraform state %s already owns %s.\n' "$STATE_KEY" "$FOUNDATION_RG"
            else
                printf 'Importing existing resource group %s into Kubernetes Terraform state (%s).\n' "$FOUNDATION_RG" "$STATE_KEY"
                terraform -chdir="$k8s_tf_dir" import -input=false \
                    azurerm_resource_group.this \
                    "/subscriptions/$subscription_id/resourceGroups/$FOUNDATION_RG" 2>/dev/null || true
            fi
        else
            printf 'Note: could not initialize Terraform backend for state %s; skipping state import.\n' "$STATE_KEY"
        fi
    fi
done

# 3. Configure GitHub Repositories (Variables, Branch Protection, Environments & Secrets)
printf '\n==============================================================================\n'
printf 'Configuring GitHub Repositories (Variables, Branch Protection, Environments)\n'
printf '==============================================================================\n'

for target_repo in "${all_target_repos[@]}"; do
    if ! gh repo view "$target_repo" >/dev/null 2>&1; then
        printf 'warning: repository %s is not accessible via gh; skipping.\n' "$target_repo" >&2
        continue
    fi

    printf '\n--- Configuring GitHub repository: %s ---\n' "$target_repo"

    # Repository-level variables
    printf 'Setting repository-level variables on %s...\n' "$target_repo"
    set_repo_variable "$target_repo" AZURE_CLIENT_ID "$plan_client_id"
    set_repo_variable "$target_repo" AZURE_TENANT_ID "$tenant_id"
    set_repo_variable "$target_repo" AZURE_SUBSCRIPTION_ID "$subscription_id"
    set_repo_variable "$target_repo" AZURE_LOCATION "$AZURE_LOCATION"
    set_repo_variable "$target_repo" APIM_PUBLISHER_NAME "$APIM_PUBLISHER_NAME"
    set_repo_variable "$target_repo" APIM_PUBLISHER_EMAIL "$APIM_PUBLISHER_EMAIL"
    set_repo_variable "$target_repo" CATCAR_FOUNDATION_RESOURCE_GROUP "$FOUNDATION_RG"
    set_repo_variable "$target_repo" AZURE_TF_STATE_RG "$STATE_RG"
    set_repo_variable "$target_repo" AZURE_TF_STATE_STORAGE_ACCOUNT "$STATE_STORAGE_ACCOUNT"

    # Branch Protection Rules (main and develop)
    if [[ "$skip_branch_protection" != "true" ]]; then
        ensure_branch_protection "$target_repo" "main"
        ensure_branch_protection "$target_repo" "develop"
    fi

    # Environment-scoped configurations
    for env in "${environments[@]}"; do
        get_env_config "$env"
        printf 'Configuring environment %s on %s...\n' "$GH_ENV" "$target_repo"

        # Create GitHub environment
        gh api --method PUT "repos/$target_repo/environments/$GH_ENV" --silent 2>/dev/null || true

        # Environment-scoped variables
        set_env_variable "$target_repo" "$GH_ENV" AZURE_DEPLOY_CLIENT_ID "$deploy_client_id"
        set_env_variable "$target_repo" "$GH_ENV" CATCAR_FOUNDATION_RESOURCE_GROUP "$FOUNDATION_RG"
        set_env_variable "$target_repo" "$GH_ENV" ASPIRE_WORKLOAD_RESOURCE_GROUP "$WORKLOAD_RG"
        set_env_variable "$target_repo" "$GH_ENV" TF_BACKEND_RESOURCE_GROUP "$STATE_RG"
        set_env_variable "$target_repo" "$GH_ENV" TF_BACKEND_STORAGE_ACCOUNT "$STATE_STORAGE_ACCOUNT"
        set_env_variable "$target_repo" "$GH_ENV" TF_BACKEND_CONTAINER "$STATE_CONTAINER"
        set_env_variable "$target_repo" "$GH_ENV" AZURE_TF_STATE_RG "$STATE_RG"
        set_env_variable "$target_repo" "$GH_ENV" AZURE_TF_STATE_STORAGE_ACCOUNT "$STATE_STORAGE_ACCOUNT"
        set_env_variable "$target_repo" "$GH_ENV" AZURE_LOCATION "$AZURE_LOCATION"
        set_env_variable "$target_repo" "$GH_ENV" APIM_PUBLISHER_NAME "$APIM_PUBLISHER_NAME"
        set_env_variable "$target_repo" "$GH_ENV" APIM_PUBLISHER_EMAIL "$APIM_PUBLISHER_EMAIL"
        set_env_variable "$target_repo" "$GH_ENV" CATCAR_AKS_CLUSTER_NAME "$AKS_CLUSTER_NAME"
        set_env_variable "$target_repo" "$GH_ENV" ACR_NAME "$ACR_NAME"
        set_env_variable "$target_repo" "$GH_ENV" KEY_VAULT_NAME "$KEY_VAULT_NAME"
        set_env_variable "$target_repo" "$GH_ENV" CATCAR_LOG_ANALYTICS_WORKSPACE_NAME "$LOG_ANALYTICS_NAME"
        set_env_variable "$target_repo" "$GH_ENV" CATCAR_APPLICATION_INSIGHTS_NAME "$APP_INSIGHTS_NAME"

        # Environment-scoped secrets
        set_env_secret "$target_repo" "$GH_ENV" POSTGRES_ADMIN_PASSWORD "$ENV_POSTGRES_ADMIN_PASSWORD"
        set_env_secret "$target_repo" "$GH_ENV" POSTGRES_AUTH_READONLY_PASSWORD "$ENV_POSTGRES_AUTH_READONLY_PASSWORD"
        set_env_secret "$target_repo" "$GH_ENV" JWT_SECRET "$ENV_JWT_SECRET"
        set_env_secret "$target_repo" "$GH_ENV" CUSTOMER_JWT_SIGNING_KEY "$ENV_CUSTOMER_JWT_SIGNING_KEY"
    done
done

printf '\n==============================================================================\n'
printf 'CatCar Azure & GitHub Bootstrap completed successfully for: %s\n' "$target_environment"
printf '==============================================================================\n'
