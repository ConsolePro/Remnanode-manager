<p align="center">
  <img src="assets/remnanode-manager-logo.png" alt="RemnaNode Manager" width="220">
</p>

<h1 align="center">RemnaNode Manager</h1>

<p align="center">
  Один скрипт для установки и ежедневного администрирования Remnawave Node<br>
  на Ubuntu LTS и Debian stable. Ничего не нужно устанавливать — запускается одной командой.
</p>

> [!IMPORTANT]
> Скрипт запускается от `root`. Перед установкой рекомендуется иметь доступ к VPS-консоли провайдера на случай ошибки в DNS, firewall или сетевых настройках.

![Главный экран RemnaNode Manager](assets/dashboard.svg)

## Быстрый запуск

```bash
bash <(curl -Ls https://raw.githubusercontent.com/OverlayNode/Remnanode-manager/main/install.sh)
```

Запускается только `install.sh` — ядро: установка и управление нодой, Reality, профиль Xray, шапка и главное меню. Остальное вынесено в модули и подгружается при первом открытии соответствующего пункта меню:

| Модуль | Что внутри |
|---|---|
| [`sites`](modules/sites.sh) | сайты-заглушки: каталог шаблонов, уникализация |
| [`routing`](modules/routing.sh) | geo-файлы roscomvpn, DNS, политика РФ-трафика, клиентская маршрутизация |
| [`panel`](modules/panel.sh) | Remnawave Panel API |
| [`warp`](modules/warp.sh), [`psiphon`](modules/psiphon.sh), [`tor`](modules/tor.sh), [`zapret`](modules/zapret.sh) | внешние выходы и обход DPI |
| [`monitor`](modules/monitor.sh) | live-монитор, ресурсы, порты, логи, диагностика |
| [`admin`](modules/admin.sh) | UFW, BBR, swap, ping, fail2ban, обновления, бэкапы |
| [`clients`](modules/clients.sh) | хосты, полный клиентский JSON, балансировщик |
| [`extensions`](modules/extensions.sh) | замена ядра Xray, плагины ноды через API |
| [`network`](modules/network.sh) | диагностика, IPv6, серверный мост |
| [`checker`](modules/checker.sh) | внешний Xray Checker |

Модуль берётся из каталога `modules/` рядом со скриптом (клон репозитория), из `/usr/local/lib/remnanode/modules` (установленная команда) или скачивается из GitHub в `/run/remnanode-manager/modules`. Скачанный модуль проходит `bash -n` и должен совпадать по версии с ядром — иначе он не загружается. Шаблоны сайтов скачиваются только в момент выбора шаблона.

По желанию можно поставить команду `remnanode` вместе со всеми модулями, чтобы запускать меню без `curl` и без сети (меню → «Администрирование» → «Установить команду remnanode» или `install.sh install-command`). Повторный запуск этого пункта обновляет команду и модули.

### Более проверяемый способ

```bash
git clone https://github.com/OverlayNode/Remnanode-manager.git
cd Remnanode-manager
for file in install.sh modules/*.sh; do bash -n "$file" || exit; done
sudo ./install.sh
```

При запуске из клона модули и шаблоны берутся из локальных каталогов, без обращения к сети.

## Возможности

- **Установка Node** — три сценария:
  - только RemnaNode (Xray внутри ноды);
  - RemnaNode + Selfsteal + SSL;
  - Selfsteal для уже установленной Node (существующий Compose дополняется, а не перезаписывается).
- **Версия Node** — обновление, выбор тега с Docker Hub, откат на предыдущую версию по digest (работает даже с `latest`), закрепление версии.
- **Сайты-заглушки** — 12 готовых шаблонов; при каждом развёртывании сайт уникализируется.
- **Протоколы** — VLESS TCP (RAW) + Reality + Vision, VLESS XHTTP + Reality, Hysteria2: любой один или сразу все; 3–12 случайных shortIds, ротация ключей.
- **Routing** — сервер без автоматического РФ-block, полный клиентский JSON РФ-direct, балансировщик и мост через VLESS/Shadowsocks; опциональные серверные geo-файлы.
- **DNS** — общий DoH ноды без фильтрации CDN по стране IP, отдельный клиентский DNS; перехват порта 53 включается по выбору.
- **Модули** — WARP, Psiphon, Tor (с мостами obfs4/webtunnel/snowflake), Zapret2.
- **Мониторинг** — шапка со статусами и метриками, live-монитор, Docker, порты и подключения, логи, диагностика, тест скорости.
- **Администрирование** — UFW, BBR, swap, ping, fail2ban, обновление системы, очистка Docker, бэкапы.
- **Remnawave Panel API** — обновление Config Profile с diff и backup (режимы merge и full).

## Шапка

При каждом открытии меню показывается состояние сервера:

```text
 ● Node        ONLINE         Ver: 2.1.3
 ● Xray        RUNNING        Ver: 25.9.11
 ● Selfsteal   HEALTHY        nginx · status-page · SSL 71d
 ● Panel       CONNECTED      API ✓

 CPU   8%        RAM  624 MB / 2 GB        Disk 18%
 Load  0.08      Uptime 14d 8h             Docker RUNNING

 IPv4  185.xxx.xxx.xxx
 IPv6  — нет
```

| Строка | Как определяется |
|---|---|
| Node | `ONLINE` — контейнер запущен, Node API слушает порт и Xray работает; `WAITING` — API поднят, Panel ещё не прислала конфиг; `DEGRADED`, `OFFLINE` |
| Xray | процесс `xray` / `rw-core`; версия — из бинарника в контейнере |
| Selfsteal | healthcheck `nginx-selfsteal` и наличие `/dev/shm/nginx.sock`, текущий шаблон, дни до конца сертификата |
| Panel | `CONNECTED` — есть соединение Panel → Node или Xray получил конфиг; `API ✓/✗` — если сохранён API-токен |
| IPv4/IPv6 | публичные адреса интерфейсов; за NAT — внешний адрес (кешируется на час) |

## Сценарии установки

| Пункт меню | Что делает |
|---|---|
| 1. RemnaNode | Docker, Compose, UFW, контейнер `remnanode`. Inbound'ы настраиваются в Panel |
| 2. RemnaNode + Selfsteal + SSL | + домен, сертификат Let's Encrypt (acme.sh), `nginx-selfsteal` на `/dev/shm/nginx.sock`, сайт-заглушка, Xray-профиль с RAW / XHTTP / Hysteria2 |
| 3. Selfsteal к установленной Node | находит Compose существующей ноды и безопасно дополняет его через PyYAML (с backup и `docker compose config`) |

Дополнительные серверные geo-файлы можно подключить через Routing. Для полного клиентского шаблона базы обновляет клиент, устанавливать их на ноду не требуется.

### Протоколы

При установке Selfsteal (и в меню «Xray profile» → «Настроить inbound'ы заново») можно выбрать один протокол или любую комбинацию: `1`, `1,3`, `2,3`, `1,2,3`.

| # | Протокол | Порт по умолчанию | Маскировка |
|---|---|---|---|
| 1 | VLESS TCP (RAW) + REALITY + Vision | `443/tcp` | Reality → собственный Selfsteal-сайт |
| 2 | VLESS XHTTP + REALITY | `8443/tcp` (или `443`, если RAW не выбран) | Reality → собственный Selfsteal-сайт, случайный path |
| 3 | Hysteria2 | `443/udp` | TLS-сертификат домена ноды |

TCP и UDP `443` используются одновременно без конфликта.

#### Hysteria2 и обфускация Salamander

При подключении из РФ ТСПУ режет или замедляет QUIC/HTTP3 на UDP 443 к зарубежным IP, а Hysteria2 по умолчанию выглядит именно как QUIC. При выборе Hysteria2 скрипт предлагает включить **Salamander** — обфускацию, после которой трафик выглядит как случайный UDP.

Remnawave берёт параметры обфускации для ссылки `hysteria2://` не из inbound'а, а из настроек Host, поэтому после включения нужно **вставить выведенный скриптом JSON в Panel → Hosts → хост HYSTERIA2 → Final mask**, например:

```json
{"udp":[{"type":"salamander","settings":{"password":"<пароль из profile-info>"}}]}
```

Без этого клиент получит ссылку без `obfs` и не подключится. Включить или выключить Salamander позже: меню «Xray profile» → «Hysteria2: обфускация Salamander».

Если Hysteria2 не подключается — меню «Xray profile» → «Проверить Hysteria2». Проверка по шагам покажет, где обрыв: inbound в профиле, Xray слушает UDP-порт (то есть Panel применила профиль), UFW, сертификат и его домен, доступ контейнера к ключу, ошибки в логах ноды, профиль и пароль обфускации в Panel. Firewall провайдера (security group) должен отдельно пропускать UDP-порт. Flow `xtls-rprx-vision` назначается пользователям в Panel только для RAW, не для XHTTP. Ноде без Selfsteal (пункт 1) inbound'ы задаются в Panel: для Reality и Hysteria2 нужны домен и сертификат, которые настраивает Selfsteal.

### Версия Node

Меню «Управление Node»:

- **обновить** — `pull` текущего тега; digest прежнего образа сохраняется для отката;
- **выбрать версию** — список тегов `remnawave/node` с Docker Hub;
- **откатиться** — возврат на сохранённый digest; если после смены версии нода не поднялась, откат предлагается автоматически;
- **закрепить** — образ фиксируется по digest, обновления перестают его менять.

## Шаблоны сайтов-заглушек

Шаблоны лежат в [`templates/sites`](templates/sites). Все сделаны на чистых HTML, CSS, JS и SVG, без внешних CDN и шрифтов, и совместимы со строгим CSP nginx (без inline-скриптов и стилей, без форм и полей паролей).

| | | |
|---|---|---|
| **cloud-gateway**<br>![](templates/sites/cloud-gateway/preview.png) | **status-page**<br>![](templates/sites/status-page/preview.png) | **dev-docs**<br>![](templates/sites/dev-docs/preview.png) |
| **file-transfer**<br>![](templates/sites/file-transfer/preview.png) | **cdn-edge**<br>![](templates/sites/cdn-edge/preview.png) | **analytics-saas**<br>![](templates/sites/analytics-saas/preview.png) |
| **photo-studio**<br>![](templates/sites/photo-studio/preview.png) | **game-studio**<br>![](templates/sites/game-studio/preview.png) | **unit-converter**<br>![](templates/sites/unit-converter/preview.png) |
| **net-diagnostics**<br>![](templates/sites/net-diagnostics/preview.png) | **maintenance**<br>![](templates/sites/maintenance/preview.png) | **tech-blog**<br>![](templates/sites/tech-blog/preview.png) |

Скриншоты сделаны с одним из случайных вариантов: цвет и бренд на сервере будут другими.

### Уникальный отпечаток

Даже один и тот же шаблон при каждом развёртывании и при каждой перегенерации (меню «Сайт-заглушка» → «Перегенерировать») отличается:

- случайный префикс всех CSS-классов (`xq-banner`, `pks-banner`, …);
- случайный каталог ресурсов и имена файлов (`/static/7a01cf/524db1fe.css`, `/dist/974da2/…`);
- случайный оттенок палитры, бренд, версия, build-метки;
- случайное число бессмысленных, но валидных CSS-правил, дополнения в JS, атрибуты `<body>`;
- случайная минификация HTML;
- собственный favicon.

В итоге у HTML, CSS и JS каждый раз другие SHA-256, размеры и структура. Предыдущие 5 версий сайта хранятся в `backups/`, откат — одним пунктом меню.

Бренд можно задать постоянный или оставить случайным при каждом развёртывании.

## Переход на 5.0 и стабильная работа

В 4.x сервер по умолчанию блокировал российские IP/домены, а split DNS принимал ответы для РФ-доменов только с российскими IP. Это могло ломать CDN, изображения и отдельные сайты. В 5.0 страновые правила на ноде выключены, DNS не ограничивает страну ответа, перехват клиентского DNS выключен, выход Xray использует IPv4. Изменение этих значений **не меняет уже сохранённый Config Profile в Panel**.

Для существующей установки:

1. Обнови установленную команду и модули через `bash install.sh install-command` из обновлённого клона.
2. `sudo remnanode network` → «Стабильный профиль»: сохраняет backup состояния и генерирует новый профиль. Старые явно сохранённые настройки не сбрасываются при обычном запуске меню.
3. Panel API → отправка профиля в режиме merge: просмотри diff, проверь результат Xray и примени. Merge оставляет inbound-параметры панели, обновляя outbounds/routing/dns.
4. `sudo remnanode clients` → настрой хосты, затем назначь полный клиентский JSON выбранным хостам. Обнови именно Xray JSON-подписку на устройствах.
5. Если проблема повторяется, `sudo remnanode network` → диагностика. Проверяй DNS, HTTP/TLS IPv4/IPv6, OOM/перезапуски, conntrack и свободное место. Проверка с ноды не заменяет проверку через реальное клиентское подключение.

Скрипт не устанавливает причину прежних обрывов без данных действующей ноды. TCP MTU probing/keepalive применяются отдельным пунктом, с сохранением предыдущих sysctl. Это помогает при некоторых проблемах PMTU/мёртвых соединений, но не исправляет ограничения IP со стороны сайта или недоступный серверный выход.

## Routing, клиенты и хосты

Серверный профиль и клиентский JSON решают разные задачи. `DIRECT` на ноде выходит с **IP ноды**. Российский сайт получает IP пользователя только при клиентском direct; другой вариант — настроенный мост на сервер в РФ. WARP не гарантирует российский IP.

Готовый клиентский шаблон: [`templates/subscriptions/xray-ru-direct.json`](templates/subscriptions/xray-ru-direct.json). Подробности и требования: [инструкция](templates/subscriptions/README.md).

```bash
sudo remnanode client-template  # /opt/remnanode/profiles/subscription-xray-ru-direct.json
sudo remnanode clients          # хосты, публикация JSON, балансировщик
sudo remnanode network          # серверный мост, IPv6, диагностика
```

- Клиентский шаблон: РФ напрямую, заблокированные RU-ресурсы через прокси с приоритетом по GeoSite, BitTorrent в блок. Sniffing меняет только выбор маршрута (`routeOnly`). DNS использует Yandex DoH с bootstrap-адресом и резервным UDP DNS, как упрощённый вариант предоставленного рабочего конфига. Это не обещает отсутствие любых DNS-утечек; DNS устройства/браузера и split tunneling настраиваются в клиенте.
- Балансировщик: хосты подставляет панель через `injectHosts`, `burstObservatory` измеряет задержку, `leastPing` выбирает выход. При отказе всех выходов — `block`, чтобы не отправить зарубежный трафик напрямую. Пользователю нужен доступ ко всем выбранным хостам через группы панели. Балансировщик назначается выбранным существующим хостам; они остаются видимыми в подписке. Для каждой группы доступов выбирай собственный набор хостов.
- Хосты SelfSteal создаются или исправляются с backup по UUID/порту inbound панели: address/SNI = домен ноды, security = DEFAULT, fingerprint = chrome, ALPN = h2/http/1.1. Reality publicKey/shortId и транспорт наследуются из inbound. Для RAW в inbound клиента панели нужен flow `xtls-rprx-vision`, для XHTTP flow пустой; path обновляется из streamSettings, mode наследуется из inbound; имя существующего хоста сохраняется. Генератор создаёт RAW/XHTTP-хосты, Hysteria2 продолжает настраиваться по `profile-info.txt`.
- Серверный мост: подготовь на втором сервере служебный inbound VLESS/Shadowsocks с UDP и передай его исходящий JSON мастеру. Можно отправлять через мост российский трафик либо зарубежный. Мастер генерирует локальный профиль; установка удалённого сервера и создание служебного пользователя не выполняются. Приватные сети и торрент-блок имеют приоритет перед мостом. Правила выбранных WARP/Tor/Psiphon-доменов также выполняются раньше моста.
- roscomvpn: нужен на каждой исполняющей `ext:roscom-*.dat` серверной ноде. Для клиентского JSON используются отдельные базы runetfreedom; источники не взаимозаменяемы.

## Ядро, плагины, WARP, IPv6, сертификаты, мониторинг

```bash
sudo remnanode extensions  # Xray и плагины ноды через Panel API
sudo remnanode checker     # Xray Checker на отдельном сервере
```

**Ядро Xray.** Загружается последняя стабильная официальная сборка XTLS для x86_64/arm64; SHA256 обязательна. Версионный read-only bind mount перекрывает `/usr/local/bin/xray`. При неудачном запуске восстанавливается прежний Compose. Уже работавший Xray обязан снова перейти в ONLINE: одного WAITING для успешного обновления недостаточно. Чужой mount не перезаписывается. У новых Node `rw-core` может указывать на отдельное ядро профиля панели — проверяй фактически работающую версию в статусе. Новые REALITY-сборки могут требовать актуальные клиенты/uTLS; сначала проверяй обновление на одной ноде.

**Плагины.** У ноды один `activePluginUuid`. Torrent Blocker и остальные секции хранятся в общем плагине. Сохраняются прочие настройки, выполняются PATCH → sync → привязка выбранных нод, предыдущая конфигурация/привязки копируются в backups. Torrent Blocker требует Node 2.7+ и Xray 26.3.27+, блокирует IP целиком; пользователи за одним NAT могут получить общий бан. Доступны длительность бана, IP-исключения без CIDR, статистика и JSON-редактор для ingress/egress. API должен поддерживаться версией панели; на старой панели операция завершается ошибкой.

**WARP Native.** Используется [distillium/warp-native](https://github.com/distillium/warp-native), интерфейс `warp`, `Table = off`, mark `51888` для совместимости с его kill-switch. Общий default route не переводится в WARP. Перед включением outbound проверяются интерфейс и `warp=on/plus`. Установщик меняет системный DNS; менеджер сохраняет и восстанавливает содержимое `/etc/resolv.conf`. Ранее установленный сторонний WARP автоматически не мигрируется и может не иметь kill-switch Native. Изменение профиля требуется отправить в Panel.

**IPv6.** Можно отдельно выбрать dual-stack Xray или изменить IPv6 ОС. По умолчанию меняется только предпочтение выхода Xray. При отключении IPv6 ОС по текущему IPv6 SSH операция отклоняется; значения sysctl сохраняются. Скрипт не меняет GRUB и не создаёт отсутствующие адреса/маршруты провайдера. При включении IPv6 ОС нужно проверить сетевой менеджер и AAAA-записи.

**SelfSteal и сертификаты.** Xray принимает Reality и передаёт маскировочный TLS на Unix-сокет Nginx с PROXY protocol. Nginx отдаёт HTTP → HTTPS с фиксированным настроенным доменом, без доверия пользовательскому Host. Если Reality TCP-порт нестандартный, он входит в redirect; при одном Hysteria2 Nginx обслуживает TCP/443 сам. IPv6-публикацию входящих портов нужно согласовать с AAAA и listen-настройками; серверный `IP_MODE=dual` управляет только исходящим трафиком.

ACME pre-hook освобождает 80 остановкой только `nginx-selfsteal`, post-hook возвращает его после выпуска/ошибки. Посторонний слушатель 80 не останавливается. Hooks сохраняются acme.sh для автоматического продления; при переходе существующей установки запусти ручной renew один раз. Reload проверяет Nginx, перезапускает работающую ноду только при включённом Hysteria2. Ошибка CA не показывается как успешное продление. Сертификаты подключены каталогом, чтобы новые файлы были видны контейнерам. При изменении конфигурации Nginx сохраняется inode bind-mounted файла.

**Xray Checker.** Устанавливается на отдельном сервере, использует служебную HTTPS-подписку, методы `ip/status/download`, обновление подписки и локальные метрики/UI на `127.0.0.1:2112`. Доступ: SSH-туннель `ssh -L 2112:127.0.0.1:2112 root@monitor-server`. Публичный домен, Telegram-бот и отдельная статус-страница в этом модуле не разворачиваются. Доступны настройка, статус, логи, перезапуск, обновление и удаление контейнера. Конфиг с URL подписки имеет права 600; не публикуй его.

## Проверки

```bash
for file in install.sh modules/*.sh tests/*.sh; do bash -n "$file" || exit; done
bash tests/test_install.sh
bash tests/test_features.sh
python3 tests/test_compose.py  # python3-yaml
RNM_XRAY_BIN=/path/to/xray RNM_XRAY_ASSETS=/path/to/assets python3 tests/test_xray_runtime.py
```

В runtime-тесте используется настоящее ядро и базы runetfreedom; секреты реальных пользователей не нужны. Тест подставляет локальные outbound-заглушки вместо результата рендеринга панели. Реальные Panel API, Docker/ACME на Linux, внешние VPN-подключения и длительная работа на VPS требуют отдельной проверки развёртывания.

Реализация опирается на [eGamesAPI/remnawave-reverse-proxy](https://github.com/eGamesAPI/remnawave-reverse-proxy), изученный commit `93e6631aae5f7bff28eadfc45faab43150cc22c6`. Лицензия источника: [MIT](LICENSE.egames). Использованы подходы SelfSteal, монтирования ядра, общего плагина и API шаблонов; исходный установщик целиком не запускается.

## Модули

| Модуль | Источник | Как подключается | Примечание |
|---|---|---|---|
| **WARP** | [distillium/warp-native](https://github.com/distillium/warp-native) | outbound `WARP`: `freedom` + `sockopt.interface: warp` | default route ОС не меняется; домены — в `routing/warp.list` |
| **Psiphon** | [Chara-Freedom/vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon) | outbound `PSIPHON`: SOCKS5 `127.0.0.1:1080`, только TCP | ставится с `--bind-loopback`; не использовать как выход из страны с DPI |
| **Tor** | пакет `tor` | outbound `TOR`: SOCKS5 `127.0.0.1:9050` | мосты obfs4 / webtunnel / snowflake для серверов в РФ; `.onion` → Tor |
| **Zapret2** | [bol-van/zapret2](https://github.com/bol-van/zapret2) | обработка исходящего трафика сервера (nfqws2) | архив релиза сверяется с `sha256sum.txt`; интерактивный `install_easy.sh`, `blockcheck2` для подбора стратегии |

Сторонние установщики WARP и Psiphon скачиваются во временный файл и проходят `bash -n`. Перед запуском скрипт показывает URL и SHA-256 и ждёт подтверждения.

## Remnawave Panel API

Меню «Remnawave Panel API»:

1. Сохранить URL панели и API-токен (`/opt/remnanode/panel.env`, `0600`).
2. Выбрать Config Profile.
3. Отправить профиль:
   - **merge** — inbound'ы панели остаются, заменяются `outbounds`, `routing`, `dns` (подходит для любой ноды);
   - **full** — профиль заменяется целиком (для Selfsteal-нод со сгенерированными inbound'ами).

Перед отправкой текущий профиль сохраняется в `backups/` и показывается diff (приватные ключи скрыты). Используются `GET /api/config-profiles`, `GET /api/config-profiles/{uuid}` и `PATCH /api/config-profiles`.

Токен не обязателен: без него статус Panel в шапке определяется по связи панели с нодой.

## Мониторинг и администрирование

- **Live-монитор** — шапка, топ процессов, `docker stats`, подключения по inbound'ам с числом уникальных IP; обновление каждые 3 с.
- **Сервер подробно** — ОС, CPU, RAM, swap, диски, сеть, трафик интерфейсов, BBR, NTP.
- **Порты** — слушающие сокеты, нагрузка по inbound'ам, топ-10 IP.
- **Логи** — RemnaNode (в том числе в реальном времени), nginx, журнал скрипта, системные ошибки, UFW, WARP / Psiphon / Tor.
- **Диагностика** — Docker, контейнеры, firewall, geo-файлы, модули, DNS, сертификаты, TLS через Reality fallback, проверка профиля в Xray ноды.
- **Администрирование** — UFW (открыть или закрыть порт, разрешить IP), BBR, swap, ответы на ping, fail2ban для SSH, `apt upgrade`, очистка Docker, перезагрузка.
- **Бэкапы** — архив `/opt/remnanode` (без кеша и старых бэкапов) и восстановление.

## Команды

```bash
install.sh                  # интерактивное меню
install.sh status           # только шапка
install.sh install-command  # установить команду remnanode
install.sh geo-update       # обновить geo-файлы roscomvpn
install.sh site-refresh     # перегенерировать сайт с новым отпечатком
install.sh profile          # пересобрать Xray profile
```

## Файлы и каталоги

```text
/opt/remnanode/
├── docker-compose.yml          Compose ноды (0600)
├── installer.conf              состояние скрипта
├── reality.env                 Reality keys и shortIds (0600)
├── panel.env                   URL и токен Panel API (0600)
├── nginx.conf                  конфигурация Selfsteal
├── ssl/                        сертификат и ключ
├── html/                       текущий сайт-заглушка
├── geo/                        roscom-geosite.dat, roscom-geoip.dat
├── routing/                    warp.list, psiphon.list, tor.list
├── profiles/                   xray-profile.json, profile-info.txt, клиентские routing / DNS / приложения
├── backups/                    бэкапы, копии сайта, профили из Panel
└── .cache/                     кеш каталога шаблонов
/usr/local/bin/remnanode               команда (после install-command)
/usr/local/lib/remnanode/modules/      модули установленной команды
/run/remnanode-manager/modules/        кеш скачанных модулей (до перезагрузки)
/usr/local/sbin/remnanode-geo-update   ежедневное обновление geo (systemd timer)
/var/log/remnanode-manager.log         журнал
```

## Порты

| Порт / endpoint | Назначение | Публичный доступ |
|---|---|---|
| SSH (обычно `22/tcp`) | администрирование | нужен администратору |
| `2222/tcp` | RemnaNode API, подключение Panel → Node | желательно только с IP/CIDR Panel |
| `80/tcp` | ACME HTTP-01 | нужен для выпуска и продления сертификата |
| `443/tcp` | VLESS RAW + Reality | клиентам |
| `8443/tcp` | VLESS XHTTP + Reality | клиентам, если используется XHTTP |
| `443/udp` | Hysteria2 | клиентам, если используется Hysteria2 |
| `/dev/shm/nginx.sock` | Reality Selfsteal target | локальный UNIX socket |
| `127.0.0.1:1080` | Psiphon SOCKS | только локально |
| `127.0.0.1:9050` | Tor SOCKS | только локально |

## Внешние подключения

| Адрес | Когда |
|---|---|
| `raw.githubusercontent.com`, `codeload.github.com` | запуск скрипта, модули при первом открытии, каталог шаблонов, команда `remnanode` |
| `download.docker.com`, Docker Hub | установка Docker, образы, список тегов `remnawave/node` |
| `get.acme.sh`, Let's Encrypt | выпуск и продление сертификата |
| `github.com/hydraponique/roscomvpn-*` | geo-файлы (при включении и ежедневно) |
| `api.github.com/repos/bol-van/zapret2` | установка Zapret2 |
| DNS-резолверы из настроек (по умолчанию Яндекс, Cloudflare, Google) | резолв доменов Xray на ноде |
| URL вашей панели | только при настроенном Panel API |
| `api.ipify.org` | внешний IPv4, только если на интерфейсах нет публичного адреса |
| `speed.cloudflare.com`, `www.cloudflare.com/cdn-cgi/trace`, `check.torproject.org` | только по запросу: тест скорости и проверки модулей |

Скрипт не отправляет телеметрию.

## Разработка

```bash
for file in install.sh modules/*.sh; do bash -n "$file" || exit; done
bash tests/test_install.sh           # нужны jq и openssl
shellcheck -x install.sh modules/*.sh tests/*.sh tools/*.sh
bash tools/render-previews.sh        # пересобрать preview.png (Chrome/Chromium + python3)
```

Новый модуль — файл `modules/<name>.sh` со строкой `RNM_MODULE_VERSION="<версия ядра>"`; его имя добавляется в `RNM_MODULES`, а пункт меню вызывает `open_module_menu <name> <функция>`. При смене версии ядра обновляется маркер во всех модулях.

Новый шаблон — это каталог `templates/sites/<name>/` с файлами `index.html`, `404.html`, `manifest.json`, CSS/JS/SVG. В нём доступны плейсхолдеры:

| Плейсхолдер | Значение |
|---|---|
| `__P__` | префикс классов |
| `__BRAND__`, `__BRAND_SLUG__` | бренд |
| `__DOMAIN__` | домен ноды |
| `__HUE__`, `__HUE2__` | оттенки палитры |
| `__SEED__` | число для JS |
| `__VERSION__`, `__BUILD__` | версия и build-метка |
| `__YEAR__` | текущий год |

Ссылки на ресурсы должны быть абсолютными (`/style.css`, `/assets/x.svg`). Тесты проверяют, что после рендера не остаётся плейсхолдеров, inline-скриптов и стилей, форм, а все ссылки ведут на существующие файлы.

## Важные замечания

- Не публикуйте `installer.conf`, `reality.env`, `panel.env`, `docker-compose.yml` и бэкапы: там `SECRET_KEY`, приватные ключи и токены.
- Регенерация Reality keys или shortIds требует обновить клиентские конфигурации.
- Не назначайте один TCP-порт одновременно RAW и XHTTP.
- Firewall провайдера (security group) нужно настраивать отдельно.

## Решение проблем

### APT/dpkg занят unattended-upgrades

Сразу после запуска VPS на Ubuntu автоматическое обновление может удерживать `/var/lib/dpkg/lock-frontend`. Удалять lock-файл вручную нельзя. Скрипт ждёт освобождения APT до 600 секунд; таймаут можно изменить:

```bash
APT_LOCK_TIMEOUT=1200 bash <(curl -Ls https://raw.githubusercontent.com/OverlayNode/Remnanode-manager/main/install.sh)
```

### Xray не запускается после включения geo

Проверь, что на ноде есть файлы (меню «Мониторинг» → «Диагностика», раздел Routing / geo). Если профиль с `ext:`-правилами назначен ноде без geo-файлов, включи на ней geo или отправь в Panel профиль без них.
