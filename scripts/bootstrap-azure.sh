#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

readonly APPLICATION_NAME="catcar"
readonly ENVIRONMENT_NAME="prod"
AZURE_LOCATION="${AZURE_LOCATION:-}"
readonly GITHUB_ENVIRONMENT="production"
FOUNDATION_RESOURCE_GROUP="${FOUNDATION_RESOURCE_GROUP:-CatCar}"
readonly WORKLOAD_RESOURCE_GROUP="rg-catcar-workloads-prod"
readonly STATE_RESOURCE_GROUP="rg-catcar-tfstate-prod"
readonly STATE_CONTAINER="tfstate"
readonly PLAN_APPLICATION_NAME="catcar-github-terraform-plan"
readonly DEPLOY_APPLICATION_NAME="catcar-github-production-deploy"
readonly OIDC_ISSUER="https://token.actions.githubusercontent.com"
readonly OIDC_AUDIENCE="api://AzureADTokenExchange"

mode="dry-run"
bootstrap_principal_object_id="${BOOTSTRAP_PRINCIPAL_OBJECT_ID:-}"
bootstrap_principal_type="${BOOTSTRAP_PRINCIPAL_TYPE:-User}"
usage() {
    cat <<'EOF'
Usage: scripts/bootstrap-azure.sh [--dry-run | --apply] [--bootstrap-principal-object-id OBJECT_ID] [--bootstrap-principal-type TYPE]

Creates or reuses only CatCar Azure/GitHub control-plane prerequisites. --dry-run is the default.
--apply requires these environment variables without printing their values:
  APIM_PUBLISHER_NAME, APIM_PUBLISHER_EMAIL,
  POSTGRES_ADMIN_PASSWORD, POSTGRES_AUTH_READONLY_PASSWORD,
  JWT_SECRET, CUSTOMER_JWT_SIGNING_KEY

For a non-user Azure login, pass --bootstrap-principal-object-id and
--bootstrap-principal-type (or set BOOTSTRAP_PRINCIPAL_OBJECT_ID and
BOOTSTRAP_PRINCIPAL_TYPE) so the bootstrap identity can receive state-blob access.
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_nonempty_environment() {
    local name="$1"
    [[ -n "${!name:-}" ]] || fail "--apply requires environment variable $name"
}

require_secret_environment() {
    local name="$1"
    local minimum_length="$2"
    local value

    require_nonempty_environment "$name"
    value="${!name}"
    (( ${#value} >= minimum_length )) || fail "$name must contain at least $minimum_length characters"
}
preflight_self_hosted_runner() {
    local compatible_runner_names

    if ! compatible_runner_names="$(gh api --method GET --paginate "repos/$github_repository/actions/runners?per_page=100" \
        --jq '.runners[] | select((.status | ascii_downcase) == "online" and ([.labels[].name | ascii_downcase] | index("self-hosted") != null) and ([.labels[].name | ascii_downcase] | index("linux") != null) and ([.labels[].name | ascii_downcase] | index("x64") != null)) | .name')"; then
        printf 'warning: unable to complete the read-only GitHub runner preflight; verify an online self-hosted runner has self-hosted, linux, and x64 labels before production deployment.\n' >&2
        return
    fi

    if [[ -z "$compatible_runner_names" ]]; then
        printf 'warning: no online self-hosted runner with self-hosted, linux, and x64 labels is registered; the existing production job cannot run until one is online.\n' >&2
    fi
}


ensure_resource_group() {
    local name="$1"
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
        --tags "application=$APPLICATION_NAME" "environment=$ENVIRONMENT_NAME" "managed_by=bootstrap" \
        --only-show-errors \
        --output none
}

ensure_storage_account() {
    local existing_name

    existing_name="$(az storage account list \
        --resource-group "$STATE_RESOURCE_GROUP" \
        --subscription "$subscription_id" \
        --query "[?name=='$state_storage_account'].name | [0]" \
        --output tsv)"

    if [[ -z "$existing_name" ]]; then
        printf 'Creating Terraform state storage account %s.\n' "$state_storage_account"
        az storage account create \
            --name "$state_storage_account" \
            --resource-group "$STATE_RESOURCE_GROUP" \
            --location "$AZURE_LOCATION" \
            --subscription "$subscription_id" \
            --sku Standard_LRS \
            --kind StorageV2 \
            --https-only true \
            --min-tls-version TLS1_2 \
            --allow-blob-public-access false \
            --allow-shared-key-access false \
            --public-network-access Enabled \
            --tags "application=$APPLICATION_NAME" "environment=$ENVIRONMENT_NAME" "managed_by=bootstrap" \
            --only-show-errors \
            --output none
    elif [[ "$existing_name" == "$state_storage_account" ]]; then
        printf 'Reusing Terraform state storage account %s.\n' "$state_storage_account"
    else
        fail "Azure returned an unexpected storage account name: $existing_name"
    fi

    state_storage_account_id="$(az storage account show \
        --name "$state_storage_account" \
        --resource-group "$STATE_RESOURCE_GROUP" \
        --subscription "$subscription_id" \
        --query id \
        --output tsv)"

    assert_storage_property "allowSharedKeyAccess" "false"
    assert_storage_property "allowBlobPublicAccess" "false"
    assert_storage_property "enableHttpsTrafficOnly" "true"
    assert_storage_property "minimumTlsVersion" "TLS1_2"
    assert_storage_property "publicNetworkAccess" "Enabled"
}

assert_storage_property() {
    local property="$1"
    local expected="$2"
    local actual

    actual="$(az storage account show \
        --name "$state_storage_account" \
        --resource-group "$STATE_RESOURCE_GROUP" \
        --subscription "$subscription_id" \
        --query "$property" \
        --output tsv)"
    [[ "${actual,,}" == "${expected,,}" ]] || fail "existing state storage account $state_storage_account has $property=$actual; expected $expected"
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
    local attempt

    for ((attempt = 1; attempt <= 12; attempt++)); do
        if az storage container create \
            --account-name "$state_storage_account" \
            --name "$STATE_CONTAINER" \
            --auth-mode login \
            --public-access off \
            --only-show-errors \
            --output none; then
            return
        fi
        if (( attempt == 12 )); then
            fail "could not create or access state container $STATE_CONTAINER after waiting for Azure RBAC propagation"
        fi
        printf 'Waiting for state-blob RBAC propagation (%d/12).\n' "$attempt"
        sleep 5
    done
}

set_repository_variable() {
    gh variable set "$1" --repo "$github_repository" --body "$2"
}

set_environment_variable() {
    gh variable set "$1" --repo "$github_repository" --env "$GITHUB_ENVIRONMENT" --body "$2"
}

set_environment_secret() {
    local name="$1"

    printf '%s' "${!name}" | gh secret set "$name" --repo "$github_repository" --env "$GITHUB_ENVIRONMENT"
}

while (($# > 0)); do
    case "$1" in
        --dry-run)
            mode="dry-run"
            ;;
        --apply)
            mode="apply"
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

require_command az
require_command gh
require_command sha256sum

subscription_id="$(az account show --query id --output tsv)"
tenant_id="$(az account show --query tenantId --output tsv)"
github_repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
[[ -n "$subscription_id" ]] || fail "Azure CLI did not return a subscription ID"
[[ -n "$tenant_id" ]] || fail "Azure CLI did not return a tenant ID"
[[ "$github_repository" =~ ^[[:alnum:]_.-]+/[[:alnum:]_.-]+$ ]] || fail "GitHub CLI returned an invalid repository name: $github_repository"

preflight_self_hosted_runner

if [[ -z "$AZURE_LOCATION" ]]; then
    foundation_resource_group_exists="$(az group exists --name "$FOUNDATION_RESOURCE_GROUP" --subscription "$subscription_id" --output tsv)"
    [[ "$foundation_resource_group_exists" == "true" ]] \
        || fail "foundation resource group $FOUNDATION_RESOURCE_GROUP does not exist; set AZURE_LOCATION before bootstrapping a new foundation group"
    AZURE_LOCATION="$(az group show --name "$FOUNDATION_RESOURCE_GROUP" --subscription "$subscription_id" --query location --output tsv)"
fi
[[ -n "$AZURE_LOCATION" ]] || fail "AZURE_LOCATION must not be empty"

subscription_hash="$(printf '%s' "$subscription_id" | sha256sum)"
subscription_hash="${subscription_hash%% *}"
state_storage_account="st${APPLICATION_NAME}${ENVIRONMENT_NAME}${subscription_hash:0:8}"
(( ${#state_storage_account} >= 3 && ${#state_storage_account} <= 24 )) || fail "derived invalid storage account name: $state_storage_account"

printf 'Azure bootstrap %s for %s.\n' "$mode" "$github_repository"
printf 'State backend: %s / %s / %s (%s).\n' "$STATE_RESOURCE_GROUP" "$state_storage_account" "$STATE_CONTAINER" "$AZURE_LOCATION"
printf 'Terraform state keys: catcar-kubernetes.tfstate, catcar-database.tfstate, catcar-alerts.tfstate.\n'
printf 'Foundation resource group: %s (Terraform-owned and imported when necessary).\n' "$FOUNDATION_RESOURCE_GROUP"
printf 'Aspire workload resource group: %s.\n' "$WORKLOAD_RESOURCE_GROUP"
printf 'GitHub environment: %s.\n' "$GITHUB_ENVIRONMENT"

if [[ "$mode" == "dry-run" ]]; then
    cat <<'EOF'
No Azure, Microsoft Entra, or GitHub configuration was changed. Re-run with --apply after supplying the required environment variables.
EOF
    exit 0
fi

require_nonempty_environment APIM_PUBLISHER_NAME
require_nonempty_environment APIM_PUBLISHER_EMAIL
[[ "$APIM_PUBLISHER_EMAIL" == *"@"* ]] || fail "APIM_PUBLISHER_EMAIL must contain @"
require_secret_environment POSTGRES_ADMIN_PASSWORD 12
require_secret_environment POSTGRES_AUTH_READONLY_PASSWORD 12
require_secret_environment JWT_SECRET 32
require_secret_environment CUSTOMER_JWT_SIGNING_KEY 32
require_command terraform

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

ensure_resource_group "$STATE_RESOURCE_GROUP"
ensure_resource_group "$FOUNDATION_RESOURCE_GROUP"
ensure_resource_group "$WORKLOAD_RESOURCE_GROUP"

ensure_storage_account
ensure_role_assignment "$bootstrap_principal_object_id" "$bootstrap_principal_type" "Storage Blob Data Contributor" "$state_storage_account_id"
create_state_container

ensure_application "$PLAN_APPLICATION_NAME"
plan_client_id="$application_client_id"
ensure_service_principal
plan_service_principal_object_id="$service_principal_object_id"
ensure_federated_credential "github-main" "repo:$github_repository:ref:refs/heads/main"
ensure_federated_credential "github-pull-request" "repo:$github_repository:pull_request"
ensure_role_assignment "$plan_service_principal_object_id" "ServicePrincipal" "Reader" "/subscriptions/$subscription_id"

ensure_application "$DEPLOY_APPLICATION_NAME"
deploy_client_id="$application_client_id"
ensure_service_principal
deploy_service_principal_object_id="$service_principal_object_id"
ensure_federated_credential "github-production" "repo:$github_repository:environment:$GITHUB_ENVIRONMENT"
foundation_resource_group_id="$(az group show --name "$FOUNDATION_RESOURCE_GROUP" --subscription "$subscription_id" --query id --output tsv)"
workload_resource_group_id="$(az group show --name "$WORKLOAD_RESOURCE_GROUP" --subscription "$subscription_id" --query id --output tsv)"
ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "Contributor" "$foundation_resource_group_id"
ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "User Access Administrator" "$foundation_resource_group_id"
ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "Azure Kubernetes Service RBAC Cluster Admin" "$foundation_resource_group_id"
ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "Contributor" "$workload_resource_group_id"
ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "Storage Blob Data Contributor" "$state_storage_account_id"
ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "AcrPush" "$foundation_resource_group_id"
ensure_role_assignment "$deploy_service_principal_object_id" "ServicePrincipal" "Key Vault Secrets Officer" "$foundation_resource_group_id"

export TF_VAR_resource_group_name="$FOUNDATION_RESOURCE_GROUP"
export TF_VAR_location="$AZURE_LOCATION"
export TF_VAR_apim_publisher_name="$APIM_PUBLISHER_NAME"
export TF_VAR_apim_publisher_email="$APIM_PUBLISHER_EMAIL"
export TF_VAR_customer_jwt_signing_key="$CUSTOMER_JWT_SIGNING_KEY"

terraform -chdir=infra/kubernetes init -input=false -reconfigure \
    -backend-config="resource_group_name=$STATE_RESOURCE_GROUP" \
    -backend-config="storage_account_name=$state_storage_account" \
    -backend-config="container_name=$STATE_CONTAINER" \
    -backend-config="key=catcar-kubernetes.tfstate" \
    -backend-config="use_azuread_auth=true"
terraform_state_addresses="$(terraform -chdir=infra/kubernetes state list)"
if [[ $'\n'"$terraform_state_addresses"$'\n' == *$'\nazurerm_resource_group.this\n'* ]]; then
    printf 'Terraform state already owns %s.\n' "$FOUNDATION_RESOURCE_GROUP"
else
    printf 'Importing existing resource group %s into Kubernetes Terraform state.\n' "$FOUNDATION_RESOURCE_GROUP"
    terraform -chdir=infra/kubernetes import -input=false \
        azurerm_resource_group.this \
        "/subscriptions/$subscription_id/resourceGroups/$FOUNDATION_RESOURCE_GROUP"
fi

# GitHub environment-scoped configuration is only available to the protected production deployment job.
gh api --method PUT "repos/$github_repository/environments/$GITHUB_ENVIRONMENT" --silent
set_repository_variable AZURE_CLIENT_ID "$plan_client_id"
set_repository_variable AZURE_TENANT_ID "$tenant_id"
set_repository_variable AZURE_SUBSCRIPTION_ID "$subscription_id"
set_repository_variable AZURE_LOCATION "$AZURE_LOCATION"
set_repository_variable CATCAR_FOUNDATION_RESOURCE_GROUP "$FOUNDATION_RESOURCE_GROUP"
set_repository_variable APIM_PUBLISHER_NAME "$APIM_PUBLISHER_NAME"
set_repository_variable APIM_PUBLISHER_EMAIL "$APIM_PUBLISHER_EMAIL"
set_environment_variable AZURE_DEPLOY_CLIENT_ID "$deploy_client_id"
set_environment_variable TF_BACKEND_RESOURCE_GROUP "$STATE_RESOURCE_GROUP"
set_environment_variable TF_BACKEND_STORAGE_ACCOUNT "$state_storage_account"
set_environment_variable TF_BACKEND_CONTAINER "$STATE_CONTAINER"
set_environment_variable AZURE_LOCATION "$AZURE_LOCATION"
set_environment_variable ASPIRE_WORKLOAD_RESOURCE_GROUP "$WORKLOAD_RESOURCE_GROUP"
set_environment_secret POSTGRES_ADMIN_PASSWORD
set_environment_secret POSTGRES_AUTH_READONLY_PASSWORD
set_environment_secret JWT_SECRET
set_environment_secret CUSTOMER_JWT_SIGNING_KEY

printf 'Azure bootstrap completed.\n'
