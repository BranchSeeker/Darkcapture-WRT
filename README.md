# Darkcapture-WRT

Превращает ваш обычный OpenWrt-роутер в **DarkcaptureWRT** — автономную станцию
захвата EAPOL-рукопожатий: скан эфира, выбор цели, deauth, захват, проверка
пригодности хэша и сохранение артефактов (cap файлов). Управление — из LuCI или по SSH.

> Только для лабораторных работ и сетей, на которые у вас есть разрешение.

## Системные требования

| | |
|---|---|
| ОС | **OpenWrt 25+** (apk; проверено на 25.12) |
| Постоянная память | **~8 МБ** под сам Darkcapture-WRT; зависимости (aircrack-ng, LuCI и др.) |
| Wi-Fi | Желательно **два диапазона**: **2.4 ГГц** — захват (Capture), **5 ГГц** — удалённое подключение и просмотр состояния |
| Адаптер | Должен поддерживать **monitor mode** и инъекцию. |
| Доступ | SSH root (или LuCI) |

На одном радио 2.4 ГГц во время захвата интерфейс уходит в monitor mode, поэтому
SSH/LuCI по этому же диапазону может пропасть. Для управления лучше использовать
5 ГГц, Ethernet или второе радио. Если на 2.4 ГГц уже поднята точка доступа,
радио нужно освободить — иначе воркер вернёт `E_RADIO_BUSY`.

## Установка через SSH — одной командой

```sh
wget -O /tmp/darkcapture-install.sh https://raw.githubusercontent.com/BranchSeeker/Darkcapture-WRT/main/install.sh && chmod +x /tmp/darkcapture-install.sh && sh /tmp/darkcapture-install.sh'
```

Установщик всегда доступен по постоянному пути:

```text
https://raw.githubusercontent.com/BranchSeeker/Darkcapture-WRT/main/install.sh
```

После установки его копия остаётся на роутере:

```text
/usr/libexec/darkcapture-wrt/install.sh
```

## Что делает установщик

1. Проверяет OpenWrt 25+ и наличие `apk`.
2. Ставит зависимости: `aircrack-ng`, `tcpdump`, `iw`, `uci`, `ucode`,
   `ucode-mod-fs`, `ca-bundle`; для LuCI — `luci-base`, `rpcd-mod-ucode`,
   `rpcd-mod-file` и ucode-модули.
3. Скачивает **последний релиз** с GitHub и устанавливает ядро и LuCI-приложение.
   Если релиза ещё нет, ставится ветка `main`.
4. Сохраняет существующий `/etc/config/mrdark`, включает службу `mrdark`,
   перезапускает `rpcd` и сбрасывает кэш LuCI.
5. Проверяет, поддерживает ли адаптер monitor mode. 

Полезные опции:

```sh
sh /usr/libexec/darkcapture-wrt/install.sh --no-luci        # только ядро и CLI
sh /usr/libexec/darkcapture-wrt/install.sh --with-hcxtools  # + hcxtools (.22000)
sh /usr/libexec/darkcapture-wrt/install.sh --version v1.0.0 # конкретный релиз
```

Обновление или повторная установка:

```sh
sh /usr/libexec/darkcapture-wrt/install.sh
```

Удаление (конфиг и артефакты сохраняются):

```sh
sh /usr/libexec/darkcapture-wrt/install.sh --uninstall
```

## Готовые APK

При пуше тега `v*` workflow [build-apk.yml](.github/workflows/build-apk.yml)
собирает универсальные пакеты (`PKGARCH=all`, в APK — `arch:noarch`) и прикрепляет их к релизу:

- `mrdark-core-*.apk`
- `luci-app-mrdark-*.apk`
- `SHA256SUMS`

Ручная установка на роутер (зависимости подтянутся из фидов):

```sh
apk update
apk add --allow-untrusted ./mrdark-core-*.apk ./luci-app-mrdark-*.apk
```

Основной установщик по-прежнему ставит из исходников и сам подтягивает
зависимости; APK в git не хранятся — только в релизах.

## Использование

LuCI: **Network → mrdark** (вкладки «Сканер», «Задача», «Артефакты», «Настройки»).

CLI:

```sh
mrdark scan
mrdark target add 94:A7:B7:49:DE:2E 1 Lab-2G
mrdark target list
mrdark start
mrdark status
mrdark log -n 50
mrdark artifacts
mrdark stop
```

Артефакты: `/root/cap/<ESSID>/<BSSID>_<дата>.cap` (и `.22000`, если установлен
`hcxtools`). Успех определяется валидатором пар M1–M4, а не размером файла.

> Внутри используются исторические имена: пакеты `mrdark-core` и
> `luci-app-mrdark`, служба `mrdark`, CLI `mrdark`. Это не влияет на установку
> и работу Darkcapture-WRT.

## Ограничения

- Захват только 2.4 ГГц.
- Только EAPOL 4-way.
- Без PMKID и WPS. (в планах)
- Нет уведомлений Telegram/email. (в планах)
- Артефакты в `/root/cap` не переживают sysupgrade.
- Нужен адаптер с monitor mode; встроенное радио подходит не всегда.

## Сборка из исходников

Пакеты `mrdark-core` и `luci-app-mrdark` собираются через OpenWrt SDK 25.12.
Подробности — в [packages/README.md](packages/README.md).

## Лицензия

GPL-2.0-only. См. [LICENSE](LICENSE).
