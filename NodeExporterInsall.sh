#!/bin/bash

# Функция для получения последней версии с GitHub
get_latest_version() {
  REPO=$1
  curl -s "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

# Получение последних версий Prometheus и Node Exporter
PROMETHEUS_VERSION=$(get_latest_version "prometheus/prometheus")
NODE_EXPORTER_VERSION=$(get_latest_version "prometheus/node_exporter")
IP_ADDRESS=$(hostname -I | awk '{print $1}')

# Обновление системы
echo "Обновление системы..."
sudo apt update

# Установка Prometheus
echo "Установка Prometheus версии ${PROMETHEUS_VERSION}..."
sudo useradd --no-create-home --shell /bin/false prometheus
sudo mkdir /etc/prometheus /var/lib/prometheus

cd /tmp
wget https://github.com/prometheus/prometheus/releases/download/${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
tar xvf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
cd prometheus-${PROMETHEUS_VERSION}.linux-amd64
sudo cp prometheus promtool /usr/local/bin/
sudo cp -r consoles console_libraries /etc/prometheus/
sudo cp prometheus.yml /etc/prometheus/

sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
sudo chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool

cat <<EOF | sudo tee /etc/systemd/system/prometheus.service > /dev/null
[Unit]
Description=Prometheus Monitoring
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable prometheus
sudo systemctl start prometheus

# Настройка Prometheus для Node Exporter
echo "Настройка Prometheus для Node Exporter..."
sudo sed -i '/scrape_configs:/a \ \ - job_name: "node"\n    static_configs:\n      - targets: ["localhost:9100"]' /etc/prometheus/prometheus.yml
sudo systemctl restart prometheus

# Установка Node Exporter
echo "Установка Node Exporter версии ${NODE_EXPORTER_VERSION}..."
sudo useradd --no-create-home --shell /bin/false node_exporter

cd /tmp
wget https://github.com/prometheus/node_exporter/releases/download/${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
tar xvf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
cd node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64
sudo cp node_exporter /usr/local/bin/

sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

cat <<EOF | sudo tee /etc/systemd/system/node_exporter.service > /dev/null
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

# Установка Grafana
echo "Установка Grafana..."
sudo apt install -y apt-transport-https software-properties-common wget
wget -q -O - https://packages.grafana.com/gpg.key | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/grafana.gpg
echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list

sudo apt update
sudo apt install -y grafana

sudo systemctl start grafana-server
sudo systemctl enable grafana-server

# Вывод статусов сервисов
echo "Проверка статусов сервисов..."
PROMETHEUS_STATUS=$(sudo systemctl is-active prometheus)
NODE_EXPORTER_STATUS=$(sudo systemctl is-active node_exporter)
GRAFANA_STATUS=$(sudo systemctl is-active grafana-server)

echo "Prometheus - $PROMETHEUS_STATUS"
echo "Node Exporter - $NODE_EXPORTER_STATUS"
echo "Grafana - $GRAFANA_STATUS"

# Инструкция для пользователя
echo "Вам нужно перейти на http://${IP_ADDRESS}:3000, настроить datasource Prometheus и импортировать дашборд ID: 1860."
