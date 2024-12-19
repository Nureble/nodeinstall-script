#!/bin/bash

set -e

# Цвета
RED="\e[1;31m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
BLUE="\e[1;34m"
PURPLE="\e[1;35m"
RESET="\e[0m"
BG_YELLOW="\033[43m"

# Функция для отображения вращающегося слэша
spin() {
    local pid=$1
    local delay=0.1
    local spin_chars='/-\|'
    while kill -0 $pid 2>/dev/null; do
        for i in $(seq 0 3); do
            echo -ne "\r${YELLOW}$2 ${PURPLE}[${YELLOW}${PURPLE}${spin_chars:$i:1}]${RESET}"
            sleep $delay
        done
    done
    echo -e "\r${YELLOW}$2 [${GREEN}OK${YELLOW}]${RESET}"
}




# Отрисовка заголовка
clear
echo -e "${BLUE}=============================================================================${RESET}"
echo -e "${BLUE}       _______       _____            __   __ ${RESET}"
echo -e "${BLUE}    /\|__   __|/\   |  __ \     /\    \ \ / / ${RESET}"
echo -e "${BLUE}   /  \  | |  /  \  | |__) |   /  \    \ V /  ${RESET}"
echo -e "${BLUE}  / /\ \ | | / /\ \ |  _  /   / /\ \    > <   ${RESET}"
echo -e "${BLUE} / ____ \| |/ ____ \| | \ \  / ____ \  / . \  ${RESET}"
echo -e "${BLUE}/_/    \_\_/_/    \_\_|  \_\/_/    \_\/_/ \_\ ${RESET}"
echo -e "${BLUE}======================================================${RESET}"
echo -e "${PURPLE}   Easy install Node Exporter Full Dashboard${RESET}"
echo -e "${YELLOW}Prometheus 3.0.1 + Node Exporter 1.8.2 + Grafana${RESET}"
echo -e "${BLUE}=============================================================================${RESET}"

echo -e "${YELLOW}Начать установку? (y/n)${RESET}"
read -r answer
if [[ "$answer" != "y" ]]; then
    echo -e "${RED}Установка отменена.${RESET}"
    exit 0
fi

# Установка Prometheus
{
    sudo apt update
    sudo useradd --no-create-home --shell /bin/false prometheus
    sudo mkdir -p /etc/prometheus /var/lib/prometheus
    cd /tmp
    wget https://github.com/prometheus/prometheus/releases/download/v3.0.1/prometheus-3.0.1.linux-amd64.tar.gz
    tar xvf prometheus-3.0.1.linux-amd64.tar.gz
    cd prometheus-3.0.1.linux-amd64
    sudo cp prometheus promtool /usr/local/bin/
    sudo cp prometheus.yml /etc/prometheus/
    sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
    sudo chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
	sudo sed -i '/^scrape_configs:/a \ \ - job_name: "node"\n\ \ \ \ static_configs:\n\ \ \ \ \ \ - targets: ["localhost:9100"]' /etc/prometheus/prometheus.yml
    sudo tee /etc/systemd/system/prometheus.service > /dev/null <<EOF
[Unit]
Description=Prometheus Monitoring
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \\
  --config.file=/etc/prometheus/prometheus.yml \\
  --storage.tsdb.path=/var/lib/prometheus/

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable prometheus
    sudo systemctl restart prometheus
} &>/dev/null &
spin $! "Устанавливаем Prometheus"

# Установка Node Exporter
{
    sudo apt update
    sudo useradd --no-create-home --shell /bin/false node_exporter
    cd /tmp
    wget https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
    tar xvf node_exporter-1.8.2.linux-amd64.tar.gz
    cd node_exporter-1.8.2.linux-amd64
    sudo cp node_exporter /usr/local/bin/
    sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter
    sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable node_exporter
    sudo systemctl start node_exporter
} &>/dev/null &
spin $! "Устанавливаем Node Exporter"

# Установка Grafana
{
    sudo apt update
    sudo apt install -y apt-transport-https software-properties-common wget
    wget -q -O - https://packages.grafana.com/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/grafana.gpg
    echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list > /dev/null
    sudo apt update
    sudo apt install -y grafana
    sudo systemctl daemon-reload
    sudo systemctl enable grafana-server
    sudo systemctl start grafana-server
} &>/dev/null &
spin $! "Устанавливаем Grafana"

# Итоговая информация
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "${BLUE}=============================================================================${RESET}"
echo -e "${YELLOW}Prometheus доступен по адресу:${RESET}        ${GREEN}http://$SERVER_IP:9090${RESET}"
echo -e "${YELLOW}Node Exporter доступен по адресу:${RESET}     ${GREEN}http://$SERVER_IP:9100/metrics${RESET}"
echo -e "${YELLOW}Grafana доступна по адресу:${RESET}           ${GREEN}http://$SERVER_IP:3000${RESET}"
echo -e "${YELLOW}Добавьте DataSource Prometheus с URL:${RESET} ${GREEN}http://localhost:9090${RESET}"
echo -e "${YELLOW}В Grafana импортируйте дашборд ID:${RESET}    ${GREEN}1860${RESET}"
echo -e "${BLUE}=============================================================================${RESET}"


RED="\e[1;31m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
BLUE="\e[1;34m"
PURPLE="\e[1;35m"
RESET="\e[0m"
BG_YELLOW="\033[43m" 