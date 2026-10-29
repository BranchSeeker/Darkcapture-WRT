#!/bin/sh
# Darkcapture-WRT installer for OpenWrt 25+.
#
# Stable location (always the latest installer):
#   https://raw.githubusercontent.com/BranchSeeker/Darkcapture-WRT/main/install.sh
#
# During installation a copy is stored on the router:
#   /usr/libexec/darkcapture-wrt/install.sh
#
# Usage:
#   sh install.sh [options]
#   sh install.sh --uninstall
#
# The installer downloads the latest GitHub release, installs the runtime
# dependencies with apk and copies the core + LuCI files into place.
# Wi-Fi drivers are intentionally NOT installed.

set -u

REPO="BranchSeeker/Darkcapture-WRT"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
API_LATEST="https://api.github.com/repos/$REPO/releases/latest"
INSTALLER_DIR="/usr/libexec/darkcapture-wrt"
INSTALLER_PATH="$INSTALLER_DIR/install.sh"
VERSION_FILE="/etc/darkcapture-wrt.version"
UA="Darkcapture-WRT-installer"

VERSION=""
NO_DEPS=0
NO_LUCI=0
WITH_HCX=0
UNINSTALL=0
FORCE=0
RELEASE_TAG=""
RELEASE_TAR=""
API_TAR=""
TMP=""
src_root=""
pkg=""

say() { printf '%s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[-] %s\n' "$*" >&2; exit 1; }

cleanup() {
	if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
		rm -rf "$TMP"
	fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' HUP INT TERM

usage() {
	cat <<EOF
Установщик Darkcapture-WRT (OpenWrt 25+)

Использование:
  sh install.sh [опции]

Опции:
  --version TAG     установить конкретный релиз (или "main")
  --no-luci         только ядро и CLI, без LuCI
  --with-hcxtools   дополнительно установить hcxtools (.22000)
  --no-deps         не устанавливать пакеты OpenWrt
  --uninstall       удалить Darkcapture-WRT (конфиг и артефакты сохраняются)
  --force           продолжить на неподдерживаемой версии OpenWrt
  -h, --help        показать эту справку

Установщик скачивает последний релиз с GitHub и ставит его. Обязательные
пакеты (aircrack-ng, tcpdump, iw, ucode, ...) устанавливаются через apk.
Драйверы Wi-Fi НЕ устанавливаются: нужен адаптер, уже поддерживаемый
вашей сборкой OpenWrt. Драйверы для TP-Link не требуются.

Сам установщик всегда доступен по адресу:
  $RAW_BASE/install.sh
EOF
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--version)
				[ "$#" -ge 2 ] || die "для --version нужен тег"
				VERSION=$2
				shift 2
				;;
			--version=*)
				VERSION=${1#*=}
				[ -n "$VERSION" ] || die "для --version нужен тег"
				shift
				;;
			--no-luci)
				NO_LUCI=1
				shift
				;;
			--with-hcxtools)
				WITH_HCX=1
				shift
				;;
			--no-deps)
				NO_DEPS=1
				shift
				;;
			--uninstall)
				UNINSTALL=1
				shift
				;;
			--force)
				FORCE=1
				shift
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				die "неизвестная опция: $1 (см. --help)"
				;;
		esac
	done
}

require_root() {
	[ "$(id -u 2>/dev/null)" = "0" ] || die "запустите от root (ssh root@router)"
}

check_openwrt() {
	_rel=""
	if [ -r /etc/openwrt_release ]; then
		. /etc/openwrt_release
		_rel=${DISTRIB_RELEASE:-}
	fi

	_major=""
	case "$_rel" in
		[0-9]*)
			_major=${_rel%%.*}
			case "$_major" in
				*[!0-9]*) _major="" ;;
			esac
			;;
	esac

	if [ -n "$_major" ] && [ "$_major" -lt 25 ]; then
		if [ "$FORCE" = "1" ]; then
			warn "OpenWrt $_rel старше 25; продолжаю из-за --force"
		else
			die "требуется OpenWrt 25+ (найдено: ${_rel:-неизвестно}); используйте --force, чтобы продолжить"
		fi
	elif [ -z "$_rel" ]; then
		warn "не удалось прочитать /etc/openwrt_release; проверяю apk"
	fi

	command -v apk >/dev/null 2>&1 ||
		die "apk не найден: установщику нужен OpenWrt 25+ (apk-tools)"
}

fetch() {
	_url=$1
	_out=$2
	rm -f "$_out"

	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -T 60 -U "$UA" -O "$_out" "$_url" 2>/dev/null
	elif command -v wget >/dev/null 2>&1; then
		wget -q -T 60 -U "$UA" -O "$_out" "$_url" 2>/dev/null
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL -A "$UA" --connect-timeout 20 --max-time 180 -o "$_out" "$_url" 2>/dev/null
	else
		warn "не найден загрузчик (uclient-fetch, wget или curl)"
		return 1
	fi

	_rc=$?
	[ "$_rc" -eq 0 ] || return "$_rc"
	[ -s "$_out" ] || return 1
	return 0
}

install_deps() {
	if [ "$NO_DEPS" = "1" ]; then
		warn "пропускаю установку зависимостей (--no-deps)"
		return 0
	fi

	say "[*] Обновляю индексы apk..."
	apk update || die "apk update завершился ошибкой; проверьте сеть и /etc/apk/repositories"

	_deps="aircrack-ng tcpdump iw uci ucode ucode-mod-fs"
	say "[*] Устанавливаю зависимости: $_deps"
	# Word splitting is intentional: apk takes a list of packages.
	# shellcheck disable=SC2086
	apk add $_deps || die "не удалось установить зависимости ядра"

	# Needed for HTTPS downloads; most images already ship it.
	if ! apk add ca-bundle >/dev/null 2>&1; then
		warn "ca-bundle недоступен; HTTPS-загрузка может не работать"
	fi

	if [ "$NO_LUCI" = "0" ]; then
		_ui="luci-base rpcd rpcd-mod-ucode rpcd-mod-file ucode-mod-uci ucode-mod-ubus"
		say "[*] Устанавливаю зависимости LuCI: $_ui"
		# shellcheck disable=SC2086
		apk add $_ui || die "не удалось установить зависимости LuCI (для headless используйте --no-luci)"
	fi

	if [ "$WITH_HCX" = "1" ]; then
		if apk add hcxtools >/dev/null 2>&1; then
			ok "hcxtools установлен"
		else
			warn "hcxtools нет в фидах; вывод .22000 будет отключён"
		fi
	fi
}

resolve_release() {
	if [ -n "$VERSION" ]; then
		RELEASE_TAG=$VERSION
		case "$VERSION" in
			main|master)
				RELEASE_TAR="https://github.com/$REPO/archive/refs/heads/$VERSION.tar.gz"
				;;
			*)
				RELEASE_TAR="https://github.com/$REPO/archive/refs/tags/$VERSION.tar.gz"
				;;
		esac
		return 0
	fi

	say "[*] Ищу последний релиз..."
	_json="$TMP/release.json"
	if fetch "$API_LATEST" "$_json"; then
		RELEASE_TAG=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_json" | head -n1)
		API_TAR=$(sed -n 's/.*"tarball_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_json" | head -n1)
	fi

	if [ -z "$RELEASE_TAG" ]; then
		warn "не удалось определить последний релиз GitHub; ставлю ветку $BRANCH"
		RELEASE_TAG=$BRANCH
		RELEASE_TAR="https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz"
		return 0
	fi

	RELEASE_TAR="https://github.com/$REPO/archive/refs/tags/$RELEASE_TAG.tar.gz"
	ok "последний релиз: $RELEASE_TAG"
}

download_and_extract() {
	_tar="$TMP/release.tar.gz"
	say "[*] Скачиваю $RELEASE_TAG..."
	if ! fetch "$RELEASE_TAR" "$_tar"; then
		if [ -n "$API_TAR" ] && fetch "$API_TAR" "$_tar"; then
			:
		else
			die "не удалось скачать $RELEASE_TAG; проверьте DNS/TLS/ca-bundle"
		fi
	fi

	tar -tzf "$_tar" >/dev/null 2>&1 || die "скачанный архив не является корректным tar.gz"
	mkdir -p "$TMP/src" || die "не удалось создать $TMP/src"
	tar -xzf "$_tar" -C "$TMP/src" || die "не удалось распаковать архив"

	for _d in "$TMP/src"/*; do
		[ -d "$_d" ] || continue
		src_root=$_d
		break
	done
	[ -n "$src_root" ] || die "в архиве нет каталога верхнего уровня"

	pkg="$src_root/packages"
	[ -d "$pkg/mrdark-core/files" ] || die "в релизе нет packages/mrdark-core"
	if [ "$NO_LUCI" = "0" ]; then
		[ -d "$pkg/luci-app-mrdark/root" ] || die "в релизе нет packages/luci-app-mrdark"
	fi
}

install_core() {
	say "[*] Устанавливаю ядро..."

	if [ -x /etc/init.d/mrdark ]; then
		/etc/init.d/mrdark stop >/dev/null 2>&1 || true
	fi
	if [ -x /usr/libexec/mrdark/cleanup.sh ]; then
		/usr/libexec/mrdark/cleanup.sh >/dev/null 2>&1 || true
	fi

	mkdir -p /etc/config /etc/init.d /etc/uci-defaults /usr/bin || die "не удалось создать каталоги ядра"
	rm -rf /usr/libexec/mrdark || die "не удалось удалить /usr/libexec/mrdark"
	mkdir -p /usr/libexec/mrdark || die "не удалось создать /usr/libexec/mrdark"
	cp -R "$pkg/mrdark-core/files/usr/libexec/mrdark/." /usr/libexec/mrdark/ ||
		die "не удалось скопировать скрипты ядра"
	chmod 0755 /usr/libexec/mrdark/* || die "не удалось выставить права на скрипты ядра"

	cp "$pkg/mrdark-core/files/usr/bin/mrdark" /usr/bin/mrdark ||
		die "не удалось установить CLI mrdark"
	chmod 0755 /usr/bin/mrdark

	cp "$pkg/mrdark-core/files/etc/init.d/mrdark" /etc/init.d/mrdark ||
		die "не удалось установить init-скрипт"
	chmod 0755 /etc/init.d/mrdark

	cp "$pkg/mrdark-core/files/etc/uci-defaults/90_mrdark" /etc/uci-defaults/90_mrdark ||
		die "не удалось установить uci-defaults"
	chmod 0755 /etc/uci-defaults/90_mrdark

	if [ -f /etc/config/mrdark ]; then
		say "[*] Сохраняю существующий /etc/config/mrdark"
	else
		cp "$pkg/mrdark-core/files/etc/config/mrdark" /etc/config/mrdark ||
			die "не удалось установить /etc/config/mrdark"
		chmod 0600 /etc/config/mrdark
	fi
}

install_luci() {
	if [ "$NO_LUCI" = "1" ]; then
		say "[*] Пропускаю LuCI (--no-luci)"
		return 0
	fi

	say "[*] Устанавливаю LuCI-приложение..."
	mkdir -p /www/luci-static/resources/view /usr/share/luci/menu.d \
		/usr/share/rpcd/acl.d /usr/share/rpcd/ucode ||
		die "не удалось создать каталоги LuCI"

	cp "$pkg/luci-app-mrdark/htdocs/luci-static/resources/view/mrdark.js" \
		/www/luci-static/resources/view/mrdark.js ||
		die "не удалось установить LuCI-вью"
	cp "$pkg/luci-app-mrdark/root/usr/share/luci/menu.d/luci-app-mrdark.json" \
		/usr/share/luci/menu.d/luci-app-mrdark.json ||
		die "не удалось установить меню LuCI"
	cp "$pkg/luci-app-mrdark/root/usr/share/rpcd/acl.d/luci-app-mrdark.json" \
		/usr/share/rpcd/acl.d/luci-app-mrdark.json ||
		die "не удалось установить ACL rpcd"
	cp "$pkg/luci-app-mrdark/root/usr/share/rpcd/ucode/mrdark.uc" \
		/usr/share/rpcd/ucode/mrdark.uc ||
		die "не удалось установить rpcd-плагин"

	chmod 0644 /www/luci-static/resources/view/mrdark.js \
		/usr/share/luci/menu.d/luci-app-mrdark.json \
		/usr/share/rpcd/acl.d/luci-app-mrdark.json \
		/usr/share/rpcd/ucode/mrdark.uc ||
		die "не удалось выставить права на файлы LuCI"
}

install_self() {
	mkdir -p "$INSTALLER_DIR" || die "не удалось создать $INSTALLER_DIR"

	if [ -f "$src_root/install.sh" ]; then
		cp "$src_root/install.sh" "$INSTALLER_PATH" || die "не удалось сохранить установщик"
	elif [ -f "$0" ] && [ "$(basename "$0")" != "sh" ]; then
		cp "$0" "$INSTALLER_PATH" || die "не удалось сохранить установщик"
	else
		warn "в релизе не найден install.sh; $INSTALLER_PATH отсутствует"
	fi

	if [ -f "$INSTALLER_PATH" ]; then
		chmod 0755 "$INSTALLER_PATH"
	fi
	printf '%s\n' "$RELEASE_TAG" >"$VERSION_FILE" 2>/dev/null ||
		warn "не удалось записать $VERSION_FILE"
}

apply_defaults() {
	say "[*] Применяю настройки и запускаю службу..."

	if [ -x /etc/uci-defaults/90_mrdark ]; then
		/etc/uci-defaults/90_mrdark >/dev/null 2>&1 ||
			warn "uci-defaults завершился ошибкой; проверьте /etc/config/mrdark"
	fi

	/etc/init.d/mrdark enable >/dev/null 2>&1 || warn "не удалось включить службу mrdark"
	/etc/init.d/mrdark restart >/dev/null 2>&1 || warn "служба mrdark не перезапустилась"

	if [ -x /etc/init.d/rpcd ]; then
		/etc/init.d/rpcd restart >/dev/null 2>&1 || warn "не удалось перезапустить rpcd"
	fi

	rm -f /tmp/luci-indexcache* 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null
}

iw_monitor_check() {
	_out="$TMP/iw-phy.txt"
	iw phy >"$_out" 2>/dev/null &
	_pid=$!
	_i=0
	while [ "$_i" -lt 5 ] && kill -0 "$_pid" 2>/dev/null; do
		sleep 1
		_i=$((_i + 1))
	done
	if kill -0 "$_pid" 2>/dev/null; then
		kill -9 "$_pid" 2>/dev/null
		# do not wait: a process stuck in D state would never be reaped
		return 124
	fi
	wait "$_pid" 2>/dev/null
	grep -q '\* monitor' "$_out" 2>/dev/null
}

post_checks() {
	say ""
	ok "Darkcapture-WRT $RELEASE_TAG установлен"
	say "  CLI:        mrdark"
	if [ "$NO_LUCI" = "0" ]; then
		say "  LuCI:       Network -> mrdark"
	fi
	say "  Артефакты:  /root/cap"
	say "  Установщик: $INSTALLER_PATH"

	for _cmd in aireplay-ng tcpdump iw ucode; do
		command -v "$_cmd" >/dev/null 2>&1 || warn "не найдена команда: $_cmd"
	done

	if command -v iw >/dev/null 2>&1; then
		iw_monitor_check
		case $? in
			0) ok "monitor mode поддерживается хотя бы одним радио" ;;
			124) warn "iw phy не ответил за 5 с; проверьте адаптер вручную" ;;
			*) warn "monitor mode не найден: используйте адаптер, поддерживаемый вашей сборкой OpenWrt" ;;
		esac
	else
		warn "iw не найден; не могу проверить monitor mode"
	fi

	if ! command -v hcxpcapngtool >/dev/null 2>&1; then
		say "  Совет: 'apk add hcxtools' (или --with-hcxtools) включает вывод .22000"
	fi

	if command -v pgrep >/dev/null 2>&1; then
		if pgrep -f 'mrdark/worker.sh' >/dev/null 2>&1; then
			ok "воркер mrdark запущен"
		else
			warn "воркер mrdark не запущен; проверьте 'logread | grep mrdark'"
		fi
	fi
}

do_uninstall() {
	say "[*] Удаляю Darkcapture-WRT..."

	if [ -x /etc/init.d/mrdark ]; then
		/etc/init.d/mrdark stop >/dev/null 2>&1 || true
		/etc/init.d/mrdark disable >/dev/null 2>&1 || true
	fi
	if [ -x /usr/libexec/mrdark/cleanup.sh ]; then
		/usr/libexec/mrdark/cleanup.sh >/dev/null 2>&1 || true
	fi

	rm -f /etc/rc.d/S95mrdark /etc/rc.d/K10mrdark
	rm -rf /usr/libexec/mrdark
	rm -f /usr/bin/mrdark /etc/init.d/mrdark /etc/uci-defaults/90_mrdark
	rm -f /www/luci-static/resources/view/mrdark.js
	rm -f /usr/share/luci/menu.d/luci-app-mrdark.json
	rm -f /usr/share/rpcd/acl.d/luci-app-mrdark.json
	rm -f /usr/share/rpcd/ucode/mrdark.uc
	rm -f /etc/darkcapture-wrt.version
	rm -rf /tmp/mrdark
	rm -f /tmp/luci-indexcache* 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null

	if [ -x /etc/init.d/rpcd ]; then
		/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	fi

	ok "Darkcapture-WRT удалён"
	say "  Сохранено: /etc/config/mrdark, /root/cap"
	say "  Установщик сохранён: $INSTALLER_PATH"
	say "  Полное удаление: rm -rf $INSTALLER_DIR"
}

main() {
	parse_args "$@"
	require_root

	if [ "$UNINSTALL" = "1" ]; then
		do_uninstall
		exit 0
	fi

	check_openwrt
	TMP=$(mktemp -d /tmp/darkcapture.XXXXXX) || die "не удалось создать временный каталог"

	install_deps
	resolve_release
	download_and_extract
	install_core
	install_luci
	install_self
	apply_defaults
	post_checks
}

main "$@"
