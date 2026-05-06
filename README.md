# nodeinstall

Bash-скрипт для установки связки **Prometheus + Node Exporter + Grafana** на Debian/Ubuntu в одну команду. Опционально — закрывает всё кроме Grafana и SSH от внешнего мира.

Установка идёт из официальных GitHub-релизов (Prometheus, Node Exporter) и официального APT-репозитория Grafana, с проверкой SHA256 и systemd-юнитами.

Целевой дашборд: [Node Exporter Full (ID 1860)](https://grafana.com/grafana/dashboards/1860-node-exporter-full).

![Скриншот](https://i.imgur.com/JO6NyQG.png)

---

## Возможности

- Установка Prometheus, Node Exporter и Grafana из официальных источников
- Удаление всей связки одной командой
- Hardening: привязка Prometheus и Node Exporter к `127.0.0.1` + UFW с дефолт-deny
- Откат hardening
- Просмотр текущих bind-адресов и правил firewall
- Автоопределение архитектуры: amd64, arm64, armv7
- Идемпотентность — повторный запуск не ломает уже установленное
- Проверка SHA256 скачанных архивов
- Лог установки в `/tmp/nodeinstall-*.log`

---

## Требования

- Debian 11+ или Ubuntu 20.04+
- systemd
- root или sudo
- интернет

---

## Быстрый запуск

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Nureble/nodeinstall-script/main/nodeinstall.sh)
```

При запуске не от root скрипт использует `sudo`.

---

## Меню

```
1) Установить Prometheus + Node Exporter + Grafana
2) Удалить Prometheus + Node Exporter + Grafana
3) Закрыть наружу всё кроме Grafana и SSH (bind + UFW)
4) Откатить пункт 3
5) Показать текущий статус (bind / порты / UFW)
6) Выход
```

### Пункт 1 — установка

1. Обновление apt и установка зависимостей (`curl`, `wget`, `jq`, `gnupg` и т.д.)
2. Скачивание последнего релиза Prometheus с GitHub, проверка SHA256, установка в `/usr/local/bin/`
3. Создание системного пользователя `prometheus`, каталогов `/etc/prometheus` и `/var/lib/prometheus`
4. Генерация конфига `prometheus.yml` с двумя job'ами: `prometheus` и `node`
5. Создание systemd-юнита `prometheus.service` с базовым hardening (`NoNewPrivileges`, `ProtectSystem=full`, `PrivateTmp`)
6. То же самое для Node Exporter (юзер `node_exporter`, юнит `node_exporter.service`)
7. Подключение официального APT-репозитория Grafana (`apt.grafana.com`, ключ в `/etc/apt/keyrings/grafana.asc`, `signed-by=`)
8. Установка пакета `grafana`, запуск `grafana-server`

После установки выводятся ссылки на сервисы и ID дашборда.

### Пункт 2 — удаление

Останавливает и удаляет все три сервиса, чистит юниты, конфиги, базы данных, юзеров, группы и репозиторий Grafana. Идемпотентно.

### Пункт 3 — hardening

- Prometheus перепривязывается с `0.0.0.0:9090` на `127.0.0.1:9090`
- Node Exporter перепривязывается с `:9100` на `127.0.0.1:9100`
- Устанавливается UFW (если ещё нет)
- Дефолтные политики: `deny incoming`, `allow outgoing`
- Открыты только: SSH (с rate-limit) и Grafana (3000)
- Smoke-тест: после рестарта проверяется, что Prometheus и Node Exporter живы на loopback

SSH-порт определяется автоматически через `sshd -T` с подтверждением. Для нестандартного порта или нескольких — ручной ввод через пробел.

После hardening:

- Снаружи доступна только Grafana (`http://<vps-ip>:3000`)
- Prometheus и Node Exporter доступны только локально, что не мешает Grafana их использовать

### Пункт 4 — откат hardening

Возвращает Prometheus и Node Exporter на все интерфейсы, по запросу отключает UFW.

### Пункт 5 — статус

Текущие bind-адреса, слушающие порты, таблица UFW.

---

## Что куда ставится

| Компонент | Бинарь | Конфиг | Данные | Юнит |
|---|---|---|---|---|
| Prometheus | `/usr/local/bin/prometheus`, `/usr/local/bin/promtool` | `/etc/prometheus/prometheus.yml` | `/var/lib/prometheus/` | `/etc/systemd/system/prometheus.service` |
| Node Exporter | `/usr/local/bin/node_exporter` | — | — | `/etc/systemd/system/node_exporter.service` |
| Grafana | пакет `grafana` (apt) | `/etc/grafana/` | `/var/lib/grafana/` | `grafana-server.service` (из пакета) |

---

## После установки

1. Открыть `http://<vps-ip>:3000`
2. Войти как `admin` / `admin` (Grafana попросит сменить пароль при первом входе)
3. **Connections → Data sources → Add data source → Prometheus**
   - URL: `http://localhost:9090`
   - Save & test
4. **Dashboards → New → Import → 1860 → Load**, выбрать Prometheus как источник

---

## Проверка работоспособности

После установки:

```bash
curl http://localhost:9090/-/healthy        # Prometheus is Healthy.
curl -sI http://localhost:9100/metrics      # HTTP/1.1 200 OK
curl http://localhost:3000/api/health       # JSON со статусом
systemctl status prometheus node_exporter grafana-server
```

После hardening (с другой машины):

```bash
curl --max-time 5 http://<vps-ip>:9090   # timeout / connection refused
curl --max-time 5 http://<vps-ip>:9100   # timeout / connection refused
curl --max-time 5 http://<vps-ip>:3000   # Grafana
```

---

## Поддерживаемые архитектуры

Определяются автоматически через `dpkg --print-architecture`:

| dpkg arch | Prometheus артефакт |
|---|---|
| `amd64` | `linux-amd64` |
| `arm64` | `linux-arm64` |
| `armhf` | `linux-armv7` |

---

## Безопасность

После пункта 3:

- Bind на 127.0.0.1 — приложения физически не отвечают на пакеты с внешнего IP, ядро дропает их на уровне сокета. Надёжнее, чем закрытие портом firewall, поскольку не зависит от корректности правил
- UFW — defense in depth, страхует на случай возврата bind на `0.0.0.0`
- SSH через `ufw limit` — rate-limit от bruteforce: максимум 6 попыток с одного IP за 30 секунд
- Systemd-юниты работают с `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome`, `PrivateTmp`

Что не делает скрипт:

- HTTPS/TLS для Grafana — для этого нужен reverse proxy (nginx/Caddy/Traefik) и домен
- Смена дефолтного пароля admin Grafana — это делает сама Grafana при первом входе
- Облачный firewall провайдера (Hetzner Cloud Firewall, Oracle Security List, AWS Security Group и т.п.) — он накладывается поверх UFW и настраивается в панели провайдера

---

## FAQ

**Можно ли запускать повторно?**
Да. Установка идемпотентна — пользователи не пересоздаются, конфиги перезаписываются на свежие. Hardening тоже — `ufw reset` + накатывание правил с нуля.

**Где лог?**
`/tmp/nodeinstall-<timestamp>.log`. Туда пишется весь stdout/stderr внутренних команд.

**Не поднимается Grafana после hardening**
Облачный firewall провайдера. В панели управления VPS может быть отдельная Security Group / Firewall, блокирующая 3000-й порт независимо от UFW.

**В DataSource Grafana писать `localhost:9090` или внешний IP?**
`localhost:9090` (или `127.0.0.1:9090`). Grafana и Prometheus на одной машине, ходят через loopback. После hardening внешний IP не сработает — Prometheus там не слушает.

**Как обновить Prometheus или Node Exporter?**
Запустить пункт 1 повторно — скачаются последние релизы поверх старых. Желательно предварительно `systemctl stop prometheus` чтобы не было конфликта с работающим бинарём.

**Как обновить Grafana?**
Через apt: `sudo apt update && sudo apt upgrade grafana`.

**Поддержка systemd обязательна?**
Да. Скрипт явно проверяет `/run/systemd/system`. Альтернативные init-системы (OpenRC, runit) не поддерживаются.

**Можно использовать в Docker-контейнере?**
В обычном — нет (нет systemd). В контейнере с systemd внутри (`jrei/systemd-debian`) — да, для тестов работает.

---

## Тестирование без следов

Прогон в Docker-контейнере с systemd внутри:

```bash
docker run -d --name nodeinstall-test --privileged \
  --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$PWD/nodeinstall.sh":/root/nodeinstall.sh:ro \
  -p 3000:3000 \
  jrei/systemd-debian:12

docker exec nodeinstall-test apt-get update
docker exec nodeinstall-test apt-get install -y curl
docker exec -i nodeinstall-test bash -c "echo 1 | bash /root/nodeinstall.sh"

# зайти внутрь
docker exec -it nodeinstall-test bash

# снести всё
docker rm -f nodeinstall-test
```

---

## Troubleshooting

| Симптом | Причина / решение |
|---|---|
| `Сбой на строке X` | Полный лог команд в `/tmp/nodeinstall-*.log` |
| `SHA256 mismatch` | Артефакт повреждён или подменён. Перезапустить |
| `Не получилось обратиться к api.github.com` | Anonymous rate-limit GitHub API (60 запросов/час с IP). Подождать или сменить сеть |
| Нет SSH после hardening | Облачный firewall провайдера. Зайти через VNC/Web Console и `sudo ufw disable` |
| Prometheus не стартует | `journalctl -u prometheus -n 50`. Чаще всего — права на `/var/lib/prometheus` или синтаксис `prometheus.yml` |

---

## Лицензия

MIT
