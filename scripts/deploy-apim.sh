#!/usr/bin/env bash
# Imports/updates all APIM artifacts for one environment, in dependency order:
#   throttling tier -> common gateway policy -> 3 APIs (published) -> API Product
# Stops at the first failure (non-zero exit) and reports what was already applied.
#
#   scripts/deploy-apim.sh dev [bundle-dir]      bundle-dir defaults to target/apim (from package-apim.sh)
#
# Env: APIM_URL (default https://apim:9443, i.e. the compose service as seen by containerised apictl),
#      APIM_USER / APIM_PASS (default admin/admin for the local stack; Jenkins injects credentials).
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_NAME="${1:?usage: deploy-apim.sh <dev|prod> [bundle-dir]}"
SRC="${2:-target/apim}"
APIM_URL="${APIM_URL:-https://apim:9443}"
APICTL="bash scripts/apictl.sh"
APIS=(AccountsAPI CustomersAPI LoansAPI)
DONE=()

fail() {
  echo "FAIL: $1"
  echo "Applied before the failure: ${DONE[*]:-nothing}"
  exit 1
}
[[ -d "$SRC" ]] || fail "bundle dir $SRC not found (run scripts/package-apim.sh)"

$APICTL remove env "$ENV_NAME" >/dev/null 2>&1 || true
$APICTL add env "$ENV_NAME" --apim "$APIM_URL" >/dev/null
$APICTL login "$ENV_NAME" -u "${APIM_USER:-admin}" -p "${APIM_PASS:-admin}" -k >/dev/null 2>&1 || fail "login to $APIM_URL"

# 1. Custom subscription tier (idempotent with -u)
for f in "$SRC"/Subscription-*.yaml; do
  $APICTL import policy rate-limiting -f "$f" -u -e "$ENV_NAME" -k >/dev/null || fail "throttling policy $f"
  DONE+=("tier:$(basename "$f" .yaml)")
done

# 2. Common gateway policy. apictl has no update for API policies: an existing policy with the
#    same name+version is left as-is (change a policy => bump its version).
out=$($APICTL import policy api -f "$SRC"/jamiiCorrelationId*.zip -e "$ENV_NAME" -k 2>&1) \
  || grep -q 'already exists' <<<"$out" || fail "gateway policy jamiiCorrelationId: $out"
DONE+=("policy:jamiiCorrelationId")

# 3. APIs (lifecycle PUBLISHED in api.yaml; env-specific endpoints from params)
for api in "${APIS[@]}"; do
  echo "Importing $api -> $ENV_NAME"
  $APICTL import api -f "$SRC/${api}_v1.zip" -e "$ENV_NAME" --params "$SRC/params/$api.yaml" \
    --update --preserve-provider=true -k || fail "API $api"
  DONE+=("api:$api")
done

# 4. API Product (references the APIs above by name/version)
$APICTL import api-product -f "$SRC/JamiiSavingsProduct_v1.zip" -e "$ENV_NAME" \
  --update-api-product --preserve-provider=true -k || fail "API Product JamiiSavingsProduct"
DONE+=("product:JamiiSavingsProduct")

# 5. Verify: every API is PUBLISHED
listing=$($APICTL get apis -e "$ENV_NAME" -k)
for api in "${APIS[@]}"; do
  grep -E "^\S+\s+$api\s+v1\s+.*PUBLISHED" <<<"$listing" >/dev/null || fail "$api is not PUBLISHED in $ENV_NAME"
done
echo "$listing"
echo "OK: APIM $ENV_NAME updated (${DONE[*]})"
