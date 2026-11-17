#!/bin/sh
# ============================================================================
#  远端模式自测 (不插设备, 不需要 sshd)
#
#  原理: 用 sh -c "$*" 模拟 ssh 的语义 —— OpenSSH 会把参数用空格拼接后交给
#  远端 shell 执行, 这正是 sh -c "$*" 的行为, stdin 也原样透传。
#  配合 dev 里挂载到 /config 的模拟设备目录, 可以完整验证
#  "预取 -> 缓存 -> 解析 -> 写入 -> 回读" 全链路。
#
#  用法: sh dev/test_remote.sh
# ============================================================================

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/../device"
WORK=/tmp/webtest
rm -rf "$WORK"
mkdir -p "$WORK/var/tmp" "$WORK/var/backup"

WEBUI_ROOT="$ROOT"
WEBUI_VAR="$WORK/var"
WEBUI_ETC="$ROOT/etc"
WEBUI_LIB="$ROOT/lib"
WEBUI_LOG="$WORK/var/webui.log"
export WEBUI_ROOT WEBUI_VAR WEBUI_ETC WEBUI_LIB WEBUI_LOG

WEBUI_REMOTE=1
REMOTE_HOST=127.0.0.1
REMOTE_PORT=22
REMOTE_USER=root
export WEBUI_REMOTE REMOTE_HOST REMOTE_PORT REMOTE_USER

. "$ROOT/lib/common.sh"
. "$ROOT/lib/transport.sh"

# ---- 关键: 把 SSH 换成等价本地执行器 ----
tr_ssh() {
	sh -c "$*"
}

. "$ROOT/lib/device.sh"
. "$ROOT/lib/probe.sh"

# ---- 重置模拟设备到已知初始状态, 保证可重复运行 ----
if [ ! -d /config ] || [ ! -w /config ]; then
	echo "需要先把模拟设备挂载到 /config 与 /userdata:"
	echo "  mkdir -p /config /userdata /tmp/fakedev/{config,userdata}"
	echo "  mount --bind /tmp/fakedev/config /config"
	echo "  mount --bind /tmp/fakedev/userdata /userdata"
	exit 2
fi
cat >/config/scfg.txt <<'SEED'
#===== Customized Startup Configurations ========
# This file contains default startup configuration values
# specific to CTC
MAC         CFG_ID_MAC_ADDRESS                  = 00:19:C7:00:00:00;
MAC         CFG_ID_NE_MAC_ADDR0                 = 00:19:C7:00:00:00;
CHAR-ARRAY  CFG_ID_LOID                         = {0x4C,0x4F,0x49,0x44, 0x31,0x32,0x33,0x34, 0x35,0x36,0x37,0x38, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00};
CHAR-ARRAY  CFG_ID_PASSWD                       = {0x41,0x42,0x43,0x44, 0x45,0x46,0x47,0x48, 0x49,0x4A,0x4B,0x4C};
CHAR            CFG_ID_PON_MAC_MODE             = 0x02;
CHAR            CFG_ID_DATAPATH_MODE            = 1;
SEED
: >/userdata/scfg.txt 2>/dev/null || true
# CTC 固件特征文件, 用于验证固件识别分支(不依赖真实 /etc)
echo "CTC20220901" >/config/ctc.conf 2>/dev/null || true

PASS=0
FAIL=0
ck() {
	if [ "$2" = "$3" ]; then
		PASS=$((PASS + 1))
		printf 'PASS  %s  [%s]\n' "$1" "$2"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL  %s  期望[%s] 实际[%s]\n' "$1" "$3" "$2"
	fi
}

echo "== 1. 预取 =="
tr_prefetch
ck "缓存目录非空" "$([ -n "$(ls "$TR_CACHE"/_* 2>/dev/null)" ] && echo yes || echo no)" "yes"
ck "状态索引存在" "$([ -s "$TR_STATE" ] && echo yes || echo no)" "yes"

echo
echo "== 2. 读 scfg =="
ck "PON MAC" "$(scfg_read CFG_ID_MAC_ADDRESS)" "00:19:C7:00:00:00"
ck "LOID 转 ASCII" "$(arr_to_str "$(scfg_read CFG_ID_LOID)")" "LOID12345678"
ck "LOID 密码" "$(arr_to_str "$(scfg_read CFG_ID_PASSWD)")" "ABCDEFGHIJKL"
ck "PON 模式" "$(scfg_read CFG_ID_PON_MAC_MODE)" "0x02"
ck "类型识别" "$(scfg_type CFG_ID_LOID)" "CHAR-ARRAY"

echo
echo "== 3. 探测 =="
ck "写入目标含 /config" "$(p_write_targets | grep -c '/config/scfg.txt')" "1"
ck "写入目标只有一个" "$(p_write_targets | wc -w)" "1"
ck "读取目标含 /config" "$(p_read_targets | grep -c '/config/scfg.txt')" "1"
ck "数据通路读自 scfg" "$(scfg_read CFG_ID_DATAPATH_MODE)" "1"

echo
echo "== 4. 写 scfg (含回读) =="
scfg_write MAC CFG_ID_MAC_ADDRESS "AA:BB:CC:DD:EE:FF"
ck "写返回" "$?" "0"
ck "回读值" "$(scfg_read CFG_ID_MAC_ADDRESS)" "AA:BB:CC:DD:EE:FF"
ck "落盘内容" "$(grep -c 'AA:BB:CC:DD:EE:FF' /config/scfg.txt)" "1"
ck "原有行未丢" "$(grep -c 'CFG_ID_PON_MAC_MODE' /config/scfg.txt)" "1"

echo
echo "== 5. 重复写入不膨胀 (幂等) =="
_i=0
while [ $_i -lt 3 ]; do
	scfg_write MAC CFG_ID_MAC_ADDRESS "AA:BB:CC:DD:EE:0$_i" >/dev/null
	_i=$((_i + 1))
done
ck "MAC 行只有一条" "$(grep -c 'CFG_ID_MAC_ADDRESS' /config/scfg.txt)" "1"
ck "总行数稳定" "$(wc -l </config/scfg.txt)" "9"

echo
echo "== 6. 写另一个目标 (overlay 场景) =="
scfg_write CHAR-ARRAY CFG_ID_LOID "$(str_to_arr ZZDX99887766 24)"
ck "LOID 回读" "$(arr_to_str "$(scfg_read CFG_ID_LOID)")" "ZZDX99887766"

echo
echo "== 7. 本地备份 =="
ck "备份目录有文件" "$([ -n "$(ls "$TR_BACKUP" 2>/dev/null)" ] && echo yes || echo no)" "yes"

echo
echo "== 8. 远端模式下的 iROS 调用 (heredoc 经 ssh 转发) =="
# 用假 iros 验证: iros_run 的 heredoc 能通过 tr_ssh(sh -c 等价物)完整到达"远端",
# 且 TCL 里的 $ 符号没有被本地 shell 提前展开
mkdir -p /tmp/irostest-bin
cat >/tmp/irostest-bin/iros <<'FAKE'
#!/bin/sh
cat >/tmp/irostest-stdin
cat <<'OUT'
XE99:BEGIN
[reg_state = 1]
[mpcp_llid = 3]
[olt_mac_addr = aa:bb:cc:dd:ee:ff]
[upstream = 1]
[downstream = 1]
XE99:DDM:Temperature:10486
XE99:DDM:Vcc:33100
XE99:DDM:TxBias:7000
XE99:DDM:TxPower:16000
XE99:DDM:RxPower:180
XE99:END
OUT
FAKE
chmod +x /tmp/irostest-bin/iros
PATH="/tmp/irostest-bin:$PATH"
export PATH
rm -f /tmp/irostest-stdin
# 预取阶段在 PATH 前插假 iros 之前就缓存了 cmd:iros=0, 清掉这两条让能力探测重测
sed -i '/^cmd:iros=/d;/^cmd:ca-iros=/d' "$TR_STATE" 2>/dev/null
pon_load
ck "远端注册状态" "$(pon_get reg_state)" "1"
ck "远端 LLID" "$(pon_get llid)" "3"
ck "远端 OLT MAC" "$(pon_get olt_mac)" "aa:bb:cc:dd:ee:ff"
ck "TCL 脚本原样到达" "$(grep -c 'expr {(\[ca_uint8_array_get' /tmp/irostest-stdin)" "1"
ck "端口参数正确" "$(grep -c 'port_id 0x20007' /tmp/irostest-stdin)" "2"
ck "DOM 换算" "$(ddm_read)" "40.96 3.310 14.00 2.04 -17.45"

echo
printf '通过 %s / 失败 %s\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
