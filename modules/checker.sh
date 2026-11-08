#!/usr/bin/env bash
# External subscription monitoring with kutovoys/xray-checker.
# shellcheck disable=SC2034 # Module loader version and retry loop counter.
RNM_MODULE_VERSION="5.0.0"
CHECKER_DIR="/opt/xray-checker-rnm"

checker_compose() { docker compose -f "${CHECKER_DIR}/compose.json" "$@"; }
checker_update() { checker_compose pull && checker_compose up -d; }

checker_config_json() {
  local url="$1" interval="$2" method="$3"
  jq -n --arg url "$url" --arg interval "$interval" --arg method "$method" '{services:{"xray-checker":{
    image:"kutovoys/xray-checker:latest",restart:"unless-stopped",network_mode:"host",
    environment:{SUBSCRIPTION_URL:$url,SUBSCRIPTION_UPDATE:"true",SUBSCRIPTION_UPDATE_INTERVAL:"300",
      PROXY_CHECK_INTERVAL:$interval,PROXY_CHECK_METHOD:$method,PROXY_TIMEOUT:"30",
      METRICS_HOST:"127.0.0.1",METRICS_PORT:"2112",XRAY_LOG_LEVEL:"none",LOG_LEVEL:"info"},
    logging:{driver:"json-file",options:{"max-size":"10m","max-file":"3"}} }}}
    | .services["xray-checker"].environment.SUBSCRIPTION_URL |= gsub("\\$";"$$")'
}

checker_install() {
  echo "Запускай Checker на отдельном сервере: он проверяет настоящую подписку извне."
  echo "Метрики и интерфейс: 127.0.0.1:2112 (SSH-туннель); URL подписки хранится только в root-файле."
  local url interval method tmp
  read -r -s -p "HTTPS URL служебной подписки: " url; echo
  [[ "$url" =~ ^https://[^[:space:]\'\"]+$ ]] || die "Нужен HTTPS URL."
  read -r -p "Интервал, секунды [300]: " interval
  interval="${interval:-300}"
  [[ "$interval" =~ ^[1-9][0-9]*$ && "$interval" -ge 30 && "$interval" -le 86400 ]] || die "Интервал 30–86400."
  read -r -p "Метод: ip / status / download [status]: " method
  method="${method:-status}"
  case "$method" in ip|status|download) ;; *) die "Неизвестный метод." ;; esac
  docker version >/dev/null || die "Сначала установи Docker."
  if [[ ! -f "${CHECKER_DIR}/compose.json" ]] && ss -lnt '( sport = :2112 )' | grep -q LISTEN; then die "Порт 2112 занят."; fi
  mkdir -p "$CHECKER_DIR"; chmod 700 "$CHECKER_DIR"
  tmp="$(mktemp "${CHECKER_DIR}/.compose.XXXXXX")"
  checker_config_json "$url" "$interval" "$method" > "$tmp"
  chmod 600 "$tmp"
  # Keep subscription tokens out of the interactive diff/output.
  docker compose -f "$tmp" config --quiet || { rm -f "$tmp"; return 1; }
  confirm_no_default "Установить Checker с указанной подпиской?" || { rm -f "$tmp"; return 0; }
  backup_file "${CHECKER_DIR}/compose.json"
  mv -f "$tmp" "${CHECKER_DIR}/compose.json"
  checker_compose pull && checker_compose up -d || return 1
  local attempt
  for attempt in {1..15}; do
    if curl -fsS --max-time 3 http://127.0.0.1:2112/metrics >/dev/null; then
      ok "Checker отвечает: http://127.0.0.1:2112/metrics"; return 0
    fi
    sleep 2
  done
  warn "Контейнер запущен, но endpoint метрик ещё не отвечает. Проверь логи Checker."
  return 1
}

checker_menu() {
  while true; do
    cat <<'EOF'
XRAY CHECKER — ВНЕШНИЙ МОНИТОРИНГ
  1. Установка / настройка служебной подписки
  2. Статус
  3. Последние логи
  4. Перезапуск
  5. Обновить образ и запустить
  6. Удалить контейнер (сохранить настройки)
  0. Назад
EOF
    local choice
    read -r -p "Выбор: " choice || return 0
    case "$choice" in
      1) run_action checker_install; pause ;;
      2) run_action checker_compose ps; pause ;;
      3) run_action checker_compose logs --tail 60; pause ;;
      4) run_action checker_compose restart; pause ;;
      5) run_action checker_update; pause ;;
      6) confirm_no_default "Удалить контейнер Checker (конфиг сохранить)?" && run_action checker_compose down; pause ;;
      0) return 0 ;;
    esac
  done
}
