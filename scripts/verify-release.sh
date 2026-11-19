#!/usr/bin/env bash
set -euo pipefail

fail() { echo "release verification: $*" >&2; exit 1; }
tag='' commit='' root=''
while (($#)); do
  case "$1" in
    --tag|--commit|--repository-root)
      (($# >= 2)) || fail "missing value for $1"
      case "$1" in --tag) tag=$2;; --commit) commit=$2;; --repository-root) root=$2;; esac
      shift 2;;
    *) fail "unknown argument: $1";;
  esac
done
[[ -n $tag && -n $commit && -n $root ]] || fail 'required: --tag, --commit and --repository-root'
[[ $tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "invalid release tag: $tag"
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail 'commit must be a full lowercase SHA'
root=$(cd "$root" && pwd -P) || fail 'repository root not found'
[[ $(git -C "$root" rev-parse --show-toplevel) == "$root" ]] || fail 'path is not repository root'
actual=$(git -C "$root" rev-parse --verify "refs/tags/$tag^{commit}") || fail 'tag not found'
[[ $actual == "$commit" ]] || fail 'tag does not point to supplied commit'
git -C "$root" fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main
git -C "$root" merge-base --is-ancestor "$commit" refs/remotes/origin/main || fail 'platform commit is not on origin/main'
for component in catcar-app catcar-auth-function catcar-database-infra catcar-kubernetes-infra; do
  entry=$(git -C "$root" ls-tree "$commit" -- "$component")
  [[ $entry =~ ^160000\ commit\ ([0-9a-f]{40})$'\t' ]] || fail "missing gitlink: $component"
  sha=${BASH_REMATCH[1]}
  [[ -d $root/$component ]] || fail "missing checkout: $component"
  [[ $(git -C "$root/$component" rev-parse --show-toplevel) == "$root/$component" ]] || fail "uninitialized submodule: $component"
  [[ $(git -C "$root/$component" rev-parse HEAD) == "$sha" ]] || fail "checkout does not match gitlink: $component"
  git -C "$root/$component" fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main
  git -C "$root/$component" merge-base --is-ancestor "$sha" refs/remotes/origin/main || fail "$component gitlink is not on origin/main"
done
echo "Release $tag at $commit and all gitlinks are on their main branches."
