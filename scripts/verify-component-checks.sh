#!/usr/bin/env bash
set -euo pipefail

fail() { echo "component checks: $*" >&2; exit 1; }
root='' mode=release
while (($#)); do
  case "$1" in
    --repository-root|--mode)
      (($# >= 2)) || fail "missing value for $1"
      case "$1" in --repository-root) root=$2;; --mode) mode=$2;; esac
      shift 2;;
    *) fail "unknown argument: $1";;
  esac
done
[[ -n $root ]] || fail 'required: --repository-root <path>'
case "$mode" in release) timeout=1200;; pull-request) timeout=600;; *) fail "invalid mode: $mode";; esac
root=$(cd "$root" && pwd -P) || fail 'repository root not found'
[[ $(git -C "$root" rev-parse --show-toplevel) == "$root" ]] || fail 'path is not repository root'
: "${GH_TOKEN:?GH_TOKEN is required to read component workflow runs}"

# Query the latest eligible run for each exact gitlink, including all pages.
deadline=$((SECONDS + timeout))
for component in catcar-os-service catcar-auth-function catcar-database-infra catcar-kubernetes-infra catcar-billing-service catcar-execution-service; do
  entry=$(git -C "$root" ls-tree HEAD -- "$component")
  [[ $entry =~ ^160000\ commit\ ([0-9a-f]{40})$'\t' ]] || fail "missing gitlink: $component"
  sha=${BASH_REMATCH[1]}
  [[ $(git -C "$root/$component" rev-parse HEAD) == "$sha" ]] || fail "checkout does not match gitlink: $component"
  workflow=ci-cd.yml
  case "$component" in
    catcar-auth-function) required='["build-and-test","validate-infra"]';;
    catcar-database-infra) required='["validate"]';;
    catcar-kubernetes-infra) required='["validate-k8s","validate-alerts"]';;
    catcar-os-service|catcar-billing-service|catcar-execution-service) workflow=ci.yml; required='["build-test","security","deploy-kind"]';;
  esac
  repo="RiseOn-CatCar/$component"
  while :; do
    query="repos/$repo/actions/workflows/$workflow/runs?head_sha=$sha&per_page=100"
    if [[ $mode == release ]]; then
      query="repos/$repo/actions/workflows/$workflow/runs?branch=main&event=push&head_sha=$sha&per_page=100"
    fi
    runs=$(gh api --paginate "$query" | jq -s '[.[].workflow_runs[]]') || fail "cannot read workflow runs for $repo"
    run=$(jq -c --arg sha "$sha" --arg mode "$mode" '[.[] | select(.head_sha == $sha and (if $mode == "release" then .head_branch == "main" and .event == "push" else .event == "pull_request" or .event == "push" end))] | sort_by(.created_at, .id) | last // empty' <<<"$runs")
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
    ((SECONDS < deadline)) || fail "timed out waiting for $mode checks for $repo at $sha"
    echo "Waiting for $mode checks for $repo at $sha" >&2
    sleep 15
  done
done
