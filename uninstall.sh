#!/bin/sh
# ============================================================================
#  卸载脚本
#  用法:
#     sh uninstall.sh [HOST]
#     SSH_PASS='你的密码' sh uninstall.sh 192.168.0.1
#
#  凭据: 原厂 Package-C 固件 root / admin, Package-A 为 root / ca8271
# ============================================================================

set -u
HOST=${1:-192.168.0.1}
SSH_USER=${SSH_USER:-root}
SSH_PORT=${SSH_PORT:-22}
REMOTE_DIR=${REMOTE_DIR:-/userdata/webui}
DEF_PASS=${DEF_PASS:-admin}
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -o LogLevel=ERROR -o ServerAliveInterval=15"

HAS_SSHPASS=0
command -v sshpass >/dev/null 2>&1 && HAS_SSHPASS=1

AUTH=key
PASS=""
if [ "${SSH_PASS+set}" = "set" ] && [ "$HAS_SSHPASS" = "1" ]; then
	PASS=$SSH_PASS
	AUTH=pass
fi

rssh() {
	if [ "$AUTH" = "pass" ]; then
		SSHPASS=$PASS sshpass -e ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" "$@"
	else
		ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" "$@"
	fi
}

echo "== 卸载 XE-99S WebUI ($HOST) =="

# 密钥登录失败时, 自动试一次原厂默认密码
if ! rssh "true" >/dev/null 2>&1; then
	[ "$AUTH" != "pass" ] && [ "$HAS_SSHPASS" = "1" ] && { AUTH=pass; PASS=$DEF_PASS; }
fi

rssh "
	$REMOTE_DIR/init.d/S99webui stop 2>/dev/null
	rm -f /etc/init.d/S99webui /etc/rcS.d/S99webui 2>/dev/null
	if [ -f /etc/rc.local ]; then
		grep -v 'userdata/webui/init.d/S99webui' /etc/rc.local > /tmp/rc.local.new 2>/dev/null && mv /tmp/rc.local.new /etc/rc.local
	fi
	rm -rf $REMOTE_DIR
	echo '已删除 $REMOTE_DIR 与自启项'
" || {
	echo "错误: 远程执行失败（登录失败或权限不足）"
	echo "      密码不同时可指定: SSH_PASS='你的密码' sh uninstall.sh $HOST"
	exit 1
}
echo "完成。PON 业务与本卸载无关，无需重启。"
