# mrdark — пакеты для Darkcapture-WRT (developer notes)

Два пакета: `mrdark-core` (ядро: воркер, CLI, валидатор EAPOL) и `luci-app-mrdark`
(веб-интерфейс: сканер, очередь, задача, артефакты, настройки).

> Для обычной установки на роутер используйте [`install.sh`](../install.sh) в корне
> репозитория: он скачивает последний релиз и сам ставит зависимости. Раздел
> «Установка» ниже — ручная установка собранных пакетов для разработки.

Лабораторный инструмент. Применять только к сетям, на которые есть разрешение.

## Состав

```
packages/
├── mrdark-core/
│   ├── Makefile
│   └── files/
│       ├── etc/config/mrdark              # uci-конфиг
│       ├── etc/init.d/mrdark              # procd-супервизор воркера
│       ├── etc/uci-defaults/90_mrdark     # дефолты при установке
│       ├── usr/bin/mrdark                 # CLI
│       └── usr/libexec/mrdark/
│           ├── lib.sh       # общие функции, uci, состояние, lock
│           ├── radio.sh     # выбор phy, monitor-интерфейс, конфликт с netifd
│           ├── status.sh    # сборка /tmp/mrdark/status.json (атомарно)
│           ├── scan.sh      # скан 2.4 ГГц: tcpdump + хоппинг каналов
│           ├── attempt.sh   # одна попытка: канал, захват, залпы deauth, валидация
│           ├── archive.sh   # /tmp → /root/cap, опционально hc22000
│           ├── cleanup.sh   # идемпотентный teardown
│           ├── worker.sh    # машина состояний, очередь, таймеры
│           ├── mrdark-verify   # валидатор pcap (ucode): пары M1..M4
│           ├── mrdark-status.uc# человекочитаемый статус для CLI
│           └── mrdark-net.uc   # таблица сетей для CLI
└── luci-app-mrdark/
    ├── Makefile
    ├── htdocs/luci-static/resources/view/mrdark.js
    └── root/
        ├── usr/share/luci/menu.d/luci-app-mrdark.json
        ├── usr/share/rpcd/acl.d/luci-app-mrdark.json
        └── usr/share/rpcd/ucode/mrdark.uc    # ubus-объект `mrdark`
```

## Сборка

Через SDK OpenWrt 25.12.x. Оба пакета содержат только shell/ucode/JS, поэтому
собираются как `all` и один раз подходят для любой архитектуры OpenWrt 25:

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
cp -r packages/mrdark-core packages/luci-app-mrdark package/
make package/mrdark-core/compile V=s
make package/luci-app-mrdark/compile V=s
```

Артефакты: `bin/packages/<arch>/base/mrdark-core-*.apk` и
`bin/packages/<arch>/luci/luci-app-mrdark-*.apk` (в APK — `arch:noarch`).

CI: [`.github/workflows/build-apk.yml`](../.github/workflows/build-apk.yml)
собирает оба пакета на тег `v*` и прикрепляет APK к релизу.

## Установка

```sh
apk update
apk add aircrack-ng tcpdump iw ucode ucode-mod-fs   # зависимости ядра
apk add luci-base rpcd-mod-ucode rpcd-mod-file ucode-mod-uci  # LuCI
apk add --allow-untrusted ./mrdark-core-1.0.0-r1.apk
apk add --allow-untrusted ./luci-app-mrdark-1.0.0-r1.apk
```

`hcxtools` (конвертация в `.hc22000`) не обязателен:
`apk add hcxtools` включает её автоматически (режим `hc22000=auto`).

## Использование (CLI)

```sh
mrdark scan                 # скан 2.4 ГГц, таблица по сигналу
mrdark target add 94:A7:B7:49:DE:2E 1 Lab-2G
mrdark target list
mrdark start                # запуск задачи по очереди
mrdark status               # состояние, цель, попытки, очередь
mrdark log -n 50
mrdark artifacts            # список файлов в /root/cap
mrdark stop | pause | resume | skip
mrdark verify /tmp/cap.pcap --bssid 94:A7:B7:49:DE:2E   # проверить вручную
```

LuCI: **Network → mrdark** (вкладки «Сканер / Задача / Артефакты / Настройки»).

## Как это работает

1. `scan.sh` поднимает `mrdark-mon0`, хоппит каналы 1–13, пишет один pcap,
   затем `mrdark-verify scan-networks` разбирает бэконы/ответы на probe и
   считает клиентов по data-кадрам → `networks.json` (SSID, BSSID, канал, RSSI,
   шифрование, AKM, PMF-required, клиенты).
2. Воркер берёт цель, ставит канал, запускает `tcpdump` (фильтр
   `ether host <BSSID> and ether proto 0x888e`), отправляет 2 залпа deauth,
   ждёт окно, останавливает захват.
3. `mrdark-verify attempt` ищет **пары** M1+M2 / M2+M3 / M3+M4 с совпадением
   replay counter и nonce — то есть именно то, что даёт пригодный хэш.
   При совпадении пишет «чистый» pcap только с кадрами пары.
4. `archive.sh` кладёт `.cap` в `/root/cap/<ESSID>/<BSSID>_<дата>.cap` (папка —
   имя сети, пробелы → `_`, кириллица сохраняется, скрытые сети → `hidden`), при наличии
   `hcxpcapngtool` — рядом `.22000`. Пустая конвертация = попытка неуспешна.

Успех считается по валидатору.

## Проверено на стенде

| | |
|---|---|
| OpenWrt | 25.12.6 r33311, x86/64, ядро 6.12.112 |
| Адаптер | TP-Link TL-WN722N v2/v3 (`2357:010c`, RTL8188EUS) |
| Драйвер | `kmod-rtl8xxxu` + `rtl8188eu-firmware` |
| Возможности | monitor ✓, инъекция ✓ (`aireplay-ng --test`) |
| Скан | 24 сети за 26 с, RSSI/каналы/AKM/PMF распознаны |
| Валидатор | 10 синтетических фикстур: M1+M2, M2+M3, M3+M4, QoS, linktype 105/127, отсев неполных/смешанных |
| Машина состояний | старт → 2 попытки → `skipped` → пауза круга → `stop` → monitor снят |

## Ограничения v1

- Только 2.4 ГГц, одно радио, AP-режим не используется.
- `deauth_mode=targeted` пока не реализован (всегда broadcast, залпы 2×N/2);
  опция принимается, но игнорируется — см. лог.
- Раздел «Сканер» не умеет 5 ГГц и не показывает vendor-specific IEs.
- Артефакты в `/root/cap` не переживают sysupgrade (см. ТЗ §16.2).
- Уведомлений (telegram/email) нет.

## Особенности rtl8xxxu (проверено на стенде)

- **`aireplay-ng` нужен `--ignore-negative-one`**: на rtl8xxxu он не может
  прочитать канал monitor-интерфейса через ioctl и без этого флага **вообще не
  отправляет deauth** (`Couldn't determine current channel … --ignore-negative-one`).
  Симптом: захват идёт, EAPOL нет совсем, клиенты не отваливаются.
- **Удаление и повторное создание monitor-интерфейса убивает приём** на этом
  драйвере (десятки байт вместо десятков КБ). Поэтому интерфейс создаётся один
  раз и живёт постоянно (`option keep_monitor '1'`), а смена канала на живом
  интерфейсе безопасна.
- Если приём всё же умер (USB-проброс, гипервизор), восстановление идёт через
  **USB re-enumeration**: `echo 0 > /sys/bus/usb/devices/<dev>/authorized`,
  пауза, `echo 1 > ...`. Это ~10–15 с и надёжнее, чем `rmmod`/`modprobe`
  (последний на этом стенде умеет зависать). Код делает это сам, если
  health-check не видит кадров.
- Health-check выставляет канал перед проверкой: у только что созданного
  monitor-интерфейса канала нет, и без этого любой скан выглядел бы как
  «radio receives nothing».

## Диагностика

- Воркер: `logread | grep mrdark`, лог `/tmp/mrdark/mrdark.log`, состояние
  `/tmp/mrdark/status.json`.
- `E_RADIO_BUSY` — netifd держит радио: уберите wireless-конфиг на этом
  радио (`mv /etc/config/wireless /root/wireless.bak && wifi reload`).
- `E_NO_MONITOR` — проверьте `iw phy` (нужен `* monitor`).
- Нет `timeout`/`pkill` в busybox — код их не использует (свой watchdog,
  убийство по pid-файлам).
