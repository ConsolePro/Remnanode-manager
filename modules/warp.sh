#!/usr/bin/env bash
# RemnaNode Manager — WARP Native (distillium): отдельный интерфейс warp.
# Загружается ядром install.sh через load_module; отдельно не запускается.
# shellcheck disable=SC2034
RNM_MODULE_VERSION="5.0.0"

warp_installed() {
  [[ -f /etc/wireguard/warp.conf ]]
}

warp_install() {
  load_state
  if warp_installed; then
    ok "WARP уже установлен."
  else
    warn "WARP Native настроит интерфейс и системный DNS. Текущий resolv.conf будет восстановлен после установки."
    local dns_backup rc=0
    dns_backup="$(mktemp)"
    cp -L /etc/resolv.conf "$dns_backup"
    run_remote_installer "$WARP_INSTALL_URL" || rc=$?
    cat "$dns_backup" > /etc/resolv.conf
    rm -f "$dns_backup"
    [[ "$rc" == 0 ]] || die "Установка WARP прервана."
  fi
  grep -Eq '^Table[[:space:]]*=[[:space:]]*off' /etc/wireguard/warp.conf || die "В warp.conf отсутствует Table = off: не включаю outbound."
  ip link show warp >/dev/null 2>&1 || die "Интерфейс warp не появился."
  warp_test || die "WARP не прошёл проверку; профиль не изменён."
  WARP_OUTBOUND="1"
  save_state
  generate_xray_profile 1
  ok "WARP outbound включён. Домены: $(routing_list_file warp)"
}

warp_test() {
  ip link show warp >/dev/null 2>&1 || die "Интерфейс warp не найден."
  info "Проверка выхода через интерфейс warp:"
  local trace
  trace="$(curl -4 -fsS --max-time 15 --interface warp https://www.cloudflare.com/cdn-cgi/trace)" || return 1
  grep -E '^(ip|loc|warp)=' <<<"$trace"
  grep -Eq '^warp=(on|plus)' <<<"$trace" || die "Cloudflare не подтвердил выход через WARP."
}

warp_status() {
  wg show warp 2>/dev/null || warn "WARP не установлен."
  systemctl status wg-quick@warp warp-native-killswitch.service --no-pager || true
}

warp_uninstall() {
  confirm_no_default "Удалить WARP (wg-quick@warp, watchdog, /etc/wireguard/warp.conf)?" || return 0
  load_state
  WARP_OUTBOUND="0"
  [[ "$RU_POLICY" == "warp" ]] && RU_POLICY="direct"
  save_state
  generate_xray_profile 1
  run_remote_installer https://raw.githubusercontent.com/distillium/warp-native/main/uninstall.sh || return 1
  ok "WARP удалён. Не забудь отправить профиль в Panel."
}

warp_menu() {
  while true; do
    clear || true
    load_state
    echo -e "${C_BOLD}WARP Native${C_RESET} — Cloudflare WARP: интерфейс warp, mark 51888, выборочные домены"
    echo "Установлен: $(warp_installed && echo да || echo нет)   Outbound в профиле: ${WARP_OUTBOUND}"
    echo
    echo "1. Установить WARP и включить outbound"
    echo "2. Статус (vps-warp)"
    echo "3. Проверить выход через WARP"
    echo "4. Домены через WARP"
    echo "5. Outbound: вкл/выкл без удаления"
    echo "6. Удалить WARP"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) run_action warp_install; pause ;;
      2) run_action warp_status; pause ;;
      3) run_action warp_test; pause ;;
      4) edit_routing_list warp; run_action generate_xray_profile; pause ;;
      5) run_action toggle_outbound WARP_OUTBOUND; pause ;;
      6) run_action warp_uninstall; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}
