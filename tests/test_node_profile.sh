#!/usr/bin/env bash
# shellcheck disable=SC2034 # Variables are read by sourced profile generators.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/install.sh"
trap - ERR
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
BASE_DIR="$TEST_DIR" INSTALL_LOG="${TEST_DIR}/log"
PROFILE_DIR="${TEST_DIR}/profiles" PROFILE_FILE="${TEST_DIR}/profiles/xray-profile.json"
PROFILE_INFO="${TEST_DIR}/profiles/profile-info.txt" ROUTING_DIR="${TEST_DIR}/routing"
CLIENT_ROUTING_FILE="${PROFILE_DIR}/happ.json" CLIENT_RULES_FILE="${PROFILE_DIR}/client-rules.json"
CLIENT_DNS_FILE="${PROFILE_DIR}/client-dns.json" CLIENT_APPS_FILE="${PROFILE_DIR}/apps.txt"
GEO_DIR="${TEST_DIR}/geo"
INSTALL_MODE=selfsteal DOMAIN=node.example.com RAW_ENABLED=1 RAW_PORT=443 XHTTP_ENABLED=0 HY2_ENABLED=0
REALITY_PRIVATE_KEY=test-private-key REALITY_PUBLIC_KEY=test-public-key
RAW_SHORT_IDS_JSON='["12345678"]'
# Saved advanced settings must never bleed into the canonical node profile.
SERVER_RU_RULES=1 RU_POLICY=block BLOCK_ADS=1 WARP_OUTBOUND=1 DNS_HIJACK=1
DNS_FOREIGN=https://8.8.8.8/dns-query
generate_reality_material() { :; }
load_reality() { :; }
docker() { return 1; }
generate_xray_profile 1
jq -e --slurpfile expected "${ROOT}/tests/fixtures/selfsteal-profile.json" '.==$expected[0]' "$PROFILE_FILE" >/dev/null
grep -q 'Tag: VLESS_SELFSTEAL_WITH_NGINX' "$PROFILE_INFO"
grep -Fq 'Short IDs: [""]' "$PROFILE_INFO"
# Advanced config remains separately available, and client routing is intact.
jq -e 'any(.outbounds[]; .tag=="WARP") and any(.routing.rules[]; .ip==["geoip:ru"])' "${PROFILE_DIR}/server-routing-extensions.json" >/dev/null
jq -e 'any(.routing.rules[]; .domain==["geosite:ru-blocked"] and .outboundTag=="proxy") and any(.routing.rules[]; .ip==["geoip:ru"] and .outboundTag=="direct")' "${PROFILE_DIR}/subscription-xray-ru-direct.json" >/dev/null
# Preserve optional transports and the selected port without altering RAW shape.
XHTTP_ENABLED=1 XHTTP_PATH=/assets/test XHTTP_SHORT_IDS_JSON='["abcdef12"]' RAW_PORT=9443
build_node_profile_json | jq -e '.inbounds[0].port==9443 and .inbounds[0].streamSettings.realitySettings.shortIds==[""] and .inbounds[1].streamSettings.network=="xhttp"' >/dev/null
echo 'Canonical SelfSteal profile tests passed.'
