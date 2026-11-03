#!/usr/bin/env bash
# kong-defender-up.sh - switch the Kong lab from plain Kong to Kong + Defender plug-in (and back with --plain).
# Run from ~/cx-lab. Needs: .env (CEQUENCE_CLIENT_ID, CEQUENCE_CLIENT_SECRET), image kong-with-defender:0.22.0,
# and the trust file ca-plus-uap.crt (made here by get-uap-trust.sh from uap-cas/ if missing).
set -euo pipefail
cd "$(dirname "$0")"
C="docker compose -f docker-compose.kong.yml"

if [ "${1:-}" = "--plain" ]; then
  unset KONG_IMAGE KONG_YML KONG_TRUST
  $C up -d --force-recreate cx-kong
  echo "Back to plain Kong (no Defender)."; exit 0
fi

[ -f .env ] || { echo "ERROR: .env missing (CEQUENCE_CLIENT_ID=..., CEQUENCE_CLIENT_SECRET=...)"; exit 1; }
set -a; . ./.env; set +a
[ -n "${CEQUENCE_CLIENT_ID:-}" ] && [ -n "${CEQUENCE_CLIENT_SECRET:-}" ] || { echo "ERROR: client id/secret empty in .env"; exit 1; }
docker image inspect kong-with-defender:0.22.0 >/dev/null 2>&1 || { echo "ERROR: build the image first (docker build in ~/defender-for-kong)"; exit 1; }

mkdir -p uap-cas
if [ ! -f ca-plus-uap.crt ]; then
  echo "== trust file"
  ./get-uap-trust.sh --hosts edge.uap.seekbank.com,auth.uap.seekbank.com --ip 192.168.0.18 \
      --ca-dir uap-cas --out ca-plus-uap.crt || { echo "ERROR: trust file failed: put keycloak-ca.crt in ~/cx-lab/uap-cas/ and run again"; exit 1; }
fi

envsubst '${CEQUENCE_CLIENT_ID}' < kong/kong.defender.yml.tpl > kong/kong.defender.yml
chmod 644 kong/kong.defender.yml   # Kong runs as user "kong", must be able to read it; holds no secret (vault ref)
export KONG_IMAGE=kong-with-defender:0.22.0 KONG_YML=./kong/kong.defender.yml KONG_TRUST=/etc/cx-lab/ca-plus-uap.crt
$C up -d --force-recreate cx-kong
echo "Kong restarted with the Defender plug-in. Check:  docker logs cx-kong 2>&1 | grep -i defender | tail"
echo "Status page:  curl -s localhost:8081/__end/status"
