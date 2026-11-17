#!/bin/sh
# ============================================================================
#  Alpine 小主机侧安装脚本
#
#  场景: 猫棒在局域网的任意位置(插在交换机/路由器/任何有 SFP+ 口的机器上),
#        Alpine 小主机只需能通过网络访问它。WebUI 装在小主机上, LAN 里任何
#        设备都能通过它管理猫棒——设备操作经 SSH 转发到猫棒执行, 猫棒侧零安装。
#
#  重要: 本脚本不需要知道猫棒的地址。装完打开网页, 在登录卡片上填地址/账号/
#        密码即可, 之后随时能在「系统 → 设备连接」里改, 都不用重跑脚本。
#
#  用法(在 Alpine 上以 root 执行):
#     sh install-alpine.sh                     # 不填地址, 装完在网页里填
#     sh install-alpine.sh 192.168.0.1         # 可选: 先把地址写进配置
#     REMOTE_PASS=admin sh install-alpine.sh 192.168.0.1   # 顺带推公钥(免密)
#     REMOTE_TRANSPORT=telnet sh install-alpine.sh         # 改用 telnet
#
#  与装在猫棒上的区别: 本脚本不写猫棒的任何文件, 只在 Alpine 上落地一套
#  前端 + CGI; 猫棒侧只需要开着 SSH(或 telnet)即可。
# ============================================================================

set -u
HOST=${1:-}
RUSER=${REMOTE_USER:-root}
RPORT=${REMOTE_PORT:-22}
TRANSPORT=${REMOTE_TRANSPORT:-ssh}
DIR=${WEBUI_DIR:-/opt/xe99s-webui}
PORT=${WEBUI_PORT:-8080}
SRC=$(cd "$(dirname "$0")" && pwd)/device

msg() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 执行"
[ -d "$SRC" ] || die "未找到 device/ 目录"

# Alpine 把 busybox 拆过包: 基础包里有 busybox, 但 httpd 是编译期可选 applet,
# 只装在 busybox-extras 里。所以"有 busybox"不等于"有 httpd"——必须按 applet 查,
# 否则会出现装完启动报 "httpd: applet not found" 的坑。
has_httpd() {
	command -v httpd >/dev/null 2>&1 && return 0
	busybox --list 2>/dev/null | grep -qx httpd && return 0
	return 1
}

msg "== XE-99S WebUI（Alpine 版）=="
if [ -n "$HOST" ]; then
	msg "   猫棒地址 : $RUSER@$HOST:$RPORT  (传输: $TRANSPORT)"
else
	msg "   猫棒地址 : 装完后在网页登录页填写"
fi
msg "   安装目录 : $DIR"
msg "   监听端口 : $PORT"

# ---------------------------------------------------------------- 依赖 --
# 三个包就够: busybox-extras(提供 httpd) + openssh-client(提供 ssh/ssh-keygen)
# + sshpass(OpenSSH 不支持从管道读密码)。除此外只用 busybox 自带的 ash/awk/sed。
# 不走 npm / python / php, 所以没有运行时解释器依赖。
if command -v apk >/dev/null 2>&1; then
	_miss=""
	has_httpd || _miss="$_miss busybox-extras"
	command -v ssh >/dev/null 2>&1 || _miss="$_miss openssh-client"
	command -v sshpass >/dev/null 2>&1 || _miss="$_miss sshpass"
	if [ "$TRANSPORT" = "telnet" ] && ! command -v expect >/dev/null 2>&1; then
		_miss="$_miss expect"
	fi
	if [ -n "$_miss" ]; then
		msg "-> 安装依赖:$_miss"
		# shellcheck disable=SC2086
		if ! apk add --no-cache $_miss >/dev/null 2>&1; then
			msg "   警告: 依赖安装失败。请手动执行:"
			msg "         apk add$_miss"
			msg "         （sshpass / expect 在 community 仓库，确认 /etc/apk/repositories 里有 community）"
		fi
	fi
	has_httpd || die "缺少 httpd: 请先执行 apk add busybox-extras"
	command -v ssh >/dev/null 2>&1 || msg "   警告: 没有 ssh 客户端，远端管理不可用: apk add openssh-client"
	command -v sshpass >/dev/null 2>&1 ||
		msg "   警告: 没有 sshpass，密码登录不可用（只能走已有的免密密钥）: apk add sshpass"
else
	msg "-> 非 Alpine 系统，跳过 apk 依赖检查"
	has_httpd || die "缺少 httpd（需要 busybox 带 httpd applet，或安装 busybox-extras）"
fi

# ---------------------------------------------------------------- 落文件 --
msg "-> 安装文件到 $DIR…"
mkdir -p "$DIR"
# 注意布局: cgi-bin 必须在 www/ 里面! busybox httpd 把 URL /cgi-bin/* 映射到
# 根目录内的 cgi-bin/, 放在 www/ 平级会全部 404 (静态页能开、API 404 的经典坑)。
rm -rf "$DIR/www" "$DIR/lib" "$DIR/etc" 2>/dev/null
cp -a "$SRC/www" "$SRC/lib" "$SRC/etc" "$DIR/" || die "复制失败"
chmod +x "$DIR/www/cgi-bin/"*.cgi 2>/dev/null
mkdir -p "$DIR/var/tmp" "$DIR/var/backup" "$DIR/var/cache"

# ---------------------------------------------------------------- 密钥 --
# 生成一次; 登录页保存连接时会用密码把公钥推到猫棒, 之后自动走免密。
KEY="$DIR/etc/id_ed25519"
if [ ! -f "$KEY" ]; then
	if command -v ssh-keygen >/dev/null 2>&1; then
		msg "-> 生成专用 SSH 密钥…"
		ssh-keygen -t ed25519 -N '' -C "xe99s-webui@$(hostname 2>/dev/null || echo alpine)" \
			-f "$KEY" >/dev/null 2>&1 || msg "   警告: ssh-keygen 失败，将只能使用密码登录"
	else
		msg "   警告: 没有 ssh-keygen，只能用密码登录"
	fi
fi
[ -f "$KEY" ] && chmod 600 "$KEY" 2>/dev/null
[ -f "$KEY.pub" ] && chmod 644 "$KEY.pub" 2>/dev/null

# ---------------------------------------------------------------- 运行配置 --
# 地址允许为空: 空 = 还没配, 登录页会引导填写。绝不能拿 192.168.0.1 当默认值,
# 否则用户改了猫棒地址时会表现为"莫名连不上"而不是"还没配置"。
msg "-> 写入运行配置…"
for _v in "$HOST" "${REMOTE_PASS:-}"; do
	case $_v in
	*'
'*) die "地址/密码不能包含换行" ;;
	esac
done
cat >"$DIR/etc/remote.conf" <<EOF
# 由 install-alpine.sh 生成：WebUI 跑在本机，设备操作转发到猫棒
# REMOTE_HOST 留空 = 尚未配置，登录页会引导填写；也可在「系统 → 设备连接」里改
WEBUI_REMOTE=1
REMOTE_HOST=$HOST
REMOTE_PORT=$RPORT
REMOTE_USER=$RUSER
REMOTE_TRANSPORT=$TRANSPORT
REMOTE_AUTH=pass
REMOTE_KEY=$KEY
REMOTE_PASS=${REMOTE_PASS:-}
EOF
chmod 600 "$DIR/etc/remote.conf"

# 监听端口
if grep -q '^PORT=' "$DIR/etc/webui.conf" 2>/dev/null; then
	sed -i "s/^PORT=.*/PORT=$PORT/" "$DIR/etc/webui.conf"
else
	printf 'PORT=%s\n' "$PORT" >>"$DIR/etc/webui.conf"
fi

# ---------------------------------------------------------------- 账号 --
if [ ! -f "$DIR/etc/passwd" ]; then
	_s=$(dd if=/dev/urandom bs=1 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')
	[ -n "$_s" ] || _s="$(date +%s)$$"
	_h=$(printf '%s' "${_s}admin" | sha256sum | cut -d' ' -f1)
	printf 'admin:%s:%s\n' "$_s" "$_h" >"$DIR/etc/passwd"
	chmod 600 "$DIR/etc/passwd"
	msg "   已创建控制台账号 admin / admin"
fi
[ -f "$DIR/etc/secret" ] || {
	dd if=/dev/urandom bs=1 count=16 2>/dev/null | od -An -tx1 | tr -d ' \n' >"$DIR/etc/secret"
	chmod 600 "$DIR/etc/secret"
}

# ---------------------------------------------------------------- 服务 --
msg "-> 安装 OpenRC 服务…"
cat >/etc/init.d/xe99s-webui <<EOF
#!/sbin/openrc-run
description="XE-99S SFP ONT WebUI (remote backend)"

DIR="$DIR"
PORT="$PORT"
PIDFILE="/run/xe99s-webui.pid"

depend() {
	need net
	after firewall
}

start() {
	ebegin "Starting xe99s-webui on :\$PORT"
	start-stop-daemon --start --background --make-pidfile --pidfile "\$PIDFILE" \\
		--exec /usr/sbin/httpd -- -f -h "\$DIR/www" -c "\$DIR/etc/httpd.conf" -p "\$PORT"
	eend \$? "启动失败，检查 busybox httpd 是否可用"
}

stop() {
	ebegin "Stopping xe99s-webui"
	start-stop-daemon --stop --pidfile "\$PIDFILE" --retry 5
	eend \$?
	rm -f "\$PIDFILE"
}
EOF
chmod +x /etc/init.d/xe99s-webui
rc-update add xe99s-webui default >/dev/null 2>&1 || msg "   警告: rc-update 失败，请手动加入自启"

# httpd 可执行路径探测（busybox 的 applet 可能不在 /usr/sbin）
HTTPD_PATH=$(command -v httpd 2>/dev/null)
if [ -z "$HTTPD_PATH" ] && busybox --list 2>/dev/null | grep -qx httpd; then
	# applet 在, 但没有独立可执行文件: 补个符号链接, 让服务脚本能按路径启动
	ln -sf /bin/busybox /usr/local/bin/httpd 2>/dev/null && HTTPD_PATH=/usr/local/bin/httpd
fi
[ -n "$HTTPD_PATH" ] || HTTPD_PATH=/usr/sbin/httpd
sed -i "s|--exec /usr/sbin/httpd|--exec $HTTPD_PATH|" /etc/init.d/xe99s-webui 2>/dev/null

msg "-> 启动服务…"
/etc/init.d/xe99s-webui restart >/dev/null 2>&1 || /etc/init.d/xe99s-webui start >/dev/null 2>&1
sleep 1

# ---------------------------------------------------------------- 自检 --
IP=$(ip -4 addr show 2>/dev/null | awk '/inet /{ sub(/\/.*/, "", $2); if ($2 !~ /^127\./) { print $2; exit } }')
[ -n "$IP" ] || IP=$(hostname -i 2>/dev/null | awk '{print $1}')
[ -n "$IP" ] || IP="<本机地址>"

# 自检不需要 curl: Alpine 最小安装通常没有它。优先 curl, 其次 busybox wget,
# 两个都没有就看进程是否还活着。
_probe=2
if command -v curl >/dev/null 2>&1; then
	curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1
	_probe=$?
elif command -v wget >/dev/null 2>&1; then
	wget -q -O /dev/null "http://127.0.0.1:$PORT/" >/dev/null 2>&1
	_probe=$?
fi
if [ "$_probe" = "2" ]; then
	if [ -f /run/xe99s-webui.pid ] && kill -0 "$(cat /run/xe99s-webui.pid)" 2>/dev/null; then
		_probe=0
	else
		_probe=1
	fi
fi

msg ""
if [ "$_probe" = "0" ]; then
	msg "安装完成"
else
	msg "服务已安装，但本机访问 http://127.0.0.1:$PORT 未响应"
	msg "  排查: tail -n 30 /var/log/messages；或手动前台运行:"
	msg "        httpd -f -h $DIR/www -c $DIR/etc/httpd.conf -p $PORT"
fi
msg ""
msg "  打开   : http://$IP:$PORT"
msg "  账号   : admin / admin（登录后可在「系统」页修改）"
msg ""
msg "  下一步 : 用 admin / admin 登录控制台。首次登录若还没配过猫棒，会自动弹出"
msg "           「首次配置」向导，在里面填猫棒的地址、账号、密码，点「连接」即自动连上。"
msg "           原厂 SIEPON-C 固件默认 192.168.0.1 / root / admin。"
msg "           之后换地址/改密码在「系统 → 设备连接」里改，不用重跑本脚本。"
msg ""

# 传了地址就顺手验一次, 不通当场说清楚; 没传就没什么可验的
if [ -n "$HOST" ] && [ "$TRANSPORT" = "ssh" ] && command -v ssh >/dev/null 2>&1; then
	if [ -f "$KEY" ] && ssh -i "$KEY" -p "$RPORT" -o BatchMode=yes -o StrictHostKeyChecking=no \
		-o ConnectTimeout=6 -o LogLevel=ERROR "$RUSER@$HOST" true 2>/dev/null; then
		msg "  连通检查 : OK（已免密连上 $HOST）"
	else
		msg "  连通检查 : 尚未免密（首次连接时会在网页里用密码登录并自动推送公钥）"
		msg "             若密码也连不上，检查：本机能否 ping 通 $HOST、猫棒 SSH 是否开启"
	fi
fi
msg "  服务管理 : rc-service xe99s-webui {start|stop|restart}"
msg ""
msg "提示: 猫棒侧无需安装任何东西，只要开着 SSH 即可。"
msg "提示: 若网页能打开但登录报 404，说明是旧版安装包(CGI 放错了位置)，"
msg "      重新运行本脚本覆盖安装即可修复。"
