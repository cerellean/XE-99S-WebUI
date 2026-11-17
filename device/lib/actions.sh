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
# 只认 WebUI 自己的账号; 猫棒的地址/账号/密码属于"设备连接", 由控制台里的
# 向导或系统页提交(见 act_conn_save)。两套凭据分开, 免得用户混着填。
act_login() {
	local _u _p

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
	_load=$(tr_cat /proc/loadavg 2>/dev/null | cut -d' ' -f1-3)
	_fw=$(dev_fw_version)
	_bfw=$(dev_fw_build)
	_kern=$(tr_cat /proc/version 2>/dev/null | awk '{ print $3 }')
	_hn=$(tr_cat /proc/sys/kernel/hostname 2>/dev/null)
	_ip=$(iface_ip)
	[ -n "$_ip" ] || _ip="—"
	_mac=$(iface_mac eth0)

	# PON: 一次 iros 会话把注册状态、LLID 使能、DOM 全部取回(见 device.sh)
	pon_load
	_pmac=$(scfg_read CFG_ID_MAC_ADDRESS)
	_pmode=$(scfg_read CFG_ID_PON_MAC_MODE)
	_reg_state=$(pon_get reg_state)
	_llid=$(pon_get llid)
	_olt_mac=$(pon_get olt_mac)
	_ds=$(pon_get downstream)
	_us=$(pon_get upstream)
	_cause=$(pon_get dereg_cause)
	_retry=$(pon_get retry)

	_pon_ok=$(pon_registered)
	_auth_ok=$(pon_authorized)

	case $_pmode in
	0x02 | 0x2) _pmode_txt="10G-EPON 对称" ;;
	0x01 | 0x1) _pmode_txt="10G-EPON 非对称" ;;
	0x05 | 0x5) _pmode_txt="XGS-PON" ;;
	0x04 | 0x4) _pmode_txt="XG-PON" ;;
	'') _pmode_txt="未读取" ;;
	*) _pmode_txt="未知" ;;
	esac

	# 数据通路: 原厂 default_scfg.txt 里的 CFG_ID_DATAPATH_MODE
	_dp=$(scfg_read CFG_ID_DATAPATH_MODE)
	case $_dp in
	1) _dp_txt="桥接（SFU）" ;;
	0) _dp_txt="路由（R/G）" ;;
	'') _dp_txt="未读取" ;;
	*) _dp_txt="未知" ;;
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
	printf '"mem_total_kb":%s,"mem_free_kb":%s,"mem_used_pct":%s,"fw":%s,"fw_build":%s,"kernel":%s,"ip":%s,"webui":%s},' \
		"$_mt" "$_mf" "$_mpct" "$(jval "$_fw")" "$(jval "$_bfw")" "$(jval "$_kern")" "$(jval "$_ip")" "$(jval "$(conf_get WEBUI_VERSION 1.0.0)")"
	printf '"pon":{"mode":%s,"mode_text":%s,"reg_state":%s,"registered":%s,"authenticated":%s,' \
		"$(jval "$_pmode")" "$(jval "$_pmode_txt")" "$(jval "$_reg_state")" "$(b "$_pon_ok")" "$(b "$_auth_ok")"
	printf '"llid":%s,"olt_mac":%s,"pon_mac":%s,"downstream":%s,"upstream":%s,"dereg_cause":%s,"retry":%s},' \
		"$(jval "$_llid")" "$(jval "$_olt_mac")" "$(jval "$_pmac")" \
		"$(jval "$_ds")" "$(jval "$_us")" "$(jval "$_cause")" "$(jval "$_retry")"
	printf '"optics":{"available":%s,"temp":%s,"vcc":%s,"bias":%s,"tx_power":%s,"rx_power":%s},' \
		"$(b "$_o_avail")" "$(jnum "$_o_temp")" "$(jnum "$_o_vcc")" "$(jnum "$_o_bias")" "$(jnum "$_o_tx")" "$(jnum "$_o_rx")"
	printf '"iface":{"name":"eth0","rx_bytes":%s,"tx_bytes":%s,"speed":%s,"mac":%s},' \
		"${_rx:-0}" "${_tx:-0}" "${_sp:-0}" "$(jval "$_mac")"
	printf '"run":{"datapath":%s,"datapath_text":%s,"port_id":%s},' \
		"$(jval "$_dp")" "$(jval "$_dp_txt")" "$(jval "$(pon_port_id)")"
	printf '"caps":{%s}}\n' "$_caps"
	exit 0
}

# ---------------------------------------------------------------- 配置读取 --
# 字段全部对应原厂固件真实存在的 scfg 键(见 /config/default_scfg.txt 与
# /config/scfg.txt), 其余参数以只读方式提供 —— 用户能看见"固件现在怎么跑的",
# 但改不了不该改的东西。
act_config() {
	_loid=$(arr_to_str "$(scfg_read CFG_ID_LOID)")
	_lpwd=$(arr_to_str "$(scfg_read CFG_ID_PASSWD)")
	_hwv=$(scfg_read CFG_ID_HW_VERSION | tr -d '{}' | tr -s ' ')
	_write=$(scfg_targets)
	_read=$(scfg_read_order)

	pon_load

	http_head
	printf '{"ok":true,'
	printf '"pon":{"pon_mac":%s,"loid":%s,"loid_pwd":%s,"pon_mode":%s,"report_mode":%s},' \
		"$(jval "$(scfg_read CFG_ID_MAC_ADDRESS)")" "$(jval "$_loid")" "$(jval "$_lpwd")" \
		"$(jval "$(scfg_read CFG_ID_PON_MAC_MODE)")" "$(jval "$(scfg_read CFG_ID_PON_REPORT_MODE)")"
	printf '"fwcfg":{"llid_mode":%s,"llid_num":%s,"oam_mode":%s,"encrypt_mode":%s,' \
		"$(jval "$(scfg_read CFG_ID_PON_LLID_MODE)")" "$(jval "$(scfg_read CFG_ID_PON_LLID_NUM)")" \
		"$(jval "$(scfg_read CFG_ID_OAM_MODE)")" "$(jval "$(scfg_read CFG_ID_EPON_ENCRYPTION_MODE)")"
	printf '"datapath":%s,"register_mode":%s,"bcmc":%s,"hw_version":%s},' \
		"$(jval "$(scfg_read CFG_ID_DATAPATH_MODE)")" "$(jval "$(scfg_read CFG_ID_EN_REGISTER_AFTER_BOOT)")" \
		"$(jval "$(scfg_read CFG_ID_PON_DS_FORWARD_BCMC)")" "$(jval "$_hwv")"
	printf '"ident":{"raw":%s},' "$(jval "$(probe_get mfg)")"
	printf '"net":{"ip":%s,"mask":%s,"gw":%s,"conf":%s,"mac":%s},' \
		"$(jval "$(iface_ip)")" "$(jval "$(iface_mask)")" "$(jval "$(iface_gw)")" \
		"$(jval "$(net_conf_path)")" "$(jval "$(iface_mac eth0)")"
	printf '"paths":{"write":%s,"read":%s},' "$(jval "$_write")" "$(jval "$_read")"
	printf '"fw":{"version":%s,"build":%s}}\n' \
		"$(jval "$(dev_fw_version)")" "$(jval "$(dev_fw_build)")"
	exit 0
}

# ---------------------------------------------------------------- 网络 --
NET_CONF_CANDIDATES=${NET_CONF_CANDIDATES:-/etc/network/interfaces /userdata/network/interfaces}

net_conf_path() {
	for _f in $NET_CONF_CANDIDATES; do
		tr_exists "$_f" && { printf '%s' "$_f"; return 0; }
	done
	printf ''
}

# 网络状态一律查远端设备(装在 Alpine 上时, 关心的是猫棒地址而不是 Alpine 的)
iface_ip() {
	tr_run "ip -4 addr show eth0 2>/dev/null || ifconfig eth0 2>/dev/null" |
		awk '/inet /{ sub(/\/.*/, "", $2); print $2; exit }
			/inet addr:/{ for (i = 1; i <= NF; i++) if ($i == "inet") { a = $(i + 1); sub(/^addr:/, "", a); print a; exit } }'
}

iface_mask() {
	_o=$(tr_run "ifconfig eth0 2>/dev/null; ip -4 addr show eth0 2>/dev/null")
	_m=$(printf '%s\n' "$_o" | awk '/Mask:/{ for (i = 1; i <= NF; i++) if ($i ~ /^Mask:/) { sub(/^Mask:/, "", $i); print $i; exit } }')
	[ -n "$_m" ] && { printf '%s' "$_m"; return; }
	_p=$(printf '%s\n' "$_o" | awk '/inet /{ print $2; exit }' | sed 's/.*\///')
	[ -n "$_p" ] && awk -v p="$_p" 'BEGIN{
		n = 0
		for (i = 0; i < p; i++) n += 2 ^ (31 - i)
		printf "%d.%d.%d.%d", int(n / 16777216) % 256, int(n / 65536) % 256, int(n / 256) % 256, n % 256
	}'
}

iface_gw() {
	tr_run "ip route 2>/dev/null || route -n 2>/dev/null" | awk '/^(default|0.0.0.0)/{ print ($3 == "" ? $2 : $3); exit }'
}

# ---------------------------------------------------------------- 写入 --
act_set() {
	_f=$(form_get field)
	_v=$(form_get value)
	[ -n "$_f" ] || resp_err bad_request "缺少字段名"

	case $_f in
	pon_mac)
		_nv=$(valid_mac "$_v") || resp_err invalid "MAC 格式应为 AA:BB:CC:DD:EE:FF"
		# 全零 MAC 是"清空", EPON 认证必挂, 所以这里不允许
		[ "$_nv" = "00:00:00:00:00:00" ] && resp_err invalid "PON MAC 不能留空或全零"
		_old=$(scfg_read CFG_ID_MAC_ADDRESS)
		scfg_write MAC CFG_ID_MAC_ADDRESS "$_nv" ||
			resp_err write_fail "写入 scfg.txt 失败，请到「工具与诊断」查看实际落点"
		# CTC 出厂配置里 CFG_ID_NE_MAC_ADDR0 与 PON MAC 是同一个值, 管理口
		# (eth0) 用的就是它。只改 PON MAC 会让 PON 侧与主机侧不一致, 部分
		# 省份的 MAC 绑定认证会因此失败。仅当两者原本相同才同步, 不覆盖
		# 用户自己设过的 eth0 MAC。
		_ne=$(scfg_read CFG_ID_NE_MAC_ADDR0)
		if [ -n "$_ne" ] && [ -n "$_old" ] && [ "$_ne" = "$_old" ]; then
			scfg_write MAC CFG_ID_NE_MAC_ADDR0 "$_nv" || log_msg WARN "sync NE_MAC_ADDR0 failed"
		fi
		;;
	loid)
		valid_text "$_v" 24 || resp_err invalid "LOID 只允许字母数字与 . _ -，且 ≤24 字符"
		scfg_write CHAR-ARRAY CFG_ID_LOID "$(str_to_arr "$_v" 24)" || resp_err write_fail "写入 LOID 失败"
		;;
	loid_pwd)
		valid_text "$_v" 12 || resp_err invalid "LOID 密码 ≤12 字符且不含特殊符号"
		scfg_write CHAR-ARRAY CFG_ID_PASSWD "$(str_to_arr "$_v" 12)" || resp_err write_fail "写入 LOID 密码失败"
		;;
	pon_mode)
		# 0x02 = 10G/10G 对称, 0x01 = 10G/1G 非对称。固件支持这两种;
		# 切到 XGS-PON 需要换固件, 不是改一个字节的事。
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
	local _new_ip _new_mask _f _src _dst
	mkdir -p "$WEBUI_VAR/tmp" "$WEBUI_VAR/backup" 2>/dev/null
	_new_ip=$1
	_new_mask=$2
	_f=$(net_conf_path)
	[ -n "$_f" ] || return 1
	tr_dir_writable "$(dirname "$_f")" || return 1
	tr_cat "$_f" 2>/dev/null | grep -q "iface eth0" || return 1
	tr_backup "$_f" >/dev/null 2>&1
	_src="$WEBUI_VAR/tmp/net.$$"
	_dst="$_src.new"
	tr_cat "$_f" 2>/dev/null >"$_src"
	awk -v nip="$_new_ip" -v nmask="$_new_mask" '
		/^[[:space:]]*iface[[:space:]]+eth0/ { inblk = 1; print; next }
		/^[[:space:]]*iface[[:space:]]+/ { inblk = 0 }
		inblk && nip != "" && /^[[:space:]]*address[[:space:]]/ { print "    address " nip; next }
		inblk && nmask != "" && /^[[:space:]]*netmask[[:space:]]/ { print "    netmask " nmask; next }
		{ print }' <"$_src" >"$_dst" 2>/dev/null || { rm -f "$_src" "$_dst"; return 1; }
	tr_write "$_f" <"$_dst" || { rm -f "$_src" "$_dst"; return 1; }
	tr_refresh "$_f"
	rm -f "$_src" "$_dst"
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
# 只输出预设命令, 不接受任意输入。原厂固件没有 i2cget, 光模块的原始字节
# 也一并走 iros, 这样诊断页看到的就是页面读到的同一份数据。
act_diag() {
	_cmd="$1"
	case $_cmd in
	pon) _out="===== iros 原始输出（注册 / LLID / DOM）=====
$(pon_query 2>/dev/null)
===== 解析结果 =====
$(pon_fields 2>/dev/null)" ;;
	scfg) _out="===== 配置读取顺序 =====
$(scfg_read_order)
===== 实际写入目标 =====
$(scfg_targets)
===== /config/scfg.txt =====
$(tr_cat /config/scfg.txt 2>/dev/null)
===== /userdata/scfg.txt =====
$(tr_cat /userdata/scfg.txt 2>/dev/null)" ;;
	env) _out=$(tr_run "fw_printenv" 2>/dev/null || echo "fw_printenv 不可用（原厂固件默认不带）") ;;
	mtd) _out=$(mtd_list 2>/dev/null) ;;
	net) _out=$(tr_run "ip addr; echo '--- route ---'; ip route" 2>/dev/null) ;;
	ddm) pon_load
		_out="===== DOM 原始值（cap_i2c_read 0 0xa2，SFF-8472 A2h 页）=====
$(printf '%s\n' "$PON_FIELDS" | grep '^raw_')
===== 换算 =====
$(ddm_read 2>/dev/null || echo 'DOM 读取失败：该固件的 iROS 未提供 cap_i2c_read，或光模块无 DOM 数据')" ;;
	log) _out=$(tail -n 200 "$WEBUI_LOG" 2>/dev/null) ;;
	sys) _out=$(tr_run "uname -a; echo '--- mem ---'; head -5 /proc/meminfo; echo '--- iface ---'; cat /sys/class/net/eth0/speed" 2>/dev/null) ;;
	*)
		_out="可用命令: pon scfg env mtd net ddm log sys"
		_cmd="help"
		;;
	esac
	http_head
	printf '{"ok":true,"cmd":%s,"output":%s}\n' "$(jval "$_cmd")" "$(jval "$_out")"
	exit 0
}

# ---------------------------------------------------------------- 环境自检 --
# 把"这套 WebUI 在这台设备上到底能做什么"如实呈现出来: 配置写在哪个文件、
# 状态靠哪个命令、DOM 走哪条通道, 探测到什么就显示什么。
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

# ---------------------------------------------------------------- 连接管理 --
# 跨网络访问时, "连不上"和"密码错"必须能分开告诉用户, 不能都表现成一排横杠。
act_conn() {
	http_head
	printf '{"ok":true,"conn":%s}\n' "$(conn_json)"
	exit 0
}

# 从表单读取并校验连接参数。校验失败直接 resp_err 退出, 不会把脏值带出去。
# $1 是字段前缀(登录页用 d 避免和登录账号的 user/pass 撞名), 默认空前缀。
# 结果放在 CV_* 里。
conn_form_parse() {
	local _pf _h _p _u _pw _k _t

	_pf=${1:-}
	_h=$(form_get "${_pf}host")
	_p=$(form_get "${_pf}port")
	_u=$(form_get "${_pf}user")
	_pw=$(form_get "${_pf}pass")
	_k=$(form_get "${_pf}key")
	_t=$(form_get "${_pf}transport")

	_h=$(printf '%s' "$_h" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	_u=$(printf '%s' "$_u" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	_k=$(printf '%s' "$_k" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

	[ -n "$_h" ] || resp_err invalid_host "请填写猫棒的地址"
	[ ${#_h} -le 253 ] || resp_err invalid_host "地址过长"
	case $_h in *[!A-Za-z0-9.:_-]*) resp_err invalid_host "地址只允许字母、数字和 . : - _" ;; esac

	[ -n "$_p" ] || _p=22
	case $_p in '' | *[!0-9]*) resp_err invalid_port "端口必须是数字" ;; esac
	[ "$_p" -ge 1 ] && [ "$_p" -le 65535 ] || resp_err invalid_port "端口范围 1-65535"

	[ -n "$_u" ] || _u=root
	case $_u in *[!A-Za-z0-9._-]*) resp_err invalid_user "用户名只允许字母、数字和 . _ -" ;; esac
	[ ${#_u} -le 32 ] || resp_err invalid_user "用户名过长"

	case $_t in ssh | telnet) ;; *) _t=ssh ;; esac

	# 密码留空表示沿用原值(前端不回显密码); 换行会破坏配置文件结构
	case $_pw in
	*'
'*) resp_err invalid_pass "密码不能包含换行" ;;
	esac
	[ ${#_pw} -le 128 ] || resp_err invalid_pass "密码过长"

	case $_k in
	*'
'*) resp_err invalid_key "密钥路径不能包含换行" ;;
	esac
	[ ${#_k} -le 200 ] || resp_err invalid_key "密钥路径过长"

	CV_HOST=$_h
	CV_PORT=$_p
	CV_USER=$_u
	CV_PASS=$_pw
	CV_KEY=$_k
	CV_TRANS=$_t
}

# 用表单里的值临时覆盖连接参数(只在本次请求内存里, 不落盘)。
# 认证方式: 刚填的密码才是用户想验证的东西, 所以有密码就先用密码试;
# 没装 sshpass 或者没填密码时才退回密钥。
conn_form_apply() {
	REMOTE_HOST=$CV_HOST
	REMOTE_PORT=$CV_PORT
	REMOTE_USER=$CV_USER
	REMOTE_TRANSPORT=$CV_TRANS
	[ -n "$CV_PASS" ] && REMOTE_PASS=$CV_PASS
	[ -n "$CV_KEY" ] && REMOTE_KEY=$CV_KEY

	if [ "$CV_TRANS" = "telnet" ] || { [ -n "$REMOTE_PASS" ] && [ "$(tr_sshpass_ok)" = "1" ]; }; then
		REMOTE_AUTH=pass
	elif [ -n "$(tr_key_file)" ]; then
		REMOTE_AUTH=key
	else
		REMOTE_AUTH=pass
	fi
	WEBUI_REMOTE=1
	TR_STATE="" # 丢弃预取阶段按旧地址得到的状态, 重新建
}

act_conn_test() {
	local _h
	_h=$(form_get host)
	_h=$(printf '%s' "$_h" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

	# 带表单值 = 试连(不保存); 不带 = 测已保存的配置(系统页"测试连接")
	if [ -n "$_h" ]; then
		conn_form_parse
		conn_form_apply
	fi

	if tr_conn_test >/dev/null 2>&1; then
		log_msg INFO "conn test ok: $REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT"
	else
		log_msg WARN "conn test fail: $(tr_conn_err)"
	fi
	http_head
	printf '{"ok":true,"conn":%s}\n' "$(conn_json)"
	exit 0
}

# 把 CV_* 里的连接参数落盘并立即试连, 必要时顺手推送公钥切成免密。
# 结果: CONN_PUSHED=1/0, 状态在 conn state 里, 调用方用 conn_json 取。
# 返回 1 表示写盘失败。
conn_save_apply() {
	local _pw _auth _rc _key

	# 密码留空 = 沿用已保存的密码(前端不回显); 私钥留空同理
	_pw=$CV_PASS
	[ -n "$_pw" ] || _pw=$REMOTE_PASS
	_key=$CV_KEY
	[ -n "$_key" ] || _key=$REMOTE_KEY

	# 决定认证方式: 有密码先走密码(立刻可用), 推完公钥再切到密钥
	_auth=""
	if [ "$CV_TRANS" = "ssh" ]; then
		if [ -n "$_pw" ]; then
			_auth=pass
		elif [ -n "$(tr_key_file)" ]; then
			_auth=key
		fi
	else
		_auth=pass
	fi

	tr_conf_save "$CV_HOST" "$CV_PORT" "$CV_USER" "$_pw" "$_key" "$CV_TRANS" "$_auth" ||
		return 1

	# 换地址后旧的主连接已无意义, 清掉复用 socket 让它重新握手
	rm -f "$TR_SOCK"/cm-* 2>/dev/null
	log_msg WARN "conn saved: $CV_USER@$CV_HOST:$CV_PORT ($CV_TRANS/$_auth)"

	TR_STATE=""
	tr_conn_test >/dev/null 2>&1

	# 密码登录能用就顺手把公钥推过去: 之后走密钥更快, 也不再依赖 sshpass。
	# 失败不影响可用性(密码已经能连), 所以只在日志里留痕。
	CONN_PUSHED=0
	if [ "$(tr_conn_ok)" = "1" ] && [ "$CV_TRANS" = "ssh" ] && [ "$_auth" = "pass" ]; then
		tr_push_key
		_rc=$?
		if [ "$_rc" = "0" ]; then
			# 校验免密真的能连上, 才算切换成功; 不行就退回密码, 保持可用
			tr_conf_save "$CV_HOST" "$CV_PORT" "$CV_USER" "$_pw" "$_key" "$CV_TRANS" key >/dev/null
			TR_STATE=""
			if tr_conn_test >/dev/null 2>&1; then
				CONN_PUSHED=1
				log_msg INFO "key pushed, auth switched to key"
			else
				tr_conf_save "$CV_HOST" "$CV_PORT" "$CV_USER" "$_pw" "$_key" "$CV_TRANS" pass >/dev/null
				TR_STATE=""
				tr_conn_test >/dev/null 2>&1
			fi
		elif [ "$_rc" = "2" ]; then
			log_msg WARN "sshpass 缺失, 无法推送公钥"
		else
			log_msg WARN "推送公钥失败 (rc=$_rc), 继续使用密码登录"
		fi
	fi
	return 0
}

act_conn_save() {
	tr_remote || resp_err local_mode "当前为本机模式（WebUI 直接装在设备上），无需配置远端地址"

	conn_form_parse
	conn_save_apply || resp_err save_fail "保存失败，请检查 $WEBUI_ETC 是否可写"

	http_head
	printf '{"ok":true,"pushed":%s,"conn":%s}\n' \
		"$([ "${CONN_PUSHED:-0}" = "1" ] && printf true || printf false)" "$(conn_json)"
	exit 0
}

# 系统页「推送公钥」: 已经用密码连上之后, 手点一下切成免密
act_conn_key() {
	local _rc
	tr_remote || resp_err local_mode "当前为本机模式，无需推送公钥"
	tr_configured || resp_err not_configured "尚未配置猫棒地址"
	[ "$(tr_sshpass_ok)" = "1" ] || resp_err no_sshpass "本机缺少 sshpass，请执行：apk add sshpass"
	[ -n "$REMOTE_PASS" ] || resp_err no_pass "请先填写并保存猫棒密码"

	tr_push_key
	_rc=$?
	case $_rc in
	0)
		tr_conf_save "$REMOTE_HOST" "$REMOTE_PORT" "$REMOTE_USER" "$REMOTE_PASS" \
			"$REMOTE_KEY" "$REMOTE_TRANSPORT" key >/dev/null
		TR_STATE=""
		tr_conn_test >/dev/null 2>&1
		log_msg INFO "key pushed by user"
		;;
	2) resp_err no_sshpass "本机缺少 sshpass，请执行：apk add sshpass" ;;
	3) resp_err no_key "本机还没有密钥文件，重跑 install-alpine.sh 会生成" ;;
	*) resp_err push_fail "推送失败：密码不对，或猫棒不允许写入 authorized_keys" ;;
	esac

	http_head
	printf '{"ok":true,"conn":%s}\n' "$(conn_json)"
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
		dev_action "$_n"
		case $? in
		0) ;;
		2) resp_err no_iros "该固件没有 iROS 命令环境，无法在线重注册，请直接重启设备" ;;
		3) resp_err action_fail "重注册失败：ca_epon_reset_pon_mac 未返回成功，请直接重启设备" ;;
		*) resp_err action_fail "操作失败（当前固件未找到对应的服务脚本）" ;;
		esac
		resp_ok ",$(j_str action "$_n")"
		;;
	*)
		resp_err bad_request "未知操作"
		;;
	esac
}
