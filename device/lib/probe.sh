#!/bin/sh
# ============================================================================
#  probe.sh  —  设备环境探测 (SIEPON Package-C / 原厂 CTC 固件)
#
#  为什么还要探测:
#    虽然只支持原厂固件, 但 rootfs 是只读 squashfs + overlay, 真正可写的
#    scfg.txt 落在哪一层、iros 叫什么、有没有 nanddump, 各家批次并不完全一致。
#    硬编码任何一条都可能静默失效, 所以这里全部实测, 结果缓存到 var/probe.cache,
#    系统页可随时重新探测。
#
#  所有访问都走 transport.sh, 所以这套探测在"装在 Alpine 上、经 SSH 操作
#  猫棒"的场景下同样有效——探测的是猫棒, 不是 Alpine。
# ============================================================================

PROBE_CACHE=""

probe_dirs() {
	PROBE_CACHE="$WEBUI_VAR/probe.cache"
}

# ------------------------------------------------------------------ 基础 --
p_read() {
	for _pf in "$@"; do
		_c=$(tr_cat "$_pf" 2>/dev/null)
		[ -n "$_c" ] && { printf '%s' "$_c" | head -n 1 | cut -c1-120 | tr -d '\r'; return 0; }
	done
	printf ''
}

# ------------------------------------------------------- 可写配置目标实测 --
# 原厂固件的定制配置就是 /config/scfg.txt —— 它自己的 WebUI 也改这个文件。
# rootfs 只读时, overlay 会把写入 copy-up 到 /overlay/upper/config/scfg.txt,
# 从 /config 这一侧看依然是"可写", 所以优先判 /config。
p_write_targets() {
	_o=$(conf_get SCFG_WRITE_OVERRIDE "")
	if [ -n "$_o" ]; then
		tr_dir_writable "$(dirname "$_o")" && { printf '%s' "$_o"; return 0; }
	fi

	tr_dir_writable /config && { printf '/config/scfg.txt'; return 0; }
	tr_dir_writable /overlay/upper/config && { printf '/overlay/upper/config/scfg.txt'; return 0; }
	tr_dir_writable /userdata && { printf '/userdata/scfg.txt'; return 0; }
	printf ''
}

p_read_targets() {
	_t=""
	for _f in /config/scfg.txt /overlay/upper/config/scfg.txt /userdata/scfg.txt \
		/config/default_scfg.txt; do
		tr_exists "$_f" && _t="$_t $_f"
	done
	printf '%s' "$_t" | sed 's/^ *//'
}

# --------------------------------------------------------------- iROS --
p_iros() {
	_i=$(iros_bin)
	[ -n "$_i" ] && printf '1' || printf '0'
}

p_iros_cmd() { iros_bin; }

# --------------------------------------------------------------- 工具清单 --
p_tool_list() {
	_l=""
	for _t in iros ca-iros nanddump flash_erase mtd_debug fw_setenv fw_printenv \
		ethtool ifconfig ip tc sysctl strings; do
		tr_has_cmd "$_t" && _l="$_l $_t"
	done
	printf '%s' "$_l" | sed 's/^ *//'
}

# ------------------------------------------------------------- 出厂标识 --
p_mfg() { mfg_strings; }

# ----------------------------------------------------------- 汇总与缓存 --
probe_all() {
	probe_dirs
	# 连不上就不要再逐项探测了(每项都要等一次超时), 也不要把"空结果"写进
	# 缓存——否则设备恢复后页面还是旧数据
	if tr_remote && [ "$(tr_conn_ok)" != "1" ]; then
		PROBE_FAILED=1
		return 1
	fi
	PROBE_FAILED=0
	{
		printf 'fw_version=%s\n' "$(dev_fw_version)"
		printf 'fw_build=%s\n' "$(dev_fw_build)"
		printf 'read_targets=%s\n' "$(p_read_targets)"
		printf 'write_targets=%s\n' "$(p_write_targets)"
		printf 'port_id=%s\n' "$(pon_port_id)"
		printf 'iros=%s\n' "$(p_iros)"
		printf 'iros_cmd=%s\n' "$(p_iros_cmd)"
		printf 'mfg=%s\n' "$(p_mfg)"
		printf 'tools=%s\n' "$(p_tool_list)"
		printf 'kernel=%s\n' "$(tr_cat /proc/version 2>/dev/null | awk '{print $3}')"
		printf 'overlay=%s\n' "$(tr_exists /overlay && printf 1 || printf 0)"
		printf 'mode=%s\n' "$([ "$WEBUI_REMOTE" = "1" ] && printf 'remote' || printf 'local')"
		printf 'probed_at=%s\n' "$(date +%s 2>/dev/null)"
	} >"$PROBE_CACHE.tmp" 2>/dev/null && mv "$PROBE_CACHE.tmp" "$PROBE_CACHE" 2>/dev/null
	chmod 644 "$PROBE_CACHE" 2>/dev/null
}

probe_get() {
	probe_dirs
	if tr_remote && [ "$(tr_conn_ok)" != "1" ]; then
		return 1
	fi
	[ -s "$PROBE_CACHE" ] || probe_all
	awk -F'=' -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$PROBE_CACHE" 2>/dev/null
}

probe_json() {
	probe_dirs
	if tr_remote && [ "$(tr_conn_ok)" != "1" ]; then
		printf '{"mode":"remote","conn":%s}' "$(conn_json)"
		return 0
	fi
	[ -s "$PROBE_CACHE" ] || probe_all
	printf '{'
	_sep=""
	while IFS='=' read -r _k _v; do
		[ -n "$_k" ] || continue
		printf '%s"%s":%s' "$_sep" "$_k" "$(jval "$_v")"
		_sep=","
	done <"$PROBE_CACHE"
	# 连接状态不进缓存: 重新连上之后必须立刻反映真实情况
	printf '%s"conn":%s}' "$_sep" "$(conn_json)"
}

# 连接状态片段, 供 probe / conn 接口共用
conn_json() {
	if tr_remote; then
		_ok=$(tr_conn_ok)
		_cfg=false
		_host=""
		if tr_configured; then
			_cfg=true
			_host="$REMOTE_HOST:$REMOTE_PORT"
		fi
		printf '{"mode":"remote","configured":%s,"host":%s,"user":%s,"transport":%s,"reachable":%s,"ms":%s,"error":%s,"has_pass":%s,"key":%s,"auth":%s,"sshpass":%s,"ssh":%s}' \
			"$_cfg" "$(jval "$_host")" "$(jval "$REMOTE_USER")" \
			"$(jval "$REMOTE_TRANSPORT")" \
			"$([ "$_ok" = "1" ] && printf true || printf false)" \
			"$(jnum "$(tr_conn_ms)")" "$(jval "$(tr_conn_err)")" \
			"$([ -n "$REMOTE_PASS" ] && printf true || printf false)" \
			"$(jval "$(tr_key_file 2>/dev/null)")" \
			"$(jval "$(tr_auth_mode)")" \
			"$([ "$(tr_sshpass_ok)" = "1" ] && printf true || printf false)" \
			"$([ "$(tr_ssh_ok)" = "1" ] && printf true || printf false)"
	else
		printf '{"mode":"local","configured":true,"host":"","user":"","transport":"local","reachable":true,"ms":0,"error":"","has_pass":false,"key":"","auth":"local","sshpass":true,"ssh":true}'
	fi
}
