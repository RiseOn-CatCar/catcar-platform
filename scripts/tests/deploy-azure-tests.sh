#!/usr/bin/env bash
# shellcheck disable=SC2016 # The bash -c programs expand in the child shell.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/artifacts/kind-images" "$TMP/artifacts/kind-evidence" "$TMP/fake/catcar-app/scripts"
export PATH="$TMP/bin:$PATH" TEST_TMP="$TMP"
cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%040d\n' 1
SH
cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *' exec '* ]]; then
  [[ ${SQL_FAIL:-0} == 0 ]] || exit 1
  printf '%s\n' "${SQL_RESULT:-public.wolverine_incoming_envelopes|0}"
fi
SH
cat > "$TMP/bin/terraform" <<'SH'
#!/usr/bin/env bash
case " $* " in *' plan '*) exit 2;; *' show '*) printf '%s\n' "${PLAN_JSON:-{}}";; esac
SH
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP/fake/catcar-app/scripts/smoke-integrated.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP/bin/"* "$TMP/fake/catcar-app/scripts/smoke-integrated.sh"
export AZURE_TENANT_ID=x AZURE_SUBSCRIPTION_ID=x AZURE_DEPLOY_CLIENT_ID=x AZURE_LOCATION=x AZURE_TF_STATE_RG=x AZURE_TF_STATE_STORAGE_ACCOUNT=x TF_BACKEND_CONTAINER=x APIM_PUBLISHER_NAME=x APIM_PUBLISHER_EMAIL=x CATCAR_ALERT_EMAIL=x POSTGRES_ADMIN_PASSWORD=x POSTGRES_AUTH_READONLY_PASSWORD=x JWT_SECRET=x CUSTOMER_JWT_SIGNING_KEY=x BOOTSTRAP_ADMIN_EMAIL=x BOOTSTRAP_ADMIN_PASSWORD=x SMOKE_CUSTOMER_EMAIL=x GITHUB_REF_NAME=v1.2.3
export GITHUB_SHA; GITHUB_SHA=$(printf '%040d' 1)
mkdir -p "$TMP/docker" "$TMP/oci/blobs/sha256"
printf '{"architecture":"amd64","os":"linux"}' > "$TMP/docker/config.json"
jq -n '[{Config:"config.json",RepoTags:["localhost:5001/catcar-api:test"],Layers:[]}]' > "$TMP/docker/manifest.json"
tar -cf "$TMP/artifacts/kind-images/api.tar" -C "$TMP/docker" manifest.json config.json
config_hex=$(sha256sum "$TMP/docker/config.json"); config_hex=${config_hex%% *}
cp "$TMP/docker/config.json" "$TMP/oci/blobs/sha256/$config_hex"
jq -n --arg digest "sha256:$config_hex" '{schemaVersion:2,config:{mediaType:"application/vnd.oci.image.config.v1+json",digest:$digest},layers:[]}' > "$TMP/oci/manifest"
manifest_hex=$(sha256sum "$TMP/oci/manifest"); manifest_hex=${manifest_hex%% *}
mv "$TMP/oci/manifest" "$TMP/oci/blobs/sha256/$manifest_hex"
jq -n --arg digest "sha256:$manifest_hex" '{schemaVersion:2,manifests:[{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$digest}]}' > "$TMP/oci/index.json"
tar -cf "$TMP/artifacts/kind-images/auth-function.tar" -C "$TMP/oci" index.json blobs
(cd "$TMP/artifacts/kind-images" && sha256sum api.tar auth-function.tar > SHA256SUMS)
id="sha256:$(printf '%064d' 1)"
jq -n --arg sha "$GITHUB_SHA" --arg id "$id" --arg config "sha256:$config_hex" '{dirty:false,platformSha:$sha,componentShas:{"catcar-app":$sha,"catcar-auth-function":$sha,"catcar-database-infra":$sha,"catcar-kubernetes-infra":$sha},imageIds:{api:$id,authFunction:$id},imageConfigDigests:{api:$config,authFunction:$config},checks:{smoke:true}}' > "$TMP/artifacts/kind-evidence/validation.json"
expect_failure() {
  local label=$1 pattern=$2; shift 2
  if "$@" > "$TMP/out" 2>&1; then echo "FAIL $label: unexpectedly succeeded" >&2; exit 1; fi
  grep -q "$pattern" "$TMP/out" || { echo "FAIL $label: missing diagnostic $pattern" >&2; cat "$TMP/out" >&2; exit 1; }
  echo "PASS $label"
}
expect_failure missing-env POSTGRES_ADMIN_PASSWORD env -u POSTGRES_ADMIN_PASSWORD bash "$ROOT/scripts/deploy-azure.sh" --phase foundation --artifacts-dir "$TMP/artifacts" --check
expect_failure bad-phase 'Invalid or missing phase' bash "$ROOT/scripts/deploy-azure.sh" --phase invalid --artifacts-dir "$TMP/artifacts" --check
bash "$ROOT/scripts/deploy-azure.sh" --phase foundation --artifacts-dir "$TMP/artifacts" --check >/dev/null
echo 'PASS offline preflight'
jq '.dirty=true' "$TMP/artifacts/kind-evidence/validation.json" > "$TMP/dirty"; mv "$TMP/dirty" "$TMP/artifacts/kind-evidence/validation.json"
expect_failure dirty 'Invalid, dirty' bash "$ROOT/scripts/deploy-azure.sh" --phase foundation --artifacts-dir "$TMP/artifacts" --check
jq '.dirty=false' "$TMP/artifacts/kind-evidence/validation.json" > "$TMP/clean"; mv "$TMP/clean" "$TMP/artifacts/kind-evidence/validation.json"
jq 'del(.imageConfigDigests.api)' "$TMP/artifacts/kind-evidence/validation.json" > "$TMP/missing"; cp "$TMP/artifacts/kind-evidence/validation.json" "$TMP/original"; cp "$TMP/missing" "$TMP/artifacts/kind-evidence/validation.json"
expect_failure missing-config imageConfigDigests bash "$ROOT/scripts/deploy-azure.sh" --phase foundation --artifacts-dir "$TMP/artifacts" --check
jq --arg wrong "$id" '.imageConfigDigests.api=$wrong' "$TMP/original" > "$TMP/artifacts/kind-evidence/validation.json"
expect_failure archive-config-mismatch 'Image config digest mismatch' bash "$ROOT/scripts/deploy-azure.sh" --phase foundation --artifacts-dir "$TMP/artifacts" --check
cp "$TMP/original" "$TMP/artifacts/kind-evidence/validation.json"
expect_failure digest 'Image config digest mismatch' bash -c 'source "$1"; verify_image_id sha256:bad sha256:expected api' _ "$ROOT/scripts/deploy-azure.sh"
expect_failure pending 'queues are not drained' env SQL_RESULT='public.wolverine_incoming_envelopes|3' bash -c 'source "$1"; drain' _ "$ROOT/scripts/deploy-azure.sh"
expect_failure sql 'Wolverine drain SQL failed' env SQL_FAIL=1 bash -c 'source "$1"; drain' _ "$ROOT/scripts/deploy-azure.sh"
printf '%s\n' '{"resource_changes":[{"change":{"actions":["create","delete"]}}]}' > "$TMP/delete.json"
expect_failure replace 'delete or replacement' bash -c 'source "$1"; plan_is_safe "$2"' _ "$ROOT/scripts/deploy-azure.sh" "$TMP/delete.json"
printf '%s\n' '{"resource_changes":[{"change":{"actions":["delete"]}}]}' > "$TMP/delete.json"
expect_failure delete 'delete or replacement' bash -c 'source "$1"; plan_is_safe "$2"' _ "$ROOT/scripts/deploy-azure.sh" "$TMP/delete.json"
mkdir -p "$TMP/chart/templates/api"
cat > "$TMP/chart/templates/api/secrets.yaml" <<'YAML'
stringData:
  ConnectionStrings__catcar: "{{ .Values.secrets.api.connection }}"
  Jwt__Secret: "{{ .Values.secrets.api.jwt }}"
  CustomerJwt__SigningKey: "{{ .Values.secrets.api.customer }}"
  Communication__AzureCommunicationServicesConnectionString: "{{ .Values.secrets.api.communication }}"
YAML
for field in ConnectionStrings__catcar Jwt__Secret CustomerJwt__SigningKey; do printf '%s' value > "$TMP/$field"; done
bash -c 'source "$1"; TMP_DIR="$TEST_TMP"; Parameters__communication_connection_string=acs; write_helm_secret_values "$TMP_DIR/chart"; jq -e ".secrets.api | .connection == \"value\" and .jwt == \"value\" and .customer == \"value\" and .communication == \"acs\"" "$TMP_DIR/helm-values.json" >/dev/null' _ "$ROOT/scripts/deploy-azure.sh"
echo 'PASS private Helm values'
jq -n '{metadata:{annotations:{"meta.helm.sh/release-name":"catcar","meta.helm.sh/release-namespace":"catcar"}},spec:{selector:{matchLabels:{"app.kubernetes.io/component":"api","app.kubernetes.io/instance":"catcar","app.kubernetes.io/name":"catcar"}}}}' > "$TMP/legacy.json"
cat > "$TMP/selector-test.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
kubectl() { if [[ " $* " == *' get deployment '* ]]; then cat "$TEST_TMP/legacy.json"; elif [[ " $* " == *' delete deployment api-deployment '* ]]; then touch "$TEST_TMP/deleted"; else return 1; fi; }
read_pause() { echo "${PAUSE_VALUE:-true}"; }
prove_pause() { :; }
migrate_legacy_api_selector
SH
expect_failure unpaused-selector 'APIM must be paused' env PAUSE_VALUE=false bash "$TMP/selector-test.sh" "$ROOT/scripts/deploy-azure.sh"
[[ ! -f $TMP/deleted ]] || { echo 'FAIL unpaused selector was deleted' >&2; exit 1; }
bash "$TMP/selector-test.sh" "$ROOT/scripts/deploy-azure.sh"
[[ -f $TMP/deleted ]] || { echo 'FAIL legacy selector was not migrated' >&2; exit 1; }
rm "$TMP/deleted"
jq '.metadata.annotations["meta.helm.sh/release-name"]="other"' "$TMP/legacy.json" > "$TMP/foreign.json"; mv "$TMP/foreign.json" "$TMP/legacy.json"
expect_failure foreign-selector 'unexpected owner or selector' bash "$TMP/selector-test.sh" "$ROOT/scripts/deploy-azure.sh"
[[ ! -f $TMP/deleted ]] || { echo 'FAIL foreign selector was deleted' >&2; exit 1; }
echo 'PASS guarded legacy selector migration'
expect_failure smoke 'Azure smoke failed' bash -c '
  source "$1"; ROOT_DIR="$TEST_TMP/fake"; ARTIFACTS="$TEST_TMP/artifacts"; TMP_DIR="$TEST_TMP"; GATEWAY=https://example.invalid
  require_phase() { :; }; load_foundation() { RG=rg; }; read_pause() { echo true; }; set_pause() { echo "$1" >> "$TEST_TMP/pause-log"; }; tf_output() { echo value; }; tf_init() { :; }; tf_apply() { :; }
  phase_alerts_smoke
' _ "$ROOT/scripts/deploy-azure.sh"
[[ $(cat "$TMP/pause-log") == $'false\ntrue' ]] || { echo 'FAIL smoke did not re-pause' >&2; exit 1; }
echo 'PASS smoke re-pauses'
