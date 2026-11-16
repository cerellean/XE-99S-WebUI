#!/bin/sh
# ============================================================================
#  备份下载: ?t=config 导出配置文本 / ?t=mtd&n=N 导出 NAND 分区原始镜像
# ============================================================================

WEBUI_ROOT=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
export WEBUI_ROOT

. "$WEBUI_ROOT/lib/common.sh"
. "$WEBUI_ROOT/lib/device.sh"
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
require_auth

TYPE=$(qget t)
STAMP=$(date '+%Y%m%d-%H%M%S')

case $TYPE in
config)
	FN="xe99s-config-$STAMP.txt"
	printf 'Content-Type: text/plain; charset=utf-8\r\n'
	printf 'Content-Disposition: attachment; filename="%s"\r\n\r\n' "$FN"
	printf '# XE-99S 配置备份  %s\n' "$STAMP"
	printf '# 恢复方式：把对应键值写回 /userdata/scfg.txt 或 fw_setenv\n\n'
	printf '========== /userdata/scfg.txt ==========\n'
	cat "$SCFG_FILE_USER" 2>/dev/null
	printf '\n========== /config/scfg.txt ==========\n'
	cat "$SCFG_FILE_CONFIG" 2>/dev/null
	printf '\n========== uboot env (CA8271_*) ==========\n'
	if command -v fw_printenv >/dev/null 2>&1; then
		fw_printenv 2>/dev/null | grep -E '^CA8271_|^bootcmd|^bootargs'
	else
		echo "(fw_printenv 不可用)"
	fi
	printf '\n========== onu_manu_modle.ini ==========\n'
	for _f in $INI_FILES; do [ -r "$_f" ] && { echo "--- $_f"; cat "$_f"; }; done
	log_msg INFO "config backup downloaded"
	;;
mtd)
	N=$(qget n)
	case $N in '' | *[!0-9]*) N=99 ;; esac
	if [ "$N" -gt 15 ]; then
		printf 'Content-Type: application/json\r\n\r\n{"ok":false,"message":"分区号非法"}\n'
		exit 0
	fi
	command -v nanddump >/dev/null 2>&1 || {
		printf 'Content-Type: application/json\r\n\r\n{"ok":false,"message":"nanddump 不可用"}\n'
		exit 0
	}
	part=$(grep -E "^mtd$N:" /proc/mtd 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')
	[ -n "$part" ] || part="mtd$N"
	printf 'Content-Type: application/octet-stream\r\n'
	printf 'Content-Disposition: attachment; filename="%s-%s.bin"\r\n\r\n' "$part" "$STAMP"
	nanddump -q "/dev/mtd$N" 2>/dev/null
	log_msg WARN "mtd$N ($part) dumped by user"
	;;
*)
	printf 'Content-Type: application/json\r\n\r\n{"ok":false,"message":"未知备份类型"}\n'
	;;
esac
