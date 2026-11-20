#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs intentionally use jq variables.
set -euo pipefail
set +x
umask 077
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

main() {
  local apply=false yes=false confirm='' arg current root key address rc count node_groups leftovers
  while (($#)); do
    arg=$1; shift
    case "$arg" in
      --apply) apply=true ;;
      --yes) yes=true ;;
      --confirm) (($#)) || { fail '--confirm needs a value'; return 1; }; confirm=$1; shift ;;
      *) fail "Unknown argument: $arg"; return 1 ;;
    esac
  done
  if [[ $apply == true ]]; then
    [[ $confirm == rg-catcar ]] || { fail '--apply requires --confirm rg-catcar'; return 1; }
    if [[ $yes != true ]]; then
      [[ -t 0 ]] || { fail 'Interactive confirmation required (or pass --yes)'; return 1; }
      read -r -p 'Type rg-catcar to destroy the Azure deployment: ' answer
      [[ $answer == rg-catcar ]] || { fail 'Confirmation did not match'; return 1; }
    fi
  fi
  current=$(az account show --query id -o tsv)
  AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-$current}
  printf 'Azure subscription: %s\n' "$AZURE_SUBSCRIPTION_ID"
  [[ -n $current && $current == "$AZURE_SUBSCRIPTION_ID" ]] || { fail 'Azure subscription mismatch'; return 1; }
  AZURE_TF_STATE_RG=${AZURE_TF_STATE_RG:-rg-catcar-tfstate}
  AZURE_TF_STATE_STORAGE_ACCOUNT=${AZURE_TF_STATE_STORAGE_ACCOUNT:-stcatcartf3c4128ef}
  TF_BACKEND_CONTAINER=${TF_BACKEND_CONTAINER:-tfstate}
  export ARM_USE_AZUREAD=true ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
  export TF_VAR_foundation_state_resource_group_name="$AZURE_TF_STATE_RG" TF_VAR_foundation_state_storage_account_name="$AZURE_TF_STATE_STORAGE_ACCOUNT" TF_VAR_foundation_state_container_name="$TF_BACKEND_CONTAINER" TF_VAR_foundation_state_key=catcar-kubernetes.tfstate
  export TF_VAR_database_state_resource_group_name="$AZURE_TF_STATE_RG" TF_VAR_database_state_storage_account_name="$AZURE_TF_STATE_STORAGE_ACCOUNT" TF_VAR_database_state_container_name="$TF_BACKEND_CONTAINER" TF_VAR_database_state_key=catcar-database.tfstate
  export TF_VAR_resource_group_name=rg-catcar TF_VAR_location=brazilsouth TF_VAR_apim_publisher_name=CatCar TF_VAR_apim_publisher_email=teardown@example.com
  export TF_VAR_customer_jwt_signing_key=teardown-placeholder-01234567890123456789 TF_VAR_admin_jwt_secret=teardown-placeholder-01234567890123456789
  export TF_VAR_administrator_password='Teardown-Placeholder-123!' TF_VAR_auth_readonly_password='Teardown-Placeholder-123!'
  export TF_VAR_auth_function_image="placeholder.azurecr.io/catcar-auth-function@sha256:$(printf '%064d' 0)"
  export TF_VAR_aks_cluster_id="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-catcar/providers/Microsoft.ContainerService/managedClusters/placeholder"
  export TF_VAR_application_insights_id="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-catcar/providers/Microsoft.Insights/components/placeholder"
  export TF_VAR_log_analytics_workspace_id="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-catcar/providers/Microsoft.OperationalInsights/workspaces/placeholder"
  export TF_VAR_health_probe_url=https://example.com/api/health/ready TF_VAR_alert_email=teardown@example.com
  TMP_DIR=$(mktemp -d); trap 'rm -rf "$TMP_DIR"' EXIT
  local tmp=$TMP_DIR
  # Secret IDs are data-plane URLs rather than ARM IDs; resolve allowed vault names from Azure.
  az keyvault list -g rg-catcar -o json > "$tmp/vaults.json"
  local -a roots=(catcar-kubernetes-infra/alerts catcar-auth-function/infra catcar-database-infra catcar-kubernetes-infra)
  local -a keys=(catcar-alerts.tfstate catcar-auth-function.tfstate catcar-database.tfstate catcar-kubernetes.tfstate)
  local -a targets=()
  local i
  for i in "${!roots[@]}"; do
    root=${roots[$i]}; key=${keys[$i]}
    printf '\n=== %s ===\n' "$root"
    mise exec terraform -- terraform -chdir="$ROOT_DIR/$root" init -input=false -no-color -reconfigure \
      -backend-config="resource_group_name=$AZURE_TF_STATE_RG" -backend-config="storage_account_name=$AZURE_TF_STATE_STORAGE_ACCOUNT" \
      -backend-config="container_name=$TF_BACKEND_CONTAINER" -backend-config="key=$key" -backend-config='use_azuread_auth=true' > "$tmp/init.log" 2>&1 || { cat "$tmp/init.log" >&2; fail "Terraform init failed: $root"; return 1; }
    mise exec terraform -- terraform -chdir="$ROOT_DIR/$root" state list > "$tmp/state" || { fail "Cannot read state: $root"; return 1; }
    if [[ ! -s $tmp/state ]]; then printf 'Empty state; skipped.\n'; continue; fi
    targets=()
    if [[ $root == catcar-kubernetes-infra ]]; then
      if [[ $apply == true ]] && grep -Fxq 'azurerm_resource_group.this' "$tmp/state"; then
        mise exec terraform -- terraform -chdir="$ROOT_DIR/$root" state rm azurerm_resource_group.this || { fail 'Could not detach resource group'; return 1; }
        grep -Fxv 'azurerm_resource_group.this' "$tmp/state" > "$tmp/state.filtered" || true
        mv "$tmp/state.filtered" "$tmp/state"
      elif [[ $apply != true ]]; then
        # Target every managed address except the retained resource group. The plan safety check remains authoritative.
        while IFS= read -r address; do [[ $address == azurerm_resource_group.this ]] || targets+=("-target=$address"); done < "$tmp/state"
        if ((${#targets[@]} == 0)); then printf 'Only retained resource group in state; skipped.\n'; continue; fi
      fi
      if [[ ! -s $tmp/state ]]; then printf 'Only retained resource group in state; skipped.\n'; continue; fi
    fi
    rc=0
    mise exec terraform -- terraform -chdir="$ROOT_DIR/$root" plan -destroy -input=false -no-color -detailed-exitcode "${targets[@]}" -out="$tmp/plan" > "$tmp/plan.log" 2>&1 || rc=$?
    [[ $rc == 0 || $rc == 2 ]] || { cat "$tmp/plan.log" >&2; fail "Terraform plan failed: $root"; return 1; }
    mise exec terraform -- terraform -chdir="$ROOT_DIR/$root" show -json "$tmp/plan" > "$tmp/plan.json"
    # Fail closed on unknown/non-ARM IDs, except Key Vault secret URLs for vaults in the target group.
    jq -e --arg sub "$AZURE_SUBSCRIPTION_ID" --arg storage "$AZURE_TF_STATE_STORAGE_ACCOUNT" --slurpfile vaults "$tmp/vaults.json" '
      [ $vaults[0][]?.name | ascii_downcase ] as $vaultnames |
      all(.resource_changes[]? | select(.mode == "managed" and (.change.actions | index("delete")));
        . as $r | ($r.change.before.id // "" | ascii_downcase) as $id |
        ($r.type != "azurerm_resource_group") and
        (if $r.type == "azurerm_storage_account" then (($r.change.before.name // "" | ascii_downcase) != ($storage | ascii_downcase)) else true end) and
        (if $r.type == "azurerm_key_vault_secret" then
          ($id | capture("^https://(?<vault>[^.]+)\\.vault\\.azure\\.net/secrets/").vault) as $vault | ($vaultnames | index($vault) != null)
         else ($id | startswith("/subscriptions/" + ($sub | ascii_downcase) + "/resourcegroups/rg-catcar/")) end))' "$tmp/plan.json" >/dev/null || { fail "Unsafe deletion (resource group, state storage, outside rg-catcar, or unverifiable ID): $root"; return 1; }
    count=$(jq '[.resource_changes[]? | select(.mode == "managed" and (.change.actions | index("delete")))] | length' "$tmp/plan.json")
    printf 'Planned deletions: %s\n' "$count"
    jq -r '[.resource_changes[]? | select(.mode == "managed" and (.change.actions | index("delete")))] | group_by(.type)[] | "  \(.[0].type) (\(length)):", (.[] | "    \(.address)")' "$tmp/plan.json"
    if [[ $apply == true && $rc == 2 ]]; then
      mise exec terraform -- terraform -chdir="$ROOT_DIR/$root" apply -input=false -no-color "$tmp/plan" || { fail "Terraform apply failed: $root"; return 1; }
    fi
  done
  printf '\nNo resource group deletion planned.\n'
  if [[ $apply == true ]]; then
    leftovers=$(az resource list -g rg-catcar -o json)
    node_groups=$(az group list --query "[?starts_with(name, 'MC_rg-catcar_')].name" -o json)
    printf 'Resources remaining in rg-catcar: %s\n' "$leftovers"
    printf 'Remaining AKS node resource groups: %s\n' "$node_groups"
    printf 'Soft-deleted API Management services:\n'; az apim deletedservice list -o table
    printf 'Soft-deleted Key Vaults (purge-protected vaults remain soft-deleted without vault charges):\n'; az keyvault list-deleted -o table
    printf 'Expected remaining billable resource: state storage account %s (verify Azure billing).\n' "$AZURE_TF_STATE_STORAGE_ACCOUNT"
    printf 'Redeploy: push a new v* release tag; bootstrap need not be repeated.\n'
    [[ $(jq 'length' <<< "$leftovers") == 0 && $(jq 'length' <<< "$node_groups") == 0 ]] || { fail 'Azure resources remain; investigate before assuming costs stopped'; return 1; }
  fi
}
main "$@"
