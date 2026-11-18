#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/image-digests.sh
source "$ROOT_DIR/scripts/lib/image-digests.sh"
cd "$ROOT_DIR"

phase=${1:-}
[[ $# == 1 && ( $phase == build || $phase == evidence ) ]] || {
  echo 'Usage: build-release-images.sh build|evidence' >&2; exit 1;
}
images="$ROOT_DIR/artifacts/release-images"
evidence="$ROOT_DIR/artifacts/release-evidence"
metadata="$ROOT_DIR/artifacts/release-build.json"
components=(catcar-app catcar-auth-function catcar-database-infra catcar-kubernetes-infra)
platform_sha=$(git rev-parse HEAD)
[[ -z ${GITHUB_SHA:-} || $platform_sha == "$GITHUB_SHA" ]] || { echo 'Platform SHA does not match GITHUB_SHA' >&2; exit 1; }
[[ -z $(git status --porcelain --untracked-files=normal -- . ':(exclude)artifacts') ]] || { echo 'Platform checkout is dirty' >&2; exit 1; }
declare -A shas
for component in "${components[@]}"; do
  expected=$(git ls-tree "$platform_sha" -- "$component" | awk '$1 == "160000" && $2 == "commit" {print $3}')
  actual=$(git -C "$component" rev-parse HEAD)
  [[ -n $expected && $actual == "$expected" ]] || { echo "Component $component does not match its gitlink" >&2; exit 1; }
  [[ -z $(git -C "$component" status --porcelain --untracked-files=normal) ]] || { echo "Component $component is dirty" >&2; exit 1; }
  shas[$component]=$actual
done

if [[ $phase == build ]]; then
  mkdir -p "$images" "$evidence"
  rm -f "$evidence/release-evidence.json" "$metadata"
  api_tag="localhost:5001/catcar-api:${shas[catcar-app]}"
  auth_tag="localhost:5001/catcar-auth-function:${shas[catcar-auth-function]}"
  docker build -t "$api_tag" catcar-app
  docker build -t "$auth_tag" catcar-auth-function
  docker save -o "$images/api.tar" "$api_tag"
  docker save -o "$images/auth-function.tar" "$auth_tag"
  (cd "$images" && sha256sum api.tar auth-function.tar > SHA256SUMS)
  jq -n --arg sha "$platform_sha" --arg sdk "$(dotnet --version)" \
    --arg app "${shas[catcar-app]}" --arg auth "${shas[catcar-auth-function]}" \
    --arg database "${shas[catcar-database-infra]}" --arg kubernetes "${shas[catcar-kubernetes-infra]}" \
    '{platformSha:$sha,sdk:$sdk,componentShas:{"catcar-app":$app,"catcar-auth-function":$auth,"catcar-database-infra":$database,"catcar-kubernetes-infra":$kubernetes}}' > "$metadata"
else
  # Called only after both archive scans succeed in the same CI job.
  [[ -f $metadata ]] || { echo 'Missing build metadata' >&2; exit 1; }
  jq -e --arg sha "$platform_sha" '.platformSha == $sha' "$metadata" >/dev/null || { echo 'Platform SHA changed after image build' >&2; exit 1; }
  for component in "${components[@]}"; do
    jq -e --arg component "$component" --arg sha "${shas[$component]}" '.componentShas[$component] == $sha' "$metadata" >/dev/null || { echo "Component $component changed after image build" >&2; exit 1; }
  done
  (cd "$images" && sha256sum -c SHA256SUMS)
  api_config=$(image_archive_config_digest "$images/api.tar")
  auth_config=$(image_archive_config_digest "$images/auth-function.tar")
  jq --arg api "$api_config" --arg auth "$auth_config" \
    '. + {dirty:false,imageConfigDigests:{api:$api,authFunction:$auth},checks:{componentChecks:true,pinnedIntegration:true,trivy:true}}' \
    "$metadata" > "$evidence/release-evidence.json"
fi
