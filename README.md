# nodeinstall script

Скрипт автоматически устанавливает связку актуальных версий Prometheus + Node Exporter + Grafana для работы и настраивает с дашбордом [Node Exporter Full](https://grafana.com/grafana/dashboards/1860-node-exporter-full)


![Скриншот](https://i.imgur.com/JO6NyQG.png)

Описание:
Скрипт автоматически устанавливает:
1. Prometheus версии 3.0.1 и редактирует файл prometheus.yml, добавляя настройки для мониторинга метрик, предоставляемых Node Exporter.

В файл prometheus.yml добавляются следующие инструкции:
```
  - job_name: node
    static_configs:
      - targets: ['localhost:9100']
```


2. Node Exporter 1.8.2
3. Grafana

После выполнения, скрипт предоставит вам ссылки, по которым можно зайти в Prometheus и Grafana:

![Гиф анимация процесса установки](https://i.imgur.com/jGUN5WM.gif)

Далее останется только добавить Datasource Prometheus в Grafana и импортировать дашборд.

Скрипт может удалить всю связку по команде.



Для запуска выполните команду:
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Nureble/nodeinstall-script/main/nodeinstall.sh)
```


