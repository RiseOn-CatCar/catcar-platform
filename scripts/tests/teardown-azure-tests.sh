#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH" TEST_TMP="$TMP" AZURE_SUBSCRIPTION_ID=sub
cat > "$TMP/bin/az" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'account show') echo "${MOCK_SUB:-sub}" ;;
  'keyvault list'|'keyvault list-deleted'|'apim deletedservice'|'resource list'|'group list') echo '[]' ;;
  *) echo "unexpected az: $*" >&2; exit 1 ;;
esac
SH
cat > "$TMP/bin/mise" <<'SH'
#!/usr/bin/env bash
shift 3
exec "$@"
SH
cat > "$TMP/bin/terraform" <<'SH'
#!/usr/bin/env bash
root=${1#-chdir=}; shift
case "$root" in */alerts) root=alerts;; */catcar-auth-function/infra) root=function;; */catcar-database-infra) root=database;; *) root=foundation;; esac
command=$1; shift
printf '%s %s %s\n' "$root" "$command" "$*" >> "$TEST_TMP/log"
case "$command" in
 init) ;;
 state)
   if [[ $1 == list ]]; then
     if [[ ${EMPTY_ROOT:-} == "$root" ]]; then exit 0; fi
     if [[ $root == foundation ]]; then echo azurerm_resource_group.this; fi
     echo azurerm_virtual_network.this
   fi ;;
 plan) exit 2 ;;
 show)
   if [[ ${UNSAFE:-false} == true ]]; then type=azurerm_resource_group; else type=azurerm_virtual_network; fi
   jq -n --arg type "$type" '{resource_changes:[{mode:"managed",type:$type,address:($type+".this"),change:{actions:["delete"],before:{id:"/subscriptions/sub/resourceGroups/rg-catcar/providers/Microsoft.Network/virtualNetworks/test"}}}]}' ;;
 apply) ;;
 *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/"*
expect_fail() { local pattern=$1; shift; if "$@" > "$TMP/out" 2>&1; then echo "Expected failure: $pattern" >&2; exit 1; fi; grep -q -- "$pattern" "$TMP/out" || { cat "$TMP/out" >&2; exit 1; }; }
run() { /usr/bin/bash "$ROOT/scripts/teardown-azure.sh" "$@"; }
: > "$TMP/log"; run > "$TMP/out"
! grep -q ' apply ' "$TMP/log"
[[ $(awk '$2 == "plan" {print $1}' "$TMP/log" | paste -sd,) == alerts,function,database,foundation ]]
echo 'PASS dry run and order'
expect_fail 'requires --confirm' run --apply --yes
expect_fail 'subscription mismatch' env MOCK_SUB=other /usr/bin/bash "$ROOT/scripts/teardown-azure.sh"
expect_fail 'Unsafe deletion' env UNSAFE=true /usr/bin/bash "$ROOT/scripts/teardown-azure.sh"
echo 'PASS safety guards'
: > "$TMP/log"; run --apply --confirm rg-catcar --yes > "$TMP/out"
awk '$1 == "foundation" && $2 == "state" && $3 == "rm" {rmline=NR} $1 == "foundation" && $2 == "plan" {if (!rmline || rmline >= NR) exit 1; found=1} END {if (!found) exit 1}' "$TMP/log"
: > "$TMP/log"; EMPTY_ROOT=database run > "$TMP/out"
grep -q 'Empty state; skipped' "$TMP/out"
! grep -q '^database plan ' "$TMP/log"
echo 'PASS detach and empty state'
