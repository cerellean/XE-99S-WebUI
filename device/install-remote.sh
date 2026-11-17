#!/bin/sh
# ============================================================================
#  设备端安装脚本 (在光猫棒上以 root 运行)
#  通常由 PC 侧的 install.sh 自动调用, 也可手动执行:
#     sh /userdata/webui/install-remote.sh
# ============================================================================

set -u
ROOT=$(cd "$(dirname "$0")" && pwd)
echo "== XE-99S WebUI 安装 =="
echo "目标目录: $ROOT"

# ---------------------------------------------------------------- 权限 --
chmod +x "$ROOT/www/cgi-bin/"*.cgi 2>/dev/null
chmod +x "$ROOT/init.d/S99webui" 2>/dev/null
mkdir -p "$ROOT/var/tmp" "$ROOT/var/backup"

# ------------------------------------------------------------ 固件识别 --
# 本控制台只支持原厂 Package-C; 这里只做提示, 行为差异交给 probe.sh 实测
FW_NOTE="未能识别(不影响使用, 可在 WebUI「环境自检」查看详情)"
if grep -qiE 'SIEPON|CTC' /etc/version /etc/VERSION /etc/siepon_version /etc/fw_version 2>/dev/null; then
	FW_NOTE="SIEPON Package-C (原厂 CTC 固件)"
elif grep -qiE 'SIEPON[_-]?A|siepon_a' /etc/version /etc/siepon_version /etc/fw_version 2>/dev/null; then
	FW_NOTE="SIEPON Package-A (自定义固件) —— 本控制台按原厂固件校准, 部分能力可能与它不一致"
fi
echo "固件类型: $FW_NOTE"
echo "  写入位置/可用工具以 WebUI「系统 → 环境自检」实测结果为准"

# ---------------------------------------------------------------- 账号 --
if [ ! -f "$ROOT/etc/passwd" ]; then
	_s=$( (dd if=/dev/urandom bs=1 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n') )
	[ -n "$_s" ] || _s="$(date +%s)$$"
	_p="admin"
	# 计算 hash: 优先 sha256sum
	if command -v sha256sum >/dev/null 2>&1; then
		_h=$(printf '%s' "$_s$_p" | sha256sum | cut -d' ' -f1)
	elif command -v md5sum >/dev/null 2>&1; then
		_h=$(printf '%s' "$_s$_p" | md5sum | cut -d' ' -f1)
	else
		_h=$(printf '%s' "$_s$_p" | cksum | tr -d ' ')
	fi
	printf 'admin:%s:%s\n' "$_s" "$_h" >"$ROOT/etc/passwd"
	chmod 600 "$ROOT/etc/passwd"
	echo "已创建默认账号: admin / admin"
else
	echo "账号文件已存在, 保留原密码"
fi

[ -f "$ROOT/etc/secret" ] || {
	dd if=/dev/urandom bs=1 count=16 2>/dev/null | od -An -tx1 | tr -d ' \n' >"$ROOT/etc/secret" 2>/dev/null
	[ -s "$ROOT/etc/secret" ] || date +%s%N >"$ROOT/etc/secret"
	chmod 600 "$ROOT/etc/secret"
}

# ---------------------------------------------------------------- httpd --
if ! command -v busybox >/dev/null 2>&1; then
	echo "警告: 未找到 busybox, 若系统自带 httpd 请在其配置中指向 $ROOT/www"
fi
if command -v busybox >/dev/null 2>&1 && ! busybox httpd --help >/dev/null 2>&1; then
	echo "警告: busybox 未编译 httpd 组件, WebUI 可能无法启动"
fi

# ---------------------------------------------------------------- 启动 --
"$ROOT/init.d/S99webui" stop >/dev/null 2>&1
"$ROOT/init.d/S99webui" start

PORT=$(sed -n 's/^PORT=\([0-9]*\).*/\1/p' "$ROOT/etc/webui.conf" 2>/dev/null | head -n1)
PORT=${PORT:-8080}

# ------------------------------------------------------------ 开机自启 --
AUTOSTART="no"
if [ -d /etc/init.d ] && [ -w /etc/init.d ]; then
	cp -f "$ROOT/init.d/S99webui" /etc/init.d/S99webui 2>/dev/null
	chmod +x /etc/init.d/S99webui 2>/dev/null
	# 若 rcS 存在且以 S.. 顺序执行, 建软链或直接放入即可
	if [ -d /etc/rcS.d ] && [ ! -e /etc/rcS.d/S99webui ]; then
		ln -sf /etc/init.d/S99webui /etc/rcS.d/S99webui 2>/dev/null
	fi
	AUTOSTART="yes(/etc/init.d)"
elif [ -f /etc/rc.local ] && [ -w /etc/rc.local ]; then
	if ! grep -q "userdata/webui/init.d/S99webui" /etc/rc.local 2>/dev/null; then
		printf '\n[ -x /userdata/webui/init.d/S99webui ] && /userdata/webui/init.d/S99webui start\n' >>/etc/rc.local
	fi
	AUTOSTART="yes(/etc/rc.local)"
fi

# ---------------------------------------------------------------- 结果 --
IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{ sub(/\/.*/, "", $2); print $2; exit }')
[ -n "$IP" ] || IP=$(ifconfig eth0 2>/dev/null | awk '/inet addr:/{ sub(/.*inet addr:/, ""); sub(/ .*/, ""); print; exit }')
[ -n "$IP" ] || IP=192.168.0.1

echo
echo "安装完成"
echo "  访问地址 : http://$IP:$PORT"
echo "  默认账号 : admin / admin  (请立即在「系统」页修改)"
echo "  开机自启 : $AUTOSTART"
echo "  服务管理 : $ROOT/init.d/S99webui {start|stop|restart|status}"
echo "  日志     : $ROOT/var/webui.log"

# ------------------------------------------------------------ 自检摘要 --
# 直接在终端给出探测结果, 免去先开浏览器才能确认写入路径的麻烦。
# 整段放在子 shell 里并关掉 -u, 探测失败不影响安装结果。
(
	set +u
	WEBUI_ROOT=$ROOT
	export WEBUI_ROOT
	. "$ROOT/lib/common.sh" 2>/dev/null || exit 0
	. "$ROOT/lib/device.sh" 2>/dev/null || exit 0
	. "$ROOT/lib/probe.sh" 2>/dev/null || exit 0
	probe_all >/dev/null 2>&1 || exit 0
	echo
	echo "环境自检（与 WebUI「系统 → 环境自检」同源）"
	printf '  应用版本 : %s\n' "$(probe_get fw_version)"
	printf '  固件构建 : %s\n' "$(probe_get fw_build)"
	printf '  配置读入 : %s\n' "$(probe_get read_targets)"
	printf '  配置写入 : %s\n' "$(probe_get write_targets)"
	printf '  iROS     : %s (port_id=%s)\n' "$(probe_get iros_cmd)" "$(probe_get port_id)"
	printf '  可用工具 : %s\n' "$(probe_get tools)"
)

