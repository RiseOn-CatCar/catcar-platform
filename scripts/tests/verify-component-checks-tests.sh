#!/usr/bin/env bash
# shellcheck disable=SC2016 # The jq programs expand variables in jq, not in Bash.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo"
export PATH="$TMP/bin:$PATH" TEST_ROOT="$TMP/repo" TEST_TMP="$TMP" GH_TOKEN=test
export TEST_SHA=0123456789abcdef0123456789abcdef01234567
cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
case "$3" in
  rev-parse) if [[ ${4:-} == --show-toplevel ]]; then printf '%s\n' "$TEST_ROOT"; else printf '%s\n' "$TEST_SHA"; fi;;
  ls-tree) printf '160000 commit %s\t%s\n' "$TEST_SHA" "$6";;
  *) exit 1;;
esac
SH
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
[[ $1 == api && $2 == --paginate ]] || exit 1
printf '%s\n' "$3" >> "$TEST_TMP/queries"
case "$3" in
  *'/actions/workflows/'*)
    jq -n --arg sha "${RUN_SHA:-$TEST_SHA}" --arg branch "${RUN_BRANCH:-main}" --arg event "${RUN_EVENT:-push}" '{workflow_runs:[{id:1,head_sha:$sha,head_branch:$branch,event:$event,status:"completed",conclusion:"success",created_at:"2026-01-01T00:00:00Z"}]}'
    ;;
  *'/actions/runs/1/jobs?'*)
    jq -n --arg job "${BAD_JOB:-}" --arg kind "${BAD_KIND:-}" '
      {jobs: (["Build & Test", "Opengrep SAST Scan", "Security Scan", "Docker Build & Scan", "Validate Aspire Publish Model", "build-and-test", "validate-infra", "validate", "validate-k8s", "validate-alerts"]
        | map(select(. != $job or $kind != "missing") | {name:., status:"completed", conclusion:(if . == $job and ($kind == "skipped" or $kind == "cancelled") then $kind else "success" end)}))}'
    ;;
  *) exit 1;;
esac
SH
cat > "$TMP/bin/sleep" <<'SH'
#!/usr/bin/env bash
# Stop immediately once a rejected run enters the polling loop.
exit 1
SH
chmod +x "$TMP/bin/"*

expect_success() {
  local name=$1; shift
  : > "$TMP/queries"
  if ! "$@" > "$TMP/output" 2>&1; then
    echo "FAIL $name" >&2; cat "$TMP/output" >&2; exit 1
  fi
  [[ $(grep -c '/actions/runs/1/jobs?' "$TMP/queries") == 4 ]] || { echo "FAIL $name: expected four job queries" >&2; exit 1; }
  echo "PASS $name"
}
expect_failure() {
  local name=$1 expected=$2; shift 2
  : > "$TMP/queries"
  if "$@" > "$TMP/output" 2>&1; then
    echo "FAIL $name: unexpectedly succeeded" >&2; exit 1
  fi
  grep -Fq "$expected" "$TMP/output" || { echo "FAIL $name: expected $expected" >&2; cat "$TMP/output" >&2; exit 1; }
  echo "PASS $name"
}
verify=(bash "$ROOT/scripts/verify-component-checks.sh" --repository-root "$TMP/repo")
expect_success release-default "${verify[@]}"
expect_success release-explicit "${verify[@]}" --mode release
expect_success pr-pull-request env RUN_EVENT=pull_request RUN_BRANCH=feature "${verify[@]}" --mode pull-request
expect_success pr-push env RUN_EVENT=push RUN_BRANCH=feature "${verify[@]}" --mode pull-request
expect_failure release-wrong-event 'Waiting for release checks' env RUN_EVENT=pull_request "${verify[@]}" --mode release
expect_failure release-wrong-branch 'Waiting for release checks' env RUN_BRANCH=feature "${verify[@]}" --mode release
expect_failure pr-wrong-event 'Waiting for pull-request checks' env RUN_EVENT=workflow_dispatch "${verify[@]}" --mode pull-request
expect_failure pr-wrong-sha 'Waiting for pull-request checks' env RUN_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "${verify[@]}" --mode pull-request
for mode in release pull-request; do
  for kind in skipped missing cancelled; do
    expect_failure "$mode-$kind" 'missing a successful required job' env BAD_JOB='Build & Test' BAD_KIND="$kind" "${verify[@]}" --mode "$mode"
  done
done
expect_failure invalid-mode 'invalid mode' "${verify[@]}" --mode invalid
