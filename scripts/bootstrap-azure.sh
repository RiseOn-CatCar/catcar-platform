#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

readonly APPLICATION_NAME="catcar"
readonly STATE_CONTAINER_DEFAULT="tfstate"
readonly DEPLOY_APPLICATION_NAME="catcar-github-azure-deploy"
readonly OIDC_ISSUER="https://token.actions.githubusercontent.com"
readonly OIDC_AUDIENCE="api://AzureADTokenExchange"
readonly GITHUB_REPOSITORY="RiseOn-CatCar/catcar-platform"
readonly EXPECTED_PREFIX="repo:RiseOn-CatCar@330941078/catcar-platform@1376139605"
readonly GH_ENV="azure"

mode="dry-run"
env_file=".env"
bootstrap_principal_object_id="${BOOTSTRAP_PRINCIPAL_OBJECT_ID:-}"
bootstrap_principal_type="${BOOTSTRAP_PRINCIPAL_TYPE:-User}"
usage() {
    cat <<'EOF'
Usage: scripts/bootstrap-azure.sh [--dry-run | --apply] [--env-file PATH]
       [--bootstrap-principal-object-id OBJECT_ID] [--bootstrap-principal-type TYPE]

Preview the single Azure release bootstrap by default; --apply explicitly changes
Azure and the azure environment in RiseOn-CatCar/catcar-platform.
STATE_PREFLIGHT_CONFIRMED=true is required for apply after reviewing existing state
and resource ownership. See docs/azure-bootstrap.md for required configuration.
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

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_nonempty_environment() {
    local name="$1"
    [[ -n "${!name:-}" ]] || fail "--apply requires environment variable $name"
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
    local suffix
    suffix="$(printf '%s' "$subject" | sha256sum)"
    credential_name="${credential_name}-${suffix:0:8}"

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
        if [[ "$existing_subject" == "$subject" && "$existing_issuer" == "$OIDC_ISSUER" && "$existing_audience" == "$OIDC_AUDIENCE" ]]; then
            printf 'Reusing federated credential %s.\n' "$credential_name"
            return
        fi
        fail "Federated credential $credential_name exists with different issuer, audience or subject; inspect it manually"
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

while (($# > 0)); do
    case "$1" in
        --dry-run) mode="dry-run" ;;
        --apply) mode="apply" ;;
        --env-file|-f)
            (($# >= 2)) || fail "--env-file requires a path"
            env_file="$2"; shift ;;
        --env-file=*) env_file="${1#*=}" ;;
        --bootstrap-principal-object-id)
            (($# >= 2)) || fail "--bootstrap-principal-object-id requires an object ID"
            bootstrap_principal_object_id="$2"; shift ;;
        --bootstrap-principal-type)
            (($# >= 2)) || fail "--bootstrap-principal-type requires a type"
            bootstrap_principal_type="$2"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
    shift
done

load_env_file "$env_file"
require_command az
require_command gh
require_command jq
require_command sha256sum

subscription_id="$(az account show --query id --output tsv)"
tenant_id="$(az account show --query tenantId --output tsv)"
[[ -n "$subscription_id" && -n "$tenant_id" ]] || fail "select an Azure subscription and tenant"
repo_id="$(gh api "repos/$GITHUB_REPOSITORY" --jq '.id')"
owner_id="$(gh api "repos/$GITHUB_REPOSITORY" --jq '.owner.id')"
[[ "$repo_id" == 1376139605 && "$owner_id" == 330941078 ]] || fail "GitHub repository identity changed"
prefix="$(gh api "repos/$GITHUB_REPOSITORY/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty')"
[[ "$prefix" == "$EXPECTED_PREFIX" ]] || fail "unexpected GitHub OIDC sub_claim_prefix; verify the repository's immutable subject configuration"

AZURE_LOCATION="${AZURE_LOCATION:-brazilsouth}"
STATE_RG="${AZURE_TF_STATE_RG:-rg-catcar-tfstate}"
STATE_STORAGE_ACCOUNT="${AZURE_TF_STATE_STORAGE_ACCOUNT:-stcatcartf3c4128ef}"
STATE_CONTAINER="${TF_BACKEND_CONTAINER:-$STATE_CONTAINER_DEFAULT}"
FOUNDATION_RG="rg-catcar"
WORKLOAD_RG="$FOUNDATION_RG"

printf 'Mode: %s\nSubscription: %s\nTenant: %s\nLocation: %s\n' "$mode" "$subscription_id" "$tenant_id" "$AZURE_LOCATION"
printf 'Repository/environment: %s / %s\nOIDC subject: %s:environment:%s\n' "$GITHUB_REPOSITORY" "$GH_ENV" "$prefix" "$GH_ENV"
printf 'State: %s / %s / %s\nFoundation RG: %s\nWorkload RG: %s\n' "$STATE_RG" "$STATE_STORAGE_ACCOUNT" "$STATE_CONTAINER" "$FOUNDATION_RG" "$WORKLOAD_RG"
printf 'Deploy identity: %s; RG-scoped Contributor, User Access Administrator, AKS RBAC Cluster Admin, AcrPush and Key Vault Secrets Officer; state account Blob Data Contributor.\n' "$DEPLOY_APPLICATION_NAME"
printf 'GitHub environment policy: custom tags v* only; workflow enforces strict release tag syntax.\n'
printf 'Environment variables: AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_DEPLOY_CLIENT_ID AZURE_LOCATION AZURE_TF_STATE_RG AZURE_TF_STATE_STORAGE_ACCOUNT TF_BACKEND_CONTAINER APIM_PUBLISHER_NAME APIM_PUBLISHER_EMAIL CATCAR_ALERT_EMAIL\n'
printf 'Environment secrets: POSTGRES_ADMIN_PASSWORD POSTGRES_AUTH_READONLY_PASSWORD JWT_SECRET CUSTOMER_JWT_SIGNING_KEY BOOTSTRAP_ADMIN_EMAIL BOOTSTRAP_ADMIN_PASSWORD SMOKE_CUSTOMER_EMAIL\n'
if [[ "$mode" == "dry-run" ]]; then
    printf 'Preview only; no Azure or GitHub changes made. Use --apply after preflight.\n'
    exit 0
fi

[[ "${STATE_PREFLIGHT_CONFIRMED:-}" == "true" ]] || fail "review existing state and resource ownership, then set STATE_PREFLIGHT_CONFIRMED=true"
for name in APIM_PUBLISHER_NAME APIM_PUBLISHER_EMAIL CATCAR_ALERT_EMAIL POSTGRES_ADMIN_PASSWORD POSTGRES_AUTH_READONLY_PASSWORD JWT_SECRET CUSTOMER_JWT_SIGNING_KEY BOOTSTRAP_ADMIN_EMAIL BOOTSTRAP_ADMIN_PASSWORD SMOKE_CUSTOMER_EMAIL; do
    require_nonempty_environment "$name"
done
[[ "$APIM_PUBLISHER_EMAIL" == *@* && "$CATCAR_ALERT_EMAIL" == *@* ]] || fail "publisher and alert email addresses must contain @"
[[ ${#POSTGRES_ADMIN_PASSWORD} -ge 12 && ${#POSTGRES_AUTH_READONLY_PASSWORD} -ge 12 ]] || fail "PostgreSQL passwords must contain at least 12 characters"
[[ ${#JWT_SECRET} -ge 32 && ${#CUSTOMER_JWT_SIGNING_KEY} -ge 32 ]] || fail "JWT signing keys must contain at least 32 characters"
if [[ -z "$bootstrap_principal_object_id" ]]; then
    bootstrap_principal_object_id="$(az ad signed-in-user show --query id --output tsv)"
fi
[[ "$bootstrap_principal_object_id" =~ ^[0-9a-fA-F-]{36}$ ]] || fail "bootstrap principal object ID must be a Microsoft Entra object ID"
case "$bootstrap_principal_type" in
    User|ServicePrincipal|Group|ForeignGroup) ;;
    *) fail "invalid bootstrap principal type" ;;
esac

# Refuse to weaken an existing environment or retain policies broader than v*.
environment_json="$(gh api --paginate "repos/$GITHUB_REPOSITORY/environments?per_page=100" --jq ".environments[] | select(.name == \"$GH_ENV\")")"
if [[ -n "$environment_json" ]]; then
    [[ "$(jq -r '.deployment_branch_policy.custom_branch_policies // false' <<< "$environment_json")" == true ]] \
        || fail "existing azure environment must already use custom deployment policies; configure it without removing its protection rules"
    policies="$(gh api --paginate "repos/$GITHUB_REPOSITORY/environments/$GH_ENV/deployment-branch-policies?per_page=100" --jq '.branch_policies[] | [.type, .name] | @tsv')"
    if [[ -n "$policies" ]] && [[ "$policies" != $'tag\tv*' ]]; then
        fail "existing azure deployment policies are not exclusively the v* tag policy; review them manually"
    fi
else
    policies=""
fi

ensure_resource_group "$STATE_RG" azure
ensure_resource_group "$FOUNDATION_RG" azure
ensure_resource_group "$WORKLOAD_RG" azure
ensure_storage_account "$STATE_STORAGE_ACCOUNT" "$STATE_RG" azure
ensure_role_assignment "$bootstrap_principal_object_id" "$bootstrap_principal_type" "Storage Blob Data Contributor" "$state_storage_account_id"
create_state_container "$STATE_STORAGE_ACCOUNT"

ensure_application "$DEPLOY_APPLICATION_NAME"
deploy_client_id="$application_client_id"
ensure_service_principal
deploy_principal_id="$service_principal_object_id"
ensure_federated_credential "gh-platform-azure" "${prefix}:environment:${GH_ENV}"
foundation_id="$(az group show --name "$FOUNDATION_RG" --subscription "$subscription_id" --query id --output tsv)"
for role in "Contributor" "User Access Administrator" "Azure Kubernetes Service RBAC Cluster Admin" "AcrPush" "Key Vault Secrets Officer"; do
    ensure_role_assignment "$deploy_principal_id" "ServicePrincipal" "$role" "$foundation_id"
done
ensure_role_assignment "$deploy_principal_id" "ServicePrincipal" "Storage Blob Data Contributor" "$state_storage_account_id"

if [[ -z "$environment_json" ]]; then
    printf '%s\n' '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
        | gh api --method PUT "repos/$GITHUB_REPOSITORY/environments/$GH_ENV" --input - --silent
fi
if [[ -z "$policies" ]]; then
    gh api --method POST "repos/$GITHUB_REPOSITORY/environments/$GH_ENV/deployment-branch-policies" \
        -f name='v*' -f type=tag --silent
fi
set_env_variable "$GITHUB_REPOSITORY" "$GH_ENV" AZURE_TENANT_ID "$tenant_id"
set_env_variable "$GITHUB_REPOSITORY" "$GH_ENV" AZURE_SUBSCRIPTION_ID "$subscription_id"
set_env_variable "$GITHUB_REPOSITORY" "$GH_ENV" AZURE_DEPLOY_CLIENT_ID "$deploy_client_id"
set_env_variable "$GITHUB_REPOSITORY" "$GH_ENV" AZURE_LOCATION "$AZURE_LOCATION"
set_env_variable "$GITHUB_REPOSITORY" "$GH_ENV" AZURE_TF_STATE_RG "$STATE_RG"
set_env_variable "$GITHUB_REPOSITORY" "$GH_ENV" AZURE_TF_STATE_STORAGE_ACCOUNT "$STATE_STORAGE_ACCOUNT"
set_env_variable "$GITHUB_REPOSITORY" "$GH_ENV" TF_BACKEND_CONTAINER "$STATE_CONTAINER"
for name in APIM_PUBLISHER_NAME APIM_PUBLISHER_EMAIL CATCAR_ALERT_EMAIL; do
    set_env_variable "$GITHUB_REPOSITORY" "$GH_ENV" "$name" "${!name}"
done
for name in POSTGRES_ADMIN_PASSWORD POSTGRES_AUTH_READONLY_PASSWORD JWT_SECRET CUSTOMER_JWT_SIGNING_KEY BOOTSTRAP_ADMIN_EMAIL BOOTSTRAP_ADMIN_PASSWORD SMOKE_CUSTOMER_EMAIL; do
    set_env_secret "$GITHUB_REPOSITORY" "$GH_ENV" "$name" "${!name}"
done
printf 'Azure release bootstrap complete for %s / %s.\n' "$GITHUB_REPOSITORY" "$GH_ENV"
