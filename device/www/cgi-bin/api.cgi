#!/bin/sh
# ============================================================================
#  XE-99S WebUI - API 入口 (busybox httpd CGI)
#  前端统一访问 /cgi-bin/api.cgi?r=<动作>
# ============================================================================

WEBUI_ROOT=$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)
export WEBUI_ROOT

. "$WEBUI_ROOT/lib/common.sh"
. "$WEBUI_ROOT/lib/transport.sh"
. "$WEBUI_ROOT/lib/device.sh"
. "$WEBUI_ROOT/lib/probe.sh"
. "$WEBUI_ROOT/lib/actions.sh"
[ "$WEBUI_MOCK" = "1" ] && . "$WEBUI_ROOT/lib/mock.sh"

# 取查询串中的键值 (仅取第一个)
qget() {
	printf '%s' "$QUERY_STRING" | tr '&' '\n' |
		awk -v k="$1" '{
			i = index($0, "=")
			if (i < 2) next
			if (substr($0, 1, i - 1) == k) { print substr($0, i + 1); exit }
		}'
}

REQ=${PATH_INFO##*/}
[ -n "$REQ" ] || REQ=$(qget r)
[ -n "$REQ" ] || REQ=$(printf '%s' "$QUERY_STRING" | sed -n 's/^r=\([a-z_]*\).*/\1/p')
case $REQ in '' | *[!a-z_]*) REQ="" ;; esac

form_init

# 远端模式(装在局域网小主机上, 经 TCP 连到猫棒): 每个请求先批量预取一次,
# 之后所有读操作命中本地缓存, 避免十几次往返。
#
# login / conn_* 不预取: 它们自己会按表单里的新地址重新连, 多连一次纯属浪费。
TR_OK=1
case $REQ in
login | logout | ping | conn_test | conn_save | conn_key | password) ;;
*) tr_prefetch || TR_OK=0 ;;
esac

# 依赖设备数据的接口: 连不上就明确报错, 不要返回一屏空值让用户猜
need_device() {
	[ "$TR_OK" = "1" ] && return 0
	resp_err device_unreachable "$(tr_conn_err)"
}

case $REQ in
login)
	act_login
	;;
logout)
	act_logout
	;;
status)
	require_auth
	need_device
	act_status
	;;
config)
	require_auth
	need_device
	act_config
	;;
set)
	require_auth
	need_device
	act_set
	;;
password)
	require_auth
	act_password
	;;
action)
	require_auth
	need_device
	act_action
	;;
diag)
	require_auth
	need_device
	_d=$(qget cmd)
	case $_d in '' | *[!a-z_]*) _d="help" ;; esac
	act_diag "$_d"
	;;
mtd)
	require_auth
	need_device
	act_mtd
	;;
conn)
	require_auth
	act_conn
	;;
conn_test)
	require_auth
	act_conn_test
	;;
conn_save)
	require_auth
	act_conn_save
	;;
conn_key)
	require_auth
	act_conn_key
	;;
probe)
	require_auth
	# 重新探测: 清缓存后重跑, 结果供系统页展示
	probe_dirs
	rm -f "$PROBE_CACHE" 2>/dev/null
	act_probe
	;;
probe_cached)
	require_auth
	act_probe
	;;
ping)
	resp_ok ",$(j_str version "$(conf_get WEBUI_VERSION 1.0.0)")"
	;;
"")
	resp_err bad_request "缺少 r 参数"
	;;
*)
	resp_err not_found "未知接口：$REQ"
	;;
esac
