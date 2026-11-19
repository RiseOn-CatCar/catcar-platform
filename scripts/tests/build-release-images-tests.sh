#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/scripts/lib" "$TMP/bin" "$TMP/image"
cp "$ROOT/scripts/build-release-images.sh" "$TMP/repo/scripts/"
cp "$ROOT/scripts/lib/image-digests.sh" "$TMP/repo/scripts/lib/"
printf '{"architecture":"amd64","os":"linux"}' > "$TMP/image/config.json"
printf '[{"Config":"config.json","RepoTags":[],"Layers":[]}]' > "$TMP/image/manifest.json"
export PATH="$TMP/bin:$PATH" TEST_TMP="$TMP" GITHUB_SHA=1111111111111111111111111111111111111111
cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' status '*) [[ ${DIRTY:-false} == false ]] || echo dirty ;;
  *' ls-tree '*) printf '160000 commit %s\t%s\n' "$GITHUB_SHA" "${*: -1}" ;;
  *' rev-parse '*) echo "$GITHUB_SHA" ;;
  *) exit 1 ;;
esac
SH
cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  build) echo build >> "$TEST_TMP/builds" ;;
  save) tar -cf "$3" -C "$TEST_TMP/image" manifest.json config.json ;;
  *) exit 1 ;;
esac
SH
cat > "$TMP/bin/dotnet" <<'SH'
#!/usr/bin/env bash
echo 11.0.100
SH
chmod +x "$TMP/bin/"*
builder="$TMP/repo/scripts/build-release-images.sh"
bash "$builder" build
[[ $(wc -l < "$TMP/builds") == 2 ]]
bash "$builder" evidence
jq -e --arg sha "$GITHUB_SHA" '.platformSha == $sha and .dirty == false and .checks == {componentChecks:true,pinnedIntegration:true,trivy:true} and (.imageConfigDigests.api | startswith("sha256:"))' "$TMP/repo/artifacts/release-evidence/release-evidence.json" >/dev/null
printf x >> "$TMP/repo/artifacts/release-images/api.tar"
if bash "$builder" evidence >/dev/null 2>&1; then echo 'FAIL tampered archive accepted' >&2; exit 1; fi
if DIRTY=true bash "$builder" build >/dev/null 2>&1; then echo 'FAIL dirty checkout accepted' >&2; exit 1; fi
echo 'PASS release image builder'
