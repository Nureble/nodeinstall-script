#!/bin/bash

set -e

# ------ Цвета и служебные переменные ------
RED="\e[1;31m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
BLUE="\e[1;34m"
PURPLE="\e[1;35m"
RESET="\e[0m"

# Спиннер для отображения прогресса в фоне
spin() {
    local pid="$1"
    local msg="$2"
    local delay=0.1
    local spin_chars='/-\|'
    while kill -0 "$pid" 2>/dev/null; do
        for i in $(seq 0 3); do
            echo -ne "\r${YELLOW}${msg} ${PURPLE}[${spin_chars:$i:1}]${RESET}"
            sleep $delay
        done
    done
    echo -e "\r${YELLOW}${msg} [${GREEN}OK${YELLOW}]${RESET}"
}

# Функция для красивого заголовка
print_banner() {
    clear
    echo -e "${BLUE}======================================================${RESET}"
    echo -e "${BLUE}       _______       _____            __   __ ${RESET}"
    echo -e "${BLUE}    /\|__   __|/\   |  __ \     /\    \ \ / / ${RESET}"
    echo -e "${BLUE}   /  \  | |  /  \  | |__) |   /  \    \ V /  ${RESET}"
    echo -e "${BLUE}  / /\ \ | | / /\ \ |  _  /   / /\ \    > <   ${RESET}"
    echo -e "${BLUE} / ____ \| |/ ____ \| | \ \  / ____ \  / . \  ${RESET}"
    echo -e "${BLUE}/_/    \_\_/_/    \_\_|  \_\/_/    \_\/_/ \_\ ${RESET}"
    echo -e "${BLUE}======================================================${RESET}"
    echo -e "${PURPLE}   Easy install Node Exporter Full Dashboard${RESET}"
    echo -e "${YELLOW}     Prometheus + Node Exporter + Grafana${RESET}"	
    echo -e "${BLUE}======================================================${RESET}"
}
# Обновление пакетов перед установкой
update_system() {
  {
    sudo apt update -y &>/dev/null;
    sudo apt upgrade -y &>/dev/null;
  }  &  # Запуск в фоновом режиме
  spin $! "Обновление списка пакетов"
}

# -------------------- УСТАНОВКА --------------------
install_stack() {
  echo -e "${YELLOW}Начинаем установку Prometheus, Node Exporter и Grafana...${RESET}"

# 1. Установка пакета jq (если не установлен)
if ! command -v jq &>/dev/null; then
  echo -e "${YELLOW}Устанавливаем jq...${RESET}"
  sudo apt install -y jq &>/dev/null
  if ! command -v jq &>/dev/null; then
    echo -e "${RED}Ошибка: jq не удалось установить. Прекращение выполнения.${RESET}"
    exit 1
  fi
fi

# ===============================
#     Установка Prometheus
# ===============================

{
  # Проверяем, существует ли пользователь prometheus
  if id "prometheus" &>/dev/null; then
    echo "Пользователь prometheus уже существует. Пропускаем создание."
  else
    sudo useradd --no-create-home --shell /bin/false prometheus &>/dev/null
  fi

  # Создаем каталоги и настраиваем права
  sudo mkdir -p /etc/prometheus /var/lib/prometheus &>/dev/null
  sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus &>/dev/null

  # Получаем ссылку на последний релиз
  latest_prometheus_url=$(curl -s https://api.github.com/repos/prometheus/prometheus/releases/latest \
    | jq -r '.assets[] | select(.name | test("linux-amd64\\.tar\\.gz$")) | .browser_download_url')

  if [[ -z "$latest_prometheus_url" ]]; then
    echo -e "${RED}Ошибка: не удалось получить URL последнего релиза Prometheus.${RESET}"
    exit 1
  fi

  # Скачиваем и распаковываем архив
  cd /tmp
  wget "$latest_prometheus_url" -O prometheus.tar.gz &>/dev/null
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Ошибка: не удалось скачать Prometheus с URL: $latest_prometheus_url${RESET}"
    exit 1
  fi
  tar xvf prometheus.tar.gz &>/dev/null
  prometheus_dir=$(tar -tf prometheus.tar.gz | head -n 1 | cut -d"/" -f1)

  if [[ ! -d "$prometheus_dir" ]]; then
    echo -e "${RED}Ошибка: не удалось распаковать архив Prometheus.${RESET}"
    exit 1
  fi

  # Копируем бинарники и конфиг
  cd "$prometheus_dir"
  sudo cp prometheus promtool /usr/local/bin/ &>/dev/null
  sudo cp prometheus.yml /etc/prometheus/ &>/dev/null
  sudo chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool &>/dev/null

  # Дополняем конфиг
  sudo sed -i '/^scrape_configs:/a \ \ - job_name: "node"\n\ \ \ \ static_configs:\n\ \ \ \ \ \ - targets: ["localhost:9100"]' /etc/prometheus/prometheus.yml &>/dev/null

  # Создаем systemd unit
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

  sudo systemctl daemon-reload &>/dev/null
  sudo systemctl enable prometheus &>/dev/null
  sudo systemctl restart prometheus &>/dev/null
} || {
  echo -e "${RED}Ошибка на этапе установки Prometheus.${RESET}"
  exit 1
} 
spin $! "Устанавливаем Prometheus"

# ===============================
# Установка Node Exporter
# ===============================
{
  # Проверяем, существует ли пользователь node_exporter
  if id "node_exporter" &>/dev/null; then
    echo "Пользователь node_exporter уже существует. Пропускаем создание."
  else
    sudo useradd --no-create-home --shell /bin/false node_exporter &>/dev/null
  fi

  # Получаем ссылку на последний релиз Node Exporter
  cd /tmp
  latest_nodeexporter_url=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest \
    | jq -r '.assets[] | select(.name | test("linux-amd64\\.tar\\.gz$")) | .browser_download_url')

  if [[ -z "$latest_nodeexporter_url" ]]; then
    echo -e "${RED}Ошибка: не удалось получить URL последнего релиза Node Exporter.${RESET}"
    exit 1
  fi

  wget "$latest_nodeexporter_url" -O node_exporter.tar.gz &>/dev/null
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Ошибка: не удалось скачать Node Exporter с URL: $latest_nodeexporter_url${RESET}"
    exit 1
  fi
  tar xvf node_exporter.tar.gz &>/dev/null
  nodeexporter_dir=$(tar -tf node_exporter.tar.gz | head -n 1 | cut -d"/" -f1)

  if [[ ! -d "$nodeexporter_dir" ]]; then
    echo -e "${RED}Ошибка: не удалось распаковать архив Node Exporter.${RESET}"
    exit 1
  fi

  cd "$nodeexporter_dir"
  sudo cp node_exporter /usr/local/bin/ &>/dev/null
  sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter &>/dev/null

  # Создаем systemd unit
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

  sudo systemctl daemon-reload &>/dev/null
  sudo systemctl enable node_exporter &>/dev/null
  sudo systemctl start node_exporter &>/dev/null
} || {
  echo -e "${RED}Ошибка на этапе установки Node Exporter.${RESET}"
  exit 1
}
spin $! "Устанавливаем Node Exporter"

# ===============================
# Установка Grafana
# ===============================
{
  sudo apt update &>/dev/null
  sudo apt install -y apt-transport-https software-properties-common wget &>/dev/null
  wget -q -O - https://packages.grafana.com/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/grafana.gpg &>/dev/null
  echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list > /dev/null
  sudo apt update &>/dev/null
  sudo apt install -y grafana &>/dev/null

  sudo systemctl daemon-reload &>/dev/null
  sudo systemctl enable grafana-server &>/dev/null
  sudo systemctl start grafana-server &>/dev/null
} || {
  echo -e "${RED}Ошибка на этапе установки Grafана.${RESET}"
  exit 1
}
spin $! "Устанавливаем Grafana"

# ===============================
# Вывод итоговой информации
# ===============================
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "${BLUE}=============================================================================${RESET}"
echo -e "${YELLOW}Prometheus доступен по адресу:${RESET}    ${GREEN}http://$SERVER_IP:9090${RESET}"
echo -e "${YELLOW}Node Exporter доступен по адресу:${RESET} ${GREEN}http://$SERVER_IP:9100/metrics${RESET}"
echo -e "${YELLOW}Grafana доступна по адресу:${RESET}               ${GREEN}http://$SERVER_IP:3000${RESET}"
echo -e "${YELLOW}DataSource Prometheus URL (в Grafana):${RESET}    ${GREEN}http://localhost:9090${RESET}"
echo -e "${YELLOW}Рекомендуемый дашборд ID (Node Exporter):${RESET}  ${GREEN}1860${RESET}"
echo -e "${BLUE}=============================================================================${RESET}"

}




# -------------------- УДАЛЕНИЕ --------------------
remove_stack() {
  echo -e "${YELLOW}Начинаю удаление Prometheus, Node Exporter и Grafana...${RESET}"

  # Проверка наличия Prometheus
  is_prometheus_installed() {
    command -v prometheus &>/dev/null
  }

  # Проверка наличия Node Exporter
  is_nodeexporter_installed() {
    command -v node_exporter &>/dev/null
  }

  # Проверка наличия Grafana
  is_grafana_installed() {
    systemctl list-unit-files | grep -q grafana-server.service
  }

  # =============================
  #     Удаление Prometheus
  # =============================
  if is_prometheus_installed; then
    {
      echo -e "${YELLOW}Удаляем Prometheus...${RESET}"

      # Останавливаем и отключаем сервис
      sudo systemctl stop prometheus || true
      sudo systemctl disable prometheus || true

      # Удаляем бинарники и конфигурации
      sudo rm -f /usr/local/bin/prometheus /usr/local/bin/promtool
      sudo rm -rf /etc/prometheus /var/lib/prometheus
      sudo rm -f /etc/systemd/system/prometheus.service

      # Убеждаемся, что все процессы остановлены
      pgrep -u prometheus &>/dev/null && sudo pkill -u prometheus

      # Удаляем пользователя Prometheus
      if id "prometheus" &>/dev/null; then
        sudo userdel -r prometheus || echo "Ошибка при удалении пользователя prometheus."
      else
        echo "Пользователь prometheus не существует. Пропускаем удаление."
      fi

      # Удаляем группу Prometheus
      if getent group prometheus &>/dev/null; then
        sudo groupdel prometheus || echo "Ошибка при удалении группы prometheus."
      else
        echo "Группа prometheus не существует. Пропускаем удаление."
      fi

      # Перезагружаем systemd
      sudo systemctl daemon-reload
      sudo systemctl reset-failed
    } &>/dev/null &
    spin $! "Удаляем Prometheus"
  else
    echo -e "${YELLOW}Prometheus уже удалён или не найден. Пропускаем.${RESET}"
  fi

  # =============================
  #   Удаление Node Exporter
  # =============================
  if is_nodeexporter_installed; then
    {
      echo -e "${YELLOW}Удаляем Node Exporter...${RESET}"

      # Останавливаем и отключаем сервис
      sudo systemctl stop node_exporter || true
      sudo systemctl disable node_exporter || true

      # Удаляем бинарники и конфигурации
      sudo rm -f /usr/local/bin/node_exporter
      sudo rm -f /etc/systemd/system/node_exporter.service

      # Убеждаемся, что все процессы остановлены
      pgrep -u node_exporter &>/dev/null && sudo pkill -u node_exporter

      # Удаляем пользователя Node Exporter
      if id "node_exporter" &>/dev/null; then
        sudo userdel -r node_exporter || echo "Ошибка при удалении пользователя node_exporter."
      else
        echo "Пользователь node_exporter не существует. Пропускаем удаление."
      fi

      # Удаляем группу Node Exporter
      if getent group node_exporter &>/dev/null; then
        sudo groupdel node_exporter || echo "Ошибка при удалении группы node_exporter."
      else
        echo "Группа node_exporter не существует. Пропускаем удаление."
      fi

      # Перезагружаем systemd
      sudo systemctl daemon-reload
      sudo systemctl reset-failed
    } &>/dev/null &
    spin $! "Удаляем Node Exporter"
  else
    echo -e "${YELLOW}Node Exporter уже удалён или не найден. Пропускаем.${RESET}"
  fi

  # =============================
  #        Удаление Grafana
  # =============================
  if is_grafana_installed; then
    {
      echo -e "${YELLOW}Удаляем Grafana...${RESET}"

      # Останавливаем и отключаем сервис
      sudo systemctl stop grafana-server || true
      sudo systemctl disable grafana-server || true

      # Удаляем пакеты Grafana
      sudo apt purge -y grafana || true
      sudo apt autoremove -y || true

      # Удаляем репозиторий Grafana
      sudo rm -f /etc/apt/sources.list.d/grafana.list
      sudo rm -f /etc/apt/trusted.gpg.d/grafana.gpg

      # Удаляем директории Grafana, включая базу данных
      sudo rm -rf /var/lib/grafana /etc/grafana /var/log/grafana /usr/share/grafana

      # Проверяем, остались ли процессы Grafana
      pgrep -f grafana-server &>/dev/null && sudo pkill -f grafana-server

      # Перезагружаем systemd
      sudo systemctl daemon-reload
      sudo systemctl reset-failed
    } &>/dev/null &
    spin $! "Удаляем Grafana"
  else
    echo -e "${YELLOW}Grafana уже удалена или не найдена. Пропускаем.${RESET}"
  fi

  # =============================
  #     Завершающая очистка
  # =============================
  {
    echo -e "${YELLOW}Удаляем временные файлы...${RESET}"

    # Удаляем временные файлы, скачанные для установки
    sudo rm -rf /tmp/prometheus-* /tmp/node_exporter-* /tmp/grafana*
  } &>/dev/null &
  spin $! "Чистим временные файлы"

  echo -e "${GREEN}Процесс удаления завершён!${RESET}"
}





# -------------------- ОСНОВНОЕ МЕНЮ --------------------
print_banner
echo -e "${YELLOW}Выберите действие:${RESET}"
echo -e "${YELLOW}1) Установить связку Prometheus + Node Exporter + Grafana${RESET}"
echo -e "${YELLOW}2) Удалить связку Prometheus + Node Exporter + Grafana${RESET}"
echo -ne "${YELLOW}Введите 1 или 2: ${RESET}" 
read -r choice

# Очищаем экран после выбора
clear
print_banner

case "$choice" in
  1)
    update_system
    install_stack
    ;;
  2)
    remove_stack
    ;;
  *)
    echo -e "${RED}Неверный выбор. Завершение.${RESET}"
    exit 1
    ;;
esac
