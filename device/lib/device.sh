#!/bin/sh
# ============================================================================
#  XE-99S 设备抽象层  (SIEPON Package-C / 原厂 CTC 固件专用)
#
#  所有对硬件/固件的读写都收敛在这里, 上层只调用 dev_* / pon_* 函数。
#  系统访问一律经过 transport.sh 的 4 个原语:
#      tr_cat  读文件      tr_write 写文件
#      tr_run  跑命令      tr_dir_writable / tr_has_cmd  探测能力
#  因此同一份代码既能装在本机(猫棒), 也能装在 Alpine 上通过 SSH 操作猫棒。
#
#  ---------------------------------------------------------------------------
#  本文件里的路径/命令全部对照原厂固件实机内容校准, 依据:
#    · /config/scfg.txt        —— CTC 定制配置 (自定义值, 优先级高于 default)
#    · /config/default_scfg.txt—— 厂商出厂配置 (只读参考)
#    · /usr/bin/iros           —— 就是 `ca-iros /etc/ca-iros.rc`, 只有经过它
#                                 才会加载 /etc/cortina/iros/qa/wca 下的
#                                 命令库, `wca_*` 命令才存在
#    · /etc/8271version        —— 应用版本;  /etc/version —— 构建版本
#    · BOSA.tcl(cap_i2c_read 0 0xa2 ...) —— 光模块 DOM 的读法
#  详见 README「这些参数是从哪来的」。
# ============================================================================

# scfg 读取优先级: 定制配置 > 用户配置 > 出厂默认。
# 原厂固件在启动时按这个顺序覆盖, 所以界面读到的必须是"定制值优先",
# 否则会显示 default_scfg.txt 里的 0x04 而不是实际生效的 0x0。
SCFG_FILE_CONFIG=${SCFG_FILE_CONFIG:-/config/scfg.txt}
SCFG_FILE_USER=${SCFG_FILE_USER:-/userdata/scfg.txt}
SCFG_FILE_DEFAULT=${SCFG_FILE_DEFAULT:-/config/default_scfg.txt}
SCFG_ORDER="$SCFG_FILE_CONFIG $SCFG_FILE_USER $SCFG_FILE_DEFAULT"

# EPON 的 PON 口 port_id。原厂固件自己的脚本(Background_API.sh 的
# classifier 规则、status.sh 的注册查询)都用 0x20007(UNI 口是 0x30006),
# 所以这里不再逐个试错, 留 webui.conf 的 PON_PORT_ID 作为人工覆盖。
PON_PORT_ID=$(conf_get PON_PORT_ID 0x20007)

# 读取顺序: 优先用探测到的真实文件, 否则用候选清单
scfg_read_order() {
	local _p
	if command -v p_read_targets >/dev/null 2>&1; then
		_p=$(p_read_targets)
		[ -n "$_p" ] && { printf '%s' "$_p"; return 0; }
	fi
	printf '%s' "$SCFG_ORDER"
}

# ---------------------------------------------------------------- 能力探测 --
dev_caps() {
	local _m _n _e _i _f
	_m=0; tr_exists /proc/mtd && _m=1
	_n=0; tr_has_cmd nanddump && _n=1
	_e=0; tr_has_cmd fw_setenv && tr_has_cmd fw_printenv && _e=1
	_i=0; [ -n "$(iros_bin)" ] && _i=1
	_f=0; tr_has_cmd flash_erase && _f=1
	printf 'mtd=%s\n' "$_m"
	printf 'nanddump=%s\n' "$_n"
	printf 'env=%s\n' "$_e"
	printf 'iros=%s\n' "$_i"
	printf 'flash=%s\n' "$_f"
}

dev_has() { dev_caps | grep -q "^$1=1$"; }

# ---------------------------------------------------------------- iROS 封装 --
# 原厂 rootfs 里 /usr/bin/iros 只有一行: ca-iros /etc/ca-iros.rc
# 这个 rc 会 source SC_COMMAND_LIB.tcl 并 namespace import gw::*, `wca_*`
# 命令才被注册。直接调 ca-iros 是拿不到这些命令的 —— 这正是很多第三方
# 脚本"读不到 PON 状态"的原因。
iros_bin() {
	if tr_has_cmd iros; then
		printf 'iros'
	elif tr_has_cmd ca-iros; then
		if tr_exists /etc/ca-iros.rc; then
			printf 'ca-iros /etc/ca-iros.rc'
		else
			printf 'ca-iros'
		fi
	fi
}

iros_ready() { [ -n "$(iros_bin)" ]; }

# 把一段 TCL 脚本喂给 iros 执行。整体作为一次远端命令下发, 所以远端模式
# 只多一次往返; heredoc 加了引号, 脚本里的 $ 不会被子 shell 展开。
iros_run() {
	_cmd=$(iros_bin)
	[ -n "$_cmd" ] || return 1
	_to=""
	tr_has_cmd timeout && _to="timeout 25"
	tr_run "$_to $_cmd <<'XE99_IROS'
$1
XE99_IROS"
}

# ---------------------------------------------------------------- scfg 读写 --
# 写入落点只有一个: 原厂自己的 WebUI(set_ponmac_set.sh) 就是直接改
# /config/scfg.txt。同时写多份会让"哪份生效"变得不可预测, 所以这里实测
# 选一个可写的, 其余只读。
scfg_targets() {
	local _t
	if command -v p_write_targets >/dev/null 2>&1; then
		_t=$(p_write_targets)
		[ -n "$_t" ] && { printf '%s' "$_t"; return 0; }
	fi
	if tr_dir_writable /config; then
		printf '%s' "$SCFG_FILE_CONFIG"
	elif tr_dir_writable /overlay/upper/config; then
		printf '%s' "/overlay/upper/config/scfg.txt"
	elif tr_dir_writable /userdata; then
		printf '%s' "$SCFG_FILE_USER"
	fi
}

# scfg_read 键名  -> 输出原始值(不含分号/注释), 找不到返回 1
scfg_read() {
	local _f _v
	for _f in $(scfg_read_order); do
		[ -n "$_f" ] || continue
		_v=$(tr_cat "$_f" 2>/dev/null | awk -v k="$1" '
			{
				line = $0
				sub(/^[[:space:]]+/, "", line)
				if (line ~ /^#/ || line ~ /^\[/) next
				eq = index(line, "=")
				if (eq < 2) next
				left = substr(line, 1, eq - 1)
				sub(/[[:space:]]+$/, "", left)
				n = split(left, a, /[[:space:]]+/)
				if (a[n] != k) next
				right = substr(line, eq + 1)
				sub(/;.*$/, "", right)
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", right)
				print right
				exit
			}')
		if [ -n "$_v" ]; then
			printf '%s' "$_v"
			return 0
		fi
	done
	return 1
}

# scfg_type 键名 -> 输出类型关键字 (CHAR / INT / MAC / STRING / CHAR-ARRAY)
scfg_type() {
	local _f _v
	for _f in $(scfg_read_order); do
		[ -n "$_f" ] || continue
		_v=$(tr_cat "$_f" 2>/dev/null | awk -v k="$1" '
			{
				line = $0
				sub(/^[[:space:]]+/, "", line)
				if (line ~ /^#/ || line ~ /^\[/) next
				eq = index(line, "=")
				if (eq < 2) next
				left = substr(line, 1, eq - 1)
				sub(/[[:space:]]+$/, "", left)
				n = split(left, a, /[[:space:]]+/)
				if (a[n] != k) next
				print a[1]
				exit
			}')
		[ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
	done
	return 1
}

# scfg_write 类型 键名 值 -> 写可写目标, 回读校验
# 内容拉到本地处理再推回: 解析逻辑只有一份, 远远端不存在两套 awk
scfg_write() {
	local _ty _k _val _ok _f _old _tmp _nex _chk
	_ty=$1; _k=$2; _val=$3
	_ok=0
	mkdir -p "$WEBUI_VAR/tmp" "$WEBUI_VAR/backup" 2>/dev/null
	for _f in $(scfg_targets); do
		[ -n "$_f" ] || continue
		tr_dir_writable "$(dirname "$_f")" || continue

		tr_backup "$_f" >/dev/null 2>&1
		_old=$(tr_cat "$_f" 2>/dev/null)

		_tmp="$WEBUI_VAR/tmp/scfg.$$"
		_nex="$_tmp.new"
		: >"$_tmp" 2>/dev/null || continue
		[ -n "$_old" ] && printf '%s\n' "$_old" >>"$_tmp"

		# 删掉同名键的所有旧行, 其余原样保留
		awk -v k="$_k" '
			{
				line = $0; t = line
				sub(/^[[:space:]]+/, "", t)
				drop = 0
				if (t !~ /^#/ && t !~ /^\[/ && index(t, "=") > 1) {
					left = substr(t, 1, index(t, "=") - 1)
					sub(/[[:space:]]+$/, "", left)
					n = split(left, a, /[[:space:]]+/)
					if (a[n] == k) drop = 1
				}
				if (!drop) print line
			}' <"$_tmp" >"$_nex" 2>/dev/null || { rm -f "$_tmp" "$_nex"; continue; }

		printf '%-11s %-40s = %s;\n' "$_ty" "$_k" "$_val" >>"$_nex"

		if tr_write "$_f" <"$_nex"; then
			_ok=1
			tr_refresh "$_f"
			log_msg INFO "scfg_write $_k=$_val -> $_f"
		fi
		rm -f "$_tmp" "$_nex"
	done
	[ "$_ok" = "1" ] || return 1
	_chk=$(scfg_read "$_k" 2>/dev/null)
	[ -n "$_chk" ] || return 2
	return 0
}

# ------------------------------------------------- 类型转换: 值 <-> 显示 --
arr_to_str() {
	printf '%s' "$1" | tr -d '{}' | tr ',' '\n' |
		awk '{
			gsub(/[[:space:]]/, "")
			if ($0 == "") next
			v = $0
			sub(/^0[xX]/, "", v)
			v = tolower(v)
			n = 0
			for (i = 1; i <= length(v); i++) {
				d = index("0123456789abcdef", substr(v, i, 1))
				if (d == 0) next
				n = n * 16 + (d - 1)
			}
			if (n == 0) exit
			if (n >= 32 && n < 127) printf "%c", n
		}'
}

str_to_arr() {
	_pad=${2:-0}
	printf '%s' "$1" | od -An -tx1 -v | tr -s ' ' '\n' | grep -v '^$' |
		awk -v pad="$_pad" '
			{ b[n++] = toupper($0) }
			END {
				while (n < pad) b[n++] = "00"
				out = "{"
				for (i = 0; i < n; i++) {
					if (i > 0) out = out ","
					if (i % 4 == 0 && i > 0) out = out " "
					out = out "0x" b[i]
				}
				printf "%s}", out
			}'
}

# ---------------------------------------------------------------- uboot env --
env_get() {
	if tr_remote; then
		tr_fetch_env
		sed -n "s/^$1=//p" "$TR_CACHE/.env" 2>/dev/null | head -n1
		return 0
	fi
	command -v fw_printenv >/dev/null 2>&1 || return 1
	fw_printenv "$1" 2>/dev/null | sed -n "s/^$1=//p"
}

# ------------------------------------------------------- PON 状态(一次取全) --
# 原厂 status.sh 的做法: 一次 iros 会话里把注册状态、LLID 使能、DOM 全部读完。
# 这里沿用同样的思路 —— 一次会话比三次快得多, 而且在远端模式下只多一次往返。
# 输出统一成 key=value, 供 actions.sh 组装 JSON。
pon_tcl() {
	cat <<'XE99_TCL'
set __rx [ca_uint8_array_create 0 1]
puts "XE99:BEGIN"
if {[catch {wca_epon_mpcp_registration_status_get -device_id 0 -port_id __PORT__ -llid 0} __e1]} {puts "XE99:ERR:reg:$__e1"}
if {[catch {wca_epon_llid_traffic_enable_get -device_id 0 -port_id __PORT__ -llid 0x0} __e2]} {puts "XE99:ERR:llid:$__e2"}
foreach {__n __a} {Temperature 0x60 Vcc 0x62 TxBias 0x64 TxPower 0x66 RxPower 0x68} {
	if {[catch {cap_i2c_read 0 0xa2 $__a 2 $__rx} __e3]} {
		puts "XE99:DDMERR:$__n"
	} else {
		puts "XE99:DDM:$__n:[expr {([ca_uint8_array_get $__rx 0] << 8) | [ca_uint8_array_get $__rx 1]}]"
	}
}
puts "XE99:END"
XE99_TCL
}

pon_port_id() { printf '%s' "${PON_PORT_ID:-0x20007}"; }

pon_query() {
	_p=$(pon_port_id)
	_tcl=$(pon_tcl | sed "s/__PORT__/$_p/g")
	iros_run "$_tcl" 2>/dev/null
}

# 把 iros 的原始输出解析成 key=value。DDM 原始值原样输出, 换算放到本地,
# 避免把浮点/log 计算压到猫棒的 400MHz CPU 上。
pon_fields() {
	_raw=$(pon_query)
	[ -n "$_raw" ] || return 1
	printf '%s\n' "$_raw" | awk '
		function val(k,   v) {
			if (!match($0, "\\[ *" k " *= *[^]]*")) return ""
			v = substr($0, RSTART, RLENGTH)
			sub(/^\[ *[^=]*= */, "", v)
			sub(/[ ]*$/, "", v)
			return v
		}
		/\[ *reg_state *=/            { print "reg_state=" val("reg_state"); next }
		/\[ *olt_mac_addr *=/         { print "olt_mac=" val("olt_mac_addr"); next }
		/\[ *mpcp_llid *=/            { print "llid=" val("mpcp_llid"); next }
		/\[ *deregistration_cause *=/ { print "dereg_cause=" val("deregistration_cause"); next }
		/\[ *retry_times *=/          { print "retry=" val("retry_times"); next }
		/\[ *upstream *=/             { print "upstream=" val("upstream"); next }
		/\[ *downstream *=/           { print "downstream=" val("downstream"); next }
		/^XE99:DDM:[A-Za-z]*:/        { split($0, a, ":"); print "raw_" tolower(a[3]) "=" a[4]; next }
		/^XE99:DDMERR:/               { print "dom_err=1"; next }
	'
}

# 一次请求里只查一次 iros (status / config / diag 共用)
pon_load() {
	[ "${PON_LOADED:-0}" = "1" ] && return 0
	PON_FIELDS=$(pon_fields 2>/dev/null)
	PON_LOADED=1
	[ -n "$PON_FIELDS" ]
}

pon_get() {
	printf '%s\n' "${PON_FIELDS:-}" | sed -n "s/^$1=//p" | head -n1
}

# 注册状态: 1 = 已注册
pon_registered() {
	pon_load
	[ "$(pon_get reg_state)" = "1" ] && printf '1' || printf '0'
}

# 业务认证: 上下行 LLID 都使能
pon_authorized() {
	pon_load
	[ "$(pon_get upstream)" = "1" ] && [ "$(pon_get downstream)" = "1" ] && printf '1' || printf '0'
}

# ---------------------------------------------------------------- 光模块 DOM --
# 原厂固件没有 i2cget, DOM 只能走 iros 自带的 I2C 通道:
#   cap_i2c_read 0 0xa2 <页内偏移> 2 <buf>
# 0xa2 是 A2h 页的 8 位地址(7 位地址 0x51) —— 温度/电压/偏置/收发光都在这一页,
# 读 0x50 只会拿到 A0h 页的厂商字符串。BOSA.tcl 用的就是这个地址。
# 换算沿用 SFF-8472: 温度 1/256℃、电压 100µV、偏置 2µA、光功率 0.1µW。
ddm_read() {
	pon_load || return 1
	_t=$(pon_get raw_temperature)
	_v=$(pon_get raw_vcc)
	_b=$(pon_get raw_txbias)
	_tx=$(pon_get raw_txpower)
	_rx=$(pon_get raw_rxpower)
	case $_t$_v$_b$_tx$_rx in '' | *[!0-9]*) return 1 ;; esac
	[ "$_t" -gt 0 ] 2>/dev/null || [ "$_v" -gt 0 ] 2>/dev/null || return 1
	awk -v t="$_t" -v v="$_v" -v b="$_b" -v tx="$_tx" -v rx="$_rx" 'BEGIN{
		if (t >= 32768) t -= 65536
		txv = (tx > 0) ? 10 * log(tx / 10000) / log(10) : -40
		rxv = (rx > 0) ? 10 * log(rx / 10000) / log(10) : -40
		printf "%.2f %.3f %.2f %.2f %.2f", t / 256, v / 10000, b * 2 / 1000, txv, rxv
	}'
}

# ---------------------------------------------------------------- 系统信息 --
file_first() {
	local _f _c
	for _f in "$@"; do
		_c=$(tr_cat "$_f" 2>/dev/null)
		[ -n "$_c" ] && { printf '%s' "$_c" | head -n 1 | tr -d '\r'; return 0; }
	done
	return 1
}

# 应用版本: 原厂放在 /etc/8271version (如 1.3.0)
dev_fw_version() {
	local v
	v=$(file_first /etc/8271version)
	[ -n "$v" ] && { printf '%s' "$v"; return 0; }
	v=$(file_first /etc/siepon_version /etc/fw_version)
	[ -n "$v" ] && { printf '%s' "$v"; return 0; }
	echo "unknown"
}

# 构建版本: /etc/version (CTC 构建号或时间戳, 如 CTC20220901)
dev_fw_build() {
	local v
	v=$(file_first /etc/version /etc/VERSION)
	[ -n "$v" ] && { printf '%s' "$v"; return 0; }
	echo "unknown"
}

sys_uptime_sec() {
	tr_cat /proc/uptime 2>/dev/null | awk '{ printf "%d", $1 }'
}

sys_meminfo() {
	tr_cat /proc/meminfo 2>/dev/null | awk '
		/^MemTotal:/    { t = $2 }
		/^MemFree:/     { f = $2 }
		/^MemAvailable:/{ a = $2 }
		END { if (a == "") a = f; printf "%d %d %d", t, f, a }'
}

sys_iface_stat() {
	local _if _rx _tx _sp
	_if=${1:-eth0}
	_rx=$(tr_cat "/sys/class/net/$_if/statistics/rx_bytes" 2>/dev/null || echo 0)
	_tx=$(tr_cat "/sys/class/net/$_if/statistics/tx_bytes" 2>/dev/null || echo 0)
	_sp=$(tr_cat "/sys/class/net/$_if/speed" 2>/dev/null || echo 0)
	[ "$_sp" = "-1" ] && _sp=0
	printf '%s %s %s' "${_rx:-0}" "${_tx:-0}" "${_sp:-0}"
}

iface_mac() {
	tr_cat "/sys/class/net/${1:-eth0}/address" 2>/dev/null | tr -d '\n'
}

# ---------------------------------------------------------------- 命令白名单 --
dev_action() {
	case $1 in
	reboot)
		log_msg WARN "user triggered reboot"
		tr_run "( sleep 1; sync; reboot ) >/dev/null 2>&1 &"
		;;
	factory_reset)
		log_msg WARN "user triggered factory reset"
		tr_run "rm -rf /overlay/upper/* 2>/dev/null"
		;;
	restart_webui)
		# 远端模式下重启的是 Alpine 上的本控制台
		log_msg INFO "restart webui"
		"$WEBUI_ROOT/init.d/S99webui" restart >/dev/null 2>&1 &
		;;
	pon_reset)
		# 原厂 iROS 自带 PON MAC 复位, 等价于让 ONU 重新走一遍 MPCP 注册;
		# 比 kill ca-app 温和, 也不会把管理口一起断掉。
		log_msg WARN "pon reset"
		iros_ready || return 2
		_out=$(iros_run 'if {[catch {ca_epon_reset_pon_mac 0} __rv]} {puts "XE99:RESET:ERR:$__rv"} else {puts "XE99:RESET:OK:$__rv"}' 2>/dev/null)
		case $_out in *XE99:RESET:OK:0*) return 0 ;; esac
		return 3
		;;
	*)
		return 1
		;;
	esac
	return 0
}

# ---------------------------------------------------------------- mtd 分区 --
mtd_list() {
	local _raw _id _name _hs _he _ds _de
	# /proc/mtd: mtd0: 00400000 00020000 "ssb"
	_raw=$(tr_cat /proc/mtd 2>/dev/null)
	[ -n "$_raw" ] || return 1
	printf '%s\n' "$_raw" | awk 'NR > 1 {
		id = $1; sub(/:$/, "", id); sub(/^mtd/, "", id)
		name = $4; gsub(/"/, "", name)
		printf "%s|%s|%s|%s\n", id, name, $2, $3
	}' | while IFS='|' read -r _id _name _hs _he; do
		_ds=$(awk -v h="$_hs" 'BEGIN{ printf "%d", ("0x" h) + 0 }' 2>/dev/null)
		_de=$(awk -v h="$_he" 'BEGIN{ printf "%d", ("0x" h) + 0 }' 2>/dev/null)
		printf '%s %s %s %s\n' "$_id" "$_name" "${_ds:-0}" "${_de:-0}"
	done
}

mtd_index() {
	# $1 = 分区名关键字, 输出 mtd 编号
	tr_cat /proc/mtd 2>/dev/null | awk -v k="$1" '
		$0 ~ k {
			id = $1; sub(/:$/, "", id); sub(/^mtd/, "", id); print id; exit
		}'
}

# 出厂标识 (mfginfo 分区): 厂商/型号/硬件版本/序列号都在这里, 产线写入,
# 原厂固件没有任何 scfg 键可改它。这里只读出来给人看, 不提供写入。
mfg_strings() {
	_id=$(mtd_index mfginfo)
	[ -n "$_id" ] || return 1
	_tmp="$WEBUI_VAR/tmp/mfg.$$"
	tr_run "nanddump -q -l 1024 /dev/mtd$_id 2>/dev/null || dd if=/dev/mtd$_id bs=1024 count=1 2>/dev/null" \
		>"$_tmp" 2>/dev/null
	if [ ! -s "$_tmp" ]; then
		rm -f "$_tmp"
		return 1
	fi
	LC_ALL=C tr -c '\040-\176\012' '\012' <"$_tmp" |
		awk 'length($0) >= 4' | head -n 12 | tr '\n' '|' | sed 's/|$//'
	rm -f "$_tmp"
}
