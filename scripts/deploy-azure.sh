#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs intentionally use jq variables.
set -euo pipefail
set +x
umask 077

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/scripts/lib/image-digests.sh"
PAUSE_NAME=catcar-work-order-mutations-paused
NAMESPACE=catcar

fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
require_env() { local name; for name in "$@"; do [[ -n ${!name:-} ]] || { fail "Missing required environment variable: $name"; return 1; }; done; }
diagnose_previous_release() {
  local repository=${GITHUB_REPOSITORY_SLUG:-${GITHUB_REPOSITORY:-}} runs run_id run_url artifact_id
  if [[ -z $repository || -z ${GH_TOKEN:-} ]] || ! command -v gh >/dev/null; then
    echo 'Previous release diagnostics unavailable: GitHub API credentials or repository missing.' >&2
    return 0
  fi
  if ! runs=$(gh api "repos/$repository/actions/workflows/release.yml/runs?status=success&per_page=100" 2>/dev/null); then
    echo 'Previous release diagnostics unavailable: GitHub API request failed.' >&2
    return 0
  fi
  # This workflow has a single deployment job and its sole environment is azure.
  run_id=$(jq -r --arg current "${GITHUB_RUN_ID:-}" '[.workflow_runs[] | select((.id | tostring) != $current and .conclusion == "success")] | .[0].id // empty' <<<"$runs") || return 0
  if [[ -z $run_id ]]; then
    echo 'No previous successful Azure release was found.' >&2
    return 0
  fi
  run_url=$(jq -r --arg id "$run_id" '.workflow_runs[] | select((.id | tostring) == $id) | .html_url' <<<"$runs") || return 0
  echo "Previous successful Azure release: $run_url" >&2
  artifact_id=$(gh api "repos/$repository/actions/runs/$run_id/artifacts?per_page=100" 2>/dev/null | jq -r '[.artifacts[] | select(.name == "release-manifest" and .expired == false)] | .[0].id // empty') || return 0
  [[ -z $artifact_id ]] || echo "Previous immutable manifest artifact: https://github.com/$repository/actions/runs/$run_id/artifacts/$artifact_id" >&2
}
validate_evidence() {
  local evidence=$1 component actual
  jq -e --arg sha "$GITHUB_SHA" '.dirty == false and .platformSha == $sha and (.checks | type == "object" and .componentChecks == true and .pinnedIntegration == true and .trivy == true) and (.imageConfigDigests | [.api,.authFunction] | all(.[]; type == "string" and test("^sha256:[0-9a-f]{64}$")))' "$evidence" >/dev/null || { fail 'Invalid, dirty, or mismatched release evidence (required checks and imageConfigDigests required)'; return 1; }
  for component in catcar-app catcar-auth-function catcar-database-infra catcar-kubernetes-infra; do
    actual=$(git -C "$ROOT_DIR" rev-parse "HEAD:$component") || return 1
    jq -e --arg component "$component" --arg sha "$actual" '.componentShas[$component] == $sha' "$evidence" >/dev/null || { fail "Release evidence gitlink mismatch: $component"; return 1; }
  done
}
verify_archive_configs() {
  local key archive actual expected
  for key in api authFunction; do
    if [[ $key == api ]]; then archive=api.tar; else archive=auth-function.tar; fi
    expected=$(jq -er --arg key "$key" '.imageConfigDigests[$key]' "$ARTIFACTS/release-evidence/release-evidence.json") || return 1
    actual=$(image_archive_config_digest "$ARTIFACTS/release-images/$archive") || return 1
    verify_image_id "$actual" "$expected" "$key" || return 1
  done
}
preflight() {
  require_env AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_DEPLOY_CLIENT_ID AZURE_LOCATION AZURE_TF_STATE_RG AZURE_TF_STATE_STORAGE_ACCOUNT TF_BACKEND_CONTAINER APIM_PUBLISHER_NAME APIM_PUBLISHER_EMAIL CATCAR_ALERT_EMAIL POSTGRES_ADMIN_PASSWORD POSTGRES_AUTH_READONLY_PASSWORD JWT_SECRET CUSTOMER_JWT_SIGNING_KEY BOOTSTRAP_ADMIN_EMAIL BOOTSTRAP_ADMIN_PASSWORD SMOKE_CUSTOMER_EMAIL GITHUB_SHA GITHUB_REF_NAME || return 1
  [[ $GITHUB_REF_NAME =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { fail 'Invalid release tag'; return 1; }
  [[ $(git -C "$ROOT_DIR" rev-parse HEAD) == "$GITHUB_SHA" ]] || { fail 'Checkout does not match GITHUB_SHA'; return 1; }
  local file
  for file in release-images/api.tar release-images/auth-function.tar release-images/SHA256SUMS release-evidence/release-evidence.json; do
    [[ -f $ARTIFACTS/$file ]] || { fail "Missing artifact: $file"; return 1; }
  done
  validate_evidence "$ARTIFACTS/release-evidence/release-evidence.json" || return 1
  awk 'BEGIN { ok=1 } !/^[0-9a-f]+  (api\.tar|auth-function\.tar)$/ || length($1) != 64 { ok=0 } /  api\.tar$/ { api++ } /  auth-function\.tar$/ { auth++ } END { exit !(ok && NR == 2 && api == 1 && auth == 1) }' "$ARTIFACTS/release-images/SHA256SUMS" || { fail 'Invalid image archive checksum manifest'; return 1; }
  (cd "$ARTIFACTS/release-images" && sha256sum -c SHA256SUMS >/dev/null) || { fail 'Image archive checksum mismatch'; return 1; }
  verify_archive_configs || return 1
  if [[ $CHECK == true ]]; then return 0; fi
  [[ $(az account show --query tenantId -o tsv) == "$AZURE_TENANT_ID" ]] || { fail 'Azure tenant mismatch'; return 1; }
  [[ $(az account show --query id -o tsv) == "$AZURE_SUBSCRIPTION_ID" ]] || { fail 'Azure subscription mismatch'; return 1; }
}
tf_init() {
  local root=$1 key=$2
  terraform -chdir="$ROOT_DIR/$root" init -input=false -no-color -reconfigure \
    -backend-config="resource_group_name=$AZURE_TF_STATE_RG" -backend-config="storage_account_name=$AZURE_TF_STATE_STORAGE_ACCOUNT" \
    -backend-config="container_name=$TF_BACKEND_CONTAINER" -backend-config="key=$key" -backend-config='use_azuread_auth=true' > "$TMP_DIR/terraform-init.log" 2>&1 || { fail "Terraform init failed: $root"; return 1; }
}
plan_is_safe() { jq -e '[.resource_changes[]?.change.actions[] | select(. == "delete")] | length == 0' "$1" >/dev/null || { fail 'Terraform plan contains delete or replacement'; return 1; }; }
tf_apply() {
  local root=$1 rc=0 plan="$TMP_DIR/plan.tfplan"
  terraform -chdir="$ROOT_DIR/$root" plan -input=false -no-color -detailed-exitcode -out="$plan" > "$TMP_DIR/plan.log" 2>&1 || rc=$?
  [[ $rc == 0 || $rc == 2 ]] || { fail "Terraform plan failed: $root"; return 1; }
  terraform -chdir="$ROOT_DIR/$root" show -json "$plan" > "$TMP_DIR/plan.json" || return 1
  plan_is_safe "$TMP_DIR/plan.json" || return 1
  if [[ $rc == 2 ]]; then
    terraform -chdir="$ROOT_DIR/$root" apply -input=false -no-color -auto-approve "$plan" > "$TMP_DIR/apply.log" 2>&1 || { fail "Terraform apply failed: $root"; return 1; }
  fi
}
tf_output() { terraform -chdir="$ROOT_DIR/$1" output -raw "$2"; }
foundation_init() { tf_init catcar-kubernetes-infra catcar-kubernetes.tfstate; }
database_init() { tf_init catcar-database-infra catcar-database.tfstate; }
common_tf_env() {
  export ARM_USE_AZUREAD=true ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID" ARM_TENANT_ID="$AZURE_TENANT_ID"
  export TF_VAR_foundation_state_resource_group_name="$AZURE_TF_STATE_RG" TF_VAR_foundation_state_storage_account_name="$AZURE_TF_STATE_STORAGE_ACCOUNT" TF_VAR_foundation_state_container_name="$TF_BACKEND_CONTAINER" TF_VAR_foundation_state_key=catcar-kubernetes.tfstate
  export TF_VAR_database_state_resource_group_name="$AZURE_TF_STATE_RG" TF_VAR_database_state_storage_account_name="$AZURE_TF_STATE_STORAGE_ACCOUNT" TF_VAR_database_state_container_name="$TF_BACKEND_CONTAINER" TF_VAR_database_state_key=catcar-database.tfstate
  export TF_VAR_location="$AZURE_LOCATION" TF_VAR_apim_publisher_name="$APIM_PUBLISHER_NAME" TF_VAR_apim_publisher_email="$APIM_PUBLISHER_EMAIL" TF_VAR_customer_jwt_signing_key="$CUSTOMER_JWT_SIGNING_KEY" TF_VAR_admin_jwt_secret="$JWT_SECRET" TF_VAR_administrator_password="$POSTGRES_ADMIN_PASSWORD" TF_VAR_auth_readonly_password="$POSTGRES_AUTH_READONLY_PASSWORD"
}
manifest_update() {
  local filter=$1; shift
  jq "$@" "$filter" "$ARTIFACTS/release-manifest.json" > "$TMP_DIR/manifest.json"
  mv "$TMP_DIR/manifest.json" "$ARTIFACTS/release-manifest.json"
}
manifest_init() {
  if [[ -f $ARTIFACTS/release-manifest.json ]]; then
    jq -e --arg sha "$GITHUB_SHA" --arg tag "$GITHUB_REF_NAME" '.platformSha == $sha and .tag == $tag' "$ARTIFACTS/release-manifest.json" >/dev/null || { fail 'Release manifest belongs to another release'; return 1; }
  else
    jq -n --arg sha "$GITHUB_SHA" --arg tag "$GITHUB_REF_NAME" --slurpfile evidence "$ARTIFACTS/release-evidence/release-evidence.json" '{tag:$tag,platformSha:$sha,gitlinks:$evidence[0].componentShas,imageConfigDigests:$evidence[0].imageConfigDigests,images:{},resources:{},phases:{}}' > "$ARTIFACTS/release-manifest.json"
  fi
}
require_phase() { jq -e --arg phase "$1" '.phases[$phase] == true' "$ARTIFACTS/release-manifest.json" >/dev/null || { fail "Required previous phase missing: $1"; return 1; }; }
load_foundation() {
  foundation_init
  RG=$(tf_output catcar-kubernetes-infra resource_group_name)
  ACR=$(tf_output catcar-kubernetes-infra acr_name)
  ACR_SERVER=$(tf_output catcar-kubernetes-infra acr_login_server)
  AKS=$(tf_output catcar-kubernetes-infra aks_cluster_name)
  APIM_ID=$(tf_output catcar-kubernetes-infra api_management_id)
  APIM=${APIM_ID##*/}
  GATEWAY=$(tf_output catcar-kubernetes-infra api_management_gateway_url); GATEWAY=${GATEWAY%/}
}
load_images() {
  API_IMAGE=$(jq -er '.images.api' "$ARTIFACTS/release-manifest.json")
  AUTH_IMAGE=$(jq -er '.images.authFunction' "$ARTIFACTS/release-manifest.json")
  [[ $API_IMAGE =~ ^[a-z0-9]+\.azurecr\.io/catcar-api@sha256:[0-9a-f]{64}$ && $AUTH_IMAGE =~ ^[a-z0-9]+\.azurecr\.io/catcar-auth-function@sha256:[0-9a-f]{64}$ ]] || { fail 'Invalid approved image references'; return 1; }
}
verify_image_id() { [[ $1 == "$2" ]] || { fail "Image config digest mismatch: $3"; return 1; }; }
publish_images() {
  local key repo component sha expected image digest config full
  az acr login --name "$ACR" >/dev/null
  docker load -i "$ARTIFACTS/release-images/api.tar" > "$TMP_DIR/docker.log"
  docker load -i "$ARTIFACTS/release-images/auth-function.tar" >> "$TMP_DIR/docker.log"
  for key in api authFunction; do
    if [[ $key == api ]]; then repo=catcar-api; component=catcar-app; else repo=catcar-auth-function; component=catcar-auth-function; fi
    sha=$(git -C "$ROOT_DIR" rev-parse "HEAD:$component")
    image="localhost:5001/$repo:$sha"
    expected=$(jq -er --arg key "$key" '.imageConfigDigests[$key]' "$ARTIFACTS/release-evidence/release-evidence.json")
    docker tag "$image" "$ACR_SERVER/$repo:$sha"
    docker push "$ACR_SERVER/$repo:$sha" > "$TMP_DIR/docker-push.log"
    digest=$(az acr repository show --name "$ACR" --image "$repo:$sha" --query digest -o tsv)
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { fail 'ACR returned invalid digest'; return 1; }
    full="$ACR_SERVER/$repo@$digest"
    config=$(docker buildx imagetools inspect --raw "$full" | jq -er '.config.digest')
    verify_image_id "$config" "$expected" "$key" || return 1
    manifest_update '.images[$key]=$image' --arg key "$key" --arg image "$full"
  done
}
phase_foundation() {
  foundation_init
  if ! terraform -chdir="$ROOT_DIR/catcar-kubernetes-infra" state show azurerm_resource_group.this > "$TMP_DIR/state.log" 2>&1; then
    terraform -chdir="$ROOT_DIR/catcar-kubernetes-infra" import -input=false azurerm_resource_group.this "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-catcar" > "$TMP_DIR/import.log" 2>&1 || { fail 'Foundation resource group import failed'; return 1; }
  fi
  tf_apply catcar-kubernetes-infra
  load_foundation
  az acr show --name "$ACR" --resource-group "$RG" --output none
  manifest_update '.resources += {resourceGroup:$rg,aks:$aks,acr:$acr,apimId:$apim}' --arg rg "$RG" --arg aks "$AKS" --arg acr "$ACR_SERVER" --arg apim "$APIM_ID"
  publish_images
}
phase_database() {
  local id kv
  require_phase foundation
  tf_init catcar-database-infra catcar-database.tfstate
  tf_apply catcar-database-infra
  id=$(tf_output catcar-database-infra postgresql_server_id)
  kv=$(tf_output catcar-database-infra key_vault_id)
  manifest_update '.resources.postgresqlId=$id | .resources.keyVaultId=$kv' --arg id "$id" --arg kv "$kv"
}
connect_aks() {
  export KUBECONFIG="$TMP_DIR/kubeconfig"
  az aks get-credentials --resource-group "$RG" --name "$AKS" --file "$KUBECONFIG" --overwrite-existing >/dev/null
  kubelogin convert-kubeconfig -l azurecli
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}
read_pause() { az apim nv show --resource-group "$RG" --service-name "$APIM" --named-value-id "$PAUSE_NAME" --query value -o tsv; }
set_pause() {
  az apim nv update --resource-group "$RG" --service-name "$APIM" --named-value-id "$PAUSE_NAME" --value "$1" --output none
  [[ $(read_pause) == "$1" ]] || { fail 'APIM pause readback failed'; return 1; }
  printf '%s\n' "$1" > "$ARTIFACTS/apim-paused"
}
prove_pause() {
  local path status
  # The policy barrier precedes JWT validation, so anonymous requests cannot create events.
  for path in /api/v1/service-operations/work-orders /api/v1/communication/approval-links/invalid/decision; do
    status=$(curl --silent --show-error --max-time 30 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{}' "$GATEWAY$path")
    [[ $status == 503 ]] || { fail "APIM mutation barrier returned $status instead of 503"; return 1; }
  done
}
prepare_secrets() {
  local host db conn escaped
  database_init
  host=$(tf_output catcar-database-infra postgresql_fqdn); db=$(tf_output catcar-database-infra database_name)
  escaped=${POSTGRES_ADMIN_PASSWORD//\'/\'\'}
  conn="Host=$host;Database=$db;Username=catcaradmin;SSL Mode=Require;Password='$escaped'"
  printf '%s' "$conn" > "$TMP_DIR/ConnectionStrings__catcar"
  printf "'%s'" "$escaped" > "$TMP_DIR/POSTGRES_PASSWORD"
  printf '%s' "$POSTGRES_AUTH_READONLY_PASSWORD" > "$TMP_DIR/POSTGRES_AUTH_READONLY_PASSWORD"
  printf '%s' "$JWT_SECRET" > "$TMP_DIR/JWT_SECRET"
  printf '%s' "$CUSTOMER_JWT_SIGNING_KEY" > "$TMP_DIR/CUSTOMER_JWT_SIGNING_KEY"
  printf '%s' "$BOOTSTRAP_ADMIN_EMAIL" > "$TMP_DIR/BOOTSTRAP_ADMIN_EMAIL"
  printf '%s' "$BOOTSTRAP_ADMIN_PASSWORD" > "$TMP_DIR/BOOTSTRAP_ADMIN_PASSWORD"
  printf '%s' "$JWT_SECRET" > "$TMP_DIR/Jwt__Secret"
  printf '%s' "$CUSTOMER_JWT_SIGNING_KEY" > "$TMP_DIR/CustomerJwt__SigningKey"
  printf '%s' "$POSTGRES_AUTH_READONLY_PASSWORD" > "$TMP_DIR/AuthReadOnly__Password"
  printf '%s' 'auth_readonly' > "$TMP_DIR/AuthReadOnly__Login"
  printf '%s' "$BOOTSTRAP_ADMIN_EMAIL" > "$TMP_DIR/BootstrapAdmin__Email"
  printf '%s' "$BOOTSTRAP_ADMIN_PASSWORD" > "$TMP_DIR/BootstrapAdmin__Password"
  printf '%s' "$POSTGRES_ADMIN_PASSWORD" > "$TMP_DIR/PGPASSWORD"
  printf '%s' "$host" > "$TMP_DIR/PGHOST"
  printf '%s' "$db" > "$TMP_DIR/PGDATABASE"
  printf '%s' catcaradmin > "$TMP_DIR/PGUSER"
  printf '%s' require > "$TMP_DIR/PGSSLMODE"
  kubectl -n "$NAMESPACE" create secret generic catcar-migration-secret --from-file="$TMP_DIR/POSTGRES_PASSWORD" --from-file="$TMP_DIR/POSTGRES_AUTH_READONLY_PASSWORD" --from-file="$TMP_DIR/JWT_SECRET" --from-file="$TMP_DIR/CUSTOMER_JWT_SIGNING_KEY" --from-file="$TMP_DIR/BOOTSTRAP_ADMIN_EMAIL" --from-file="$TMP_DIR/BOOTSTRAP_ADMIN_PASSWORD" --from-file="$TMP_DIR/ConnectionStrings__catcar" --from-file="$TMP_DIR/Jwt__Secret" --from-file="$TMP_DIR/CustomerJwt__SigningKey" --from-file="$TMP_DIR/AuthReadOnly__Password" --from-file="$TMP_DIR/AuthReadOnly__Login" --from-file="$TMP_DIR/BootstrapAdmin__Email" --from-file="$TMP_DIR/BootstrapAdmin__Password" --from-file="$TMP_DIR/PGPASSWORD" --from-file="$TMP_DIR/PGHOST" --from-file="$TMP_DIR/PGDATABASE" --from-file="$TMP_DIR/PGUSER" --from-file="$TMP_DIR/PGSSLMODE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NAMESPACE" create configmap catcar-migration-config --from-literal=ASPNETCORE_ENVIRONMENT=Production --from-literal=DOTNET_ENVIRONMENT=Production --from-literal=AuthReadOnly__Login=auth_readonly --from-literal="DATABASE_CONNECTION_PREFIX=Host=$host;Database=$db;Username=catcaradmin;SSL Mode=Require;" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}
drain() {
  local pod="catcar-drain-${GITHUB_RUN_ID:-local}" result
  kubectl -n "$NAMESPACE" delete pod "$pod" --ignore-not-found --wait=true >/dev/null
  kubectl -n "$NAMESPACE" run "$pod" --image=postgres:17-alpine --restart=Never --overrides='{"spec":{"containers":[{"name":"drain","image":"postgres:17-alpine","command":["sleep","600"],"envFrom":[{"secretRef":{"name":"catcar-migration-secret"}}]}]}}' >/dev/null
  kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$pod" --timeout=180s >/dev/null || { kubectl -n "$NAMESPACE" delete pod "$pod" --ignore-not-found --wait=false >/dev/null; fail 'Wolverine drain pod not ready'; return 1; }
  # psql executes identifiers quoted by PostgreSQL and prints only table names/counts.
  if ! result=$(kubectl -n "$NAMESPACE" exec -i "$pod" -- psql -X -v ON_ERROR_STOP=1 -At <<'SQL'
SELECT format('SELECT %L, count(*) FROM %I.%I;', table_schema || '.' || table_name, table_schema, table_name)
FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_name IN ('wolverine_incoming_envelopes','wolverine_outgoing_envelopes') ORDER BY 1
\gexec
SQL
); then kubectl -n "$NAMESPACE" delete pod "$pod" --ignore-not-found --wait=false >/dev/null; fail 'Wolverine drain SQL failed'; return 1; fi
  kubectl -n "$NAMESPACE" delete pod "$pod" --wait=false >/dev/null
  printf '%s\n' "$result" | awk -F '|' 'NF && (NF != 2 || $2 !~ /^[0-9]+$/ || $2 != 0) { print "Pending envelopes: " $0 > "/dev/stderr"; bad=1 } END { exit bad }' || { fail 'Wolverine queues are not drained'; return 1; }
}
run_job() {
  local name=$1 mode=$2
  kubectl -n "$NAMESPACE" delete job "$name" --ignore-not-found --wait=true >/dev/null
  if [[ $mode == migration ]]; then
    awk -v image="$API_IMAGE" '{gsub(/__API_IMAGE__/, image); gsub(/__RUNTIME_SECRET__/, "catcar-migration-secret"); print}' "$ROOT_DIR/catcar-app/k8s/migration-job.yaml" | kubectl -n "$NAMESPACE" apply -f - >/dev/null
  else
    jq -n --arg image "$API_IMAGE" --arg name "$name" '{apiVersion:"batch/v1",kind:"Job",metadata:{name:$name,labels:{"app.kubernetes.io/component":"reconciliation"}},spec:{backoffLimit:0,template:{metadata:{labels:{"app.kubernetes.io/component":"reconciliation"}},spec:{restartPolicy:"Never",containers:[{name:"reconciliation",image:$image,args:["--reconcile-inventory"],envFrom:[{configMapRef:{name:"catcar-migration-config"}},{secretRef:{name:"catcar-migration-secret"}}]}]}}}}' | kubectl -n "$NAMESPACE" apply -f - >/dev/null
  fi
  kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$name" --timeout=600s >/dev/null || { fail "Maintenance job failed: $name"; return 1; }
}
write_helm_secret_values() {
  local chart=$1 item field file line key
  local template="$chart/templates/api/secrets.yaml"
  [[ -f $template ]] || { fail 'Generated API secret template is missing'; return 1; }
  printf '%s' "$Parameters__communication_connection_string" > "$TMP_DIR/communication"
  jq -n '{secrets:{api:{}}}' > "$TMP_DIR/helm-values.json"
  for item in 'ConnectionStrings__catcar:ConnectionStrings__catcar' 'Jwt__Secret:Jwt__Secret' 'CustomerJwt__SigningKey:CustomerJwt__SigningKey' 'Communication__AzureCommunicationServicesConnectionString:communication'; do
    field=${item%%:*}; file=${item#*:}
    line=$(grep -E "^[[:space:]]*\"?$field\"?[[:space:]]*:" "$template") || { fail "Generated chart missing secret mapping: $field"; return 1; }
    key=$(grep -oE '\.Values\.secrets\.api\.[A-Za-z0-9_]+' <<<"$line" | sort -u) || { fail "Generated chart has no values reference for $field"; return 1; }
    [[ $key =~ ^\.Values\.secrets\.api\.[A-Za-z0-9_]+$ ]] || { fail "Generated chart has ambiguous secret mapping: $field"; return 1; }
    key=${key##*.}
    jq --arg key "$key" --rawfile value "$TMP_DIR/$file" '.secrets.api[$key]=$value' "$TMP_DIR/helm-values.json" > "$TMP_DIR/helm-values-next.json"
    mv "$TMP_DIR/helm-values-next.json" "$TMP_DIR/helm-values.json"
  done
}
migrate_legacy_api_selector() {
  local existing
  existing=$(kubectl -n "$NAMESPACE" get deployment api-deployment -o json --ignore-not-found) || { fail 'Cannot inspect existing API deployment'; return 1; }
  [[ -n $existing ]] || return 0
  if jq -e '.spec.selector.matchLabels["catcar.io/workload"] == "api"' <<<"$existing" >/dev/null; then return 0; fi
  jq -e --arg namespace "$NAMESPACE" '
    .metadata.annotations["meta.helm.sh/release-name"] == "catcar" and
    .metadata.annotations["meta.helm.sh/release-namespace"] == $namespace and
    .spec.selector.matchLabels == {"app.kubernetes.io/component":"api","app.kubernetes.io/instance":"catcar","app.kubernetes.io/name":"catcar"} and
    ((.spec.selector.matchExpressions // []) | length == 0)' <<<"$existing" >/dev/null || { fail 'Existing API deployment has an unexpected owner or selector'; return 1; }
  [[ $(read_pause) == true ]] || { fail 'APIM must be paused before legacy API selector migration'; return 1; }
  prove_pause
  kubectl -n "$NAMESPACE" delete deployment api-deployment --wait=true >/dev/null
}
phase_api() {
  require_phase database; load_foundation; load_images; connect_aks
  local before; before=$(read_pause); [[ $before == true || $before == false ]] || { fail 'Unexpected APIM pause state'; return 1; }
  printf '%s\n' "$before" > "$ARTIFACTS/apim-pause-before"
  set_pause true; prove_pause; prepare_secrets; drain
  run_job catcar-maintenance migration
  export Parameters__foundation_resource_group="$RG" Parameters__acr_name="$ACR" Parameters__api_image_name="${API_IMAGE%@*}" Parameters__api_image_digest="${API_IMAGE##*@}"
  Parameters__log_analytics_workspace_name=$(tf_output catcar-kubernetes-infra log_analytics_workspace_name)
  Parameters__application_insights_name=$(tf_output catcar-kubernetes-infra application_insights_name)
  Parameters__api_private_ip=$(tf_output catcar-kubernetes-infra api_private_ip)
  Parameters__communication_connection_string=$(tf_output catcar-kubernetes-infra communication_connection_string)
  Parameters__communication_sender_address=$(tf_output catcar-kubernetes-infra communication_sender_address)
  printf '::add-mask::%s\n' "$Parameters__communication_connection_string"
  export Parameters__log_analytics_workspace_name Parameters__application_insights_name Parameters__api_private_ip
  export Parameters__jwt_secret="$JWT_SECRET" Parameters__customer_jwt_signing_key="$CUSTOMER_JWT_SIGNING_KEY"
  export Parameters__communication_connection_string Parameters__communication_sender_address Parameters__communication_external_base_url="$GATEWAY"
  export ConnectionStrings__catcar; ConnectionStrings__catcar=$(<"$TMP_DIR/ConnectionStrings__catcar")
  (cd "$ROOT_DIR/catcar-app" && dotnet tool restore > "$TMP_DIR/tool.log" 2>&1 && dotnet tool run aspire -- publish --non-interactive --apphost src/Host/CatCar.AppHost/CatCar.AppHost.csproj --environment Production -o "$TMP_DIR/chart") > "$TMP_DIR/publish.log" 2>&1 || { fail 'Aspire publish failed'; return 1; }
  local -a charts; mapfile -t charts < <(find "$TMP_DIR/chart" -name Chart.yaml -type f)
  ((${#charts[@]} == 1)) || { fail 'Expected one generated chart'; return 1; }
  write_helm_secret_values "${charts[0]%/Chart.yaml}"
  migrate_legacy_api_selector
  helm upgrade --install catcar "${charts[0]%/Chart.yaml}" -n "$NAMESPACE" -f "$TMP_DIR/helm-values.json" --wait --timeout 10m > "$TMP_DIR/helm.log" 2>&1 || { fail 'Helm deployment failed'; return 1; }
  kubectl -n "$NAMESPACE" rollout status deployment/api-deployment --timeout=600s
  kubectl -n "$NAMESPACE" get endpoints catcar-api -o json | jq -e '[.subsets[]?.addresses[]? | .targetRef.name // ""] | length > 0 and all(.[]; startswith("api-deployment-"))' >/dev/null || { fail 'API service contains unexpected endpoints'; return 1; }
  run_job catcar-reconciliation reconcile
  drain
}
phase_function() {
  local id
  require_phase api; load_images
  tf_init catcar-auth-function/infra catcar-auth-function.tfstate
  export TF_VAR_auth_function_image="$AUTH_IMAGE"
  tf_apply catcar-auth-function/infra
  id=$(tf_output catcar-auth-function/infra container_app_id)
  manifest_update '.resources.functionId=$id' --arg id "$id"
}
phase_alerts_smoke() {
  require_phase function; load_foundation
  [[ $(read_pause) == true ]] || { fail 'Expected APIM mutations paused before readiness'; return 1; }
  TF_VAR_aks_cluster_id=$(tf_output catcar-kubernetes-infra aks_cluster_id)
  TF_VAR_application_insights_id=$(tf_output catcar-kubernetes-infra application_insights_id)
  TF_VAR_log_analytics_workspace_id=$(tf_output catcar-kubernetes-infra log_analytics_workspace_id)
  export TF_VAR_aks_cluster_id TF_VAR_application_insights_id TF_VAR_log_analytics_workspace_id
  export TF_VAR_resource_group_name="$RG" TF_VAR_health_probe_url="$GATEWAY/api/health/ready" TF_VAR_alert_email="$CATCAR_ALERT_EMAIL"
  tf_init catcar-kubernetes-infra/alerts catcar-alerts.tfstate; tf_apply catcar-kubernetes-infra/alerts
  curl --fail --silent --show-error --max-time 30 "$GATEWAY/api/health/ready" -o /dev/null
  RELEASE_UNPAUSING=true
  set_pause false
  if ! API_BASE_URL="$GATEWAY" AUTH_BASE_URL="$GATEWAY" HEALTH_BASE_URL="$GATEWAY/api" bash "$ROOT_DIR/catcar-app/scripts/smoke-integrated.sh" --mode azure; then
    set_pause true || fail 'CRITICAL: could not re-pause APIM after failed smoke'
    fail 'Azure smoke failed; mutations must remain paused'; return 1
  fi
}
main() {
  local phase='' artifacts='' CHECK=false
  while (($#)); do case $1 in --phase) (($# >= 2)) || { fail 'Missing --phase value'; return 1; }; phase=$2; shift 2;; --artifacts-dir) (($# >= 2)) || { fail 'Missing --artifacts-dir value'; return 1; }; artifacts=$2; shift 2;; --check|--dry-run) CHECK=true; shift;; *) fail "Unknown argument: $1"; return 1;; esac; done
  case $phase in foundation|database|api|function|alerts-smoke) ;; *) fail 'Invalid or missing phase'; return 1;; esac
  [[ -d $artifacts ]] || { fail 'Missing artifacts directory'; return 1; }
  ARTIFACTS=$(cd "$artifacts" && pwd)
  preflight
  [[ $CHECK == false ]] || { echo 'Offline preflight passed'; return 0; }
  local secret; for secret in POSTGRES_ADMIN_PASSWORD POSTGRES_AUTH_READONLY_PASSWORD JWT_SECRET CUSTOMER_JWT_SIGNING_KEY BOOTSTRAP_ADMIN_EMAIL BOOTSTRAP_ADMIN_PASSWORD SMOKE_CUSTOMER_EMAIL; do printf '::add-mask::%s\n' "${!secret}"; done
  TMP_DIR=$(mktemp -d); chmod 700 "$TMP_DIR"
  trap 'rc=$?; if ((rc)) && [[ ${RELEASE_UNPAUSING:-false} == true ]]; then set_pause true || echo "CRITICAL: failed to re-pause APIM" >&2; fi; if ((rc)); then diagnose_previous_release || true; echo "Release failed. Keep APIM paused; rerun the same tag or publish a corrective tag." >&2; fi; rm -rf -- "${TMP_DIR:-}"' EXIT
  common_tf_env; manifest_init
  case $phase in foundation) phase_foundation;; database) phase_database;; api) phase_api;; function) phase_function;; alerts-smoke) phase_alerts_smoke;; esac
  manifest_update '.phases[$phase]=true' --arg phase "$phase"
  RELEASE_UNPAUSING=false
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
