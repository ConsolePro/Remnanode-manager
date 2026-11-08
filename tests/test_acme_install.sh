#!/usr/bin/env bash
# shellcheck disable=SC2034 # Settings are consumed by sourced manager functions.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/install.sh"
trap - ERR
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
INSTALL_LOG="${TEST_DIR}/log"
export ACME_TEST_CALLS="${TEST_DIR}/calls" ACME_TEST_ARCHIVE="${TEST_DIR}/source.tar.gz"
export ACME_TEST_SCENARIO=fallback ACME_TEST_INSTALL_FAIL=0 ACME_TEST_REGISTER_FAIL=0
mkdir -p "${TEST_DIR}/source/acme.sh-master" "${TEST_DIR}/bin"
cat > "${TEST_DIR}/source/acme.sh-master/acme.sh" <<'EOF'
#!/bin/sh
printf 'acme %s\n' "$*" >> "$ACME_TEST_CALLS"
case "$1" in
  --install)
    [ "$ACME_TEST_INSTALL_FAIL" = 0 ] || exit 7
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in --home) acme_test_home="$2"; shift ;; esac
      shift
    done
    mkdir -p "$acme_test_home"
    cp "$0" "$acme_test_home/acme.sh"
    chmod 755 "$acme_test_home/acme.sh"
    ;;
  --register-account) [ "$ACME_TEST_REGISTER_FAIL" = 0 ] || exit 8 ;;
esac
EOF
tar -czf "$ACME_TEST_ARCHIVE" -C "${TEST_DIR}/source" acme.sh-master
cat > "${TEST_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
while (($#)); do
  case "$1" in -o) output="$2"; shift ;; https://*) url="$1" ;; esac
  shift
done
printf 'curl %s\n' "$url" >> "$ACME_TEST_CALLS"
if [[ "$ACME_TEST_SCENARIO" == bad || ( "$ACME_TEST_SCENARIO" == fallback && "$url" == https://codeload.github.com/* ) ]]; then
  printf '<html>upstream error</html>\n' > "$output"
else
  cp "$ACME_TEST_ARCHIVE" "$output"
fi
EOF
cat > "${TEST_DIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
cat > "${TEST_DIR}/bin/docker" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod +x "${TEST_DIR}/bin/"*
export PATH="${TEST_DIR}/bin:$PATH"

# HTTP 200 containing HTML must fall back, not execute or pass it to an installer.
ACME_HOME="${TEST_DIR}/fallback-home" ACME_BIN="${TEST_DIR}/fallback-home/acme.sh"
install_acme admin@example.com
[[ -x "$ACME_BIN" ]]
[[ "$(grep -c '^curl ' "$ACME_TEST_CALLS")" == 2 ]]
grep -q '^curl https://codeload.github.com/' "$ACME_TEST_CALLS"
grep -q '^curl https://github.com/' "$ACME_TEST_CALLS"
grep -q -- '--install --home .* --accountemail admin@example.com' "$ACME_TEST_CALLS"
if grep -q 'get.acme.sh\|install-online' "$ACME_TEST_CALLS"; then echo 'Nested online installer used' >&2; exit 1; fi

# Existing working installations are preserved and do not download source again.
: > "$ACME_TEST_CALLS"
install_acme admin@example.com
if grep -q '^curl ' "$ACME_TEST_CALLS"; then echo 'Working ACME was downloaded again' >&2; exit 1; fi
ACME_TEST_REGISTER_FAIL=1
if install_acme admin@example.com; then echo 'CA registration error ignored' >&2; exit 1; fi
ACME_TEST_REGISTER_FAIL=0

# All sources corrupt: no install, no misleading success.
ACME_HOME="${TEST_DIR}/bad-home" ACME_BIN="${TEST_DIR}/bad-home/acme.sh"
ACME_TEST_SCENARIO=bad
: > "$ACME_TEST_CALLS"
if install_acme admin@example.com; then echo 'Corrupt sources accepted' >&2; exit 1; fi
[[ ! -e "$ACME_BIN" ]]
if grep -q '^acme ' "$ACME_TEST_CALLS"; then echo 'Invalid archive executed' >&2; exit 1; fi

# An error inside the local installer must stop even in a menu/conditional context.
ACME_TEST_SCENARIO=good ACME_TEST_INSTALL_FAIL=1
: > "$ACME_TEST_CALLS"
if install_acme admin@example.com; then echo 'Local installer error ignored' >&2; exit 1; fi
[[ ! -e "$ACME_BIN" ]]
if grep -q -- '--register-account' "$ACME_TEST_CALLS"; then echo 'CA called after installation failure' >&2; exit 1; fi

# Resume must stop before Docker/profile changes if certificate issuance fails.
BASE_DIR="${TEST_DIR}/node" NODE_COMPOSE_FILE="${TEST_DIR}/node/compose.yml"
INSTALL_MODE=selfsteal DOMAIN=node.example.com ACME_EMAIL=admin@example.com
mkdir -p "${BASE_DIR}/html"
touch "$NODE_COMPOSE_FILE" "${BASE_DIR}/nginx.conf" "${BASE_DIR}/html/index.html"
load_state() { :; }
issue_certificate() { echo issue >> "$ACME_TEST_CALLS"; return 1; }
start_stack() { echo start >> "$ACME_TEST_CALLS"; }
verify_basic() { echo basic >> "$ACME_TEST_CALLS"; }
verify_selfsteal_local() { echo selfsteal >> "$ACME_TEST_CALLS"; }
generate_xray_profile() { echo profile >> "$ACME_TEST_CALLS"; }
save_state() { echo save >> "$ACME_TEST_CALLS"; }
: > "$ACME_TEST_CALLS"
if resume_selfsteal_install; then echo 'Resume ignored CA failure' >&2; exit 1; fi
[[ "$(cat "$ACME_TEST_CALLS")" == issue ]]
issue_certificate() { echo issue >> "$ACME_TEST_CALLS"; }
: > "$ACME_TEST_CALLS"
resume_selfsteal_install
[[ "$(paste -sd, "$ACME_TEST_CALLS")" == issue,start,basic,selfsteal,profile,save ]]

# Both installation entry points must stop on an ACME error. These no-op stubs
# keep the tests independent of Docker, apt, the firewall and /opt.
for fn in ensure_fresh_install_target prompt_secret_and_panel prompt_domain_and_site prompt_inbounds \
  install_base_packages install_docker ensure_base_dirs validate_selected_port_plan ensure_selected_ports_free \
  deploy_site write_nginx_conf write_selfsteal_compose tune_hysteria_udp configure_firewall \
  detect_os detect_existing_compose prompt_panel_network compose_edit; do
  eval "${fn}() { :; }"
done
PANEL_IP=192.0.2.1
issue_certificate() { echo issue >> "$ACME_TEST_CALLS"; return 1; }
: > "$ACME_TEST_CALLS"
if install_node_selfsteal; then echo 'Fresh install ignored CA failure' >&2; exit 1; fi
if grep -q '^start$' "$ACME_TEST_CALLS"; then echo 'Stack started without certificate' >&2; exit 1; fi
: > "$ACME_TEST_CALLS"
if install_selfsteal_for_existing_node; then echo 'Existing-node install ignored CA failure' >&2; exit 1; fi
if grep -q '^start$' "$ACME_TEST_CALLS"; then echo 'Existing stack started after CA failure' >&2; exit 1; fi
echo 'ACME installation and resume tests passed.'
