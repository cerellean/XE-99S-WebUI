#!/bin/sh
# ============================================================================
#  业务逻辑层: 组装 JSON / 校验入参 / 落地写入
# ============================================================================

b() { if [ "$1" = "1" ]; then printf 'true'; else printf 'false'; fi; }

uptime_text() {
	_s=${1:-0}
	_d=$((_s / 86400))
	_h=$(((_s % 86400) / 3600))
	_m=$(((_s % 3600) / 60))
	if [ "$_d" -gt 0 ]; then
		printf '%d 天 %d 小时 %d 分' "$_d" "$_h" "$_m"
	else
		printf '%d 小时 %d 分' "$_h" "$_m"
	fi
}

# ---------------------------------------------------------------- 登录 --
act_login() {
	_u=$(form_get user)
	_p=$(form_get pass)
	[ -r "$WEBUI_PASSWD" ] || resp_err no_account "设备上还没有账号，请先运行 install.sh"
	_stored=$(awk -F: -v u="$_u" '$1 == u { print $2 ":" $3; exit }' "$WEBUI_PASSWD")
	[ -n "$_stored" ] || {
		sleep 1
		resp_err bad_login "用户名或密码错误"
	}
	_salt=${_stored%%:*}
	_hash=${_stored#*:}
	if [ "$(hash_str "$_salt$_p")" != "$_hash" ]; then
		sleep 1
		log_msg WARN "login failed user=$_u ip=$REMOTE_ADDR"
		resp_err bad_login "用户名或密码错误"
	fi
	log_msg INFO "login ok user=$_u ip=$REMOTE_ADDR"
	resp_ok ",$(j_str token "$(issue_token "$_u")"),$(j_str user "$_u")"
}

act_logout() { resp_ok ""; }

# ---------------------------------------------------------------- 状态 --
act_status() {
	_caps=$(dev_caps | awk -F= '{ printf "%s\"%s\":%s", (NR > 1 ? "," : ""), $1, ($2 == "1" ? "true" : "false") }')

	_up=$(sys_uptime_sec)
	set -- $(sys_meminfo)
	_mt=${1:-0}; _mf=${2:-0}; _ma=${3:-0}
	_mpct=0
	[ "$_mt" -gt 0 ] && _mpct=$(((_mt - _ma) * 100 / _mt))
	_load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
	_fw=$(dev_fw_version)
	_bfw=$(dev_base_fw_version)
	_kern=$(awk '{ print $3 }' /proc/version 2>/dev/null)
	_hn=$(cat /proc/sys/kernel/hostname 2>/dev/null)
	_ip=$(iface_ip)
	[ -n "$_ip" ] || _ip="—"

	# PON
	_pmac=$(scfg_read CFG_ID_MAC_ADDRESS)
	_pmode=$(scfg_read CFG_ID_PON_MAC_MODE)
	_reg_raw=$(pon_reg_status 2>/dev/null)
	_trf_raw=$(pon_traffic_status 2>/dev/null)
	_reg_state=$(printf '%s' "$_reg_raw" | sed -n 's/.*\[reg_state *= *\([0-9]*\)\].*/\1/p' | head -n1)
	_olt_mac=$(printf '%s' "$_reg_raw" | sed -n 's/.*\[olt_mac_addr *= *\([0-9A-Fa-f:]*\)\].*/\1/p' | head -n1)
	_ds=$(printf '%s' "$_trf_raw" | sed -n 's/.*\[downstream *= *\([0-9]*\)\].*/\1/p' | head -n1)
	_us=$(printf '%s' "$_trf_raw" | sed -n 's/.*\[upstream *= *\([0-9]*\)\].*/\1/p' | head -n1)

	_pon_ok=0
	[ "$_reg_state" = "1" ] && _pon_ok=1
	_auth_ok=0
	[ "$_ds" = "1" ] && [ "$_us" = "1" ] && _auth_ok=1

	case $_pmode in
	0x02 | 0x2) _pmode_txt="10G-EPON 对称" ;;
	0x01 | 0x1) _pmode_txt="10G-EPON 非对称" ;;
	0x05 | 0x5) _pmode_txt="XGS-PON" ;;
	0x04 | 0x4) _pmode_txt="XG-PON" ;;
	'') _pmode_txt="未读取" ;;
	*) _pmode_txt="未知" ;;
	esac

	# 光模块
	_o_avail=0
	_o_temp=""; _o_vcc=""; _o_bias=""; _o_tx=""; _o_rx=""
	_ddm=$(ddm_read 2>/dev/null)
	if [ -n "$_ddm" ]; then
		set -- $_ddm
		_o_temp=$1; _o_vcc=$2; _o_bias=$3; _o_tx=$4; _o_rx=$5
		_o_avail=1
	fi

	set -- $(sys_iface_stat eth0)
	_rx=${1:-0}; _tx=${2:-0}; _sp=${3:-0}

	http_head
	printf '{"ok":true,"ts":%s,' "$NOW"
	printf '"sys":{"hostname":%s,"uptime":%s,"uptime_text":%s,"load":%s,' \
		"$(jval "$_hn")" "${_up:-0}" "$(jval "$(uptime_text "$_up")")" "$(jval "$_load")"
	printf '"mem_total_kb":%s,"mem_free_kb":%s,"mem_used_pct":%s,"fw":%s,"base_fw":%s,"kernel":%s,"ip":%s,"webui":%s},' \
		"$_mt" "$_mf" "$_mpct" "$(jval "$_fw")" "$(jval "$_bfw")" "$(jval "$_kern")" "$(jval "$_ip")" "$(jval "$(conf_get WEBUI_VERSION 1.0.0)")"
	printf '"pon":{"mode":%s,"mode_text":%s,"reg_state":%s,"registered":%s,"authenticated":%s,' \
		"$(jval "$_pmode")" "$(jval "$_pmode_txt")" "$(jval "$_reg_state")" "$(b "$_pon_ok")" "$(b "$_auth_ok")"
	printf '"olt_mac":%s,"pon_mac":%s,"downstream":%s,"upstream":%s},' \
		"$(jval "$_olt_mac")" "$(jval "$_pmac")" "$(jval "$_ds")" "$(jval "$_us")"
	printf '"optics":{"available":%s,"temp":%s,"vcc":%s,"bias":%s,"tx_power":%s,"rx_power":%s},' \
		"$(b "$_o_avail")" "$(jnum "$_o_temp")" "$(jnum "$_o_vcc")" "$(jnum "$_o_bias")" "$(jnum "$_o_tx")" "$(jnum "$_o_rx")"
	printf '"iface":{"name":"eth0","rx_bytes":%s,"tx_bytes":%s,"speed":%s},' "${_rx:-0}" "${_tx:-0}" "${_sp:-0}"
	printf '"caps":{%s}}\n' "$_caps"
	exit 0
}

# ---------------------------------------------------------------- 配置读取 --
act_config() {
	_loid=$(arr_to_str "$(scfg_read CFG_ID_LOID)")
	_lpwd=$(arr_to_str "$(scfg_read CFG_ID_PASSWD)")
	_hwv=$(scfg_read CFG_ID_HW_VERSION | tr -d '{}' | tr -s ' ')

	http_head
	printf '{"ok":true,'
	printf '"pon":{"pon_mac":%s,"loid":%s,"loid_pwd":%s,"sn":%s,"sn_rw":%s,"pon_mode":%s,"report_mode":%s},' \
		"$(jval "$(scfg_read CFG_ID_MAC_ADDRESS)")" "$(jval "$_loid")" "$(jval "$_lpwd")" \
		"$(jval "$(dev_sn)")" "$(jval "$(dev_sn_writable)")" \
		"$(jval "$(scfg_read CFG_ID_PON_MAC_MODE)")" "$(jval "$(scfg_read CFG_ID_PON_REPORT_MODE)")"
	printf '"tlv":{"fw_bootver":%s,"fw_bootcrc":%s,"fw_fwver":%s,"fw_fwcrc":%s,' \
		"$(jval "$(env_get CA8271_FW_BOOTVER)")" "$(jval "$(env_get CA8271_FW_BOOTCRC)")" \
		"$(jval "$(env_get CA8271_FW_FWVER)")" "$(jval "$(env_get CA8271_FW_FWCRC)")"
	printf '"chip_id":%s,"chip_model":%s,' \
		"$(jval "$(env_get CA8271_CHIP_ID)")" "$(jval "$(env_get CA8271_CHIP_MODEL)")"
	printf '"manu_year":%s,"manu_mon":%s,"manu_info":%s,' \
		"$(jval "$(env_get CA8271_MANU_YEAR)")" "$(jval "$(env_get CA8271_MANU_MON)")" \
		"$(jval "$(ini_get manu_info)")"
	printf '"ven_name":%s,"model":%s,"hw_ver":%s},' \
		"$(jval "$(env_get CA8271_VEN_NAME)")" "$(jval "$(ini_get model)")" "$(jval "$(env_get CA8271_HW_VER)")"
	printf '"bridge":{"force_bridge":%s,"force_bridge_mac":%s,"force_traffic":%s},' \
		"$(jval "$(env_get CA8271_FORCE_BRIDGE)")" "$(jval "$(env_get CA8271_FORCE_BRIDGE_MAC)")" \
		"$(jval "$(env_get CA8271_FORCE_TRAFFIC)")"
	printf '"net":{"ip":%s,"mask":%s,"gw":%s,"conf":%s},' \
		"$(jval "$(iface_ip)")" "$(jval "$(iface_mask)")" "$(jval "$(iface_gw)")" "$(jval "$(net_conf_path)")"
	printf '"misc":{"hw_version_scfg":%s}}\n' "$(jval "$_hwv")"
	exit 0
}

# ---------------------------------------------------------------- 网络 --
NET_CONF_CANDIDATES=${NET_CONF_CANDIDATES:-/etc/network/interfaces /userdata/network/interfaces}

net_conf_path() {
	for _f in $NET_CONF_CANDIDATES; do
		[ -r "$_f" ] && { printf '%s' "$_f"; return 0; }
	done
	printf ''
}

iface_ip() {
	ip -4 addr show eth0 2>/dev/null | awk '/inet /{ sub(/\/.*/, "", $2); print $2; exit }'
}

iface_mask() {
	_m=$(ifconfig eth0 2>/dev/null | awk '/Mask:/{ for (i = 1; i <= NF; i++) if ($i ~ /^Mask:/) { sub(/^Mask:/, "", $i); print $i; exit } }')
	[ -n "$_m" ] && { printf '%s' "$_m"; return; }
	# 由前缀长度换算
	_p=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{ print $2; exit }' | sed 's/.*\///')
	[ -n "$_p" ] && awk -v p="$_p" 'BEGIN{
		n = 0
		for (i = 0; i < p; i++) n += 2 ^ (31 - i)
		printf "%d.%d.%d.%d", int(n / 16777216) % 256, int(n / 65536) % 256, int(n / 256) % 256, n % 256
	}'
}

iface_gw() {
	ip route 2>/dev/null | awk '/^default/{ print $3; exit }'
}

# ---------------------------------------------------------------- ini --
ini_get() {
	for _f in $INI_FILES; do
		[ -r "$_f" ] || continue
		_v=$(awk -v k="$1" '
			{
				i = index($0, "=")
				if (i < 2) next
				key = substr($0, 1, i - 1)
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
				if (key != k) next
				v = substr($0, i + 1); gsub(/\r/, "", v)
				print v; exit
			}' "$_f")
		[ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
	done
	return 1
}

ini_set() {
	local _ok _f
	_ok=0
	for _f in $INI_FILES; do
		[ -w "$_f" ] || continue
		cp -f "$_f" "$WEBUI_VAR/backup/$(basename "$_f").$(date +%s)" 2>/dev/null
		if awk -v k="$1" -v v="$2" '
			BEGIN { done = 0 }
			{
				i = index($0, "=")
				key = (i > 1) ? substr($0, 1, i - 1) : ""
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
				if (key == k) { print k "=" v; done = 1; next }
				print
			}
			END { if (!done) print k "=" v }' "$_f" >"$_f.new.$$" 2>/dev/null; then
			mv -f "$_f.new.$$" "$_f" && _ok=1
		else
			rm -f "$_f.new.$$"
		fi
	done
	[ "$_ok" = 1 ] || return 1
	[ "$(ini_get "$1")" = "$2" ] || return 2
	return 0
}

# ---------------------------------------------------------------- 写入 --
act_set() {
	_f=$(form_get field)
	_v=$(form_get value)
	[ -n "$_f" ] || resp_err bad_request "缺少字段名"

	case $_f in
	pon_mac)
		_nv=$(valid_mac "$_v") || resp_err invalid "MAC 格式应为 AA:BB:CC:DD:EE:FF"
		scfg_write MAC CFG_ID_MAC_ADDRESS "$_nv" || resp_err write_fail "写入 scfg.txt 失败，请查看诊断页"
		;;
	loid)
		valid_text "$_v" 24 || resp_err invalid "LOID 只允许字母数字与 . _ -，且 ≤24 字符"
		scfg_write CHAR-ARRAY CFG_ID_LOID "$(str_to_arr "$_v" 24)" || resp_err write_fail "写入 LOID 失败"
		;;
	loid_pwd)
		valid_text "$_v" 12 || resp_err invalid "LOID 密码 ≤12 字符且不含特殊符号"
		scfg_write CHAR-ARRAY CFG_ID_PASSWD "$(str_to_arr "$_v" 12)" || resp_err write_fail "写入 LOID 密码失败"
		;;
	sn)
		# CTC 序列号: 常见 12 位 (4 位厂商码 + 8 位序列) 或 16 位 HEX。
		# 不同省份规则不一, 这里只拦危险字符, 不做格式硬约束。
		valid_text "$_v" 24 || resp_err invalid "序列号只允许字母数字与 . _ -，且 ≤24 字符"
		case $(dev_sn_writable) in
		scfg) scfg_write STRING CFG_ID_SERIAL_NUMBER "$_v" || resp_err write_fail "写入序列号失败" ;;
		env) env_set CA8271_SERIAL_NUMBER "$_v" || resp_err write_fail "写入序列号失败（需 fw_setenv）" ;;
		*) resp_err unsupported "当前固件未找到可写的序列号位置，请在自检页确认" ;;
		esac
		;;
	pon_mode)
		case $_v in
		0x02 | 0x01) _nv=$_v ;;
		*) resp_err invalid "PON 模式取值非法" ;;
		esac
		scfg_write CHAR CFG_ID_PON_MAC_MODE "$_nv" || resp_err write_fail "写入 PON 模式失败"
		;;
	report_mode)
		_nv=$(valid_enum "$_v" "0 1 2 3 4 5") || resp_err invalid "Report 模式取值非法"
		scfg_write CHAR CFG_ID_PON_REPORT_MODE "$_nv" || resp_err write_fail "写入 Report 模式失败"
		;;
	fw_bootver | fw_bootcrc | fw_fwver | fw_fwcrc | chip_id | chip_model | ven_name | hw_ver | manu_year | manu_mon)
		valid_text "$_v" 32 || resp_err invalid "内容含非法字符或过长"
		case $_f in
		fw_bootver) _k=CA8271_FW_BOOTVER ;;
		fw_bootcrc) _k=CA8271_FW_BOOTCRC ;;
		fw_fwver) _k=CA8271_FW_FWVER ;;
		fw_fwcrc) _k=CA8271_FW_FWCRC ;;
		chip_id) _k=CA8271_CHIP_ID ;;
		chip_model) _k=CA8271_CHIP_MODEL ;;
		ven_name) _k=CA8271_VEN_NAME ;;
		hw_ver) _k=CA8271_HW_VER ;;
		manu_year) _k=CA8271_MANU_YEAR ;;
		manu_mon) _k=CA8271_MANU_MON ;;
		esac
		env_set "$_k" "$_v" || resp_err write_fail "写入环境变量 $_k 失败（需 fw_setenv）"
		;;
	manu_info | model)
		valid_text "$_v" 64 || resp_err invalid "内容含非法字符或过长"
		ini_set "$_f" "$_v" || resp_err write_fail "写入 onu_manu_modle.ini 失败"
		;;
	force_bridge | force_traffic)
		_nv=$(valid_enum "$_v" "0 1") || resp_err invalid "取值只能是 0 或 1"
		case $_f in
		force_bridge) _k=CA8271_FORCE_BRIDGE ;;
		force_traffic) _k=CA8271_FORCE_TRAFFIC ;;
		esac
		env_set "$_k" "$_nv" || resp_err write_fail "写入环境变量 $_k 失败"
		;;
	force_bridge_mac)
		_nv=$(valid_mac "$_v") || resp_err invalid "MAC 格式错误"
		env_set CA8271_FORCE_BRIDGE_MAC "$_nv" || resp_err write_fail "写入 MAC 过滤失败"
		;;
	net_ip)
		_nv=$(valid_ipv4 "$_v") || resp_err invalid "IP 地址非法"
		net_write_address "$_nv" "" || resp_err write_fail "无法修改网络配置（只读或格式未知）"
		;;
	net_mask)
		_nv=$(valid_ipv4 "$_v") || resp_err invalid "掩码非法"
		net_write_address "" "$_nv" || resp_err write_fail "无法修改网络配置"
		;;
	*)
		resp_err bad_request "未知字段：$_f"
		;;
	esac

	log_msg INFO "set $_f = $_v"
	resp_ok ",$(j_str field "$_f"),$(j_str value "$_v")"
}

net_write_address() {
	local _new_ip _new_mask _f
	_new_ip=$1
	_new_mask=$2
	_f=$(net_conf_path)
	[ -n "$_f" ] && [ -w "$_f" ] || return 1
	grep -q "iface eth0" "$_f" 2>/dev/null || return 1
	cp -f "$_f" "$WEBUI_VAR/backup/interfaces.$(date +%s)" 2>/dev/null
	awk -v nip="$_new_ip" -v nmask="$_new_mask" '
		/^[[:space:]]*iface[[:space:]]+eth0/ { inblk = 1; print; next }
		/^[[:space:]]*iface[[:space:]]+/ { inblk = 0 }
		inblk && nip != "" && /^[[:space:]]*address[[:space:]]/ { print "    address " nip; next }
		inblk && nmask != "" && /^[[:space:]]*netmask[[:space:]]/ { print "    netmask " nmask; next }
		{ print }' "$_f" >"$_f.new.$$" && mv -f "$_f.new.$$" "$_f" || return 1
	return 0
}

# ---------------------------------------------------------------- 改密码 --
act_password() {
	_old=$(form_get old)
	_new=$(form_get new)
	[ ${#_new} -ge 6 ] || resp_err invalid "新密码至少 6 位"
	_u=$(conf_get WEBUI_USER admin)
	_stored=$(awk -F: -v u="$_u" '$1 == u { print $2 ":" $3; exit }' "$WEBUI_PASSWD")
	_salt=${_stored%%:*}
	[ "$(hash_str "$_salt$_old")" = "${_stored#*:}" ] || resp_err bad_login "原密码不正确"
	_ns=$(rand_hex 8)
	printf '%s:%s:%s\n' "$_u" "$_ns" "$(hash_str "$_ns$_new")" >"$WEBUI_PASSWD"
	chmod 600 "$WEBUI_PASSWD" 2>/dev/null
	# 轮换密钥, 让所有已签发的旧令牌立即失效
	rand_hex 16 >"$WEBUI_SECRET" 2>/dev/null
	log_msg INFO "webui password changed"
	resp_ok ""
}

# ---------------------------------------------------------------- 诊断 --
act_diag() {
	_cmd="$1"
	case $_cmd in
	scfg) _out="===== /config/scfg.txt =====
$(cat /config/scfg.txt 2>/dev/null)
===== /userdata/scfg.txt =====
$(cat /userdata/scfg.txt 2>/dev/null)" ;;
	env) _out=$(fw_printenv 2>/dev/null || echo "fw_printenv 不可用") ;;
	pon) _out="===== mpcp registration =====
$(pon_reg_status 2>/dev/null)
===== llid traffic =====
$(pon_traffic_status 2>/dev/null)" ;;
	mtd) _out=$(mtd_list 2>/dev/null) ;;
	net) _out=$(ip addr 2>/dev/null
		echo "--- route ---"
		ip route 2>/dev/null) ;;
	ddm) _out=$(for _o in 0x60 0x62 0x64 0x66 0x68; do
		printf '%s = %s\n' "$_o" "$(i2c_word "$_o" 2>/dev/null || echo n/a)"
	done) ;;
	log) _out=$(tail -n 200 "$WEBUI_LOG" 2>/dev/null) ;;
	sys) _out=$(uname -a 2>/dev/null
		echo "--- mem ---"
		cat /proc/meminfo 2>/dev/null | head -5
		echo "--- iface ---"
		cat /sys/class/net/eth0/speed 2>/dev/null) ;;
	*)
		_out="可用命令: scfg env pon mtd net ddm log sys"
		_cmd="help"
		;;
	esac
	http_head
	printf '{"ok":true,"cmd":%s,"output":%s}\n' "$(jval "$_cmd")" "$(jval "$_out")"
	exit 0
}

# ---------------------------------------------------------------- 环境自检 --
# 把"这套 WebUI 在这台设备上到底能做什么"如实呈现出来。
# 原厂 SIEPON-C 与自定义 SIEPON-A 的差异全部体现在这里, 不靠猜。
act_probe() {
	http_head
	printf '{"ok":true,"env":%s,"caps":{' "$(probe_json)"
	_sep=""
	dev_caps | while IFS='=' read -r _k _v; do
		printf '%s"%s":%s' "$_sep" "$_k" "$_v"
		_sep=","
	done
	printf '}}\n'
	exit 0
}

# ---------------------------------------------------------------- 分区表 --
act_mtd() {
	http_head
	printf '{"ok":true,"parts":['
	mtd_list 2>/dev/null | awk 'NF >= 4 {
		name = $2; gsub(/["\\]/, "", name)
		printf "%s{\"id\":\"%s\",\"name\":\"%s\",\"size\":%s,\"erase\":%s}", (NR > 1 ? "," : ""), $1, name, $3, $4
	}'
	printf ']}\n'
	exit 0
}

# ---------------------------------------------------------------- 动作 --
act_action() {
	_n=$(form_get name)
	case $_n in
	reboot | factory_reset | restart_webui | pon_reset)
		log_msg WARN "action $_n ip=$REMOTE_ADDR"
		dev_action "$_n" || resp_err action_fail "操作失败（当前固件未找到对应的服务脚本）"
		resp_ok ",$(j_str action "$_n")"
		;;
	*)
		resp_err bad_request "未知操作"
		;;
	esac
}
