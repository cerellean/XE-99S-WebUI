#!/bin/sh
# ============================================================================
#  PC 侧一键部署脚本
#  用法:
#     sh install.sh                     # 默认 root@192.168.0.1, 自动尝试密码 admin
#     sh install.sh 192.168.0.1         # 指定地址
#     SSH_USER=root SSH_PORT=22 sh install.sh 192.168.0.1
#     SSH_PASS='你的密码' sh install.sh   # 密码不是 admin 时(需 sshpass)
#
#  固件默认凭据:
#     SIEPON Package-C (CIG 原厂 CTC 固件) : root / admin      <- 本站棒子
#     SIEPON Package-A (自定义固件)        : root / ca8271
#     少数老批次原厂固件 root 为空密码, 可用 SSH_PASS='' 指定
#
#  本脚本自身不改设备 root 密码, 只用它登录部署。
# ============================================================================

set -u
HOST=${1:-192.168.0.1}
SSH_USER=${SSH_USER:-root}
SSH_PORT=${SSH_PORT:-22}
REMOTE_DIR=${REMOTE_DIR:-/userdata/webui}
DEF_PASS=${DEF_PASS:-admin}
SRC=$(cd "$(dirname "$0")" && pwd)/device

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -o LogLevel=ERROR -o ServerAliveInterval=15"
# 没有 sshpass 时, 靠连接复用让整轮部署只输一次密码
CM_SOCK="/tmp/xe99s-webui-$$-%r@%h:%p"
case $(ssh -V 2>&1) in
*OpenSSH*) SSH_OPTS="$SSH_OPTS -o ControlMaster=auto -o ControlPath=$CM_SOCK -o ControlPersist=120" ;;
esac

# --------------------------------------------------------------- 认证方式 --
HAS_SSHPASS=0
command -v sshpass >/dev/null 2>&1 && HAS_SSHPASS=1

AUTH=key # key = 免密/密钥, pass = 密码
PASS=""
if [ "${SSH_PASS+set}" = "set" ]; then
	PASS=$SSH_PASS
	if [ "$HAS_SSHPASS" = "1" ]; then
		AUTH=pass
	else
		echo "提示: 已指定 SSH_PASS, 但本机没有 sshpass, 将改为手动输入密码"
		echo "      Debian/Ubuntu: sudo apt install sshpass"
		echo "      macOS:         brew install hudochenkov/sshpass/sshpass"
	fi
fi

# 统一入口: 密码走 SSHPASS 环境变量, 不出现在 ps 命令行里
rssh() {
	if [ "$AUTH" = "pass" ]; then
		SSHPASS=$PASS sshpass -e ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" "$@"
	else
		ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" "$@"
	fi
}

echo "== XE-99S WebUI 部署 =="
echo "  目标: $SSH_USER@$HOST:$REMOTE_DIR"

# ---------------------------------------------------------------- 前置检查 --
for c in ssh tar gzip; do
	command -v "$c" >/dev/null 2>&1 || { echo "错误: 本机缺少 $c"; exit 1; }
done
[ -d "$SRC" ] || { echo "错误: 未找到 $SRC 目录"; exit 1; }

# ------------------------------------------------------------ 连通性探测 --
echo "-> 检查 SSH 连通性…"
LOGIN_OK=0
if [ "$HAS_SSHPASS" = "1" ]; then
	# 有 sshpass: 静默依次试 密钥 -> 原厂默认密码
	if rssh "echo ok" >/dev/null 2>&1; then
		LOGIN_OK=1
		echo "   已用密钥/免密登录"
	elif [ "$AUTH" != "pass" ]; then
		AUTH=pass
		PASS=$DEF_PASS
		if rssh "echo ok" >/dev/null 2>&1; then
			LOGIN_OK=1
			echo "   已用默认密码登录（$SSH_USER / $DEF_PASS）"
			echo "   建议: 自行修改设备 root 密码, 默认密码风险较高"
		fi
	fi
else
	# 没有 sshpass: 直接交互, 必须让密码提示可见, 否则用户以为卡住
	echo "   需要输入 $SSH_USER@$HOST 的密码（原厂默认为 $DEF_PASS）"
	if rssh "echo ok" >/dev/null; then
		LOGIN_OK=1
		echo "   登录成功"
	fi
fi

if [ "$LOGIN_OK" != "1" ]; then
	echo
	echo "无法通过 SSH 登录设备。请确认:"
	echo "  1. 电脑网口地址已设为 192.168.0.5/24, 能 ping 通 $HOST"
	echo "  2. 原厂 Package-C 固件: ssh $SSH_USER@$HOST, 密码 $DEF_PASS"
	echo "     Package-A 自定义固件: 密码 ca8271"
	echo "  3. 密码不同时可指定: SSH_PASS='你的密码' sh install.sh $HOST"
	echo "     (需要 sshpass: sudo apt install sshpass / brew install hudochenkov/sshpass/sshpass)"
	echo "  4. 也可以先手动登录一次并 ssh-copy-id, 之后本脚本即可免密运行"
	echo
	echo "若固件未开启 SSH, 可先用 UART (115200 8N1) 登录, 离线安装步骤见"
	echo "README 的「离线安装」一节。"
	exit 1
fi

echo "-> 检查目标可写…"
if ! rssh "mkdir -p $REMOTE_DIR && test -w $REMOTE_DIR" 2>/dev/null; then
	echo "错误: 无法写入 $REMOTE_DIR (分区只读?)"
	exit 1
fi

echo "-> 上传文件 (约 $(du -sk "$SRC" | awk '{print $1}') KB)…"
# 先落本地临时包, 这样打包失败能被捕获(管道里 tar 的退出码会丢)
TGZ="/tmp/xe99s-webui-$$.tgz"
if ! tar czf "$TGZ" -C "$SRC" .; then
	rm -f "$TGZ"
	echo "错误: 本地打包失败"; exit 1
fi
if ! rssh "rm -rf $REMOTE_DIR/www $REMOTE_DIR/lib && tar xzf - -C $REMOTE_DIR" <"$TGZ"; then
	rm -f "$TGZ"
	echo "错误: 上传失败"; exit 1
fi
rm -f "$TGZ"

echo "-> 设备端初始化…"
rssh "sh $REMOTE_DIR/install-remote.sh" || { echo "错误: 设备端安装失败"; exit 1; }

# 释放复用的 SSH 连接
case $(ssh -V 2>&1) in
*OpenSSH*) ssh -O exit -p "$SSH_PORT" -o ControlPath="$CM_SOCK" "$SSH_USER@$HOST" >/dev/null 2>&1 ;;
esac

echo
echo "提示: 浏览器打开上方地址, 用 admin/admin 登录后立即改密码。"
echo "      首次登录请看「系统 → 环境自检」, 确认写入路径与端口探测结果。"
echo "      如需卸载: sh uninstall.sh $HOST"
