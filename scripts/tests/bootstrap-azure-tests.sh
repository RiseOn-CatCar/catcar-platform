#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH" TEST_TMP="$TMP"
cat > "$TMP/bin/az" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_TMP/az-calls"
case "$1 $2" in
  'account show') echo test-id ;;
  'provider show')
    if [[ $4 == Microsoft.Compute ]]; then echo Registered; else echo NotRegistered; fi ;;
  'provider register') [[ $* == *'--subscription test-id'* && $* == *'--wait'* ]] || exit 1 ;;
  'group exists') echo 'stopped after provider registration' >&2; exit 99 ;;
  *) echo "Unexpected az call: $*" >&2; exit 1 ;;
esac
SH
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'actions/oidc/customization/sub'*) echo 'repo:RiseOn-CatCar@330941078/catcar-platform@1376139605' ;;
  *'environments?per_page=100'*) : ;;
  *'.owner.id'*) echo 330941078 ;;
  *'.id'*) echo 1376139605 ;;
  *) echo "Unexpected gh call: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$TMP/bin/az" "$TMP/bin/gh"
export STATE_PREFLIGHT_CONFIRMED=true APIM_PUBLISHER_NAME=test APIM_PUBLISHER_EMAIL=test@example.com CATCAR_ALERT_EMAIL=test@example.com
export POSTGRES_ADMIN_PASSWORD=123456789012 POSTGRES_AUTH_READONLY_PASSWORD=123456789012
export JWT_SECRET=12345678901234567890123456789012 CUSTOMER_JWT_SIGNING_KEY=12345678901234567890123456789012
export BOOTSTRAP_ADMIN_EMAIL=test@example.com BOOTSTRAP_ADMIN_PASSWORD=test SMOKE_CUSTOMER_EMAIL=test@example.com
bootstrap=(bash "$ROOT/scripts/bootstrap-azure.sh" --env-file "$TMP/no-env" --bootstrap-principal-object-id 00000000-0000-0000-0000-000000000000)
"${bootstrap[@]}" --dry-run > "$TMP/output" 2>&1
if grep -q '^provider ' "$TMP/az-calls"; then echo 'FAIL dry-run touched providers' >&2; exit 1; fi
echo 'PASS dry-run does not register providers'
: > "$TMP/az-calls"
if "${bootstrap[@]}" --apply > "$TMP/output" 2>&1; then echo 'FAIL apply should stop at mocked group operation' >&2; exit 1; fi
grep -Fq 'stopped after provider registration' "$TMP/output" || { cat "$TMP/output" >&2; exit 1; }
providers=(Microsoft.AlertsManagement Microsoft.ApiManagement Microsoft.App Microsoft.Authorization Microsoft.Communication Microsoft.Compute Microsoft.ContainerRegistry Microsoft.ContainerService Microsoft.DBforPostgreSQL Microsoft.Insights Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.Network Microsoft.OperationalInsights Microsoft.Storage)
for provider in "${providers[@]}"; do
  [[ $(grep -Fc "provider show --namespace $provider --subscription test-id" "$TMP/az-calls") == 1 ]] || { echo "FAIL provider lookup $provider" >&2; exit 1; }
  count=$(grep -Fc "provider register --namespace $provider --subscription test-id" "$TMP/az-calls" || true)
  if [[ $provider == Microsoft.Compute ]]; then expected=0; else expected=1; fi
  [[ $count == "$expected" ]] || { echo "FAIL provider registration $provider" >&2; exit 1; }
done
[[ $(grep -c '^provider show ' "$TMP/az-calls") == ${#providers[@]} ]] || { echo 'FAIL unexpected provider lookup' >&2; exit 1; }
[[ $(grep -c '^provider register ' "$TMP/az-calls") == $((${#providers[@]} - 1)) ]] || { echo 'FAIL unexpected provider registration' >&2; exit 1; }
echo 'PASS apply checks and registers missing providers'
