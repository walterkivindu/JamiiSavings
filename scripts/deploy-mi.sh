#!/usr/bin/env bash
# Deploys target/JamiiSavings_1.0.0.car to the docker-compose MI runtime and
# fails unless the CAR is reported deployed with no artifact errors.
# Usage: scripts/deploy-mi.sh            (assumes `./mvnw clean install` already ran)
set -euo pipefail
cd "$(dirname "$0")/.."

CAR="target/JamiiSavings_1.0.0.car"
MGMT="${MI_MGMT_URL:-https://localhost:9164/management}"
[ -f "$CAR" ] || { echo "FAIL: $CAR not found, build first"; exit 1; }

docker compose up -d mysql
docker compose up -d --force-recreate mi

echo "Waiting for MI to start..."
for _ in $(seq 1 60); do
  if docker logs jamii-mi 2>&1 | grep -q 'Micro Integrator started'; then break; fi
  sleep 3
done
docker logs jamii-mi 2>&1 | grep -q 'Micro Integrator started' || { echo "FAIL: MI did not start"; docker logs --tail 50 jamii-mi; exit 1; }

if docker logs jamii-mi 2>&1 | grep -E 'ERROR|Deployment of .* failed|faulty' ; then
  echo "FAIL: MI reported deployment errors (see above)"; exit 1
fi
docker logs jamii-mi 2>&1 | grep -q 'Successfully Deployed Carbon Application : JamiiSavings' \
  || { echo "FAIL: CAR not deployed"; exit 1; }

# Cross-check through the Management API (admin/admin is the MI default for local runs).
TOKEN=$(curl -sk -u "${MI_USER:-admin}:${MI_PASS:-admin}" "$MGMT/login" | sed -n 's/.*"AccessToken":"\([^"]*\)".*/\1/p')
if [ -n "$TOKEN" ]; then
  curl -sk -H "Authorization: Bearer $TOKEN" "$MGMT/apis" | grep -o '"name":"[^"]*"' | sort -u
fi
echo "OK: CAR deployed to MI"
