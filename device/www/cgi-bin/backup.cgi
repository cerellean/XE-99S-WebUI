#!/bin/sh
# ============================================================================
#  备份下载: ?t=config 导出配置文本 / ?t=mtd&n=N 导出 NAND 分区原始镜像
# ============================================================================

WEBUI_ROOT=$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)
export WEBUI_ROOT

. "$WEBUI_ROOT/lib/common.sh"
. "$WEBUI_ROOT/lib/transport.sh"
. "$WEBUI_ROOT/lib/device.sh"
. "$WEBUI_ROOT/lib/probe.sh"
. "$WEBUI_ROOT/lib/actions.sh"
[ "$WEBUI_MOCK" = "1" ] && . "$WEBUI_ROOT/lib/mock.sh"

qget() {
	printf '%s' "$QUERY_STRING" | tr '&' '\n' |
		awk -v k="$1" '{
			i = index($0, "=")
			if (i < 2) next
			if (substr($0, 1, i - 1) == k) { print substr($0, i + 1); exit }
		}'
}

form_init
tr_prefetch
require_auth

TYPE=$(qget t)
STAMP=$(date '+%Y%m%d-%H%M%S')

case $TYPE in
config)
	FN="xe99s-config-$STAMP.txt"
	printf 'Content-Type: text/plain; charset=utf-8\r\n'
	printf 'Content-Disposition: attachment; filename="%s"\r\n\r\n' "$FN"
	printf '# XE-99S 配置备份  %s\n' "$STAMP"
	printf '# 原厂 SIEPON-C 固件：可改的只有 /config/scfg.txt 里的键值，\n'
	printf '# 改完需要重启才生效；恢复时把对应行写回该文件即可。\n\n'
	printf '========== 固件版本 ==========\n'
	printf 'app(8271version) = %s\n' "$(dev_fw_version)"
	printf 'build(version)   = %s\n\n' "$(dev_fw_build)"
	printf '========== /config/scfg.txt（实际生效的定制配置）==========\n'
	tr_cat /config/scfg.txt 2>/dev/null
	printf '\n========== /userdata/scfg.txt ==========\n'
	tr_cat /userdata/scfg.txt 2>/dev/null
	printf '\n========== 出厂标识（mfginfo，只读）==========\n'
	_m=$(probe_get mfg 2>/dev/null)
	printf '%s\n' "$(printf '%s' "$_m" | tr '|' '\n')"
	printf '\n========== /etc/network/interfaces（管理地址）==========\n'
	for _f in /etc/network/interfaces /userdata/network/interfaces; do
		_c=$(tr_cat "$_f" 2>/dev/null)
		[ -n "$_c" ] && { printf '%s\n' "--- $_f"; printf '%s\n' "$_c"; }
	done
	printf '\n========== uboot env ==========\n'
	if tr_has_cmd fw_printenv; then
		tr_run "fw_printenv 2>/dev/null" | grep -E '^(bootcmd|bootargs|img_|CA8271_)' 
	else
		echo "(fw_printenv 不可用，原厂固件默认不带)"
	fi
	log_msg INFO "config backup downloaded"
	;;
mtd)
	N=$(qget n)
	case $N in '' | *[!0-9]*) N=99 ;; esac
	if [ "$N" -gt 15 ]; then
		printf 'Content-Type: application/json\r\n\r\n{"ok":false,"message":"分区号非法"}\n'
		exit 0
	fi
	tr_has_cmd nanddump || {
		printf 'Content-Type: application/json\r\n\r\n{"ok":false,"message":"nanddump 不可用"}\n'
		exit 0
	}
	part=$(tr_cat /proc/mtd 2>/dev/null | grep -E "^mtd$N:" | sed 's/.*"\(.*\)".*/\1/')
	[ -n "$part" ] || part="mtd$N"
	printf 'Content-Type: application/octet-stream\r\n'
	printf 'Content-Disposition: attachment; filename="%s-%s.bin"\r\n\r\n' "$part" "$STAMP"
	tr_run "nanddump -q /dev/mtd$N" 2>/dev/null
	log_msg WARN "mtd$N ($part) dumped by user"
	;;
*)
	printf 'Content-Type: application/json\r\n\r\n{"ok":false,"message":"未知备份类型"}\n'
	;;
esac
