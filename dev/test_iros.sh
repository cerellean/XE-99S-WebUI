#!/bin/sh
# ============================================================================
#  iROS 调用自测 —— 验证"到底怎么读 PON 状态 / 光功率"这一层
#
#  为什么单独测这一层:
#    原厂固件里 `iros` 是 `ca-iros /etc/ca-iros.rc` 的包装, 只有经过它才会
#    加载 wca_* 命令库; 光模块 DOM 在 A2h 页(0xa2), 读 0x50 只会拿到厂商
#    字符串。这两点错了, 页面上的 PON 状态和光功率就是一片"—", 而且在
#    PC 上完全看不出来。所以这里用一个假的 iros 记录"我们到底发了什么"。
#
#  用法: sh dev/test_iros.sh
# ============================================================================

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/../device"
WORK=/tmp/irostest
rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/var/tmp" "$WORK/var/backup"

WEBUI_ROOT="$ROOT"
WEBUI_VAR="$WORK/var"
WEBUI_ETC="$WORK/etc"
WEBUI_LIB="$ROOT/lib"
WEBUI_LOG="$WORK/var/webui.log"
WEBUI_REMOTE=0
export WEBUI_ROOT WEBUI_VAR WEBUI_ETC WEBUI_LIB WEBUI_LOG WEBUI_REMOTE

PASS=0
FAIL=0
ck() {
	if [ "$2" = "$3" ]; then
		PASS=$((PASS + 1))
		printf 'PASS  %-34s [%s]\n' "$1" "$3"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL  %-34s want=[%s] got=[%s]\n' "$1" "$3" "$2"
	fi
}

contains() {
	case $2 in
	*"$3"*) ck "$1" 1 1 ;;
	*) ck "$1" "缺失:$3" 1 ;;
	esac
}

# ---- 假 iros: 记下 stdin, 再吐出与实机同格式的输出 -------------------------
cat >"$WORK/bin/iros" <<'FAKE'
#!/bin/sh
cat >"$IROS_STDIN"
cat <<'OUT'
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
OUT
FAKE
chmod +x "$WORK/bin/iros"
IROS_STDIN="$WORK/stdin.txt"
export IROS_STDIN
PATH="$WORK/bin:$PATH"
export PATH

. "$ROOT/lib/common.sh"
. "$ROOT/lib/transport.sh"
. "$ROOT/lib/device.sh"
. "$ROOT/lib/probe.sh"

echo "== 1. iROS 命令选择 =="
ck "找到 iros" "$(iros_bin)" "iros"
ck "iros 可用" "$(iros_ready && echo yes || echo no)" "yes"

echo
echo "== 2. 一次会话取全 PON 状态 =="
pon_load
ck "注册状态" "$(pon_get reg_state)" "1"
ck "LLID" "$(pon_get llid)" "1"
ck "OLT MAC" "$(pon_get olt_mac)" "58:41:20:1a:2b:3c"
ck "去注册原因" "$(pon_get dereg_cause)" "0"
ck "重试次数" "$(pon_get retry)" "0"
ck "上行使能" "$(pon_get upstream)" "1"
ck "下行使能" "$(pon_get downstream)" "1"
ck "已注册" "$(pon_registered)" "1"
ck "已认证" "$(pon_authorized)" "1"

echo
echo "== 3. 发给 iros 的 TCL 脚本 =="
_s=$(cat "$IROS_STDIN")
contains "调用注册查询" "$_s" "wca_epon_mpcp_registration_status_get -device_id 0 -port_id 0x20007 -llid 0"
contains "调用 LLID 查询" "$_s" "wca_epon_llid_traffic_enable_get -device_id 0 -port_id 0x20007 -llid 0x0"
contains "DOM 读 A2h 页" "$_s" "cap_i2c_read 0 0xa2"
contains "温度寄存器" "$_s" "Temperature 0x60"
contains "收光寄存器" "$_s" "RxPower 0x68"
ck "没有多余的 i2cget 调用" "$(printf '%s' "$_s" | grep -c i2cget)" "0"

echo
echo "== 4. DOM 换算 (SFF-8472) =="
ck "温度/电压/偏置/发光/收光" "$(ddm_read)" "42.30 3.290 12.40 2.15 -18.60"

echo
echo "== 5. 读不到时降级而不是报错 =="
iq=$(mktemp -d)
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' >"$iq/iros"
chmod +x "$iq/iros"
# 直接把 iros_run 换成失败, 模拟固件没有 iROS 命令库
_iros_run_save=$(command -v iros_run)
iros_run() { return 1; }
PON_LOADED=0
PON_FIELDS=""
ck "pon_load 返回失败" "$(pon_load && echo ok || echo fail)" "fail"
ck "ddm_read 返回空" "$(ddm_read || echo empty)" "empty"
ck "注册状态视为未注册" "$(pon_registered)" "0"
rm -rf "$iq"

echo
printf '通过 %s / 失败 %s\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
