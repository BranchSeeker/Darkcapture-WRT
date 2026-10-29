#!/bin/sh
# archive.sh <section> <bssid> <essid> <clean.pcap>
# Copies the verified capture into the artefacts dir.
# exit: 0 = stored, 1 = nothing to store, 2 = hc22000 conversion failed (fail-closed)

. /usr/libexec/mrdark/lib.sh

_sec=$1
_bssid=$2
_essid=$3
_src=$4

[ -s "$_src" ] || exit 1

_dir=$(mrd_cfg artifacts_dir /root/cap)
mkdir -p "$_dir" 2>/dev/null || exit 2
chmod 0700 "$_dir" 2>/dev/null

_mac=$(printf '%s' "$_bssid" | tr -d ':' | tr 'a-f' 'A-F')
[ -n "$_mac" ] || exit 2

# folder name is the ESSID: spaces and path separators become "_", the rest
# (including cyrillic) is kept as is; empty ESSID (hidden network) -> "hidden"
_ess=$(printf '%s' "$_essid" | tr ' ' '_' | tr -d '\r' |
	sed -e 's#/#_#g' -e 's#\\#_#g' -e 's/__*/_/g' \
	    -e 's/^[._]*//' -e 's/[._]*$//' |
	cut -b1-64)
[ -n "$_ess" ] || _ess=hidden

mkdir -p "$_dir/$_ess" 2>/dev/null
chmod 0700 "$_dir/$_ess" 2>/dev/null

_stamp=$(date +%Y%m%d-%H%M%S)
_base="${_mac}_${_stamp}"
_n=1
while [ -e "$_dir/$_ess/$_base.cap" ]; do
	_n=$((_n + 1))
	_base="${_mac}_${_stamp}-${_n}"
done

cp "$_src" "$_dir/$_ess/$_base.cap" 2>/dev/null || exit 2
chmod 0600 "$_dir/$_ess/$_base.cap" 2>/dev/null

# enforce the artefacts size cap (storage_max_mb, 2 MB by default): the oldest
# files are removed first, never the one just written
mrd_trim_artifacts() {
	_max=$(mrd_cfg storage_max_mb 2)
	case "$_max" in
		''|*[!0-9]*) _max=2 ;;
	esac
	[ "$_max" -gt 0 ] || return 0
	_limit=$((_max * 1024))
	_used=$(du -sk "$_dir" 2>/dev/null | awk '{ print $1 }')
	[ -n "$_used" ] || return 0
	[ "$_used" -le "$_limit" ] && return 0
	mrd_log warn "artefacts exceed ${_max}MB, trimming oldest"
	ls -1tr "$_dir"/*/*.cap "$_dir"/*/*.22000 2>/dev/null | while read -r _f; do
		_used=$(du -sk "$_dir" 2>/dev/null | awk '{ print $1 }')
		[ -n "$_used" ] || break
		[ "$_used" -le "$_limit" ] && break
		case "$_f" in
			"$_dir/$_ess/$_base.cap"|"$_dir/$_ess/$_base.22000") continue ;;
		esac
		rm -f "$_f"
		mrd_log warn "storage cap: removed $_f"
	done
}

mrd_trim_artifacts

# optional hc22000 conversion
_mode=$(mrd_cfg hc22000 auto)
if [ "$_mode" = "never" ]; then
	mrd_log info "archived $_dir/$_mac/$_base.cap"
	printf '%s\n' "$_dir/$_ess/$_base.cap"
	exit 0
fi

if command -v hcxpcapngtool >/dev/null 2>&1; then
	printf '%s' "$_essid" >"$MRD_RAW/essid.txt" 2>/dev/null
	rm -f "$MRD_RAW/$_base.22000"
	hcxpcapngtool -o "$MRD_RAW/$_base.22000" -E "$MRD_RAW/essid.txt" "$_src" \
		>/dev/null 2>>"$MRD_TMP/mrdark.log"
	if [ -s "$MRD_RAW/$_base.22000" ]; then
		cp "$MRD_RAW/$_base.22000" "$_dir/$_ess/$_base.22000" 2>/dev/null
		chmod 0600 "$_dir/$_ess/$_base.22000" 2>/dev/null
		rm -f "$MRD_RAW/$_base.22000"
		mrd_log info "archived $_dir/$_mac/$_base.cap + .22000"
		printf '%s\n%s\n' "$_dir/$_ess/$_base.cap" "$_dir/$_ess/$_base.22000"
		exit 0
	fi
	rm -f "$MRD_RAW/$_base.22000"
	mrd_log error "E_HCX_EMPTY: hcxpcapngtool produced no hash for $_base"
	mrd_error E_HCX_EMPTY "conversion produced no hash"
	# fail-closed: drop the unverifiable artefact
	rm -f "$_dir/$_ess/$_base.cap"
	exit 2
fi

if [ "$_mode" = "always" ]; then
	mrd_error E_NO_HCXTOOL "hc22000=always but hcxpcapngtool is missing"
	rm -f "$_dir/$_ess/$_base.cap"
	exit 2
fi

mrd_log info "archived $_dir/$_mac/$_base.cap (hcxtools not installed)"
printf '%s\n' "$_dir/$_ess/$_base.cap"
exit 0
