#!/bin/sh
# ============================================================================
#  本地模拟层 (仅开发预览用, 不会部署到设备)
#  目的: 让 lib/actions.sh 里的真实业务代码在 PC 上原样跑通, 便于验证
#        接口、校验、JSON 结构和前端交互, 而不需要插着光猫调试
# ============================================================================

MOCK_DIR=${WEBUI_MOCK_DIR:-$(cd "$WEBUI_ROOT/../dev" 2>/dev/null && pwd)/mock_state}
mkdir -p "$MOCK_DIR/config" "$MOCK_DIR/userdata" "$MOCK_DIR/tmp" \
	"$MOCK_DIR/etc/network" "$MOCK_DIR/var" 2>/dev/null

SCFG_FILE_TMP="$MOCK_DIR/tmp/scfg.txt"
SCFG_FILE_USER="$MOCK_DIR/userdata/scfg.txt"
SCFG_FILE_CONFIG="$MOCK_DIR/config/scfg.txt"
SCFG_FILE_DEFAULT="$MOCK_DIR/config/default_scfg.txt"
SCFG_ORDER="$SCFG_FILE_TMP $SCFG_FILE_USER $SCFG_FILE_CONFIG $SCFG_FILE_DEFAULT"
INI_FILES="$MOCK_DIR/etc/onu_manu_modle.ini"
NET_CONF_CANDIDATES="$MOCK_DIR/etc/network/interfaces"
MOCK_ENV="$MOCK_DIR/etc/env.txt"
WEBUI_VAR="$MOCK_DIR/var"
WEBUI_LOG="$MOCK_DIR/var/webui.log"
WEBUI_PASSWD="$MOCK_DIR/etc/passwd"
FORM_FILE="$WEBUI_VAR/form.$$"

seed_mock() {
	[ -f "$MOCK_DIR/.seeded" ] && return 0
	cat >"$SCFG_FILE_DEFAULT" <<'EOF'
#===== Default Startup Configurations ========
# 模拟数据, 结构取自 CIG XE-99S 出厂配置

[ASIC INFO]
STRING          CFG_ID_MODEL_NAME                               = 8271;  ##max length 16 bytes
CHAR-ARRAY      CFG_ID_HW_VERSION                               = {0x1, 0, 0, 0};    ##ASIC version major.major.minor.minor
MAC             CFG_ID_MAC_ADDRESS                              = 00:19:C7:00:00:00;    ##MAC addr in PON MAC
MAC             CFG_ID_IPHOST_MAC_ADDRESS                       = 00:19:C7:00:00:00;
CHAR            CFG_ID_PON_MAC_MODE                             = 0x02; ##PON MAC mode setting
STRING          CFG_ID_PON_VENDOR_ID                            = CORT;
CHAR-ARRAY      CFG_ID_LOID                                     = {0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00};
CHAR-ARRAY      CFG_ID_PASSWD                                   = {0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00};
EOF
	cat >"$SCFG_FILE_CONFIG" <<'EOF'
#===== 厂商出厂配置 (只读) ========
CHAR            CFG_ID_PON_REPORT_MODE              = 0x0;
CHAR            CFG_ID_PON_LLID_MODE                = 0;
INT             CFG_ID_EPON_ENCRYPTION_MODE         = 0x5;
EOF
	: >"$SCFG_FILE_USER"

	cat >"$MOCK_ENV" <<'EOF'
CA8271_VEN_NAME=CIG
CA8271_HW_VER=V1.0
CA8271_CHIP_ID=0879
CA8271_CHIP_MODEL=4701
CA8271_MANU_YEAR=2023
CA8271_MANU_MON=09
CA8271_FW_BOOTVER=V1.0.0
CA8271_FW_BOOTCRC=1A2B3C4D
CA8271_FW_FWVER=V1.3.0
CA8271_FW_FWCRC=5E6F7A8B
CA8271_FORCE_BRIDGE=1
CA8271_FORCE_BRIDGE_MAC=00:00:00:00:00:00
CA8271_FORCE_TRAFFIC=0
CA8271_SERIAL_NUMBER=CIG0123456789
EOF
	cat >"$INI_FILES" <<'EOF'
manu_info=CIG
model=XE-99S
EOF
	cat >"$MOCK_DIR/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 192.168.0.1
    netmask 255.255.255.0
EOF
	# 预览用账号: admin / admin
	_s=$(rand_hex 8)
	printf 'admin:%s:%s\n' "$_s" "$(hash_str "${_s}admin")" >"$WEBUI_PASSWD"
	date >"$MOCK_DIR/.seeded"
}
seed_mock

# ---------------------------------------------------------------- 覆盖实现 --
env_get() {
	[ -r "$MOCK_ENV" ] || return 1
	sed -n "s/^$1=//p" "$MOCK_ENV" | head -n1
}

env_set() {
	grep -v "^$1=" "$MOCK_ENV" >"$MOCK_ENV.tmp" 2>/dev/null
	printf '%s=%s\n' "$1" "$2" >>"$MOCK_ENV.tmp"
	mv -f "$MOCK_ENV.tmp" "$MOCK_ENV"
}

dev_caps() {
	printf 'mtd=1\nenv=1\ni2c=1\ncairos=1\ncigcli=1\nflash=1\nsn=1\n'
}

# 环境探测覆盖: 设备上 probe.sh 读的是绝对路径, 预览时必须改指 mock 目录
p_read_targets() {
	_l=""
	for _f in "$SCFG_FILE_USER" "$SCFG_FILE_CONFIG" "$SCFG_FILE_DEFAULT"; do
		[ -r "$_f" ] && _l="$_l $_f"
	done
	printf '%s' "$_l" | sed 's/^ *//'
}

p_write_targets() {
	_l=""
	[ -d "$MOCK_DIR/config" ] && _l="$_l $SCFG_FILE_CONFIG"
	[ -d "$MOCK_DIR/userdata" ] && _l="$_l $SCFG_FILE_USER"
	printf '%s' "$_l" | sed 's/^ *//'
}

# WEBUI_MOCK_FW=C 模拟原厂 CTC 固件(默认, 与目标设备一致)
# WEBUI_MOCK_FW=A 模拟 SIEPON-A 自定义固件(自带 WebUI)
p_fw_variant() {
	case ${WEBUI_MOCK_FW:-C} in A) printf 'A' ;; *) printf 'C' ;; esac
}

p_builtin_web() {
	case ${WEBUI_MOCK_FW:-C} in A) printf '1' ;; *) printf '0' ;; esac
}

p_busy_ports() {
	case ${WEBUI_MOCK_FW:-C} in A) printf '80 88' ;; *) printf '' ;; esac
}

p_port_id() { printf '0x20007'; }

p_tool_list() {
	printf 'ca-iros i2cget fw_setenv fw_printenv nanddump flash_erase'
}

i2c_word() {
	case $1 in
	0x60) echo 10829 ;; # 42.3 度
	0x62) echo 32900 ;; # 3.29V
	0x64) echo 6200 ;;  # 12.4mA
	0x66) echo 16400 ;; # 2.15dBm
	0x68) echo 138 ;;   # -18.6dBm
	*) return 1 ;;
	esac
}

ddm_read() {
	_t=$(i2c_word 0x60); _v=$(i2c_word 0x62); _b=$(i2c_word 0x64)
	_tx=$(i2c_word 0x66); _rx=$(i2c_word 0x68)
	awk -v t="$_t" -v v="$_v" -v b="$_b" -v tx="$_tx" -v rx="$_rx" 'BEGIN{
		if (t > 32767) t -= 65536
		printf "%.2f %.3f %.2f %.2f %.2f", t/256, v/10000, b*2/1000,
			10*log(tx/10000)/log(10), 10*log(rx/10000)/log(10)
	}'
}

pon_reg_status() {
	cat <<'EOF'
[registration_id = 0]
[deregistration_cause = 0]
[mpcp_llid = 1]
[olt_mac_addr = 58:41:20:1A:2B:3C]
[reg_state = 1]
[retry_times = 0]
Return Value : 0 - CA_E_OK
1
EOF
}

pon_traffic_status() {
	cat <<'EOF'
[downstream = 1]
[upstream = 1]
0
EOF
}

sys_uptime_sec() { echo 268740; }
sys_meminfo() { echo "126976 68320 58984"; }
sys_iface_stat() { echo "1284939223 483920112 10000"; }

dev_fw_version() {
	case ${WEBUI_MOCK_FW:-C} in A) echo "SIEPON-A v1.3.0" ;; *) echo "CTC20220901" ;; esac
}
dev_base_fw_version() { echo "CTC20220901"; }

iface_ip() { echo "192.168.0.1"; }
iface_mask() { echo "255.255.255.0"; }
iface_gw() { echo ""; }

mtd_list() {
	cat <<'EOF'
0 ssb 4194304 131072
1 uboot-env 4194304 131072
2 dtb0 4194304 131072
3 kernel0 6291456 131072
4 rootfs0 41943040 131072
5 dtb1 4194304 131072
6 kernel1 6291456 131072
7 rootfs1 41943040 131072
8 userdata 20971520 131072
9 mfginfo1 4194304 131072
10 mfginfo2 4194304 131072
EOF
}

dev_action() {
	case $1 in
	reboot | factory_reset | restart_webui | pon_reset) ;;
	*) return 1 ;;
	esac
	printf '%s mock action=%s\n' "$(date '+%T')" "$1" >>"$MOCK_DIR/var/actions.log"
	return 0
}
