#!/usr/bin/env bash
# apictl wrapper.
#  - If APICTL_BIN is set (e.g. a Linux Jenkins agent with apictl installed), run it directly.
#  - Otherwise run the Linux apictl binary from tools/ inside a throwaway container on the
#    docker-compose network, so it reaches APIM as https://apim:9443. (The Windows apictl 4.7.2
#    build rejects valid policy directories because of a path-separator bug; Linux is fine.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -n "${APICTL_BIN:-}" ]]; then
  exec "$APICTL_BIN" "$@"
fi

APICTL_VERSION="${APICTL_VERSION:-4.7.2}"
BIN_DIR="$ROOT/tools/linux/apictl"
if [[ ! -x "$BIN_DIR/apictl" ]]; then
  mkdir -p "$ROOT/tools/linux"
  curl -sSfL "https://github.com/wso2/product-apim-tooling/releases/download/v${APICTL_VERSION}/apictl-${APICTL_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C "$ROOT/tools/linux"
fi
mkdir -p "$ROOT/tools/.apictl-home"

MSYS_NO_PATHCONV=1 docker run --rm -i \
  --network "${COMPOSE_NETWORK:-jamiisavings_default}" \
  -v "$ROOT:/work" -v "$ROOT/tools/.apictl-home:/root" -w /work \
  debian:bookworm-slim /work/tools/linux/apictl/apictl "$@"
