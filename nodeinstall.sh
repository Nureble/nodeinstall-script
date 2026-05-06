#!/usr/bin/env bash
#
# nodeinstall.sh — Prometheus + Node Exporter + Grafana installer/uninstaller
# Дашборд: https://grafana.com/grafana/dashboards/1860-node-exporter-full
#
# Поддержка: Debian 11+ / Ubuntu 20.04+ на amd64 / arm64 / armhf
# Требования: systemd, sudo (или запуск от root), интернет.
#

set -Eeuo pipefail

# ------------------------------------------------------------------
# Цвета
# ------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'
    BLUE=$'\e[1;34m'; PURPLE=$'\e[1;35m'; RESET=$'\e[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; PURPLE=""; RESET=""
fi

# ------------------------------------------------------------------
# Логирование
# ------------------------------------------------------------------
LOG_FILE="/tmp/nodeinstall-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG_FILE"

log()   { printf '%s [INFO ] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
info()  { echo -e "${YELLOW}==>${RESET} $*"; log "$*"; }
ok()    { echo -e "${GREEN}[OK]${RESET} $*"; log "OK: $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; log "WARN: $*"; }
err()   { echo -e "${RED}[ERR]${RESET} $*" >&2; log "ERR: $*"; }
die()   { err "$*"; echo -e "${RED}Подробности в $LOG_FILE${RESET}" >&2; exit 1; }

trap 'die "Сбой на строке $LINENO (команда: $BASH_COMMAND)"' ERR

# ------------------------------------------------------------------
# Запуск шага с индикатором
# ------------------------------------------------------------------
run_step() {
    local msg="$1"; shift
    echo -ne "${YELLOW}${msg}...${RESET} "
    if "$@" >>"$LOG_FILE" 2>&1; then
        echo -e "${GREEN}[OK]${RESET}"
    else
        echo -e "${RED}[FAIL]${RESET}"
        die "Шаг \"$msg\" завершился с ошибкой. См. $LOG_FILE"
    fi
}

# ------------------------------------------------------------------
# Баннер
# ------------------------------------------------------------------
print_banner() {
    clear
    cat <<EOF
${BLUE}======================================================${RESET}
${BLUE}       _______       _____            __   __ ${RESET}
${BLUE}    /\\|__   __|/\\   |  __ \\     /\\    \\ \\ / / ${RESET}
${BLUE}   /  \\  | |  /  \\  | |__) |   /  \\    \\ V /  ${RESET}
${BLUE}  / /\\ \\ | | / /\\ \\ |  _  /   / /\\ \\    > <   ${RESET}
${BLUE} / ____ \\| |/ ____ \\| | \\ \\  / ____ \\  / . \\  ${RESET}
${BLUE}/_/    \\_\\_/_/    \\_\\_|  \\_\\/_/    \\_\\/_/ \\_\\ ${RESET}
${BLUE}======================================================${RESET}
${PURPLE}   Easy install Node Exporter Full Dashboard${RESET}
${YELLOW}     Prometheus + Node Exporter + Grafana${RESET}
${BLUE}======================================================${RESET}
EOF
}

# ------------------------------------------------------------------
# Проверки окружения
# ------------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo &>/dev/null; then
            SUDO="sudo"
        else
            die "Нужны права root (или установленный sudo)."
        fi
    else
        SUDO=""
    fi
}

detect_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release не найден — неизвестный дистрибутив."
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ;;
        *) die "Поддерживаются только Debian и Ubuntu (обнаружено: ${ID:-unknown})." ;;
    esac
    log "OS: $PRETTY_NAME"
}

detect_arch() {
    local dpkg_arch
    dpkg_arch=$(dpkg --print-architecture)
    case "$dpkg_arch" in
        amd64) PROM_ARCH="amd64" ;;
        arm64) PROM_ARCH="arm64" ;;
        armhf) PROM_ARCH="armv7" ;;   # у Prometheus артефакт называется armv7
        *) die "Архитектура $dpkg_arch не поддерживается." ;;
    esac
    log "Architecture: dpkg=$dpkg_arch, prometheus=$PROM_ARCH"
}

require_systemd() {
    [[ -d /run/systemd/system ]] || die "systemd не обнаружен — этот скрипт его требует."
}

# ------------------------------------------------------------------
# Установка зависимостей
# ------------------------------------------------------------------
install_prereqs() {
    info "Обновляю apt и ставлю зависимости"
    run_step "apt update" $SUDO apt-get update -y
    run_step "Установка пакетов" $SUDO apt-get install -y \
        curl wget jq tar ca-certificates gnupg apt-transport-https software-properties-common
}

# ------------------------------------------------------------------
# Скачать последний релиз с GitHub + проверить SHA256
# Аргументы: $1 = repo (например prometheus/prometheus)
#            $2 = arch suffix (amd64/arm64/armv7)
#            $3 = выходной .tar.gz
#            $4 = выходное имя каталога (через nameref)
# ------------------------------------------------------------------
download_github_release() {
    local repo="$1" arch="$2" out_tgz="$3"
    local -n out_dir_ref="$4"

    local api="https://api.github.com/repos/${repo}/releases/latest"
    local meta
    meta=$(curl -fsSL "$api") || die "Не получилось обратиться к $api (rate-limit?)"

    # Подбираем именно linux-<arch>.tar.gz. Ограничиваем результат в самом jq
    # через first(...) — это безопаснее, чем `| head -n1` под set -o pipefail.
    local tgz_url sums_url
    tgz_url=$(echo "$meta" | jq -r --arg pat "linux-${arch}\\.tar\\.gz$" \
        'first(.assets[] | select(.name | test($pat)) | .browser_download_url) // empty')
    sums_url=$(echo "$meta" | jq -r \
        'first(.assets[] | select(.name | test("sha256sums\\.txt$")) | .browser_download_url) // empty')

    [[ -n "$tgz_url" ]] || die "Не найден linux-${arch} артефакт в последнем релизе ${repo}"

    log "Скачиваю $tgz_url"
    curl -fSL --retry 3 "$tgz_url" -o "$out_tgz"

    # Проверка SHA256, если файл с суммами есть
    if [[ -n "$sums_url" ]]; then
        local sums_file="${out_tgz}.sha256sums"
        curl -fsSL "$sums_url" -o "$sums_file"
        local expected actual fname
        fname=$(basename "$tgz_url")
        expected=$(awk -v f="$fname" '$2==f || $2=="*"f {print $1; exit}' "$sums_file")
        if [[ -n "$expected" ]]; then
            actual=$(sha256sum "$out_tgz" | awk '{print $1}')
            [[ "$expected" == "$actual" ]] || die "SHA256 mismatch для $fname"
            log "SHA256 OK для $fname"
        else
            warn "В sha256sums.txt не нашлось записи для $fname — пропускаю проверку"
        fi
    else
        warn "sha256sums.txt не опубликован — пропускаю проверку"
    fi

    # Распаковка. Имя каталога вытаскиваем после распаковки через find,
    # без pipe — иначе pipefail + SIGPIPE от head валит pipeline.
    local extract_dir
    extract_dir=$(dirname "$out_tgz")

    # Распаковываем во временный поддиректорий, чтобы там был ровно один каталог
    local subdir="${extract_dir}/unpacked.$$"
    mkdir -p "$subdir"
    tar -xf "$out_tgz" -C "$subdir"

    # В архивах prometheus/node_exporter всегда один корневой каталог
    local found
    found=$(find "$subdir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
    [[ -n "$found" && $(wc -l <<<"$found") -eq 1 ]] \
        || die "Ожидался один каталог в архиве, получено: $found"

    # Переносим к стандартному пути и подчищаем
    mv "$subdir/$found" "$extract_dir/$found"
    rmdir "$subdir"
    out_dir_ref="$found"
    [[ -d "$extract_dir/$out_dir_ref" ]] || die "Распакованный каталог не найден"
}

# ------------------------------------------------------------------
# Prometheus
# ------------------------------------------------------------------
install_prometheus() {
    info "Устанавливаю Prometheus"

    if ! id prometheus &>/dev/null; then
        $SUDO useradd --system --no-create-home --shell /usr/sbin/nologin prometheus
    fi
    $SUDO mkdir -p /etc/prometheus /var/lib/prometheus

    local tmp; tmp=$(mktemp -d)
    local pdir
    download_github_release "prometheus/prometheus" "$PROM_ARCH" "$tmp/prom.tar.gz" pdir

    $SUDO install -m 0755 -o prometheus -g prometheus "$tmp/$pdir/prometheus" /usr/local/bin/prometheus
    $SUDO install -m 0755 -o prometheus -g prometheus "$tmp/$pdir/promtool"   /usr/local/bin/promtool
    $SUDO cp -r "$tmp/$pdir/consoles"         /etc/prometheus/ 2>/dev/null || true
    $SUDO cp -r "$tmp/$pdir/console_libraries" /etc/prometheus/ 2>/dev/null || true

    # Детерминированный конфиг (никаких sed)
    $SUDO tee /etc/prometheus/prometheus.yml >/dev/null <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: node
    static_configs:
      - targets: ['localhost:9100']
EOF

    $SUDO chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

    $SUDO tee /etc/systemd/system/prometheus.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus
Documentation=https://prometheus.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus/ \
  --web.console.templates=/etc/prometheus/consoles \
  --web.console.libraries=/etc/prometheus/console_libraries \
  --web.listen-address=0.0.0.0:9090

# Hardening
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    rm -rf "$tmp"

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now prometheus
    ok "Prometheus запущен"
}

# ------------------------------------------------------------------
# Node Exporter
# ------------------------------------------------------------------
install_node_exporter() {
    info "Устанавливаю Node Exporter"

    if ! id node_exporter &>/dev/null; then
        $SUDO useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
    fi

    local tmp; tmp=$(mktemp -d)
    local ndir
    download_github_release "prometheus/node_exporter" "$PROM_ARCH" "$tmp/ne.tar.gz" ndir

    $SUDO install -m 0755 -o node_exporter -g node_exporter \
        "$tmp/$ndir/node_exporter" /usr/local/bin/node_exporter

    $SUDO tee /etc/systemd/system/node_exporter.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100

# Hardening
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    rm -rf "$tmp"

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now node_exporter
    ok "Node Exporter запущен"
}

# ------------------------------------------------------------------
# Grafana (актуальный apt.grafana.com + signed-by)
# ------------------------------------------------------------------
install_grafana() {
    info "Устанавливаю Grafana"

    $SUDO mkdir -p /etc/apt/keyrings
    # gpg-full.key содержит и активный ключ, и ревокацию старого
    curl -fsSL https://apt.grafana.com/gpg-full.key | $SUDO tee /etc/apt/keyrings/grafana.asc >/dev/null
    $SUDO chmod 644 /etc/apt/keyrings/grafana.asc

    echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
        | $SUDO tee /etc/apt/sources.list.d/grafana.list >/dev/null

    run_step "apt update (Grafana repo)" $SUDO apt-get update -y
    run_step "Установка grafana"          $SUDO apt-get install -y grafana

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now grafana-server
    ok "Grafana запущена"
}

# ------------------------------------------------------------------
# Финальная сводка
# ------------------------------------------------------------------
print_summary() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip="<server-ip>"

    cat <<EOF

${BLUE}=============================================================================${RESET}
${YELLOW}Prometheus:${RESET}        ${GREEN}http://${ip}:9090${RESET}
${YELLOW}Node Exporter:${RESET}     ${GREEN}http://${ip}:9100/metrics${RESET}
${YELLOW}Grafana:${RESET}           ${GREEN}http://${ip}:3000${RESET}  (admin / admin при первом входе)
${YELLOW}Prometheus DS URL:${RESET} ${GREEN}http://localhost:9090${RESET}
${YELLOW}Dashboard ID:${RESET}      ${GREEN}1860${RESET} (Node Exporter Full)
${BLUE}=============================================================================${RESET}
${YELLOW}Лог установки:${RESET} ${LOG_FILE}

EOF
}

# ------------------------------------------------------------------
# Установка целиком
# ------------------------------------------------------------------
install_stack() {
    require_root
    detect_os
    detect_arch
    require_systemd
    install_prereqs
    install_prometheus
    install_node_exporter
    install_grafana
    print_summary
}

# ------------------------------------------------------------------
# Удаление
# ------------------------------------------------------------------
remove_service() {
    local svc="$1"
    if systemctl list-unit-files "${svc}.service" &>/dev/null \
       && [[ -n $(systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null) ]]; then
        $SUDO systemctl stop "$svc" 2>/dev/null || true
        $SUDO systemctl disable "$svc" 2>/dev/null || true
    fi
}

remove_user() {
    local user="$1"
    if id "$user" &>/dev/null; then
        $SUDO userdel "$user" 2>/dev/null || warn "Не удалось удалить пользователя $user"
    fi
    if getent group "$user" &>/dev/null; then
        $SUDO groupdel "$user" 2>/dev/null || true
    fi
}

remove_stack() {
    require_root
    info "Удаляю Prometheus + Node Exporter + Grafana"

    # Prometheus
    remove_service prometheus
    $SUDO rm -f /usr/local/bin/prometheus /usr/local/bin/promtool
    $SUDO rm -f /etc/systemd/system/prometheus.service
    $SUDO rm -rf /etc/prometheus /var/lib/prometheus
    remove_user prometheus
    ok "Prometheus удалён"

    # Node Exporter
    remove_service node_exporter
    $SUDO rm -f /usr/local/bin/node_exporter
    $SUDO rm -f /etc/systemd/system/node_exporter.service
    remove_user node_exporter
    ok "Node Exporter удалён"

    # Grafana
    remove_service grafana-server
    $SUDO apt-get purge -y grafana 2>>"$LOG_FILE" || true
    $SUDO apt-get autoremove -y 2>>"$LOG_FILE" || true
    $SUDO rm -f /etc/apt/sources.list.d/grafana.list
    $SUDO rm -f /etc/apt/keyrings/grafana.asc
    # Старые пути на случай если ставилось предыдущей версией скрипта
    $SUDO rm -f /etc/apt/trusted.gpg.d/grafana.gpg
    $SUDO rm -rf /var/lib/grafana /etc/grafana /var/log/grafana /usr/share/grafana
    ok "Grafana удалена"

    $SUDO systemctl daemon-reload
    $SUDO systemctl reset-failed 2>/dev/null || true

    echo -e "${GREEN}Готово.${RESET}"
}

# ==================================================================
#   HARDENING: bind на 127.0.0.1 + UFW
# ==================================================================

# Определяем порт SSH из активной конфигурации sshd.
# sshd -T показывает effective config. Если их несколько — берём все.
detect_ssh_ports() {
    local ports
    if command -v sshd &>/dev/null; then
        ports=$($SUDO sshd -T 2>/dev/null | awk '/^port /{print $2}' | sort -u | xargs || true)
    fi
    [[ -z "${ports:-}" ]] && ports="22"
    echo "$ports"
}

# Подтверждение SSH-портов от пользователя — не закрываем доступ молча
confirm_ssh_ports() {
    local detected
    detected=$(detect_ssh_ports)

    echo -e "${YELLOW}Обнаружены SSH-порты: ${GREEN}${detected}${RESET}"
    echo -ne "${YELLOW}Использовать их для UFW? [Y/n] (или введите свои через пробел): ${RESET}"
    read -r answer

    case "${answer,,}" in
        ""|y|yes|д|да) SSH_PORTS="$detected" ;;
        n|no|нет)
            echo -ne "${YELLOW}Введите SSH-порты через пробел: ${RESET}"
            read -r SSH_PORTS
            ;;
        *) SSH_PORTS="$answer" ;;
    esac

    [[ -n "$SSH_PORTS" ]] || die "Пустой список SSH-портов — отказываюсь продолжать"

    # Валидация
    local p
    for p in $SSH_PORTS; do
        if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
            die "Некорректный порт: $p"
        fi
    done

    # Финальная проверка — реально ли SSH сейчас слушает на этих портах
    local listening
    listening=$($SUDO ss -tlnH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | sort -u)
    for p in $SSH_PORTS; do
        if ! grep -qx "$p" <<<"$listening"; then
            warn "На порту $p ничего не слушает прямо сейчас — проверь дважды!"
            echo -ne "${YELLOW}Всё равно продолжить? [y/N]: ${RESET}"
            read -r confirm
            [[ "${confirm,,}" =~ ^(y|yes|д|да)$ ]] || die "Отмена."
        fi
    done

    log "SSH ports for UFW: $SSH_PORTS"
}

# Привязываем Prometheus и Node Exporter к 127.0.0.1
harden_bind() {
    info "Привязываю Prometheus и Node Exporter к loopback (127.0.0.1)"

    [[ -f /etc/systemd/system/prometheus.service ]] \
        || die "prometheus.service не найден — сначала выполните установку"
    [[ -f /etc/systemd/system/node_exporter.service ]] \
        || die "node_exporter.service не найден — сначала выполните установку"

    # Prometheus: меняем 0.0.0.0:9090 → 127.0.0.1:9090
    if grep -q -- "--web.listen-address=0.0.0.0:9090" /etc/systemd/system/prometheus.service; then
        $SUDO sed -i 's|--web.listen-address=0.0.0.0:9090|--web.listen-address=127.0.0.1:9090|' \
            /etc/systemd/system/prometheus.service
        ok "Prometheus: bind → 127.0.0.1:9090"
    elif grep -q -- "--web.listen-address=127.0.0.1:9090" /etc/systemd/system/prometheus.service; then
        ok "Prometheus уже привязан к 127.0.0.1:9090"
    else
        warn "Не нашёл флаг --web.listen-address в prometheus.service — пропускаю"
    fi

    # Node Exporter: меняем :9100 → 127.0.0.1:9100
    if grep -q -- "--web.listen-address=:9100" /etc/systemd/system/node_exporter.service; then
        $SUDO sed -i 's|--web.listen-address=:9100|--web.listen-address=127.0.0.1:9100|' \
            /etc/systemd/system/node_exporter.service
        ok "Node Exporter: bind → 127.0.0.1:9100"
    elif grep -q -- "--web.listen-address=127.0.0.1:9100" /etc/systemd/system/node_exporter.service; then
        ok "Node Exporter уже привязан к 127.0.0.1:9100"
    else
        warn "Не нашёл флаг --web.listen-address в node_exporter.service — пропускаю"
    fi

    $SUDO systemctl daemon-reload
    $SUDO systemctl restart prometheus node_exporter

    # Дадим секунду стартовать
    sleep 2

    # Smoke check: localhost доступен, внешний адрес — нет
    if ! curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:9090/-/healthy; then
        die "Prometheus не отвечает на 127.0.0.1:9090 после рестарта"
    fi
    if ! curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:9100/metrics; then
        die "Node Exporter не отвечает на 127.0.0.1:9100 после рестарта"
    fi
    ok "Локальные эндпоинты живы"
}

# Настраиваем UFW
harden_firewall() {
    info "Настраиваю UFW"

    # Установка пакета
    if ! command -v ufw &>/dev/null; then
        run_step "Установка ufw" $SUDO apt-get install -y ufw
    fi

    confirm_ssh_ports

    # Дефолтные политики: всё входящее — запретить, исходящее — разрешить
    $SUDO ufw --force reset >>"$LOG_FILE" 2>&1
    $SUDO ufw default deny incoming  >>"$LOG_FILE" 2>&1
    $SUDO ufw default allow outgoing >>"$LOG_FILE" 2>&1

    # SSH (rate-limit чтобы блокировать ботов перебирающих пароли)
    local p
    for p in $SSH_PORTS; do
        $SUDO ufw limit "${p}/tcp" comment "SSH" >>"$LOG_FILE" 2>&1
        ok "Открыт SSH: ${p}/tcp (limit)"
    done

    # Grafana
    $SUDO ufw allow 3000/tcp comment "Grafana" >>"$LOG_FILE" 2>&1
    ok "Открыт Grafana: 3000/tcp"

    # Включаем UFW. --force чтобы не было интерактивного yes/no
    $SUDO ufw --force enable >>"$LOG_FILE" 2>&1
    ok "UFW включён"

    echo
    $SUDO ufw status verbose
}

# Отдельный пункт — статус
hardening_status() {
    echo -e "${BLUE}--- Bind адреса ---${RESET}"
    if [[ -f /etc/systemd/system/prometheus.service ]]; then
        grep -E "web.listen-address" /etc/systemd/system/prometheus.service \
            | sed 's/^/  prometheus: /' || true
    fi
    if [[ -f /etc/systemd/system/node_exporter.service ]]; then
        grep -E "web.listen-address" /etc/systemd/system/node_exporter.service \
            | sed 's/^/  node_exporter: /' || true
    fi

    echo
    echo -e "${BLUE}--- Слушающие порты ---${RESET}"
    $SUDO ss -tlnp 2>/dev/null | awk 'NR==1 || /9090|9100|3000|:22/' || true

    echo
    echo -e "${BLUE}--- UFW ---${RESET}"
    if command -v ufw &>/dev/null; then
        $SUDO ufw status verbose
    else
        echo "  ufw не установлен"
    fi
}

# Откат: возвращаем bind на 0.0.0.0/all + отключаем UFW
harden_rollback() {
    info "Откатываю harden — Prometheus и Node Exporter снова на всех интерфейсах"

    if [[ -f /etc/systemd/system/prometheus.service ]]; then
        $SUDO sed -i 's|--web.listen-address=127.0.0.1:9090|--web.listen-address=0.0.0.0:9090|' \
            /etc/systemd/system/prometheus.service
    fi
    if [[ -f /etc/systemd/system/node_exporter.service ]]; then
        $SUDO sed -i 's|--web.listen-address=127.0.0.1:9100|--web.listen-address=:9100|' \
            /etc/systemd/system/node_exporter.service
    fi

    $SUDO systemctl daemon-reload
    $SUDO systemctl restart prometheus node_exporter 2>/dev/null || true
    ok "Bind возвращён на все интерфейсы"

    if command -v ufw &>/dev/null; then
        echo -ne "${YELLOW}Отключить UFW? [y/N]: ${RESET}"
        read -r answer
        if [[ "${answer,,}" =~ ^(y|yes|д|да)$ ]]; then
            $SUDO ufw --force disable >>"$LOG_FILE" 2>&1
            ok "UFW отключён"
        else
            warn "UFW оставлен включённым — порты Prometheus/Node Exporter всё равно закрыты файрволом"
        fi
    fi
}

harden_stack() {
    require_root
    harden_bind
    harden_firewall
    echo
    info "Готово. Снаружи доступны только SSH и Grafana."
    echo -e "${YELLOW}Grafana:${RESET} ${GREEN}http://$(hostname -I | awk '{print $1}'):3000${RESET}"
    echo -e "${YELLOW}Prometheus:${RESET}    127.0.0.1:9090 (только локально)"
    echo -e "${YELLOW}Node Exporter:${RESET} 127.0.0.1:9100 (только локально)"
    echo
    echo -e "${YELLOW}Текущий статус:${RESET}"
    hardening_status
}

# ------------------------------------------------------------------
# Меню
# ------------------------------------------------------------------
main() {
    print_banner
    echo -e "${YELLOW}Выберите действие:${RESET}"
    echo -e "  ${YELLOW}1)${RESET} Установить Prometheus + Node Exporter + Grafana"
    echo -e "  ${YELLOW}2)${RESET} Удалить Prometheus + Node Exporter + Grafana"
    echo -e "  ${YELLOW}3)${RESET} Закрыть наружу всё кроме Grafana и SSH (bind + UFW)"
    echo -e "  ${YELLOW}4)${RESET} Откатить пункт 3"
    echo -e "  ${YELLOW}5)${RESET} Показать текущий статус (bind / порты / UFW)"
    echo -e "  ${YELLOW}6)${RESET} Выход"
    echo -ne "${YELLOW}Введите номер: ${RESET}"
    read -r choice

    print_banner
    case "$choice" in
        1) install_stack ;;
        2) remove_stack ;;
        3) harden_stack ;;
        4) require_root; harden_rollback ;;
        5) require_root; hardening_status ;;
        6) exit 0 ;;
        *) die "Неверный выбор." ;;
    esac
}

main "$@"
