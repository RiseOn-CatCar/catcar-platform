#!/usr/bin/env bash
set -euo pipefail

fail() { echo "component checks: $*" >&2; exit 1; }
[[ $# == 2 && $1 == --repository-root && -n $2 ]] || fail 'required: --repository-root <path>'
root=$(cd "$2" && pwd -P) || fail 'repository root not found'
[[ $(git -C "$root" rev-parse --show-toplevel) == "$root" ]] || fail 'path is not repository root'
: "${GH_TOKEN:?GH_TOKEN is required to read component workflow runs}"

# Query the latest push-main run for each exact gitlink, including all pages.
deadline=$((SECONDS + 1200))
for component in catcar-app catcar-auth-function catcar-database-infra catcar-kubernetes-infra; do
  entry=$(git -C "$root" ls-tree HEAD -- "$component")
  [[ $entry =~ ^160000\ commit\ ([0-9a-f]{40})$'\t' ]] || fail "missing gitlink: $component"
  sha=${BASH_REMATCH[1]}
  [[ $(git -C "$root/$component" rev-parse HEAD) == "$sha" ]] || fail "checkout does not match gitlink: $component"
  workflow=ci-cd.yml
  case "$component" in
    catcar-app) workflow=ci.yml; required='["Build & Test","Opengrep SAST Scan","Security Scan","Docker Build & Scan","Validate Aspire Publish Model"]';;
    catcar-auth-function) required='["build-and-test","validate-infra"]';;
    catcar-database-infra) required='["validate"]';;
    catcar-kubernetes-infra) required='["validate-k8s","validate-alerts"]';;
  esac
  repo="RiseOn-CatCar/$component"
  while :; do
    runs=$(gh api --paginate "repos/$repo/actions/workflows/$workflow/runs?branch=main&event=push&head_sha=$sha&per_page=100" | jq -s '[.[].workflow_runs[]]') || fail "cannot read workflow runs for $repo"
    run=$(jq -c --arg sha "$sha" '[.[] | select(.head_sha == $sha and .head_branch == "main" and .event == "push")] | sort_by(.created_at, .id) | last // empty' <<<"$runs")
    if [[ -n $run ]]; then
      status=$(jq -r '.status' <<<"$run")
      if [[ $status == completed ]]; then
        conclusion=$(jq -r '.conclusion' <<<"$run")
        [[ $conclusion == success ]] || fail "$repo at $sha concluded $conclusion"
        id=$(jq -r '.id' <<<"$run")
        jobs=$(gh api --paginate "repos/$repo/actions/runs/$id/jobs?filter=latest&per_page=100" | jq -s '[.[].jobs[]]') || fail "cannot read jobs for $repo run $id"
        jq -e --argjson required "$required" --argjson jobs "$jobs" 'all($required[]; . as $name | any($jobs[]; .name == $name and .status == "completed" and .conclusion == "success"))' <<<null >/dev/null || fail "$repo run $id is missing a successful required job"
        echo "$repo $sha: required jobs passed (run $id)"
        break
      fi
    fi
    ((SECONDS < deadline)) || fail "timed out waiting for push-main checks for $repo at $sha"
    echo "Waiting for push-main checks for $repo at $sha" >&2
    sleep 15
  done
done
