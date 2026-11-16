#!/bin/sh
# ============================================================================
#  XE-99S 设备抽象层
#  所有对硬件/固件的读写都收敛在这里, 上层只调用 dev_* 函数
#  写入策略: 双目标写入 + 备份 + 回读校验
# ============================================================================

SCFG_FILE_TMP=${SCFG_FILE_TMP:-/tmp/scfg.txt}
SCFG_FILE_USER=${SCFG_FILE_USER:-/userdata/scfg.txt}
SCFG_FILE_CONFIG=${SCFG_FILE_CONFIG:-/config/scfg.txt}
SCFG_FILE_DEFAULT=${SCFG_FILE_DEFAULT:-/config/default_scfg.txt}
SCFG_ORDER="$SCFG_FILE_TMP $SCFG_FILE_USER $SCFG_FILE_CONFIG $SCFG_FILE_DEFAULT"
INI_FILES=${INI_FILES:-/etc/onu_manu_modle.ini /userdata/onu_manu_modle.ini
	/overlay/upper/etc/onu_manu_modle.ini /userdata/upper/etc/onu_manu_modle.ini}

# PON port_id: 配置留空则用 probe 实测值
PON_PORT_ID=$(conf_get PON_PORT_ID "")

# 实际读取顺序: 环境探测生效时以实测存在的文件为准 (SIEPON-C 原厂固件的
# scfg.txt 位置与 A 版不同, 只有实测才能确定)
scfg_read_order() {
	if command -v p_read_targets >/dev/null 2>&1; then
		_p=$(p_read_targets)
		[ -n "$_p" ] && { printf '%s' "$_p"; return 0; }
	fi
	printf '%s' "$SCFG_ORDER"
}

# ---------------------------------------------------------------- 能力探测 --
dev_caps() {
	# 输出 key=1/0 行, 供前端决定显示哪些模块
	_p=0; [ -r /proc/mtd ] && _p=1
	_e=0; command -v fw_setenv >/dev/null 2>&1 && command -v fw_printenv >/dev/null 2>&1 && _e=1
	_i2cb=$(conf_get I2C_BUS 0)
	_i=0; command -v i2cget >/dev/null 2>&1 && [ -e "/dev/i2c-$_i2cb" ] && _i=1
	_c=0; command -v ca-iros >/dev/null 2>&1 && _c=1
	_g=0; command -v cig-cli >/dev/null 2>&1 && _g=1
	_f=0; command -v flash_erase >/dev/null 2>&1 && command -v nanddump >/dev/null 2>&1 && _f=1
	_s=0
	[ -d /proc ] && _s=1
	printf 'mtd=%s\n' "$_p"
	printf 'env=%s\n' "$_e"
	printf 'i2c=%s\n' "$_i"
	printf 'cairos=%s\n' "$_c"
	printf 'cigcli=%s\n' "$_g"
	printf 'flash=%s\n' "$_f"
}

dev_has() { dev_caps | grep -q "^$1=1$"; }

# ---------------------------------------------------------------- scfg 读写 --
# 可写目标全部交给 probe 实测: 原厂 CTC 固件的 rootfs 是只读 squashfs,
# /config 本身不可写, 真正落点是 overlay 上层, 硬编码会静默失败。
scfg_targets() {
	if command -v p_write_targets >/dev/null 2>&1; then
		_t=$(p_write_targets)
		[ -n "$_t" ] && { printf '%s' "$_t"; return 0; }
	fi
	# 探测层不可用时的保守回退
	_t=""
	{ [ -w "$SCFG_FILE_CONFIG" ] || { [ -d /config ] && [ -w /config ]; }; } && _t="$SCFG_FILE_CONFIG"
	[ -d /userdata ] && [ -w /userdata ] && _t="$_t $SCFG_FILE_USER"
	[ -n "$_t" ] || _t="$SCFG_FILE_USER"
	printf '%s' "$_t"
}

# scfg_read 键名  -> 输出原始值(不含分号/注释), 找不到返回 1
scfg_read() {
	for _f in $(scfg_read_order); do
		[ -r "$_f" ] || continue
		_v=$(awk -v k="$1" '
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
			}' "$_f")
		if [ -n "$_v" ]; then
			printf '%s' "$_v"
			return 0
		fi
	done
	return 1
}

# scfg_type 键名 -> 输出类型关键字
scfg_type() {
	for _f in $(scfg_read_order); do
		[ -r "$_f" ] || continue
		_v=$(awk -v k="$1" '
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
			}' "$_f")
		[ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
	done
	return 1
}

# scfg_write 类型 键名 值 -> 写所有可写目标, 回读校验
scfg_write() {
	local _k _ty _val _ok _f _tmp _chk
	_ty=$1; _k=$2; _val=$3
	_ok=0
	for _f in $(scfg_targets); do
		[ -d "$(dirname "$_f")" ] || continue
		# 备份
		if [ -r "$_f" ]; then
			cp -f "$_f" "$WEBUI_VAR/backup/$(basename "$_f").$(date +%s)" 2>/dev/null
		fi
		[ -r "$_f" ] || : >"$_f"
		_tmp="$_f.new.$$"
		# 删除同名键的所有旧行, 再追加新行
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
			}' "$_f" >"$_tmp" 2>/dev/null || { rm -f "$_tmp"; continue; }
		printf '%-11s %-40s = %s;\n' "$_ty" "$_k" "$_val" >>"$_tmp"
		if mv -f "$_tmp" "$_f" 2>/dev/null; then
			_ok=1
			log_msg INFO "scfg_write $_k=$_val -> $_f"
		else
			rm -f "$_tmp"
		fi
	done
	[ "$_ok" = "1" ] || return 1
	# 回读校验
	_chk=$(scfg_read "$_k" 2>/dev/null)
	[ -n "$_chk" ] || return 2
	return 0
}

# ------------------------------------------------- 类型转换: 值 <-> 显示 --
# CHAR-ARRAY {0x4C,0x4F,...} -> 可读 ASCII
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

# 可读字符串 -> {0x41,0x42,...}  (按 4 字节分组, 不足补 0x00)
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
	command -v fw_printenv >/dev/null 2>&1 || return 1
	fw_printenv "$1" 2>/dev/null | sed -n "s/^$1=//p"
}

# 设备序列号 (CTC 认证里常与 LOID 二选一)
# 存放位置随固件而异: scfg 的 CFG_ID_SERIAL_NUMBER / uboot env / mfginfo 分区
dev_sn() {
	_v=$(scfg_read CFG_ID_SERIAL_NUMBER 2>/dev/null)
	[ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
	for _k in CA8271_SERIAL_NUMBER SERIAL_NUMBER SN serial_number; do
		_v=$(env_get "$_k" 2>/dev/null)
		[ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
	done
	printf ''
}

# SN 可写位置: 有 scfg 键写 scfg, 否则写 env。都没有则报告不可写
dev_sn_writable() {
	scfg_type CFG_ID_SERIAL_NUMBER >/dev/null 2>&1 && { printf 'scfg'; return 0; }
	command -v fw_setenv >/dev/null 2>&1 && { printf 'env'; return 0; }
	# 没有 fw_setenv 但环境里已存在该键, 说明该固件用 env 存 SN
	[ -n "$(env_get CA8271_SERIAL_NUMBER 2>/dev/null)" ] && { printf 'env'; return 0; }
	printf ''
}

env_set() {
	local _chk
	command -v fw_setenv >/dev/null 2>&1 || return 1
	fw_setenv "$1" "$2" 2>/dev/null || return 1
	_chk=$(env_get "$1")
	[ "$_chk" = "$2" ] || return 2
	log_msg INFO "env_set $1=$2"
	return 0
}

# ---------------------------------------------------------------- PON 状态 --
# 通过 ca-iros 查询 MPCP 注册状态与 LLID 流量使能
# port_id 依固件而异: 配置里没写就用探测值(实测哪个能返回 CA_E_OK)
pon_port_id() {
	if [ -n "${PON_PORT_ID:-}" ]; then
		printf '%s' "$PON_PORT_ID"
		return 0
	fi
	if command -v p_port_id >/dev/null 2>&1; then
		PON_PORT_ID=$(p_port_id)
	else
		PON_PORT_ID=0x20007
	fi
	printf '%s' "$PON_PORT_ID"
}

pon_reg_status() {
	command -v ca-iros >/dev/null 2>&1 || return 1
	printf 'wca_epon_mpcp_registration_status_get -device_id 0 -port_id %s -llid 0\n' "$(pon_port_id)" |
		ca-iros 2>/dev/null
}

pon_traffic_status() {
	command -v ca-iros >/dev/null 2>&1 || return 1
	printf 'wca_epon_llid_traffic_enable_get -device_id 0 -port_id %s -llid 0x0\n' "$(pon_port_id)" |
		ca-iros 2>/dev/null
}

# ---------------------------------------------------------------- 光模块 DDM --
I2C_BUS=$(conf_get I2C_BUS 0)
I2C_ADDR=$(conf_get I2C_ADDR 0x50)

i2c_word() {
	# $1 = 字节偏移, 输出十进制(小端 16 位)
	command -v i2cget >/dev/null 2>&1 || return 1
	_h=$(i2cget -y -f "$I2C_BUS" "$I2C_ADDR" "$1" w 2>/dev/null) || return 1
	case $_h in 0x* | 0X*) : ;; *) return 1 ;; esac
	printf '%s' "$_h" | awk '{
		v = tolower($0); sub(/^0x/, "", v); n = 0
		for (i = 1; i <= length(v); i++) {
			d = index("0123456789abcdef", substr(v, i, 1))
			if (d == 0) next
			n = n * 16 + (d - 1)
		}
		printf "%d", n
	}'
}

ddm_read() {
	# 输出: temp vcc tx_bias tx_power rx_power (单位: ℃ mV mA dBm dBm)
	_t=$(i2c_word 0x60) || return 1
	_v=$(i2c_word 0x62) || return 1
	_b=$(i2c_word 0x64) || return 1
	_tx=$(i2c_word 0x66) || return 1
	_rx=$(i2c_word 0x68) || return 1
	awk -v t="$_t" -v v="$_v" -v b="$_b" -v tx="$_tx" -v rx="$_rx" 'BEGIN{
		# 有符号 16 位温度, 1/256 度
		if (t > 32767) t = t - 65536
		temp = t / 256
		vcc  = v / 10000        # 100uV -> V
		bias = b * 2 / 1000     # 2uA -> mA
		txp  = (tx > 0) ? 10 * log(tx / 10000) / log(10) : -40
		rxp  = (rx > 0) ? 10 * log(rx / 10000) / log(10) : -40
		printf "%.2f %.3f %.2f %.2f %.2f", temp, vcc, bias, txp, rxp
	}'
}

# ---------------------------------------------------------------- 系统信息 --
file_first() {
	for _f in "$@"; do
		if [ -r "$_f" ]; then
			head -n 1 "$_f" 2>/dev/null | tr -d '\r'
			return 0
		fi
	done
	return 1
}

sys_uptime_sec() {
	awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null || echo 0
}

sys_meminfo() {
	# 输出 total_kb free_kb avail_kb
	awk '
		/^MemTotal:/    { t = $2 }
		/^MemFree:/     { f = $2 }
		/^MemAvailable:/{ a = $2 }
		END { if (a == "") a = f; printf "%d %d %d", t, f, a }' /proc/meminfo 2>/dev/null || echo "0 0 0"
}

sys_iface_stat() {
	# 输出 rx_bytes tx_bytes speed
	_if=${1:-eth0}
	_rx=$(cat "/sys/class/net/$_if/statistics/rx_bytes" 2>/dev/null || echo 0)
	_tx=$(cat "/sys/class/net/$_if/statistics/tx_bytes" 2>/dev/null || echo 0)
	_sp=$(cat "/sys/class/net/$_if/speed" 2>/dev/null || echo 0)
	[ "$_sp" = "-1" ] && _sp=0
	printf '%s %s %s' "${_rx:-0}" "${_tx:-0}" "${_sp:-0}"
}

dev_fw_version() {
	v=$(file_first /etc/siepon_version /etc/fw_version /etc/version /etc/VERSION)
	[ -n "$v" ] && { printf '%s' "$v"; return 0; }
	v=$(env_get CA8271_FW_FWVER)
	[ -n "$v" ] && { printf '%s' "$v"; return 0; }
	echo "unknown"
}

dev_base_fw_version() {
	v=$(file_first /etc/base_version /etc/hisense_version /etc/ont_version)
	[ -n "$v" ] && { printf '%s' "$v"; return 0; }
	echo "unknown"
}

# ---------------------------------------------------------------- 命令白名单 --
# 危险动作只允许这些, 绝不接受前端任意命令
dev_action() {
	case $1 in
	reboot)
		log_msg WARN "user triggered reboot"
		( sleep 1; sync; reboot ) >/dev/null 2>&1 &
		;;
	factory_reset)
		log_msg WARN "user triggered factory reset"
		mkdir -p /userdata/upper 2>/dev/null
		rm -rf /overlay/upper/* 2>/dev/null
		;;
	restart_webui)
		log_msg INFO "restart webui"
		"$WEBUI_ROOT/init.d/S99webui" restart >/dev/null 2>&1 &
		;;
	pon_reset)
		# 重新触发 PON 注册: 只重启 PON 相关服务, 不动 eth0,
		# 避免把自己这条管理连接一起断掉。
		_r=""
		for _s in /etc/init.d/S*epon* /etc/init.d/S*omci* /etc/init.d/S*ca_pon* \
			/etc/init.d/*epon* /etc/rc.d/*epon*; do
			[ -f "$_s" ] && [ -x "$_s" ] || continue
			case $_s in *webui*) continue ;; esac
			_r="$_s"
			break
		done
		[ -n "$_r" ] || return 1
		log_msg WARN "pon reset via $_r"
		"$_r" restart >/dev/null 2>&1 &
		;;
	*)
		return 1
		;;
	esac
	return 0
}

# ---------------------------------------------------------------- mtd 分区 --
mtd_list() {
	# 输出: 编号 名称 字节数 擦除块  (每行一个)
	# /proc/mtd 格式: mtd0: 00400000 00020000 "ssb"
	[ -r /proc/mtd ] || return 1
	awk 'NR > 1 {
		id = $1; sub(/:$/, "", id); sub(/^mtd/, "", id)
		name = $4; gsub(/"/, "", name)
		printf "%s|%s|%s|%s\n", id, name, $2, $3
	}' /proc/mtd | while IFS='|' read -r _id _name _hs _he; do
		_ds=$(awk -v h="$_hs" 'BEGIN{ printf "%d", ("0x" h) + 0 }' 2>/dev/null)
		_de=$(awk -v h="$_he" 'BEGIN{ printf "%d", ("0x" h) + 0 }' 2>/dev/null)
		printf '%s %s %s %s\n' "$_id" "$_name" "${_ds:-0}" "${_de:-0}"
	done
}

mtd_dump_to() {
	# $1 = mtd 编号, $2 = 输出文件, $3 = 限制字节数(空=全部)
	command -v nanddump >/dev/null 2>&1 || return 1
	[ -c "/dev/mtd$1" ] || return 1
	if [ -n "$3" ]; then
		nanddump -q -l "$3" "/dev/mtd$1" >"$2" 2>/dev/null
	else
		nanddump -q "/dev/mtd$1" >"$2" 2>/dev/null
	fi
}
