#!/usr/bin/env bash
# Network diagnosis and reversible tuning; no periodic blind container restarts.
# shellcheck disable=SC2034 # Settings are saved and read by install.sh.
RNM_MODULE_VERSION="5.0.0"

network_diagnose() {
  echo "=== Интерфейсы, маршруты, DNS ==="
  ip -br addr
  ip -4 route
  ip -6 route || true
  cat /etc/resolv.conf
  echo "=== Ресурсы, conntrack, сокеты ==="
  free -h
  df -h / /dev/shm
  ss -s
  for key in net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max net.ipv4.tcp_mtu_probing net.ipv4.tcp_congestion_control; do
    sysctl "$key" 2>/dev/null || true
  done
  echo "=== HTTP по IPv4 и IPv6 с ноды (это проверка выхода сервера) ==="
  local domain family
  for domain in ya.ru www.ozon.ru www.cloudflare.com; do
    dig +time=3 +tries=1 +short A "$domain" || true
    for family in 4 6; do
      curl "-${family}" -sS -o /dev/null --connect-timeout 5 --max-time 12 \
        -w "${domain} IPv${family}: HTTP=%{http_code} IP=%{remote_ip} TLS=%{time_appconnect} total=%{time_total}\n" "https://${domain}/" || true
    done
  done
  echo "=== Node: состояние и OOM ==="
  docker inspect remnanode --format 'running={{.State.Running}} restarts={{.RestartCount}} OOM={{.State.OOMKilled}} error={{.State.Error}}' || true
  docker stats --no-stream remnanode || true
  docker logs --tail 60 remnanode 2>&1 | tail -n 60 || true
  echo "HTTP 403/429 может означать ограничения IP/CDN, а не обрыв соединения."
  echo "Проверь также с клиента через VPN HTML и адрес недогрузившегося ресурса: выход сервера и маршрут клиента различаются."
}

network_stable_profile() {
  load_state
  echo "Профиль: выход IPv4, DNS без страновых ограничений, без серверного РФ-block и перехвата клиентского DNS."
  echo "Настройки IPv6 ОС и существующий мост не изменятся. После генерации применяй профиль в Panel с diff."
  confirm_no_default "Сохранить эти настройки и пересобрать профиль?" || return 0
  SERVER_RU_RULES=0 RU_POLICY=direct IP_MODE=ipv4 DNS_HIJACK=0
  DNS_FOREIGN="https://1.1.1.1/dns-query,https://8.8.8.8/dns-query"
  backup_file "$STATE_FILE"
  save_state
  generate_xray_profile 1
}

network_tune() {
  local file=/etc/sysctl.d/90-remnanode-network.conf
  confirm_no_default "Включить TCP MTU probing и keepalive (без изменения MTU интерфейса и default route)?" || return 0
  backup_file "$file"
  mkdir -p "$BACKUP_DIR"
  sysctl net.ipv4.tcp_mtu_probing net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes \
    > "${BACKUP_DIR}/network-sysctl-$(date +%s).conf"
  cat > "$file" <<'EOF'
# RemnaNode Manager: TCP PMTU black-hole recovery and dead peer detection.
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF
  sysctl -p "$file"
  echo "Предыдущие значения сохранены в ${BACKUP_DIR}/network-sysctl-*.conf. Для отката: sysctl -p <файл>, затем удали ${file}."
}

ipv6_status() {
  if [[ ! -d /proc/sys/net/ipv6 ]]; then
    warn "IPv6 выключен параметром загрузки ядра; sysctl не сможет включить его."
    return 0
  fi
  sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6
  ip -6 addr show scope global
  ip -6 route show default
}

ipv6_set() {
  local disabled="$1" file=/etc/sysctl.d/91-remnanode-ipv6.conf peer
  [[ -d /proc/sys/net/ipv6 ]] || die "IPv6 отключён при загрузке ядра."
  peer="${SSH_CONNECTION:-}"
  peer="${peer%% *}"
  if [[ "$disabled" == 1 && "$peer" == *:* ]]; then
    die "Текущий SSH использует IPv6. Подключись по IPv4 или используй консоль VPS."
  fi
  echo "Изменение IPv6 ОС затрагивает весь сервер. При включении адреса/маршруты зависят от сетевого менеджера VPS."
  confirm_no_default "Установить disable_ipv6=${disabled} для all/default?" || return 0
  mkdir -p "$BACKUP_DIR"
  sysctl -a 2>/dev/null | grep -E '^net\.ipv6\.conf\..*\.disable_ipv6 = ' > "${BACKUP_DIR}/ipv6-$(date +%s).conf" || return 1
  backup_file "$file"
  printf 'net.ipv6.conf.all.disable_ipv6 = %s\nnet.ipv6.conf.default.disable_ipv6 = %s\n' "$disabled" "$disabled" > "$file"
  sysctl -p "$file"
  ipv6_status
}

bridge_configure() {
  load_state
  echo "Мост использует подготовленный VLESS/Shadowsocks outbound второго сервера (с поддержкой UDP)."
  echo "Для RU-выхода нужен сервер в РФ. Установка удалённого сервера здесь не выполняется."
  local file direction config
  read -r -p "Путь к JSON outbound (без обёртки outbounds): " file
  [[ -r "$file" ]] || die "Файл не найден."
  config="$(jq -ce 'select(.protocol=="vless" or .protocol=="shadowsocks") | .tag="BRIDGE"' "$file")" || die "Нужен VLESS или Shadowsocks outbound."
  read -r -p "Через мост: 1. РФ (зарубежный вход)  2. Остальное (вход в РФ) [1]: " direction
  case "${direction:-1}" in 1) direction=ru ;; 2) direction=foreign ;; *) die "Некорректный выбор." ;; esac
  echo "Для правил РФ используются серверные geo-файлы; IP страны зависит от фактического выхода второго сервера."
  confirm_no_default "Сохранить мост и пересобрать профиль для последующей отправки в Panel?" || return 0
  backup_file "$STATE_FILE"
  BRIDGE_OUTBOUND_JSON="$config" BRIDGE_DIRECTION="$direction" RU_POLICY=direct
  save_state
  generate_xray_profile 1
}

bridge_disable() {
  load_state
  confirm_no_default "Убрать мост из генерируемого профиля?" || return 0
  BRIDGE_OUTBOUND_JSON=""
  save_state
  generate_xray_profile 1
}

network_menu() {
  while true; do
    cat <<'EOF'
СЕТЬ И СТАБИЛЬНОСТЬ
  1. Диагностика DNS, доступности, ресурсов и Node
  2. Подготовить стабильный серверный профиль
  3. Настроить TCP MTU probing / keepalive
  4. Статус IPv6
  5. Включить IPv6 операционной системы
  6. Отключить IPv6 операционной системы
  7. Выбрать dual-stack для исходящего Xray
  8. Настроить серверный мост
  9. Убрать мост из генерируемого профиля
  0. Назад
EOF
    local choice
    read -r -p "Выбор: " choice || return 0
    case "$choice" in
      1) run_action network_diagnose; pause ;;
      2) run_action network_stable_profile; pause ;;
      3) run_action network_tune; pause ;;
      4) run_action ipv6_status; pause ;;
      5) run_action ipv6_set 0; pause ;;
      6) run_action ipv6_set 1; pause ;;
      7) load_state; IP_MODE=dual; save_state; run_action generate_xray_profile 1; pause ;;
      8) run_action bridge_configure; pause ;;
      9) run_action bridge_disable; pause ;;
      0) return 0 ;;
    esac
  done
}
