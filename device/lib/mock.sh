#!/bin/sh
# ============================================================================
#  本地模拟层 (仅开发预览用, 不会部署到设备)
#  目的: 让 lib/actions.sh 里的真实业务代码在 PC 上原样跑通, 便于验证
#        接口、校验、JSON 结构和前端交互, 而不需要插着光猫调试
#
#  模拟数据的结构照抄原厂 SIEPON-C 固件:
#    config/scfg.txt          —— CTC 定制配置 (与实机 /config/scfg.txt 同结构)
#    config/default_scfg.txt  —— 厂商出厂配置
#    mfginfo                  —— 出厂标识串 (与实机 mtd9 内容同形)
# ============================================================================

MOCK_DIR=${WEBUI_MOCK_DIR:-$(cd "$WEBUI_ROOT/../dev" 2>/dev/null && pwd)/mock_state}
mkdir -p "$MOCK_DIR/config" "$MOCK_DIR/userdata" "$MOCK_DIR/tmp" \
	"$MOCK_DIR/etc/network" "$MOCK_DIR/var/tmp" "$MOCK_DIR/var/backup" 2>/dev/null

SCFG_FILE_CONFIG="$MOCK_DIR/config/scfg.txt"
SCFG_FILE_USER="$MOCK_DIR/userdata/scfg.txt"
SCFG_FILE_DEFAULT="$MOCK_DIR/config/default_scfg.txt"
SCFG_ORDER="$SCFG_FILE_CONFIG $SCFG_FILE_USER $SCFG_FILE_DEFAULT"
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
# 模拟数据, 结构取自 CIG XE-99S 原厂 default_scfg.txt

[ASIC INFO]
STRING          CFG_ID_MODEL_NAME                               = 8271;  ##max length 16 bytes
CHAR-ARRAY      CFG_ID_HW_VERSION                               = {0x1, 0, 0, 0};    ##ASIC version major.major.minor.minor
CHAR            CFG_ID_DATAPATH_MODE                            = 1;    # 0 = R/G mode, 1 = bridge mode

[PON CONFIGS]
CHAR            CFG_ID_PON_MAC_MODE                             = 0x02; ##PON MAC mode setting
STRING          CFG_ID_PON_VENDOR_ID                            = CORT;
CHAR-ARRAY      CFG_ID_LOID                                     = {0x4C,0x4F,0x49,0x44, 0x31,0x32,0x33,0x34, 0x35,0x36,0x37,0x38, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00};
CHAR-ARRAY      CFG_ID_PASSWD                                   = {0x41,0x42,0x43,0x44, 0x45,0x46,0x47,0x48, 0x49,0x4A,0x4B,0x4C};
CHAR            CFG_ID_PON_REPORT_MODE                          = 0x04; ##Report mode, 2QS_8Q-0; 1QS_8Q-1;1QS_1Q-2;2QS_1Q-3;4QS_1Q-4;
CHAR            CFG_ID_PON_LLID_MODE                            = 0x01; ##EPON, 0--single LLID mode; 1--multiple LLID mode
CHAR            CFG_ID_PON_DS_FORWARD_BCMC                      = 0x01; ##EPON, 0--stop forwarding BC and MC; 1--always forward
CHAR            CFG_ID_PON_LLID_NUM                             = 0x08; ##EPON LLID num max support
CHAR            CFG_ID_OAM_MODE                                 = 1;#OAM mode: CTC-0, DPoE-1, KT-2...
INT             CFG_ID_EPON_ENCRYPTION_MODE                     = 0x1; ## 0: disabled; 1: AES_CTR; ... 5: HW_CTC_CHURNING
EOF
	cat >"$SCFG_FILE_CONFIG" <<'EOF'
#===== Customized Startup Configurations ========
# This file contains default startup configuration values
# specific to CTC
# Values in this field will overwrite values in /config/default_scfg.txt

MAC         CFG_ID_MAC_ADDRESS                  = 00:19:C7:00:00:00;
MAC         CFG_ID_NE_MAC_ADDR0                 = 00:19:C7:00:00:00;
CHAR        CFG_ID_PON_LLID_NUM                 = 0x01; ##EPON LLID num max support
CHAR        CFG_ID_EN_REGISTER_AFTER_BOOT       = 0x01; ##0--Manual; 1--Auto; 2--OAM Based
CHAR        CFG_ID_PON_REPORT_MODE              = 0x0;
CHAR        CFG_ID_OAM_MODE                     = 0;#OAM mode: CTC-0, DPoE-1, KT-2...
CHAR        CFG_ID_PON_LLID_MODE                = 0;#EPON, 0--single LLID mode; 1--multiple LLID mode
CHAR        CFG_ID_PON_MAC_MODE                 = 0x02; #10G Down, 10G Up, EPON
CHAR-ARRAY  CFG_ID_LOID                         = {0x4C,0x4F,0x49,0x44, 0x31,0x32,0x33,0x34, 0x35,0x36,0x37,0x38, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00};
CHAR-ARRAY  CFG_ID_PASSWD                       = {0x41,0x42,0x43,0x44, 0x45,0x46,0x47,0x48, 0x49,0x4A,0x4B,0x4C};
INT         CFG_ID_EPON_ENCRYPTION_MODE         = 0x5; ## 0: disabled; 1: AES_CTR; ... 5: HW_CTC_CHURNING
CHAR        CFG_ID_PON_BC_7FFF_TO_LLID_INDEX    = 0x3f;
EOF
	: >"$SCFG_FILE_USER"

	cat >"$MOCK_ENV" <<'EOF'
bootcmd=run load_kernel
bootargs=console=ttyS0,115200
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
dev_caps() {
	printf 'mtd=1\nnanddump=1\nenv=0\niros=1\nflash=1\n'
}

# 环境探测覆盖: 设备上 probe.sh 读的是绝对路径, 预览时必须改指 mock 目录
p_read_targets() {
	_l=""
	for _f in "$SCFG_FILE_CONFIG" "$SCFG_FILE_USER" "$SCFG_FILE_DEFAULT"; do
		[ -r "$_f" ] && _l="$_l $_f"
	done
	printf '%s' "$_l" | sed 's/^ *//'
}

p_write_targets() {
	[ -d "$MOCK_DIR/config" ] && printf '%s' "$SCFG_FILE_CONFIG"
}

p_iros() { printf 1; }
p_iros_cmd() { printf 'iros'; }

# 预览时把 /config、/userdata、/etc/network 指到 mock 目录, 免得读到宿主机文件
iros_bin() { printf 'iros'; }
iros_ready() { return 0; }

tr_cat() {
	case $1 in
	"$MOCK_DIR"/*) cat "$1" 2>/dev/null; return $? ;;
	/config/* | /userdata/* | /etc/network/*) cat "$MOCK_DIR$1" 2>/dev/null; return $? ;;
	esac
	cat "$1" 2>/dev/null
}
p_mfg() { printf '1DP-00016-6108233000717001HF2518600400Q|CIGECIGE#0|1.00|XE-99S|1.00|0000000000'; }

p_tool_list() {
	printf 'iros ca-iros nanddump flash_erase'
}

# iros 的模拟输出: 格式与实机一致 ([key = value] + DOM 原始值)
iros_run() {
	cat <<'EOF'
XE99:BEGIN
[registration_id = 0]
[deregistration_cause = 0]
[mpcp_llid = 1]
[olt_mac_addr = 58:41:20:1a:2b:3c]
[reg_state = 1]
[retry_times = 0]
[upstream = 1]
[downstream = 1]
XE99:DDM:Temperature:10829
XE99:DDM:Vcc:32900
XE99:DDM:TxBias:6200
XE99:DDM:TxPower:16400
XE99:DDM:RxPower:138
XE99:END
EOF
}

env_get() {
	[ -r "$MOCK_ENV" ] || return 1
	sed -n "s/^$1=//p" "$MOCK_ENV" | head -n1
}

sys_uptime_sec() { echo 268740; }

sys_meminfo() { echo "126976 68320 58984"; }

sys_iface_stat() { echo "1284939223 483920112 10000"; }

iface_mac() { echo "00:19:c7:00:00:00"; }

dev_fw_version() { echo "1.3.0"; }

dev_fw_build() { echo "CTC20220901"; }

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

mfg_strings() { p_mfg; }

dev_action() {
	case $1 in
	reboot | factory_reset | restart_webui | pon_reset) ;;
	*) return 1 ;;
	esac
	printf '%s mock action=%s\n' "$(date '+%T')" "$1" >>"$MOCK_DIR/var/actions.log"
	return 0
}

# ------------------------------------------------------- 远端模式(演示用) --
# WEBUI_MOCK_NET=1 时假装网络连通: 让"登录 -> 填地址 -> 自动连上"这条链路
# 在没有猫棒的笔记本上也能完整走一遍(截图 / e2e 用)。真机不会加载本文件。
if [ "${WEBUI_MOCK_NET:-0}" = "1" ]; then
	tr_ssh_ok() { printf 1; }
	tr_sshpass_ok() { printf 1; }
	[ -f "$MOCK_DIR/etc/id_ed25519" ] || {
		printf 'demo-key\n' >"$MOCK_DIR/etc/id_ed25519"
		printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoKeyForPreviewOnly xe99s-webui@demo\n' \
			>"$MOCK_DIR/etc/id_ed25519.pub"
	}
	tr_key_file() { printf '%s' "$MOCK_DIR/etc/id_ed25519"; }
	tr_push_key() { return 0; }

	# 演示用: 10.0.0.x / 含 256 的地址当作"连不上", 方便看失败提示
	_mock_conn_fail() {
		case $REMOTE_HOST in
		10.0.0.* | *256*) return 0 ;;
		esac
		return 1
	}

	tr_prefetch() {
		tr_remote || return 0
		tr_cache_init
		if ! tr_configured; then
			tr_conn_record 1 "$(tr_now)" "" unconfigured
			return 1
		fi
		if _mock_conn_fail; then
			printf 'ssh: connect to host %s port %s: Connection timed out\n' \
				"$REMOTE_HOST" "$REMOTE_PORT" >"$TR_CACHE/.stderr.mock"
			tr_conn_record 255 "$(( $(tr_now) - 4000 ))" "$TR_CACHE/.stderr.mock"
			return 1
		fi
		tr_conn_record 0 "$(tr_now)" ""
		return 0
	}

	tr_conn_test() {
		tr_remote || { printf 'local'; return 0; }
		tr_cache_init
		if ! tr_configured; then
			tr_conn_record 1 "$(tr_now)" "" unconfigured
			printf 'fail'
			return 1
		fi
		if _mock_conn_fail; then
			printf 'ssh: connect to host %s port %s: Connection timed out\n' \
				"$REMOTE_HOST" "$REMOTE_PORT" >"$TR_CACHE/.ctest.mock"
			tr_conn_record 255 "$(( $(tr_now) - 4000 ))" "$TR_CACHE/.ctest.mock"
			printf 'fail'
			return 1
		fi
		tr_conn_record 0 "$(( $(tr_now) - 9 ))" ""
		printf 'ok'
		return 0
	}
fi
