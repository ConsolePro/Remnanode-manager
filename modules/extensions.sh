#!/usr/bin/env bash
# Xray override and Panel node plugins. API layout adapted from eGames (MIT).
# shellcheck disable=SC2034 # Shared settings and loop counter are consumed across modules.
RNM_MODULE_VERSION="5.0.0"

core_status() {
  node_xray_exec version || return 1
  docker exec remnanode sh -c 'readlink -f /usr/local/bin/rw-core || true'
  docker inspect remnanode --format '{{range .Mounts}}{{if eq .Destination "/usr/local/bin/xray"}}{{.Source}}{{end}}{{end}}'
}

core_install() {
  require_compose
  local arch release tag asset url tmp hash actual core_dir snapshot had_xray=0
  xray_running && had_xray=1
  command -v unzip >/dev/null || apt_get_wait install -y unzip || return 1
  case "$(uname -m)" in x86_64) arch=64 ;; aarch64|arm64) arch=arm64-v8a ;; *) die "Поддерживаются x86_64 и arm64." ;; esac
  release="$(curl -fsS --connect-timeout 10 --max-time 30 https://api.github.com/repos/XTLS/Xray-core/releases/latest)" || return 1
  tag="$(jq -er '.tag_name | select(test("^v[0-9.]+$"))' <<<"$release")" || return 1
  asset="Xray-linux-${arch}.zip"
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"
  info "Официальное стабильное ядро ${tag}, ${arch}."
  echo "Новые REALITY-сборки могут требовать обновления клиентов/uTLS. Сначала проверь совместимость на одной ноде."
  confirm_no_default "Скачать, проверить и установить ядро с автоматическим откатом при ошибке запуска?" || return 0
  tmp="$(mktemp -d)"
  if ! curl -fsSL --connect-timeout 10 --max-time 180 "$url" -o "${tmp}/core.zip" \
    || ! curl -fsSL --connect-timeout 10 --max-time 30 "${url}.dgst" -o "${tmp}/core.dgst"; then
    rm -rf "$tmp"; return 1
  fi
  hash="$(sed -n 's/^SHA2-256=//p' "${tmp}/core.dgst" | tr -d ' \r' | head -n1)"
  actual="$(sha256sum "${tmp}/core.zip" | cut -d' ' -f1)"
  [[ "$hash" =~ ^[a-fA-F0-9]{64}$ && "${hash,,}" == "$actual" ]] || { rm -rf "$tmp"; die "Не совпала SHA256 ядра."; }
  unzip -q "${tmp}/core.zip" xray -d "$tmp" || { rm -rf "$tmp"; return 1; }
  chmod 755 "${tmp}/xray"
  "${tmp}/xray" version || { rm -rf "$tmp"; return 1; }
  # Immutable paths also work with single-file bind mounts and enable rollback.
  core_dir="$(dirname "$NODE_COMPOSE_FILE")/rnm-cores/${tag}-$(date +%s)"
  mkdir -p "$core_dir" "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  install -m 755 "${tmp}/xray" "${core_dir}/xray"
  rm -rf "$tmp"
  snapshot="${BACKUP_DIR}/core-compose-$(date +%Y%m%d-%H%M%S).yml"
  cp -p "$NODE_COMPOSE_FILE" "$snapshot"
  chmod 600 "$snapshot"
  if ! compose_edit core-add "${core_dir}/xray"; then return 1; fi
  if manager_compose up -d --force-recreate "$NODE_SERVICE_NAME" && core_wait_healthy "$had_xray"; then
    core_status
    ok "Ядро установлено. Compose до изменения: ${snapshot}"
    echo "Если rw-core указывает на другое ядро профиля панели, выбери штатное ядро профиля для использования этого mount."
  else
    cp -p "$snapshot" "$NODE_COMPOSE_FILE"
    manager_compose up -d --force-recreate "$NODE_SERVICE_NAME" || true
    die "Новое ядро не запустилось; восстановлен предыдущий Compose."
  fi
}

core_wait_healthy() {
  local had_xray="$1" state attempt
  for attempt in {1..20}; do
    state="$(node_state)"
    [[ "$state" == ONLINE || ( "$had_xray" == 0 && "$state" == WAITING ) ]] && return 0
    sleep 3
  done
  return 1
}

core_remove() {
  require_compose
  confirm_no_default "Вернуть ядро из Docker-образа ноды?" || return 0
  local snapshot had_xray=0
  xray_running && had_xray=1
  snapshot="$(mktemp "${NODE_COMPOSE_FILE}.core-backup.XXXXXX")"
  cp -p "$NODE_COMPOSE_FILE" "$snapshot"
  compose_edit core-remove || return 1
  if manager_compose up -d --force-recreate "$NODE_SERVICE_NAME" && core_wait_healthy "$had_xray"; then
    ok "Возвращено штатное ядро."
  else
    cp -p "$snapshot" "$NODE_COMPOSE_FILE"
    manager_compose up -d --force-recreate "$NODE_SERVICE_NAME" || true
    die "Штатное ядро не запустилось, mount восстановлен."
  fi
}

plugin_select() {
  local response choice
  response="$(panel_request GET /api/node-plugins)" || return 1
  jq -e '.response.nodePlugins | type=="array"' <<<"$response" >/dev/null || die "Панель не поддерживает Node Plugins API."
  jq -r '.response.nodePlugins[] | "\(.uuid)  \(.name)"' <<<"$response" | nl -w2 -s'. '
  echo "0. Создать общий плагин RNM Node Plugins"
  read -r -p "Номер плагина: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] || die "Нужен номер."
  if [[ "$choice" == 0 ]]; then
    local file
    file="$(mktemp)"
    printf '%s\n' '{"name":"RNM Node Plugins"}' > "$file"
    response="$(panel_request POST /api/node-plugins "$file")" || { rm -f "$file"; return 1; }
    rm -f "$file"
    PLUGIN_UUID="$(jq -er '.response.uuid' <<<"$response")" || return 1
  else
    PLUGIN_UUID="$(jq -er --argjson i "$((choice-1))" '.response.nodePlugins[$i].uuid // empty' <<<"$response")" || return 1
  fi
  PLUGIN_CONFIG="$(panel_request GET "/api/node-plugins/${PLUGIN_UUID}?_=$(date +%s)" | jq -ec '.response.pluginConfig // {}')" || return 1
}

plugin_apply() {
  local config="$1" payload response nodes selection index uuids='[]' uuid
  # Select targets first: never silently replace another active plugin.
  nodes="$(panel_request GET /api/nodes)" || return 1
  jq -r '.response[] | "\(.name) | plugin=\(.activePluginUuid // "none") | disabled=\(.isDisabled)"' <<<"$nodes" | nl -w2 -s'. '
  read -r -p "Номера нод для привязки (через пробел): " selection
  for index in $selection; do
    [[ "$index" =~ ^[1-9][0-9]*$ ]] || die "Нужны положительные номера."
    uuid="$(jq -er --argjson i "$((index-1))" '.response[$i].uuid // empty' <<<"$nodes")" || return 1
    uuids="$(jq -c --arg u "$uuid" '.+[$u]|unique' <<<"$uuids")"
  done
  [[ "$uuids" != '[]' ]] || die "Не выбраны ноды."
  echo "Изменение общего плагина затронет также все ноды, уже привязанные к ${PLUGIN_UUID}."
  jq . <<<"$config"
  confirm_no_default "Сохранить конфиг и заменить activePlugin выбранных нод?" || return 0
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  payload="${BACKUP_DIR}/plugin-${PLUGIN_UUID}-$(date +%s).json"
  jq -n --arg u "$PLUGIN_UUID" --argjson c "$PLUGIN_CONFIG" --argjson n "$nodes" '{uuid:$u,pluginConfig:$c,nodes:$n.response}' > "$payload"
  chmod 600 "$payload"
  payload="$(mktemp)"
  jq -n --arg u "$PLUGIN_UUID" --argjson c "$config" '{uuid:$u,pluginConfig:$c}' > "$payload"
  panel_request PATCH /api/node-plugins "$payload" | jq -e '.response.uuid' >/dev/null || { rm -f "$payload"; return 1; }
  jq -n --arg u "$PLUGIN_UUID" '{uuid:$u}' > "$payload"
  panel_request POST /api/node-plugins/actions/sync "$payload" >/dev/null || { rm -f "$payload"; return 1; }
  jq -n --arg u "$PLUGIN_UUID" --argjson n "$uuids" '{uuids:$n,fields:{activePluginUuid:$u}}' > "$payload"
  panel_request POST /api/nodes/bulk-actions/update "$payload" >/dev/null || { rm -f "$payload"; return 1; }
  rm -f "$payload"
  response="$(panel_request GET "/api/nodes?_=$(date +%s)")" || return 1
  jq -e --arg u "$PLUGIN_UUID" --argjson ids "$uuids" \
    '.response as $nodes | all($ids[]; . as $id | any($nodes[]; .uuid==$id and .activePluginUuid==$u))' <<<"$response" >/dev/null \
    || { warn "Конфиг сохранён, но API ещё не подтвердил все привязки; проверь их в панели."; return 1; }
  jq -r --arg u "$PLUGIN_UUID" '.response[] | select(.activePluginUuid==$u) | "Привязана: \(.name)"' <<<"$response"
  ok "Конфиг сохранён и синхронизирован. Оффлайн-ноды применят его после подключения."
}

plugin_torrent() {
  plugin_select || return 1
  echo "Torrent Blocker требует Node 2.7+ и Xray 26.3.27+. Банится IP клиента, включая других пользователей за тем же NAT."
  local enabled duration ips config
  read -r -p "Включить? [y/N]: " enabled
  if [[ "$enabled" =~ ^[yYдД]$ ]]; then enabled=true; else enabled=false; fi
  read -r -p "Длительность бана в секундах [3600]: " duration
  duration="${duration:-3600}"
  [[ "$duration" =~ ^[1-9][0-9]*$ && "$duration" -le 604800 ]] || die "Нужны секунды 1–604800."
  read -r -p "IP исключения через запятую, без CIDR (Enter = сохранить): " ips
  config="$(jq -c --argjson e "$enabled" --argjson d "$duration" \
    '.torrentBlocker=((.torrentBlocker // {ignoreLists:{ip:[],userId:[]}})+{enabled:$e,blockDuration:$d})' <<<"$PLUGIN_CONFIG")"
  if [[ -n "$ips" ]]; then
    local ip
    while read -r ip; do
      [[ "$ip" != */* ]] && validate_panel_network "$ip" || die "Нужен IP без CIDR: $ip"
    done < <(tr ',' '\n' <<<"$ips")
    config="$(jq -c --argjson ips "$(csv_to_json "$ips")" '.torrentBlocker.ignoreLists.ip=$ips' <<<"$config")"
  fi
  plugin_apply "$config"
}

plugin_edit() {
  plugin_select || return 1
  local file
  file="$(mktemp --suffix=.json)"
  jq . <<<"$PLUGIN_CONFIG" > "$file"
  "${EDITOR:-nano}" "$file"
  jq -e 'type=="object"' "$file" >/dev/null || { rm -f "$file"; die "Нужен JSON-объект."; }
  plugin_apply "$(cat "$file")"
  rm -f "$file"
}

extensions_menu() {
  while true; do
    cat <<'EOF'
ЯДРО XRAY И ПЛАГИНЫ НОДЫ
  1. Статус установленного и фактически выбранного ядра
  2. Установить свежее официальное ядро Xray
  3. Вернуть штатное ядро из Docker-образа
  4. Настроить Torrent Blocker через Panel
  5. Редактор общего плагина (ingress / egress и прочее)
  6. Статистика Torrent Blocker
  0. Назад
EOF
    local choice
    read -r -p "Выбор: " choice || return 0
    case "$choice" in
      1) run_action core_status; pause ;;
      2) run_action core_install; pause ;;
      3) run_action core_remove; pause ;;
      4) run_action plugin_torrent; pause ;;
      5) run_action plugin_edit; pause ;;
      6) run_action panel_request GET /api/node-plugins/torrent-blocker/stats; pause ;;
      0) return 0 ;;
    esac
  done
}
