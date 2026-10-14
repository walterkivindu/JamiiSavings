#!/usr/bin/env bash
# Jamii Savings smoke tests: live curl calls against all three integrations.
# Doubles as the screen-recording walkthrough and the Jenkins "Test" stage.
#
#   bash tests/smoke.sh                 # functional checks against MI (docker-compose)
#   FAULT_TESTS=1 bash tests/smoke.sh   # + DB down, backend timeout/unavailable (restarts containers)
#
#   GATEWAY=1 bash tests/smoke.sh       # same checks through the APIM gateway: subscribes a test app via the
#                                       # Dev Portal REST API; OAuth2 for accounts/customers, API key for loans
set -uo pipefail
cd "$(dirname "$0")/.."

MI="${MI_URL:-http://localhost:8290}"
GW="${GW_URL:-https://localhost:8243}"
AUTH="X-Smoke: 1"   # per-section credential header (only meaningful through the gateway)
if [[ "${GATEWAY:-0}" == "1" ]]; then
  eval "$(python scripts/apim_consumer.py --apim "${APIM_PUBLIC_URL:-https://localhost:9443}")" || exit 1
  ACCOUNTS_BASE="$GW/accounts/v1"; CUSTOMERS_BASE="$GW/customers/v1"; LOANS_BASE="$GW/loans/v1"
  # Freshly generated keys take a few seconds to reach the gateway
  for _ in $(seq 1 20); do
    [[ $(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ACCESS_TOKEN" "$ACCOUNTS_BASE/1000000001/balance") == 200 ]] && break; sleep 2
  done
  for _ in $(seq 1 20); do
    [[ $(curl -sk -o /dev/null -w '%{http_code}' -H "apikey: $API_KEY" "$CUSTOMERS_BASE/1") == 200 ]] && break; sleep 2
  done
else
  ACCOUNTS_BASE="$MI/accounts"; CUSTOMERS_BASE="$MI/customers"; LOANS_BASE="$MI/loans"
fi
gw_auth() { if [[ "${GATEWAY:-0}" == "1" ]]; then AUTH="$1"; fi; }

PASS=0; FAIL=0; FAILED=()
c_green=$'\e[32m'; c_red=$'\e[31m'; c_dim=$'\e[2m'; c_bold=$'\e[1m'; c_off=$'\e[0m'

# check <name> <expected-status> <expected-substring-in-body> <curl args...>
check() {
  local name="$1" want="$2" needle="$3"; shift 3
  local out status body
  out=$(curl -sk --max-time 30 -H "$AUTH" -w $'\n%{http_code}' "$@")
  status="${out##*$'\n'}"; body="${out%$'\n'*}"
  printf '%s> %s%s\n' "$c_bold" "$name" "$c_off"
  printf '%s  curl %s%s\n' "$c_dim" "$*" "$c_off"
  printf '  %s\n' "$body"
  if [[ "$status" == "$want" && "$body" == *"$needle"* ]]; then
    printf '  %sPASS%s HTTP %s\n\n' "$c_green" "$c_off" "$status"; PASS=$((PASS+1))
  else
    printf '  %sFAIL%s HTTP %s (want %s, body must contain %s)\n\n' "$c_red" "$c_off" "$status" "$want" "$needle"
    FAIL=$((FAIL+1)); FAILED+=("$name")
  fi
}

section() { printf '\n%s==== %s ====%s\n\n' "$c_bold" "$1" "$c_off"; }

# check_post <name> <expected-status> <expected-substring> <json-body> <url>
check_post() { check "$1" "$2" "$3" -H "Content-Type: application/json" -X POST --data-raw "$4" "$5"; }

redeploy_mi() {  # redeploy MI with extra env (for backend fault injection), quietly
  env "$@" bash scripts/deploy-mi.sh >/dev/null 2>&1 || { echo "MI redeploy failed"; exit 1; }
}

# ---------------------------------------------------------------------------
section "1a  GET /accounts/{accountNumber}/balance  (MySQL via data service)"
gw_auth "Authorization: Bearer ${ACCESS_TOKEN:-}"
check "ACTIVE account"            200 '"status":"ACTIVE"'            "$ACCOUNTS_BASE/1000000001/balance"
check "DORMANT account"           200 '"status":"DORMANT"'           "$ACCOUNTS_BASE/1000000002/balance"
check "CLOSED account"            200 '"status":"CLOSED"'            "$ACCOUNTS_BASE/1000000003/balance"
check "Large balance stays numeric" 200 '"amount":987654321.50'      "$ACCOUNTS_BASE/1000000004/balance"
check "Unknown account -> 404"    404 '"code":"ACCOUNT_NOT_FOUND"'   "$ACCOUNTS_BASE/1000000099/balance"
check "Malformed number -> 400"   400 '"code":"INVALID_ACCOUNT_NUMBER"' "$ACCOUNTS_BASE/abc/balance"
check "Too short -> 400"          400 '"code":"INVALID_ACCOUNT_NUMBER"' "$ACCOUNTS_BASE/12345/balance"

section "1b  GET /customers/{customerId}  (proxy to JSONPlaceholder)"
gw_auth "Authorization: Bearer ${ACCESS_TOKEN:-}"
check "Existing customer"         200 '"id": 1'                      "$CUSTOMERS_BASE/1"
check "Unknown customer -> 404"   404 '"code":"CUSTOMER_NOT_FOUND"'  "$CUSTOMERS_BASE/999"
check "Malformed id -> 400"       400 '"code":"INVALID_CUSTOMER_ID"' "$CUSTOMERS_BASE/abc"
hdrs=$(curl -sk --max-time 30 -H "$AUTH" -D - -o /dev/null -H "X-Correlation-ID: smoke-corr-42" "$CUSTOMERS_BASE/2")
printf '%s> Caller correlation ID is echoed back%s\n' "$c_bold" "$c_off"
if grep -qi '^X-Correlation-ID: smoke-corr-42' <<<"$hdrs"; then printf '  %sPASS%s\n\n' "$c_green" "$c_off"; PASS=$((PASS+1));
else printf '  %sFAIL%s\n%s\n' "$c_red" "$c_off" "$hdrs"; FAIL=$((FAIL+1)); FAILED+=("correlation echo"); fi
hdrs=$(curl -sk --max-time 30 -H "$AUTH" -D - -o /dev/null "$CUSTOMERS_BASE/3")
printf '%s> Correlation ID generated when missing; no backend cookies leaked%s\n' "$c_bold" "$c_off"
if grep -qi '^X-Correlation-ID: [0-9a-f-]\{36\}' <<<"$hdrs" && ! grep -qi '^Set-Cookie' <<<"$hdrs"; then printf '  %sPASS%s\n\n' "$c_green" "$c_off"; PASS=$((PASS+1));
else printf '  %sFAIL%s\n%s\n' "$c_red" "$c_off" "$hdrs"; FAIL=$((FAIL+1)); FAILED+=("correlation generate"); fi

section "1c  POST /loans/eligibility  (JSON -> SOAP Calculator -> JSON)"
gw_auth "apikey: ${API_KEY:-}"
check_post "Eligible applicant" 200 '"eligible":true' '{"customerId":"CUST-1001","monthlyIncome":120000,"monthlyObligations":20000,"requestedAmount":500000,"termMonths":12}' "$LOANS_BASE/eligibility"
check_post "Not eligible applicant" 200 '"eligible":false' '{"customerId":"CUST-1002","monthlyIncome":50000,"monthlyObligations":30000,"requestedAmount":500000,"termMonths":12}' "$LOANS_BASE/eligibility"
check_post "SOAP Fault -> 502, no XML" 502 '"code":"UPSTREAM_FAULT"' '{"customerId":"CUST-1003","monthlyIncome":120000,"monthlyObligations":20000,"requestedAmount":5000000000,"termMonths":12}' "$LOANS_BASE/eligibility"
check_post "termMonths 0 -> 400" 400 '"code":"INVALID_REQUEST"' '{"customerId":"CUST-1004","monthlyIncome":120000,"monthlyObligations":20000,"requestedAmount":500000,"termMonths":0}' "$LOANS_BASE/eligibility"
check_post "Missing fields -> 400" 400 '"code":"INVALID_REQUEST"' '{"customerId":"CUST-1005","monthlyIncome":120000}' "$LOANS_BASE/eligibility"
check "Invalid JSON -> 400"       400 '"code":"INVALID_REQUEST"' -H "Content-Type: application/json" -X POST --data-raw '{"customerId": oops' "$LOANS_BASE/eligibility"

# ---------------------------------------------------------------------------
if [[ "${FAULT_TESTS:-0}" == "1" ]]; then
  section "Fault injection (restarts containers)"
  gw_auth "Authorization: Bearer ${ACCESS_TOKEN:-}"
  docker stop jamii-mysql >/dev/null
  check "DB down -> 503 DB_UNAVAILABLE" 503 '"code":"DB_UNAVAILABLE"' "$ACCOUNTS_BASE/1000000001/balance"
  docker start jamii-mysql >/dev/null
  for _ in $(seq 1 30); do docker exec jamii-mysql mysqladmin ping -ujamii -pjamiipw >/dev/null 2>&1 && break; sleep 2; done

  redeploy_mi CUSTOMERS_BACKEND_URL='https://postman-echo.com/delay/8?id={uri.var.customerId}'
  check "Customers backend slow -> 504" 504 '"code":"BACKEND_TIMEOUT"' "$CUSTOMERS_BASE/1"
  redeploy_mi CUSTOMERS_BACKEND_URL='http://no-such-host.invalid/users/{uri.var.customerId}' CALCULATOR_SOAP_URL='http://no-such-host.invalid/calculator.asmx'
  check "Customers backend down -> 503" 503 '"code":"BACKEND_UNAVAILABLE"' "$CUSTOMERS_BASE/1"
  gw_auth "apikey: ${API_KEY:-}"
  check_post "SOAP backend down -> 503" 503 '"code":"BACKEND_UNAVAILABLE"' '{"customerId":"CUST-1001","monthlyIncome":120000,"monthlyObligations":20000,"requestedAmount":500000,"termMonths":12}' "$LOANS_BASE/eligibility"
  redeploy_mi
  gw_auth "Authorization: Bearer ${ACCESS_TOKEN:-}"
  check "Back to normal after restore"  200 '"status":"ACTIVE"' "$ACCOUNTS_BASE/1000000001/balance"
fi

if [[ "${GATEWAY:-0}" == "1" ]]; then
  section "APIM gateway: security schemes and API Product"
  gw_auth "apikey: ${API_KEY:-}"
  check "Accounts rejects an API key (OAuth2 only)" 401 '900902' "$ACCOUNTS_BASE/1000000001/balance"
  gw_auth "Authorization: Bearer ${ACCESS_TOKEN:-}"
  check_post "Loans rejects an OAuth2 token (API key only)" 401 '900902' '{}' "$LOANS_BASE/eligibility"
  check "API Product /jamii/v1 -> accounts" 200 '"status":"ACTIVE"' "$GW/jamii/v1/1000000001/balance"
fi

# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q '^jamii-mi$'; then
  section "Log hygiene (MI container logs)"
  printf '%s> No raw account numbers, customer ids or emails in MI logs%s\n' "$c_bold" "$c_off"
  leaks=$(docker logs jamii-mi 2>&1 | grep -E '10000000[0-9]{2}|CUST-10|Sincere@|Shanna@' | head -5)
  if [[ -z "$leaks" ]]; then printf '  %sPASS%s\n' "$c_green" "$c_off"; PASS=$((PASS+1));
  else printf '  %sFAIL%s\n%s\n' "$c_red" "$c_off" "$leaks"; FAIL=$((FAIL+1)); FAILED+=("log masking"); fi
  docker logs jamii-mi 2>&1 | grep -E 'REQUEST_IN|ERROR_RESPONSE' | tail -3 | cut -c1-220 | sed 's/^/  /'
fi

printf '\n%sResult: %d passed, %d failed%s\n' "$c_bold" "$PASS" "$FAIL" "$c_off"
if (( FAIL > 0 )); then printf '  failed: %s\n' "${FAILED[@]}"; exit 1; fi
