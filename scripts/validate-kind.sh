#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/image-digests.sh"
cd "$ROOT_DIR"

# LocalKubernetes chart contract: keep chart-specific names and values together.
CONTEXT=kind-catcar
NAMESPACE=catcar-local
RELEASE=catcar-local
CHART_OUTPUT="$ROOT_DIR/artifacts/kind/chart"
API_REPLICAS_KEY=apiReplicas
AUTH_REPLICAS_KEY=authFunctionReplicas
RUNTIME_SECRET=catcar-local-runtime
API_SERVICE=catcar-api
AUTH_SERVICE=catcar-auth-function
MAIL_SERVICE=mailpit
MAINTENANCE_JOB=catcar-maintenance
MIGRATION_MANIFEST="$ROOT_DIR/catcar-app/k8s/migration-job.yaml"

ARTIFACTS="$ROOT_DIR/artifacts/kind"
IMAGES="$ARTIFACTS/images"
rm -f "$ARTIFACTS/validation.json"
API_LOCAL_PORT=${API_LOCAL_PORT:-8080}
FUNCTION_LOCAL_PORT=${FUNCTION_LOCAL_PORT:-7071}
MAILPIT_LOCAL_PORT=${MAILPIT_LOCAL_PORT:-8025}
for tool in docker kind kubectl helm dotnet curl jq openssl sha256sum git python3; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
python3 - "$API_LOCAL_PORT" "$FUNCTION_LOCAL_PORT" "$MAILPIT_LOCAL_PORT" <<'PY'
import socket
import sys

sockets = []
for name, value in zip(("API_LOCAL_PORT", "FUNCTION_LOCAL_PORT", "MAILPIT_LOCAL_PORT"), sys.argv[1:]):
    try:
        port = int(value)
        if not 1 <= port <= 65535:
            raise ValueError()
        sock = socket.socket()
        sock.bind(("127.0.0.1", port))
        sockets.append(sock)
    except (OSError, ValueError):
        sys.exit(f"Cannot bind 127.0.0.1:{value}; set {name} to an available port.")
PY
platform_sha=$(git rev-parse HEAD)
declare -A component_shas
components=(catcar-app catcar-auth-function catcar-database-infra catcar-kubernetes-infra)
dirty=false
check_sources() {
  local component expected actual status
  [[ $(git rev-parse HEAD) == "$platform_sha" ]] || {
    echo "Platform HEAD changed during validation." >&2
    return 1
  }
  status=$(git status --porcelain --untracked-files=normal -- . ':(exclude)artifacts')
  [[ -z "$status" ]] || dirty=true
  for component in "${components[@]}"; do
    expected=$(git ls-tree "$platform_sha" -- "$component" | awk '$1 == "160000" && $2 == "commit" {print $3}')
    actual=$(git -C "$component" rev-parse HEAD)
    [[ -n "$expected" && "$actual" == "$expected" ]] || {
      echo "Component $component does not match the platform gitlink." >&2
      return 1
    }
    status=$(git -C "$component" status --porcelain --untracked-files=normal)
    [[ -z "$status" ]] || dirty=true
    component_shas[$component]=$actual
  done
}
check_sources
api_commit=${component_shas[catcar-app]}
auth_commit=${component_shas[catcar-auth-function]}
API_TAG="localhost:5001/catcar-api:$api_commit"
AUTH_TAG="localhost:5001/catcar-auth-function:$auth_commit"
mkdir -p "$IMAGES" "$CHART_OUTPUT"
tmp=$(mktemp -d)
forward_pids=()
cleanup() {
  local pid
  for pid in "${forward_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${forward_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
export KUBECONFIG="$tmp/kubeconfig"
if kind get clusters | grep -Fxq catcar; then
  kind get kubeconfig --name catcar > "$KUBECONFIG"
fi
"$ROOT_DIR/scripts/kind-with-registry.sh"
k=(kubectl --context "$CONTEXT")
h=(helm --kube-context "$CONTEXT" --namespace "$NAMESPACE")
"${k[@]}" create namespace "$NAMESPACE" --dry-run=client -o yaml | "${k[@]}" apply -f - >/dev/null

# A persistent database must never be paired with regenerated credentials.
secrets=$("${k[@]}" -n "$NAMESPACE" get secrets -o json)
if ! jq -e --arg name "$RUNTIME_SECRET" '.items | any(.metadata.name == $name)' <<<"$secrets" >/dev/null; then
  pvcs=$("${k[@]}" -n "$NAMESPACE" get pvc -o json)
  if jq -e '.items | length > 0' <<<"$pvcs" >/dev/null; then
    echo "A PVC exists but $RUNTIME_SECRET is missing; refusing to regenerate database credentials." >&2
    exit 1
  fi
  openssl rand -base64 36 | tr -d '\n' > "$tmp/POSTGRES_PASSWORD"
  openssl rand -base64 36 | tr -d '\n' > "$tmp/POSTGRES_AUTH_READONLY_PASSWORD"
  openssl rand -base64 36 | tr -d '\n' > "$tmp/JWT_SECRET"
  openssl rand -base64 36 | tr -d '\n' > "$tmp/CUSTOMER_JWT_SIGNING_KEY"
  printf %s 'admin@catcar.local' > "$tmp/BOOTSTRAP_ADMIN_EMAIL"
  openssl rand -base64 36 | tr -d '\n' > "$tmp/BOOTSTRAP_ADMIN_PASSWORD"
  "${k[@]}" -n "$NAMESPACE" create secret generic "$RUNTIME_SECRET" \
    --from-file="$tmp/POSTGRES_PASSWORD" --from-file="$tmp/POSTGRES_AUTH_READONLY_PASSWORD" \
    --from-file="$tmp/JWT_SECRET" --from-file="$tmp/CUSTOMER_JWT_SIGNING_KEY" \
    --from-file="$tmp/BOOTSTRAP_ADMIN_EMAIL" --from-file="$tmp/BOOTSTRAP_ADMIN_PASSWORD" >/dev/null
fi
secret=$("${k[@]}" -n "$NAMESPACE" get secret "$RUNTIME_SECRET" -o json)
for key in POSTGRES_PASSWORD POSTGRES_AUTH_READONLY_PASSWORD JWT_SECRET CUSTOMER_JWT_SIGNING_KEY BOOTSTRAP_ADMIN_EMAIL BOOTSTRAP_ADMIN_PASSWORD; do
  jq -e --arg key "$key" '.data[$key] | strings | length > 0' <<<"$secret" >/dev/null || { echo "Missing key $key in $RUNTIME_SECRET" >&2; exit 1; }
done
export BOOTSTRAP_ADMIN_EMAIL BOOTSTRAP_ADMIN_PASSWORD
BOOTSTRAP_ADMIN_EMAIL=$(jq -r '.data.BOOTSTRAP_ADMIN_EMAIL' <<<"$secret" | base64 -d)
BOOTSTRAP_ADMIN_PASSWORD=$(jq -r '.data.BOOTSTRAP_ADMIN_PASSWORD' <<<"$secret" | base64 -d)
unset secret secrets

docker build -t "$API_TAG" catcar-app
docker build -t "$AUTH_TAG" catcar-auth-function
docker push "$API_TAG"
docker push "$AUTH_TAG"
registry_digest() {
  local repository=$1 tag=$2 digest
  digest=$(curl -fsSI -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
    "http://127.0.0.1:5001/v2/$repository/manifests/$tag" | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}')
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Registry returned an invalid digest for $repository" >&2; return 1; }
  printf 'localhost:5001/%s@%s' "$repository" "$digest"
}
api_image=$(registry_digest catcar-api "$api_commit")
auth_image=$(registry_digest catcar-auth-function "$auth_commit")
api_id=$(docker image inspect --format '{{.Id}}' "$API_TAG")
auth_id=$(docker image inspect --format '{{.Id}}' "$AUTH_TAG")
registry_config() {
  local repository=$1 digest=$2 manifest child
  manifest=$(curl -fsS -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' "http://127.0.0.1:5001/v2/$repository/manifests/$digest")
  child=$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64")][0].digest // empty' <<<"$manifest")
  if [[ -n "$child" ]]; then
    manifest=$(curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' "http://127.0.0.1:5001/v2/$repository/manifests/$child")
  fi
  jq -er '.config.digest | select(test("^sha256:[0-9a-f]{64}$"))' <<<"$manifest"
}
docker save -o "$tmp/api.tar" "$API_TAG"
docker save -o "$tmp/auth-function.tar" "$AUTH_TAG"
api_config=$(image_archive_config_digest "$tmp/api.tar")
auth_config=$(image_archive_config_digest "$tmp/auth-function.tar")
[[ $(registry_config catcar-api "${api_image##*@}") == "$api_config" ]] || { echo "API archive and registry config differ" >&2; exit 1; }
[[ $(registry_config catcar-auth-function "${auth_image##*@}") == "$auth_config" ]] || { echo "Function archive and registry config differ" >&2; exit 1; }

export Parameters__local_api_image="$api_image" Parameters__local_auth_function_image="$auth_image"
(cd catcar-app && dotnet tool run aspire -- publish --non-interactive --apphost src/Host/CatCar.AppHost/CatCar.AppHost.csproj --environment LocalKubernetes -o "$CHART_OUTPUT")
mapfile -t charts < <(find "$CHART_OUTPUT" -name Chart.yaml -type f -print)
((${#charts[@]} == 1)) || { echo "Expected exactly one generated Helm chart under $CHART_OUTPUT" >&2; exit 1; }
chart=${charts[0]%/Chart.yaml}
# Bind both Deployment replicas to explicit stage values in the generated chart.
python3 - "$chart" "$API_REPLICAS_KEY" "$AUTH_REPLICAS_KEY" <<'PY'
import pathlib
import re
import sys

chart = pathlib.Path(sys.argv[1])
for resource, key in (("api", sys.argv[2]), ("auth-function", sys.argv[3])):
    path = chart / "templates" / resource / "deployment.yaml"
    text = path.read_text()
    text, count = re.subn(r"(?m)^  replicas: \d+$", "  replicas: {{ .Values." + key + " }}", text)
    if count != 1:
        raise SystemExit(f"Unexpected replica template in {path}")
    path.write_text(text)
PY
# Kubernetes Deployment selectors are immutable. Replace only the legacy Helm-owned
# API deployment when migrating its old selector; never touch the database or PVC.
old_api=$("${k[@]}" -n "$NAMESPACE" get deployment api-deployment -o json --ignore-not-found)
if [[ -n "$old_api" ]] && jq -e '.spec.selector.matchLabels["catcar.io/workload"] == null' <<<"$old_api" >/dev/null; then
  jq -e --arg release "$RELEASE" --arg namespace "$NAMESPACE" \
    '.metadata.annotations["meta.helm.sh/release-name"] == $release and
     .metadata.annotations["meta.helm.sh/release-namespace"] == $namespace and
     .spec.selector.matchLabels == {"app.kubernetes.io/component":"api","app.kubernetes.io/instance":$release,"app.kubernetes.io/name":"catcar-local"}' \
    <<<"$old_api" >/dev/null || { echo "Existing API deployment has an unexpected owner or selector; refusing replacement." >&2; exit 1; }
  "${k[@]}" -n "$NAMESPACE" delete deployment api-deployment --wait=true
fi
"${h[@]}" upgrade --install "$RELEASE" "$chart" --wait --timeout 5m \
  --set "$API_REPLICAS_KEY=0" --set "$AUTH_REPLICAS_KEY=0" \
  --set-string "config.api.Communication__ExternalBaseUrl=http://127.0.0.1:$API_LOCAL_PORT"
"${k[@]}" -n "$NAMESPACE" rollout status statefulset/postgres-statefulset --timeout=5m
"${k[@]}" -n "$NAMESPACE" rollout status deployment/azurite-deployment --timeout=5m
"${k[@]}" -n "$NAMESPACE" rollout status deployment/mailpit-deployment --timeout=5m

"${k[@]}" -n "$NAMESPACE" create configmap catcar-migration-config \
  --from-literal='DATABASE_CONNECTION_PREFIX=Host=postgres;Database=catcar;Username=postgres;' \
  --from-literal='AuthReadOnly__Login=catcar_auth_readonly' \
  --from-literal='DOTNET_ENVIRONMENT=LocalKubernetes' \
  --from-literal='ASPNETCORE_ENVIRONMENT=LocalKubernetes' \
  --from-literal='Communication__MailpitBaseUrl=http://mailpit:8025' \
  --from-literal="Communication__ExternalBaseUrl=http://127.0.0.1:$API_LOCAL_PORT" \
  --from-literal='Communication__SenderAddress=noreply@catcar.local' \
  --dry-run=client -o yaml | "${k[@]}" -n "$NAMESPACE" apply -f - >/dev/null

# The maintenance job is rerunnable; replace only this named, completed job.
"${k[@]}" -n "$NAMESPACE" delete job "$MAINTENANCE_JOB" --ignore-not-found --wait=true
awk -v image="$api_image" -v secret="$RUNTIME_SECRET" '{gsub(/__API_IMAGE__/, image); gsub(/__RUNTIME_SECRET__/, secret); print}' "$MIGRATION_MANIFEST" | "${k[@]}" -n "$NAMESPACE" apply -f -
"${k[@]}" -n "$NAMESPACE" wait --for=condition=complete "job/$MAINTENANCE_JOB" --timeout=5m
"${h[@]}" upgrade --install "$RELEASE" "$chart" --wait --timeout 5m \
  --set "$API_REPLICAS_KEY=1" --set "$AUTH_REPLICAS_KEY=1" \
  --set-string "config.api.Communication__ExternalBaseUrl=http://127.0.0.1:$API_LOCAL_PORT"
"${k[@]}" -n "$NAMESPACE" rollout status deployment/api-deployment --timeout=5m
"${k[@]}" -n "$NAMESPACE" rollout status deployment/auth-function-deployment --timeout=5m
pods=$("${k[@]}" -n "$NAMESPACE" get pods -o json)
image_ids() {
  local image=$1 phase=$2
  jq -c --arg image "$image" --arg phase "$phase" \
    '[.items[] | select(.status.phase == $phase) | . as $pod |
      .spec.containers[] | select(.image == $image) | .name as $name |
      $pod.status.containerStatuses[]? | select(.name == $name) |
      .imageID | sub("^.*@"; "") | sub("^.*://"; "")]' <<<"$pods"
}
api_running=$(image_ids "$api_image" Running)
auth_running=$(image_ids "$auth_image" Running)
job_running=$(image_ids "$api_image" Succeeded)
verify_ids() {
  local ids=$1 config=$2 digest=$3
  jq -e --arg config "$config" --arg digest "$digest" 'length > 0 and all(.[]; . == $config or . == $digest)' <<<"$ids" >/dev/null || {
    echo "A workload or maintenance image ID does not match the approved registry image." >&2
    return 1
  }
}
verify_ids "$api_running" "$api_config" "${api_image##*@}"
verify_ids "$auth_running" "$auth_config" "${auth_image##*@}"
verify_ids "$job_running" "$api_config" "${api_image##*@}"


forward() {
  local service=$1 port=$2 target=$3 setting=$4
  "${k[@]}" -n "$NAMESPACE" port-forward --address 127.0.0.1 "service/$service" "$port:$target" >"$tmp/forward-$port.log" 2>&1 &
  local pid=$! attempt
  forward_pids+=("$pid")
  for ((attempt=0; attempt<60; attempt++)); do
    kill -0 "$pid" 2>/dev/null || { echo "Port-forward failed for $service; check $setting=$port or choose an available port." >&2; cat "$tmp/forward-$port.log" >&2; return 1; }
    if grep -q 'Forwarding from 127.0.0.1:' "$tmp/forward-$port.log"; then return 0; fi
    sleep 1
  done
  echo "Port-forward for $service did not start" >&2
  return 1
}
forward "$API_SERVICE" "$API_LOCAL_PORT" 80 API_LOCAL_PORT
forward "$AUTH_SERVICE" "$FUNCTION_LOCAL_PORT" 80 FUNCTION_LOCAL_PORT
forward "$MAIL_SERVICE" "$MAILPIT_LOCAL_PORT" 8025 MAILPIT_LOCAL_PORT
export API_BASE_URL="http://127.0.0.1:$API_LOCAL_PORT" AUTH_BASE_URL="http://127.0.0.1:$FUNCTION_LOCAL_PORT"
export HEALTH_BASE_URL="$API_BASE_URL" MAILPIT_BASE_URL="http://127.0.0.1:$MAILPIT_LOCAL_PORT"
export SMOKE_RESULT_FILE="$tmp/smoke.json"
"$ROOT_DIR/catcar-app/scripts/smoke-integrated.sh" --mode kind
jq -e 'type == "object" and length > 0 and all(.[]; . == true)' "$SMOKE_RESULT_FILE" >/dev/null
mv "$tmp/api.tar" "$IMAGES/api.tar"
mv "$tmp/auth-function.tar" "$IMAGES/auth-function.tar"
(cd "$IMAGES" && sha256sum api.tar auth-function.tar > SHA256SUMS)
check_sources
jq -n --arg platformSha "$platform_sha" --arg apiImage "$api_image" --arg authFunctionImage "$auth_image" \
  --arg apiImageId "$api_id" --arg authFunctionImageId "$auth_id" --arg apiConfig "$api_config" --arg authConfig "$auth_config" --argjson dirty "$dirty" \
  --arg sdk "$(dotnet --version)" --arg aspire "$(cd catcar-app && dotnet tool run aspire -- --version)" \
  --arg kind "$(kind version)" --arg kubernetes "$("${k[@]}" version -o json | jq -r '.serverVersion.gitVersion')" \
  --argjson apiRunning "$api_running" --argjson authRunning "$auth_running" --argjson jobRunning "$job_running" \
  --arg app "${component_shas[catcar-app]}" --arg auth "${component_shas[catcar-auth-function]}" \
  --arg database "${component_shas[catcar-database-infra]}" --arg kubernetesSha "${component_shas[catcar-kubernetes-infra]}" \
  --slurpfile checks "$SMOKE_RESULT_FILE" \
  '{platformSha:$platformSha,componentShas:{"catcar-app":$app,"catcar-auth-function":$auth,"catcar-database-infra":$database,"catcar-kubernetes-infra":$kubernetesSha},dirty:$dirty,sdk:$sdk,aspire:$aspire,kind:$kind,kubernetes:$kubernetes,apiImage:$apiImage,authFunctionImage:$authFunctionImage,imageIds:{api:$apiImageId,authFunction:$authFunctionImageId},imageConfigDigests:{api:$apiConfig,authFunction:$authConfig},registryDigests:{api:$apiImage,authFunction:$authFunctionImage},runningImageIds:{api:$apiRunning,authFunction:$authRunning,maintenance:$jobRunning},checks:$checks[0]}' > "$ARTIFACTS/validation.json"
echo "Kind validation passed; evidence: $ARTIFACTS/validation.json"
