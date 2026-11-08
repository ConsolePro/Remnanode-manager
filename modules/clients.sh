#!/usr/bin/env bash
# Client templates and host settings. API conventions follow eGames Reverse-Proxy (MIT).
# shellcheck disable=SC2034 # Shared module version is read by the loader.
RNM_MODULE_VERSION="5.0.0"

client_template_json() {
  local members="${1:-[]}"
  jq -cn --argjson members "$members" '{
    log:{loglevel:"warning"},
    remnawave:(if ($members|length)>0 then
      {addVirtualHostAsOutbound:false, injectHosts:[{selector:{type:"uuids",values:$members},tagPrefix:"proxy"}]}
      else {addVirtualHostAsOutbound:true} end),
    dns:{tag:"dns-internal",queryStrategy:"UseIPv4",
      hosts:{"common.dot.dns.yandex.net":["77.88.8.8"]},
      servers:["https://common.dot.dns.yandex.net/dns-query","77.88.8.8"]},
    inbounds:[
      {tag:"socks",listen:"127.0.0.1",port:10808,protocol:"socks",settings:{auth:"noauth",udp:true},
       sniffing:{enabled:true,routeOnly:true,destOverride:["http","tls","quic"]}},
      {tag:"http",listen:"127.0.0.1",port:10809,protocol:"http",settings:{allowTransparent:false},
       sniffing:{enabled:true,routeOnly:true,destOverride:["http","tls","quic"]}}],
    outbounds:[{tag:"block",protocol:"blackhole"},
               {tag:"direct",protocol:"freedom",settings:{domainStrategy:"UseIPv4"}}],
    routing:{domainStrategy:(if ($members|length)>0 then "IPOnDemand" else "IPIfNonMatch" end),rules:[
      {type:"field",inboundTag:["dns-internal"],outboundTag:"direct"},
      {type:"field",protocol:["bittorrent"],outboundTag:"block"},
      {type:"field",domain:["geosite:private"],outboundTag:"direct"},
      {type:"field",ip:["geoip:private"],outboundTag:"direct"},
      {type:"field",domain:["geosite:ru-blocked"],outboundTag:"proxy"},
      {type:"field",domain:["geosite:category-ru","geosite:yandex","geosite:mailru","regexp:\\.ru$","regexp:\\.su$","regexp:\\.xn--p1ai$"],outboundTag:"direct"},
      {type:"field",ip:["geoip:ru-blocked"],outboundTag:"proxy"},
      {type:"field",ip:["geoip:ru"],outboundTag:"direct"} ]}
  } | if ($members|length)>0 then
    .burstObservatory={subjectSelector:["proxy"],pingConfig:{destination:"http://www.gstatic.com/generate_204",interval:"30s",sampling:3,timeout:"5s",connectivity:""}}
    | .routing.balancers=[{tag:"auto",selector:["proxy"],fallbackTag:"block",strategy:{type:"leastPing"}}]
    | .routing.rules |= (map(if .outboundTag=="proxy" then del(.outboundTag)+{balancerTag:"auto"} else . end)
       + [{type:"field",network:"tcp,udp",balancerTag:"auto"}])
  else . end'
}

client_template_write() {
  mkdir -p "$PROFILE_DIR"
  local tmp
  tmp="$(mktemp "${PROFILE_DIR}/.client.XXXXXX")"
  client_template_json > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "${PROFILE_DIR}/subscription-xray-ru-direct.json"
}

client_select_hosts() {
  local response selection uuid index
  response="$(panel_request GET /api/hosts)" || return 1
  jq -e '.response | type=="array"' <<<"$response" >/dev/null || die "Неизвестный формат /api/hosts."
  jq -r '.response[] | "\(.remark) | \(.address):\(.port) | \(.uuid)"' <<<"$response" | nl -w2 -s'. '
  read -r -p "Номера хостов через пробел: " selection
  SELECTED_HOSTS='[]'
  for index in $selection; do
    [[ "$index" =~ ^[1-9][0-9]*$ ]] || die "Нужны положительные номера."
    uuid="$(jq -r --argjson i "$((index-1))" '.response[$i] | select(.isDisabled != true and .isHidden != true) | .uuid // empty' <<<"$response")"
    [[ -n "$uuid" ]] || die "Хост ${index} отсутствует, скрыт или отключён."
    SELECTED_HOSTS="$(jq -c --arg u "$uuid" '.+[$u]|unique' <<<"$SELECTED_HOSTS")"
  done
  [[ "$SELECTED_HOSTS" != '[]' ]] || die "Не выбраны хосты."
}

client_publish_template() {
  local mode="${1:-single}" members='[]' name file response uuid payload host requested_name
  client_select_hosts || return 1
  if [[ "$mode" == balancer ]]; then
    [[ "$(jq length <<<"$SELECTED_HOSTS")" -ge 2 ]] || die "Балансировщику нужны минимум два хоста."
    members="$SELECTED_HOSTS"
    name="RNM Auto $(printf '%s' "$members" | sha256sum | cut -c1-8)"
  else
    name="RNM RU Direct"
  fi
  read -r -p "Имя шаблона [${name}] (существующее имя = обновить его): " requested_name
  name="${requested_name:-$name}"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9\ -]{1,49}$ ]] || die "Для имени нужны латиница, цифры, пробел или дефис (2–50 символов)."
  mkdir -p "$PROFILE_DIR" "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  file="${PROFILE_DIR}/subscription-${mode}.json"
  client_template_json "$members" | jq . > "$file" || return 1
  chmod 600 "$file"
  info "Шаблон подготовлен: ${file}"
  echo "Клиенту нужны geoip.dat/geosite.dat runetfreedom/russia-v2ray-rules-dat."
  echo "Для балансировки пользователь должен иметь доступ ко ВСЕМ выбранным хостам через свои группы."
  confirm_no_default "Создать/обновить шаблон ${name} и назначить выбранным хостам?" || return 0
  response="$(panel_request GET /api/subscription-templates)" || return 1
  jq -e '.response.templates | type=="array"' <<<"$response" >/dev/null || return 1
  uuid="$(jq -r --arg n "$name" '.response.templates[]? | select(.name==$n and .templateType=="XRAY_JSON") | .uuid' <<<"$response" | head -n1)"
  if [[ -n "$uuid" ]]; then
    panel_request GET "/api/subscription-templates/${uuid}" > "${BACKUP_DIR}/template-${uuid}-$(date +%s).json" || return 1
  else
    payload="$(mktemp)"
    jq -n --arg n "$name" '{name:$n,templateType:"XRAY_JSON"}' > "$payload"
    response="$(panel_request POST /api/subscription-templates "$payload")" || { rm -f "$payload"; return 1; }
    rm -f "$payload"
    uuid="$(jq -er '.response.uuid' <<<"$response")" || return 1
  fi
  payload="$(mktemp)"
  jq -n --arg u "$uuid" --slurpfile t "$file" '{uuid:$u,templateJson:$t[0]}' > "$payload"
  panel_request PATCH /api/subscription-templates "$payload" | jq -e '.response.uuid' >/dev/null || { rm -f "$payload"; return 1; }
  while read -r host; do
    panel_request GET "/api/hosts/${host}" > "${BACKUP_DIR}/host-${host}-$(date +%s).json" || { rm -f "$payload"; return 1; }
    jq -n --arg h "$host" --arg t "$uuid" '{uuid:$h,xrayJsonTemplateUuid:$t}' > "$payload"
    panel_request PATCH /api/hosts "$payload" | jq -e '.response.uuid' >/dev/null || { rm -f "$payload"; return 1; }
  done < <(jq -r '.[]' <<<"$SELECTED_HOSTS")
  rm -f "$payload"
  chmod 600 "${BACKUP_DIR}"/*.json
  ok "Шаблон назначен. Обнови Xray JSON-подписку в клиенте. Другие форматы подписок не поддерживают этот балансировщик."
}

host_payload_json() {
  local profile="$1" inbound="$2" port="$3" remark="$4"
  jq -n --arg p "$profile" --arg i "$inbound" --arg d "$DOMAIN" --arg r "$remark" --argjson port "$port" \
    '{remark:$r,address:$d,port:$port,sni:$d,host:"",path:"",keepSniBlank:false,overrideSniFromAddress:false,
      alpn:"h2,http/1.1",fingerprint:"chrome",securityLayer:"DEFAULT",
      inbound:{configProfileUuid:$p,configProfileInboundUuid:$i}}'
}

panel_create_hosts() {
  load_module panel
  load_state
  validate_domain "$DOMAIN" || die "Сначала настрой домен SelfSteal."
  panel_select_profile || return 1
  local response hosts tag uuid port payload existing path method backup found=0
  response="$(panel_request GET "/api/config-profiles/${PANEL_PROFILE_UUID}")" || return 1
  hosts="$(panel_request GET /api/hosts)" || return 1
  jq -e '.response | type=="array"' <<<"$hosts" >/dev/null || return 1
  mkdir -p "$PROFILE_DIR" "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  jq -e '.response.inbounds|type=="array"' <<<"$response" >/dev/null || die "API не вернул список inbound с UUID."
  while IFS=$'\t' read -r tag uuid port; do
    [[ -n "$uuid" ]] || continue
    # The actual inbound port is authoritative, not a saved manager default.
    case "$tag" in VLESS_SELFSTEAL_WITH_NGINX|VLESS_RAW_REALITY|VLESS_XHTTP_REALITY) ;; *) continue ;; esac
    found=$((found+1))
    validate_port "$port" || die "Нет корректного порта inbound ${tag}."
    payload="${PROFILE_DIR}/host-${tag}.json"
    host_payload_json "$PANEL_PROFILE_UUID" "$uuid" "$port" "${DOMAIN} ${tag}" > "$payload"
    chmod 600 "$payload"
    if [[ "$tag" == VLESS_XHTTP_REALITY ]]; then
      path="$(jq -r --arg t "$tag" '.response.config.inbounds[] | select(.tag==$t) | .streamSettings.xhttpSettings.path // ""' <<<"$response")"
      jq --arg p "$path" '.path=$p' "$payload" > "${payload}.tmp" && mv -f "${payload}.tmp" "$payload"
      chmod 600 "$payload"
    fi
    info "Настройки хоста: ${payload}; ключ/shortId/flow наследуются из inbound панели."
    existing="$(jq -r --arg i "$uuid" --arg d "$DOMAIN" '[.response[] | select(.inbound.configProfileInboundUuid==$i and .address==$d)][0].uuid // empty' <<<"$hosts")"
    method=POST
    if [[ -n "$existing" ]]; then
      backup="${BACKUP_DIR}/host-${existing}-$(date +%s).json"
      panel_request GET "/api/hosts/${existing}" > "$backup" || return 1
      chmod 600 "$backup"
      jq --arg u "$existing" --slurpfile old "$backup" '.uuid=$u | .remark=$old[0].response.remark' "$payload" > "${payload}.tmp" \
        && mv -f "${payload}.tmp" "$payload" || return 1
      chmod 600 "$payload"
      method=PATCH
    fi
    jq . "$payload"
    confirm_no_default "${method}: применить параметры хоста ${tag} ${DOMAIN}:${port}?" || continue
    panel_request "$method" /api/hosts "$payload" | jq -e '.response.uuid' >/dev/null || return 1
  done < <(jq -r '.response as $p | $p.inbounds[]? | . as $i | [$i.tag,$i.uuid,($p.config.inbounds[]? | select(.tag==$i.tag) | .port)] | @tsv' <<<"$response")
  [[ "$found" -gt 0 ]] || die "В выбранном профиле нет VLESS_SELFSTEAL_WITH_NGINX / VLESS_XHTTP_REALITY. Сначала примени профиль SelfSteal в Panel."
  echo "RAW: flow xtls-rprx-vision задаётся в inbound. XHTTP: без flow, path/mode из inbound."
}

clients_menu() {
  while true; do
    cat <<'EOF'
КЛИЕНТЫ И ХОСТЫ
  1. Создать / исправить хосты SelfSteal в Panel
  2. Назначить полный клиентский шаблон РФ-direct
  3. Настроить клиентский балансировщик
  0. Назад
EOF
    local choice
    read -r -p "Выбор: " choice || return 0
    case "$choice" in
      1) run_action panel_create_hosts; pause ;;
      2) run_action client_publish_template single; pause ;;
      3) run_action client_publish_template balancer; pause ;;
      0) return 0 ;;
    esac
  done
}
