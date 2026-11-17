#!/bin/sh
# ============================================================================
#  连接状态自测 —— 验证"连不上"能被正确归类成用户看得懂的原因
#
#  跨网络访问时最容易出问题的就是这个: 页面打不开/全是横杠, 但用户不知道
#  是猫棒掉电、地址改了、还是密码错了。这里逐项断言分类结果。
#
#  用法: sh dev/test_conn.sh
# ============================================================================

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/../device"
WORK=/tmp/conntest
rm -rf "$WORK"
mkdir -p "$WORK/var/tmp" "$WORK/var/backup" "$WORK/etc"

WEBUI_ROOT="$ROOT"
WEBUI_VAR="$WORK/var"
WEBUI_ETC="$WORK/etc"
WEBUI_LIB="$ROOT/lib"
WEBUI_LOG="$WORK/var/webui.log"
export WEBUI_ROOT WEBUI_VAR WEBUI_ETC WEBUI_LIB WEBUI_LOG

WEBUI_REMOTE=1
REMOTE_HOST=127.0.0.1
REMOTE_PORT=22
REMOTE_USER=root
REMOTE_PASS=
REMOTE_KEY=
REMOTE_TRANSPORT=ssh
TR_TIMEOUT=5
export WEBUI_REMOTE REMOTE_HOST REMOTE_PORT REMOTE_USER REMOTE_PASS REMOTE_KEY REMOTE_TRANSPORT

. "$ROOT/lib/common.sh"
. "$ROOT/lib/transport.sh"
. "$ROOT/lib/device.sh"
. "$ROOT/lib/probe.sh"

PASS=0
FAIL=0
ok() {
	if [ "$2" = "$3" ]; then
		PASS=$((PASS + 1))
		printf 'PASS  %-26s [%s]\n' "$1" "$3"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL  %-26s want=[%s] got=[%s]\n' "$1" "$3" "$2"
	fi
}

contains() {
	case $2 in
	*"$3"*) ok "$1" 1 1 ;;
	*) ok "$1" "0:$2" 1 ;;
	esac
}

# 每轮换一个缓存目录, 避免上一轮 state 干扰
fresh() {
	TR_CACHE="$WEBUI_VAR/cache/t$$"
	TR_SOCK="$WEBUI_VAR/sock"
	TR_STATE=""
	mkdir -p "$TR_CACHE" "$TR_SOCK" 2>/dev/null
}

# ---- 1. 正常连通 -----------------------------------------------------------
echo "== 1. 连接成功 =="
fresh
tr_ssh() { echo "hello"; return 0; }
tr_prefetch >/dev/null 2>&1
ok "conn_ok" "$(tr_conn_ok)" "1"
ok "conn_err 为空" "$(tr_conn_err)" ""

# ---- 2. 认证失败 -----------------------------------------------------------
echo
echo "== 2. 认证失败 =="
fresh
tr_ssh() {
	echo "root@127.0.0.1: Permission denied (password,publickey)." >&2
	return 255
}
tr_prefetch >/dev/null 2>&1
ok "conn_ok" "$(tr_conn_ok)" "0"
contains "归类为认证失败" "$(tr_conn_err)" "认证失败"

# ---- 3. 连接超时 -----------------------------------------------------------
echo
echo "== 3. 连接超时 =="
fresh
tr_ssh() {
	echo "ssh: connect to host 10.0.0.9 port 22: Connection timed out" >&2
	return 255
}
tr_prefetch >/dev/null 2>&1
contains "归类为超时" "$(tr_conn_err)" "连接超时"

# ---- 4. 端口未开放(真实 ssh, 不靠模拟) --------------------------------------
echo
echo "== 4. 端口未开放 (真实 ssh) =="
if command -v ssh >/dev/null 2>&1; then
	fresh
	REMOTE_HOST=127.0.0.1
	REMOTE_PORT=2299
	tr_ssh() {
		ssh -p "$REMOTE_PORT" -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
			-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
			"$REMOTE_USER@$REMOTE_HOST" "echo hi"
	}
	tr_prefetch >/dev/null 2>&1
	ok "conn_ok" "$(tr_conn_ok)" "0"
	contains "归类为被拒绝" "$(tr_conn_err)" "连接被拒绝"
	REMOTE_PORT=22
else
	echo "SKIP  无 ssh 客户端"
fi

# ---- 5. 网络不可达 ---------------------------------------------------------
echo
echo "== 5. 网络不可达 =="
fresh
tr_ssh() {
	echo "ssh: connect to host 192.0.2.1 port 22: No route to host" >&2
	return 255
}
tr_prefetch >/dev/null 2>&1
contains "归类为不可达" "$(tr_conn_err)" "网络不可达"

# ---- 6. 预取失败时不返回假数据 ---------------------------------------------
echo
echo "== 6. 失败时不留假数据 =="
fresh
tr_ssh() { echo "boom" >&2; return 255; }
tr_prefetch >/dev/null 2>&1
_rc=$?
ok "tr_prefetch 返回非0" "$_rc" "1"
ok "无残留缓存文件" "$(ls "$TR_CACHE" 2>/dev/null | grep -c '^_')" "0"

# ---- 7. 配置保存与读取(含特殊字符密码) --------------------------------------
echo
echo "== 7. 连接配置往返 =="
fresh
_pw='p@ss$w0rd"'\''x`id`'
tr_conf_save "10.1.2.3" "2222" "admin" "$_pw" "/root/.ssh/id_ed25519" "ssh"
ok "保存返回值" "$?" "0"
ok "host" "$REMOTE_HOST" "10.1.2.3"
ok "port" "$REMOTE_PORT" "2222"
ok "user" "$REMOTE_USER" "admin"
ok "密码原样保留" "$REMOTE_PASS" "$_pw"
ok "transport" "$REMOTE_TRANSPORT" "ssh"
ok "文件权限" "$(ls -l "$WEBUI_ETC/remote.conf" | cut -c1-4)" "-rw-"

# 重新加载一遍, 确认落盘后再读出来也一致
REMOTE_HOST=""; REMOTE_PORT=""; REMOTE_USER=""; REMOTE_PASS=""; REMOTE_KEY=""
tr_conf_load
ok "重载 host" "$REMOTE_HOST" "10.1.2.3"
ok "重载密码" "$REMOTE_PASS" "$_pw"

# 保存后立即生效: REMOTE_HOST 应已切换
ok "变量已同步" "$REMOTE_HOST:${REMOTE_PORT}" "10.1.2.3:2222"

echo
echo "通过 $PASS / 失败 $FAIL"
[ "$FAIL" = "0" ] || exit 1
