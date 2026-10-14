#!/usr/bin/env bash
# Packages every APIM artifact into target/apim/ (one archive each), offline.
# Fails if any OpenAPI definition is out of sync or any bundle cannot be built.
set -euo pipefail
cd "$(dirname "$0")/.."

APICTL="bash scripts/apictl.sh"
OUT=target/apim
rm -rf "$OUT" && mkdir -p "$OUT"

# The hand-written OpenAPI files are the source of truth; copy them into the apictl projects.
declare -A SPEC=( [AccountsAPI]=accounts [CustomersAPI]=customers [LoansAPI]=loans )
for api in "${!SPEC[@]}"; do
  cp "apim/openapi/${SPEC[$api]}.yaml" "apim/apis/$api/Definitions/swagger.yaml"
done

bundle() {  # bundle <source-dir>
  echo "Bundling $1"
  $APICTL bundle -s "$1" -d "$OUT" >/dev/null || { echo "FAIL: could not bundle $1"; exit 1; }
}
for api in AccountsAPI CustomersAPI LoansAPI; do bundle "apim/apis/$api"; done
bundle apim/products/JamiiSavingsProduct
bundle apim/policies/jamiiCorrelationId
cp apim/throttling/*.yaml "$OUT/"
cp -r apim/params "$OUT/params"

ls -1 "$OUT"
echo "OK: APIM artifacts packaged in $OUT"
