#!/usr/bin/env bash
# shellcheck disable=SC2034 # Variables are consumed by sourced manager functions.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/install.sh"
for module in clients extensions network checker; do load_module "$module"; done
trap - ERR
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
INSTALL_LOG="${TMP}/log"
BASE_DIR="$TMP" PROFILE_DIR="${TMP}/profiles" BACKUP_DIR="${TMP}/backups"
STATE_FILE="${TMP}/state" ROUTING_DIR="${TMP}/routing"
mkdir -p "$PROFILE_DIR" "$BACKUP_DIR"
ensure_routing_lists

# Clean installs and old state files without new keys must no longer block RU.
[[ "$SERVER_RU_RULES" == 0 && "$DNS_HIJACK" == 0 && "$IP_MODE" == ipv4 ]]
build_routing_json > "${TMP}/server-routing.json"
jq -e '[.rules[] | (.domain // [] | .[]), (.ip // [] | .[])] | all(. != "geoip:ru" and . != "geosite:category-ru")' "${TMP}/server-routing.json" >/dev/null
build_dns_json | jq -e '.. | objects | has("expectIPs") | not' >/dev/null
SERVER_RU_RULES=1 RU_POLICY=block
build_routing_json | jq -e 'any(.rules[]; .ip==["geoip:ru"] and .outboundTag=="BLOCK")' >/dev/null
SERVER_RU_RULES=0 RU_POLICY=direct

# Full templates have no user credentials; outbound injection is Panel-owned.
client_template_write
jq -e '.remnawave.addVirtualHostAsOutbound==true and .inbounds[0].sniffing.routeOnly and
  .dns.servers[0]=="https://common.dot.dns.yandex.net/dns-query" and
  all(.routing.rules[]; .network != "tcp,udp")' "${PROFILE_DIR}/subscription-xray-ru-direct.json" >/dev/null
client_template_json '["11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222"]' > "${TMP}/balancer.json"
jq -e '.routing.balancers[0].fallbackTag=="block" and .routing.balancers[0].strategy.type=="leastPing" and
  .routing.domainStrategy=="IPOnDemand" and .routing.rules[-1].balancerTag=="auto" and
  (.remnawave.injectHosts[0].selector.values|length)==2 and
  all(.routing.rules[]; .outboundTag != "proxy")' "${TMP}/balancer.json" >/dev/null

# RU/IP rules must still run before the foreign bridge catch-all.
BRIDGE_OUTBOUND_JSON='{"tag":"BRIDGE","protocol":"shadowsocks","settings":{"servers":[{"address":"192.0.2.1","port":12345,"method":"chacha20-ietf-poly1305","password":"test-password"}]}}'
BRIDGE_DIRECTION=foreign
build_routing_json | jq -e '.domainStrategy=="IPOnDemand" and .rules[-1].outboundTag=="BRIDGE" and any(.rules[]; .ip==["geoip:ru"] and .outboundTag=="DIRECT")' >/dev/null
BRIDGE_DIRECTION=ru
build_routing_json | jq -e 'any(.rules[]; .ip==["geoip:ru"] and .outboundTag=="BRIDGE")' >/dev/null
save_state
BRIDGE_OUTBOUND_JSON=''
load_state
[[ -n "$BRIDGE_OUTBOUND_JSON" ]]
BRIDGE_OUTBOUND_JSON=''

# Checker URL remains one environment value (including Compose dollar escapes).
checker_config_json 'https://sub.example.com/token?a=1&b=2' 300 status > "${TMP}/checker.json"
jq -e '.services["xray-checker"].environment.METRICS_HOST=="127.0.0.1" and
  .services["xray-checker"].environment.PROXY_CHECK_METHOD=="status"' "${TMP}/checker.json" >/dev/null
checker_config_json 'https://sub.example.com/$token' 300 status | jq -e '.services["xray-checker"].environment.SUBSCRIPTION_URL=="https://sub.example.com/$$token"' >/dev/null

# Host settings derive the port and inbound identity, without copying a user UUID.
DOMAIN=node.example.com
host_payload_json profile-uuid inbound-uuid 8443 test | jq -e '.port==8443 and .sni=="node.example.com" and .securityLayer=="DEFAULT" and .inbound.configProfileInboundUuid=="inbound-uuid"' >/dev/null

# Nginx must serve HTTP safely, share the original inode across reloads, and
# provide TCP TLS when only Hysteria2/UDP is enabled.
RAW_ENABLED=1 RAW_PORT=8443 XHTTP_ENABLED=0
write_nginx_conf node.example.com
grep -Fq 'return 301 https://node.example.com:8443$request_uri;' "${BASE_DIR}/nginx.conf"
ln "${BASE_DIR}/nginx.conf" "${BASE_DIR}/nginx-bound.conf"
RAW_ENABLED=0 HY2_ENABLED=1
write_nginx_conf second.example.com
cmp "${BASE_DIR}/nginx.conf" "${BASE_DIR}/nginx-bound.conf"
grep -Fq 'listen 443 ssl;' "${BASE_DIR}/nginx.conf"

# ACME hooks stop only our nginx and recover it when another daemon owns :80.
ACME_HOOK="${TMP}/acme-hook"
write_acme_hook
sed -i "s|/run/remnanode-acme-nginx-stopped|${TMP}/nginx-stopped|g" "$ACME_HOOK"
mkdir -p "${TMP}/bin"
export CALLS="${TMP}/calls" FOREIGN_PORT=0
cat > "${TMP}/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
[[ "$1" == inspect ]] && echo true
exit 0
EOF
cat > "${TMP}/bin/ss" <<'EOF'
#!/usr/bin/env bash
[[ "$FOREIGN_PORT" == 1 ]] && echo LISTEN
exit 0
EOF
chmod +x "${TMP}/bin/"*
export PATH="${TMP}/bin:$PATH"
"$ACME_HOOK" pre
[[ -f "${TMP}/nginx-stopped" ]]
"$ACME_HOOK" post
[[ ! -f "${TMP}/nginx-stopped" ]]
grep -q '^stop nginx-selfsteal' "$CALLS"
grep -q '^start nginx-selfsteal' "$CALLS"
export FOREIGN_PORT=1
if "$ACME_HOOK" pre; then echo 'Foreign :80 must fail' >&2; exit 1; fi
[[ ! -f "${TMP}/nginx-stopped" ]]

# CA errors propagate and never reinstall an old certificate as a success.
ACME_BIN="${TMP}/bin/acme"
printf '#!/usr/bin/env bash\nexit 5\n' > "$ACME_BIN"
chmod +x "$ACME_BIN"
install_acme() { :; }
check_domain_dns() { :; }
write_acme_hook() { :; }
install_cert_files() { touch "${TMP}/incorrect-install"; }
if issue_certificate node.example.com admin@example.com; then echo 'CA failure swallowed' >&2; exit 1; fi
[[ ! -f "${TMP}/incorrect-install" ]]

# An unsuccessful core switch must restore Compose even when WAITING is healthy
# for a brand-new node. Existing Xray must return to ONLINE.
node_state() { echo WAITING; }
sleep() { :; }
core_wait_healthy 0
if core_wait_healthy 1; then echo 'Lost Xray incorrectly accepted' >&2; exit 1; fi
NODE_COMPOSE_FILE="${TMP}/compose.yml"
printf 'original-compose\n' > "$NODE_COMPOSE_FILE"
require_compose() { :; }
confirm_no_default() { return 0; }
xray_running() { return 0; }
compose_edit() { printf 'broken-compose\n' > "$NODE_COMPOSE_FILE"; }
manager_compose() { return 0; }
if (core_remove); then echo 'Core failure incorrectly accepted' >&2; exit 1; fi
grep -qx original-compose "$NODE_COMPOSE_FILE"

# Config changes preserve other plugin sections and are actually bound/synced.
PLUGIN_UUID=plugin-uuid
PLUGIN_CONFIG='{"ingressFilter":{"enabled":true,"blockedIps":["192.0.2.0/24"]},"torrentBlocker":{"enabled":false}}'
panel_request() {
  echo "$1 $2" >> "$CALLS"
  case "$1 $2" in
    'GET /api/nodes'*) echo '{"response":[{"uuid":"node-uuid","name":"node","activePluginUuid":"plugin-uuid","isDisabled":false}]}' ;;
    'PATCH /api/node-plugins') cp "$3" "${TMP}/plugin-sent.json"; echo '{"response":{"uuid":"plugin-uuid"}}' ;;
    'POST /api/nodes/bulk-actions/update') cp "$3" "${TMP}/binding-sent.json"; echo '{"response":true}' ;;
    *) echo '{"response":true}' ;;
  esac
}
plugin_apply "$(jq -c '.torrentBlocker.enabled=true' <<<"$PLUGIN_CONFIG")" <<<1
jq -e '.pluginConfig.ingressFilter.enabled and .pluginConfig.torrentBlocker.enabled' "${TMP}/plugin-sent.json" >/dev/null
jq -e '.uuids==["node-uuid"] and .fields.activePluginUuid=="plugin-uuid"' "${TMP}/binding-sent.json" >/dev/null
grep -q 'POST /api/node-plugins/actions/sync' "$CALLS"

# Publish a rendered-by-Panel balancer and bind it to precisely the chosen hosts.
client_select_hosts() { SELECTED_HOSTS='["host-one","host-two"]'; }
panel_request() {
  case "$1 $2" in
    'GET /api/subscription-templates') echo '{"response":{"templates":[]}}' ;;
    'POST /api/subscription-templates') cp "$3" "${TMP}/template-created.json"; echo '{"response":{"uuid":"template-uuid"}}' ;;
    'PATCH /api/subscription-templates') cp "$3" "${TMP}/template-sent.json"; echo '{"response":{"uuid":"template-uuid"}}' ;;
    'GET /api/hosts/'*) echo '{"response":{"remark":"old host","uuid":"original"}}' ;;
    'PATCH /api/hosts') cat "$3" >> "${TMP}/host-bindings.jsonl"; echo '{"response":{"uuid":"host"}}' ;;
    *) echo 'Unexpected API request' >&2; return 1 ;;
  esac
}
client_publish_template balancer <<<'Test Balancer'
jq -e '.name=="Test Balancer" and .templateType=="XRAY_JSON"' "${TMP}/template-created.json" >/dev/null
jq -e '.uuid=="template-uuid" and .templateJson.routing.balancers[0].fallbackTag=="block" and
  .templateJson.remnawave.injectHosts[0].selector.values==["host-one","host-two"]' "${TMP}/template-sent.json" >/dev/null
jq -se 'length==2 and all(.[]; .xrayJsonTemplateUuid=="template-uuid") and ([.[].uuid]|sort)==["host-one","host-two"]' "${TMP}/host-bindings.jsonl" >/dev/null

# Repair a host using the authoritative inbound port/path without cloning it
# or overwriting its name and unrelated tuning.
load_module panel
load_state() { :; }
panel_select_profile() { PANEL_PROFILE_UUID=profile-uuid; }
panel_request() {
  case "$1 $2" in
    'GET /api/config-profiles/profile-uuid')
      echo '{"response":{"inbounds":[{"tag":"VLESS_XHTTP_REALITY","uuid":"ib-uuid"}],"config":{"inbounds":[{"tag":"VLESS_XHTTP_REALITY","port":8443,"streamSettings":{"xhttpSettings":{"path":"/assets/correct"}}}]}}}' \
        | jq --arg t "${HOST_FIXTURE_TAG:-VLESS_XHTTP_REALITY}" '.response.inbounds[0].tag=$t | .response.config.inbounds[0].tag=$t'
      ;;
    'GET /api/hosts') echo '{"response":[{"uuid":"existing-host","address":"node.example.com","inbound":{"configProfileInboundUuid":"ib-uuid"}}]}' ;;
    'GET /api/hosts/existing-host') echo '{"response":{"uuid":"existing-host","remark":"Original host name"}}' ;;
    'PATCH /api/hosts') cp "$3" "${TMP}/host-repaired.json"; echo '{"response":{"uuid":"existing-host"}}' ;;
    *) echo 'Unexpected API request' >&2; return 1 ;;
  esac
}
panel_create_hosts
jq -e '.uuid=="existing-host" and .port==8443 and .path=="/assets/correct" and
  .remark=="Original host name" and .sni=="node.example.com" and .keepSniBlank==false' "${TMP}/host-repaired.json" >/dev/null
HOST_FIXTURE_TAG=VLESS_SELFSTEAL_WITH_NGINX
panel_create_hosts
jq -e '.uuid=="existing-host" and .path=="" and .sni=="node.example.com"' "${TMP}/host-repaired.json" >/dev/null
echo 'Feature regression tests passed.'
