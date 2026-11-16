#!/bin/sh
# ============================================================================
#  probe.sh  —  设备环境探测
#
#  为什么需要这一层:
#    SIEPON Package-A (自定义固件) 与 Package-C (CIG/CTC 原厂固件) 虽然同一
#    套 Cortina SATURN SDK, 但 rootfs 布局、可写分区、自带服务都不同。硬编码
#    任何一个版本的路径, 换固件就会静默失效。所以这里全部实测, 结果缓存到
#    var/probe.cache, 系统页可随时重新探测。
# ============================================================================

PROBE_CACHE=""

probe_dirs() {
	PROBE_CACHE="$WEBUI_VAR/probe.cache"
}

# ------------------------------------------------------------------ 基础 --
p_first_file() {
	for _pf in "$@"; do
		[ -r "$_pf" ] && [ -s "$_pf" ] && { printf '%s' "$_pf"; return 0; }
	done
	printf ''
}

p_read() {
	_f=$(p_first_file "$@")
	[ -n "$_f" ] || { printf ''; return 0; }
	tr -d '\r' <"$_f" 2>/dev/null | head -n 1 | cut -c1-120
}

p_has() { command -v "$1" >/dev/null 2>&1 && printf '1' || printf '0'; }

# --------------------------------------------------------------- 固件识别 --
# 输出 A / C / unknown。判据按可靠性排序, 只做"倾向判断", 不作为功能开关,
# 真正决定行为的是下面的 probe_write_targets 实测结果。
p_fw_variant() {
	# A 版自定义固件自带 WebUI, 且首页是它自己的 admin 页面
	for _d in /www/index.html /var/www/index.html /web/index.html; do
		if [ -r "$_d" ] && grep -qiE 'siepon|ca8271|xe-99|onu' "$_d" 2>/dev/null; then
			printf 'A'
			return 0
		fi
	done
	# 版本串直接说明
	_v=$(p_read /etc/siepon_version /etc/fw_version /etc/version /etc/VERSION /etc/base_version)
	case $_v in
	*SIEPON[_-]?A* | *siepon_a* | *SIEPONA*) printf 'A'; return 0 ;;
	*SIEPON[_-]?C* | *CTC*) printf 'C'; return 0 ;;
	esac
	# CTC 原厂固件普遍带 CTC 版本号文件 / CTC OAM 配置
	for _f in /etc/ctc_version /etc/ctc.conf /config/ctc.conf; do
		[ -e "$_f" ] && { printf 'C'; return 0; }
	done
	# 有 ca-iros 但没有自带 WebUI: 判定为原厂固件
	if [ "$(p_has ca-iros)" = "1" ]; then
		for _d in /www /var/www /web; do
			[ -r "$_d/index.html" ] || continue
			printf 'C'
			return 0
		done
	fi
	printf 'unknown'
}

# ------------------------------------------------------- 可写配置目标实测 --
# 输出空格分隔的 scfg.txt 绝对路径, 只包含"此刻确实可写"的目标。
#
# 关键点: rootfs 为 squashfs 的固件上 /config 是只读挂载, 真正可写的副本在
# overlay 上层 (/overlay/upper 或 /userdata/upper)。写 /config 会失败, 必须
# 落到 upper 层才会被下次挂载读回。
p_write_targets() {
	# 0) 人工覆盖优先: webui.conf 里写死路径时直接用它
	_o=$(conf_get SCFG_WRITE_OVERRIDE "")
	if [ -n "$_o" ]; then
		_d=$(dirname "$_o")
		[ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
		if [ -d "$_d" ] && [ -w "$_d" ]; then
			printf '%s' "$_o"
			return 0
		fi
	fi

	_t=""

	# 1) /config 本身可写 (overlay 合并视图或直接可写分区)
	if [ -d /config ]; then
		if [ -w /config ]; then
			touch /config/.webui_w 2>/dev/null && {
				rm -f /config/.webui_w 2>/dev/null
				_t="$_t /config/scfg.txt"
			}
		fi
	fi

	# 2) overlay 上层 (rootfs 只读时的真实落点)
	if [ -z "$_t" ]; then
		for _d in /overlay/upper /userdata/upper /mnt/overlay/upper; do
			[ -d "$_d" ] || continue
			if [ ! -d "$_d/config" ]; then
				mkdir -p "$_d/config" 2>/dev/null || continue
			fi
			touch "$_d/config/.webui_w" 2>/dev/null && {
				rm -f "$_d/config/.webui_w" 2>/dev/null
				_t="$_t $_d/config/scfg.txt"
				break
			}
		done
	fi

	# 3) /userdata 持久分区 (A 版固件把 PON MAC 放这里)
	if [ -d /userdata ] && [ -w /userdata ]; then
		_t="$_t /userdata/scfg.txt"
	fi

	# 4) 兜底: 至少给一个可写位置, 避免写操作完全无目标
	if [ -z "$_t" ]; then
		[ -w /tmp ] && _t="$_t /tmp/scfg.txt"
	fi

	printf '%s' "$_t" | sed 's/^ *//'
}

# 已存在的 scfg.txt (读优先级), 只在真实存在的文件里选
p_read_targets() {
	_t=""
	for _f in /config/scfg.txt /userdata/scfg.txt /overlay/upper/config/scfg.txt \
		/userdata/upper/config/scfg.txt /tmp/scfg.txt /config/default_scfg.txt; do
		[ -r "$_f" ] && _t="$_t $_f"
	done
	printf '%s' "$_t" | sed 's/^ *//'
}

# ------------------------------------------------------------- 自带 WebUI --
p_builtin_web() {
	for _d in /www/index.html /var/www/index.html /web/index.html; do
		[ -r "$_d" ] && { printf '1'; return 0; }
	done
	printf '0'
}

# 被占用的 HTTP 端口, 用于自动避开 (原厂固件常见 80/88 有服务)
p_busy_ports() {
	_b=""
	for _p in 80 88 8000; do
		if [ -r /proc/net/tcp ]; then
			# 0x0050 = 80, 0x0058 = 88, 0x1F40 = 8000
			case $_p in
			80) _h=0050 ;;
			88) _h=0058 ;;
			8000) _h=1F40 ;;
			esac
			awk -v h=":$_h" '$2 ~ h { f = 1 } END { exit !f }' /proc/net/tcp 2>/dev/null && _b="$_b $_p"
		fi
	done
	printf '%s' "$_b" | sed 's/^ *//'
}

# ------------------------------------------------------------- PON 端口号 --
# ca-iros 的 port_id 依固件/芯片配置而变, 不能写死 0x20007。
# 依次尝试: 配置文件 -> 已知候选 -> 从 ca-iros 输出里抓
p_port_id() {
	_v=$(conf_get PON_PORT_ID "")
	[ -n "$_v" ] && { printf '%s' "$_v"; return 0; }

	# 常见候选 (SATURN EPON/GPON 端口映射)
	for _c in 0x20007 0x20006 0x20001 0x10007; do
		if command -v ca-iros >/dev/null 2>&1; then
			_o=$(printf 'wca_epon_mpcp_registration_status_get -device_id 0 -port_id %s -llid 0\nexit\n' "$_c" \
				2>/dev/null | timeout 8 ca-iros 2>/dev/null)
			case $_o in
			*"CA_E_OK"*) printf '%s' "$_c"; return 0 ;;
			esac
		fi
	done
	printf '0x20007'
}

# --------------------------------------------------------------- 工具清单 --
p_tool_list() {
	_l=""
	for _t in ca-iros cig-cli i2cget i2cdump fw_setenv fw_printenv nanddump \
		flash_erase mtd_debug ethtool ifconfig ip tc sysctl; do
		command -v "$_t" >/dev/null 2>&1 && _l="$_l $_t"
	done
	printf '%s' "$_l" | sed 's/^ *//'
}

# ----------------------------------------------------------- 汇总与缓存 --
probe_run() {
	:
}

probe_all() {
	probe_dirs
	{
		printf 'fw_variant=%s\n' "$(p_fw_variant)"
		printf 'fw_version=%s\n' "$(dev_fw_version)"
		printf 'fw_base=%s\n' "$(dev_base_fw_version)"
		printf 'builtin_web=%s\n' "$(p_builtin_web)"
		printf 'read_targets=%s\n' "$(p_read_targets)"
		printf 'write_targets=%s\n' "$(p_write_targets)"
		printf 'busy_ports=%s\n' "$(p_busy_ports)"
		printf 'port_id=%s\n' "$(p_port_id)"
		printf 'tools=%s\n' "$(p_tool_list)"
		printf 'kernel=%s\n' "$(uname -r 2>/dev/null)"
		printf 'overlay=%s\n' "$([ -d /overlay ] && printf 1 || printf 0)"
		printf 'probed_at=%s\n' "$(date +%s 2>/dev/null)"
	} >"$PROBE_CACHE.tmp" 2>/dev/null && mv "$PROBE_CACHE.tmp" "$PROBE_CACHE" 2>/dev/null
	chmod 644 "$PROBE_CACHE" 2>/dev/null
}

probe_get() {
	probe_dirs
	[ -s "$PROBE_CACHE" ] || probe_all
	awk -F'=' -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$PROBE_CACHE" 2>/dev/null
}

probe_json() {
	probe_dirs
	[ -s "$PROBE_CACHE" ] || probe_all
	printf '{'
	_sep=""
	while IFS='=' read -r _k _v; do
		[ -n "$_k" ] || continue
		printf '%s"%s":%s' "$_sep" "$_k" "$(jval "$_v")"
		_sep=","
	done <"$PROBE_CACHE"
	printf '}'
}
