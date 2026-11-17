#!/bin/sh
# ============================================================================
#  transport.sh  —  设备访问传输层
#
#  两种运行形态, 同一套 device.sh / probe.sh:
#    ① 本机模式  WEBUI_REMOTE=0  直接装在猫棒上, 所有操作在本机执行
#    ② 远端模式  WEBUI_REMOTE=1  装在局域网内的小主机上, 经 TCP 连到猫棒的
#                                SSH/Telnet 端口, 所有设备操作转发过去执行。
#                                猫棒侧零安装、零改动。
#
#  做法: 把"读文件、写文件、跑命令、探测能力"收敛成 4 个原语, 其余解析逻辑
#  (awk) 全部留在本地。远端只做字节搬运, 不存在两套解析器行为不一致的问题。
#
#  性能: 每个请求开始时用一次往返批量预取(tr_prefetch), 之后读操作全部命中
#  本地缓存; 写操作每文件 2 次往返(写 + 回读)。配合 SSH 连接复用, 单次请求
#  通常 2~4 次往返。
#
#  可靠性(跨网络访问的必要条件):
#    - 连接失败不再被静默吞掉: 退出码与 stderr 首行落到 state, 前端据此显示
#      "连不上/认证失败/命令报错", 而不是让页面只剩一列横杠。
#    - 缓存按进程隔离, 多人同时开页面不会互相清空; SSH 复用 socket 单独存放,
#      不会被缓存清理误删。
# ============================================================================

WEBUI_REMOTE=${WEBUI_REMOTE:-0}
# 地址默认留空: 远端模式下"空"表示还没配过, 由首次登录后的引导界面填写。
# 不能让默认值假装是 192.168.0.1, 否则用户改了猫棒地址会表现为"莫名连不上"。
REMOTE_HOST=${REMOTE_HOST:-}
REMOTE_PORT=${REMOTE_PORT:-22}
REMOTE_USER=${REMOTE_USER:-root}
REMOTE_KEY=${REMOTE_KEY:-}
REMOTE_PASS=${REMOTE_PASS:-}
REMOTE_TRANSPORT=${REMOTE_TRANSPORT:-ssh}
# 认证方式: key | pass | 空=自动(有私钥用私钥, 否则用密码)
REMOTE_AUTH=${REMOTE_AUTH:-}
TR_TIMEOUT=${TR_TIMEOUT:-8}

# busybox httpd 启动的 CGI 不继承自定义环境变量, 所以配置必须从文件读。
# install-alpine.sh 与系统页「设备连接」都写这个文件; 本机模式没有它。
#
# 刻意不用 source: 密码里可能有 $ ` " 等字符, 交给 shell 解释会被执行或截断。
# 这里按键名词白名单逐行赋值, 值原样保留(含空格), 不存在注入面。
tr_conf_load() {
	[ -r "$WEBUI_ETC/remote.conf" ] || return 0
	while IFS= read -r _cl || [ -n "$_cl" ]; do
		case $_cl in '' | '#'*) continue ;; esac
		_clk=${_cl%%=*}
		_clv=${_cl#*=}
		case $_clk in
		WEBUI_REMOTE) WEBUI_REMOTE=$_clv ;;
		REMOTE_HOST) REMOTE_HOST=$_clv ;;
		REMOTE_PORT) REMOTE_PORT=$_clv ;;
		REMOTE_USER) REMOTE_USER=$_clv ;;
		REMOTE_KEY) REMOTE_KEY=$_clv ;;
		REMOTE_PASS) REMOTE_PASS=$_clv ;;
		REMOTE_TRANSPORT) REMOTE_TRANSPORT=$_clv ;;
		REMOTE_AUTH) REMOTE_AUTH=$_clv ;;
		esac
	done <"$WEBUI_ETC/remote.conf"
	return 0
}
tr_conf_load

# 远端模式下是否已经填过设备地址。没填过就不发起任何网络操作(否则每次请求
# 都要等一次 DNS/连接超时, 页面会卡十几秒)。
tr_configured() {
	[ "$WEBUI_REMOTE" = "1" ] || return 0
	[ -n "$REMOTE_HOST" ]
}

# 可用的私钥: 配置里显式指定的优先, 否则找安装脚本生成的默认位置
tr_key_file() {
	if [ -n "$REMOTE_KEY" ] && [ -r "$REMOTE_KEY" ]; then
		printf '%s' "$REMOTE_KEY"
		return 0
	fi
	for _kf in "$WEBUI_ETC/id_ed25519" /etc/xe99s-webui/id_ed25519 /root/.ssh/id_ed25519; do
		[ -r "$_kf" ] && { printf '%s' "$_kf"; return 0; }
	done
	return 1
}

# 本次请求用哪种认证。显式配置优先, 否则"有私钥走密钥、没有走密码"。
tr_auth_mode() {
	case $REMOTE_AUTH in
	key | pass) printf '%s' "$REMOTE_AUTH"; return 0 ;;
	esac
	[ -n "$(tr_key_file)" ] && printf 'key' || printf 'pass'
}

# 环境能力探测: 界面据此提前提示"缺 sshpass, 只能用密钥/需要先装"
tr_ssh_ok() { command -v ssh >/dev/null 2>&1 && printf 1 || printf 0; }
tr_sshpass_ok() { command -v sshpass >/dev/null 2>&1 && printf 1 || printf 0; }

# 保存连接配置。写入格式与 tr_conf_load 对应: 裸 KEY=VALUE, 不做任何引号包裹,
# 所以值里出现 $ ` " ' 都不会有问题(只要没有换行)。
tr_conf_save() {
	local _h _p _u _pw _k _t _a _tmp
	_h=$1; _p=$2; _u=$3; _pw=$4; _k=$5; _t=$6; _a=${7:-}
	mkdir -p "$WEBUI_ETC" 2>/dev/null || return 1
	_tmp="$WEBUI_ETC/remote.conf.tmp.$$"
	{
		echo "# 由 WebUI「系统 → 设备连接」生成；也可手工编辑后重启服务"
		echo "# 格式为裸 KEY=VALUE，由 transport.sh 按键名白名单解析，不做 shell 展开"
		echo "WEBUI_REMOTE=1"
		printf 'REMOTE_HOST=%s\n' "$_h"
		printf 'REMOTE_PORT=%s\n' "$_p"
		printf 'REMOTE_USER=%s\n' "$_u"
		printf 'REMOTE_TRANSPORT=%s\n' "$_t"
		printf 'REMOTE_AUTH=%s\n' "$_a"
		printf 'REMOTE_KEY=%s\n' "$_k"
		printf 'REMOTE_PASS=%s\n' "$_pw"
	} >"$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
	chmod 600 "$_tmp" 2>/dev/null
	mv -f "$_tmp" "$WEBUI_ETC/remote.conf" 2>/dev/null || { rm -f "$_tmp"; return 1; }
	# 让本次请求立即使用新地址(保存后马上测试连接)
	WEBUI_REMOTE=1
	REMOTE_HOST=$_h
	REMOTE_PORT=$_p
	REMOTE_USER=$_u
	REMOTE_PASS=$_pw
	REMOTE_KEY=$_k
	REMOTE_TRANSPORT=$_t
	REMOTE_AUTH=$_a
	return 0
}

# 缓存按进程隔离: 两个浏览器同时刷新时各读各的, 不会读到别人清空的目录
TR_CACHE="$WEBUI_VAR/cache/$$"
# SSH 复用 socket 必须跨请求存活, 不能放在按请求清理的缓存目录里
TR_SOCK="$WEBUI_VAR/sock"
TR_BACKUP="$WEBUI_VAR/backup"
TR_STATE=""

tr_remote() { [ "$WEBUI_REMOTE" = "1" ]; }

# 远端绝对路径 -> 本地缓存文件名
tr_cache_path() {
	[ -n "$TR_STATE" ] || tr_cache_init
	printf '%s/%s' "$TR_CACHE" "$(printf '%s' "$1" | tr '/' '_')"
}

# ------------------------------------------------------------ 缓存目录管理 --
tr_cache_init() {
	TR_STATE=""
	[ "$WEBUI_REMOTE" = "1" ] || return 0
	mkdir -p "$TR_CACHE" "$TR_SOCK" "$TR_BACKUP" 2>/dev/null
	TR_STATE="$TR_CACHE/state.idx"
	: >"$TR_STATE" 2>/dev/null
	# 清掉已结束进程留下的缓存。按 PID 判断而不是时间戳, 不依赖 find 的 -mmin
	for _d in "$WEBUI_VAR"/cache/*; do
		[ -d "$_d" ] || continue
		[ "$_d" = "$TR_CACHE" ] && continue
		_pid=${_d##*/}
		case $_pid in '' | *[!0-9]*) rm -rf "$_d" 2>/dev/null; continue ;; esac
		kill -0 "$_pid" 2>/dev/null || rm -rf "$_d" 2>/dev/null
	done
	return 0
}

# state 读写: 供 device.sh / probe.sh 查询
tr_state_set() {
	[ -n "$TR_STATE" ] || tr_cache_init
	printf '%s=%s\n' "$1" "$2" >>"$TR_STATE" 2>/dev/null
}

tr_state_get() {
	[ -n "$TR_STATE" ] || tr_cache_init
	[ -f "$TR_STATE" ] || return 1
	awk -v k="$1" '
		{ i = index($0, "="); if (i < 2) next
		  if (substr($0, 1, i - 1) == k) { last = substr($0, i + 1); found = 1 } }
		END { if (!found) exit 1; print last }' "$TR_STATE" 2>/dev/null
}

# --------------------------------------------------------------- SSH 封装 --
tr_ssh_opts() {
	_o="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
	_o="$_o -o ConnectTimeout=4 -o LogLevel=ERROR"
	# 网络半断(主机在线但不回包)时不让请求无限挂住
	_o="$_o -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o ConnectionAttempts=1"
	# 连接复用: 一次请求内多次往返只握一次手, 60 秒内跨请求也复用
	_o="$_o -o ControlMaster=auto -o ControlPath=$TR_SOCK/cm-%r@%h:%p -o ControlPersist=60"
	printf '%s' "$_o"
}

# 密钥方式: 只试密钥, 不许回落到密码——否则密码错/密钥错会互相掩盖
tr_ssh_key() {
	_trk_k=$1
	shift
	ssh -p "$REMOTE_PORT" -i "$_trk_k" -o IdentitiesOnly=yes -o BatchMode=yes \
		$(tr_ssh_opts) "$REMOTE_USER@$REMOTE_HOST" "$@"
}

# 密码方式: 猫棒默认密码登录, 需要 sshpass 代填(OpenSSH 不支持管道喂密码)
tr_ssh_pass() {
	command -v sshpass >/dev/null 2>&1 || {
		echo "tr: 密码登录需要 sshpass (apk add sshpass)" >&2
		return 127
	}
	SSHPASS="$REMOTE_PASS" sshpass -e ssh -p "$REMOTE_PORT" \
		-o NumberOfPasswordPrompts=1 -o PreferredAuthentications=password,keyboard-interactive \
		$(tr_ssh_opts) "$REMOTE_USER@$REMOTE_HOST" "$@"
}

# 统一远端执行入口。$@ 原样交给远端 sh。
# 认证方式只由 tr_auth_mode 决定, 一次请求只发一次连接, 失败能被准确归类。
tr_ssh() {
	_trk_mode=$(tr_auth_mode)
	if [ "$_trk_mode" = "key" ]; then
		_trk_kf=$(tr_key_file)
		if [ -n "$_trk_kf" ]; then
			tr_ssh_key "$_trk_kf" "$@"
			return $?
		fi
		# 配置说用密钥但文件没了: 有密码就退回密码, 没有就只能报错
		[ -n "$REMOTE_PASS" ] || {
			echo "tr: 找不到私钥文件，请重新填写密码或指定私钥路径" >&2
			return 1
		}
	fi
	[ -n "$REMOTE_PASS" ] || {
		echo "tr: 尚未设置密码" >&2
		return 1
	}
	tr_ssh_pass "$@"
}

# 用当前密码把本地公钥推到猫棒, 之后免密登录(密码只在首次需要)。
# 返回 0 成功 / 1 失败 / 2 缺 sshpass / 3 没有密钥
tr_push_key() {
	tr_remote || return 1
	_trpk_kf=$(tr_key_file) || return 3
	[ -f "$_trpk_kf.pub" ] || return 3
	command -v sshpass >/dev/null 2>&1 || return 2
	[ -n "$REMOTE_PASS" ] || return 1
	# 只取 "类型 base64" 两段, 丢掉注释, 保证嵌进远端脚本时不含引号
	_trpk_pub=$(cut -d' ' -f1,2 "$_trpk_kf.pub" 2>/dev/null)
	[ -n "$_trpk_pub" ] || return 3

	_trpk_script='p="'"$_trpk_pub"'"
for d in /root/.ssh /etc/dropbear /userdata/.ssh /overlay/upper/root/.ssh; do
	mkdir -p "$d" 2>/dev/null || continue
	[ -w "$d" ] || continue
	f="$d/authorized_keys"
	grep -qF "$p" "$f" 2>/dev/null || printf "%s\n" "$p" >>"$f" 2>/dev/null || continue
	chmod 700 "$d" 2>/dev/null
	chmod 600 "$f" 2>/dev/null
	printf "KEYOK:%s\n" "$d"
	exit 0
done
exit 1'

	SSHPASS="$REMOTE_PASS" sshpass -e ssh -p "$REMOTE_PORT" \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=6 -o LogLevel=ERROR -o NumberOfPasswordPrompts=1 \
		"$REMOTE_USER@$REMOTE_HOST" "$_trpk_script" 2>/dev/null | grep -q '^KEYOK:' || return 1

	# 推完自己验一次: 免密能连上才算真的成功。
	# 刻意不共用 ControlMaster, 否则刚建好的密码连接会让校验假通过。
	ssh -p "$REMOTE_PORT" -i "$_trpk_kf" -o IdentitiesOnly=yes -o BatchMode=yes \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=6 -o ControlPath=none -o LogLevel=ERROR \
		"$REMOTE_USER@$REMOTE_HOST" "echo __KEYOK__" 2>/dev/null | grep -q __KEYOK__ || return 1
	return 0
}


# ------------------------------------------------------------- Telnet 降级 --
# 猫棒原厂固件同时开着 telnet(root/admin)。telnet 没有退出码, 只能靠 expect
# 做提示符同步, 因此标注为实验性: 只支持"不含单引号"的命令(内部命令统一用
# 双引号包路径来满足这一约束)。
tr_telnet() {
	command -v expect >/dev/null 2>&1 || {
		echo "tr: telnet 后端需要 expect (apk add expect)" >&2
		return 1
	}
	expect -c "
	set timeout 15
	log_user 0
	spawn telnet $REMOTE_HOST $REMOTE_PORT
	expect {
		-re \"(?i)(login|username)\" { send \"$REMOTE_USER\r\"; exp_continue }
		-re \"(?i)password\"        { send \"$REMOTE_PASS\r\"; exp_continue }
		-re {\# |\\\$ }             { }
		timeout { puts stderr \"telnet 登录超时\"; exit 1 }
	}
	send \"sh -c '$*' 2>&1; echo __TR_END__\r\"
	log_user 1
	expect {
		-re \"__TR_END__\" { }
		timeout { puts stderr \"telnet 执行超时\"; exit 1 }
	}
	catch close
	exit 0
" 2>/dev/null | tr -d '\r' | sed '/__TR_END__/d'
}

tr_exec() {
	if [ "$REMOTE_TRANSPORT" = "telnet" ]; then
		tr_telnet "$@"
	else
		tr_ssh "$@"
	fi
}

# --------------------------------------------------------------- 预取清单 --
# 一次请求内可能读到的全部文件。多取几个不存在的代价极小(远端 test 一下),
# 漏取会导致读到空值, 所以宁可宽一点。
tr_file_list() {
	cat <<'TR_FILES'
/config/scfg.txt
/userdata/scfg.txt
/config/default_scfg.txt
/overlay/upper/config/scfg.txt
/etc/network/interfaces
/userdata/network/interfaces
/etc/8271version
/etc/version
/etc/VERSION
/etc/siepon_version
/etc/ca-iros.rc
/proc/mtd
/proc/uptime
/proc/meminfo
/proc/net/dev
/proc/net/route
/proc/net/tcp
/proc/version
/proc/loadavg
/proc/sys/kernel/hostname
/sys/class/net/eth0/statistics/rx_bytes
/sys/class/net/eth0/statistics/tx_bytes
/sys/class/net/eth0/speed
/sys/class/net/eth0/address
TR_FILES
}

tr_dir_list() {
	cat <<'TR_DIRS'
/config
/userdata
/overlay
/overlay/upper
/overlay/upper/config
/overlay/upper/etc
/userdata/upper
/userdata/upper/config
/userdata/upper/etc
/etc/network
TR_DIRS
}

tr_cmd_list() {
	echo "iros ca-iros timeout strings nanddump flash_erase mtd_debug fw_setenv fw_printenv ip ifconfig ethtool"
}

# ---------------------------------------------------------------- 预取执行 --
# 远端输出分段标记, 本地拆成缓存文件 + 状态索引:
#   @@@FILE:<path> ...内容... @@@END
#   @@@D:<dir>:0|1   目录可写
#   @@@C:<cmd>:0|1   命令存在
tr_prefetch() {
	tr_remote || return 0

	# 还没填地址: 直接短路。这里绝不能去连, 否则每次刷新页面都要等一次
	# DNS/连接超时, 而且"连不上"会盖住"还没配置"这个更准确的原因。
	if ! tr_configured; then
		tr_cache_init
		tr_conn_record 1 "$(tr_now)" "" unconfigured
		return 1
	fi

	tr_cache_init

	_files=$(tr_file_list | tr '\n' ' ')
	_dirs=$(tr_dir_list | tr '\n' ' ')
	_cmds=$(tr_cmd_list)

	_err="$TR_CACHE/.stderr"
	_raw="$TR_CACHE/.raw"
	_ms0=$(tr_now)

	tr_exec sh -s -- $_files __SEP__ $_dirs __SEP__ $_cmds <<'TR_SCRIPT' >"$_raw" 2>"$_err"
mode=file
for a in "$@"; do
	if [ "$a" = "__SEP__" ]; then
		if [ "$mode" = "file" ]; then mode=dir; else mode=cmd; fi
		continue
	fi
	if [ "$mode" = "file" ]; then
		[ -r "$a" ] || continue
		printf '@@@FILE:%s\n' "$a"
		cat "$a" 2>/dev/null
		printf '\n@@@END\n'
	elif [ "$mode" = "dir" ]; then
		w=0
		[ -d "$a" ] && [ -w "$a" ] && w=1
		printf '@@@D:%s:%s\n' "$a" "$w"
	else
		c=0
		command -v "$a" >/dev/null 2>&1 && c=1
		printf '@@@C:%s:%s\n' "$a" "$c"
	fi
done
TR_SCRIPT
	_rc=$?

	tr_conn_record "$_rc" "$_ms0" "$_err"

	if [ "$_rc" != "0" ]; then
		# 连不上: 保留错误信息供页面展示, 不假装设备是空的
		: >"$_raw" 2>/dev/null
		rm -f "$_err" 2>/dev/null
		return 1
	fi

	_tr_split <"$_raw"
	rm -f "$_raw" "$_err" 2>/dev/null
	return 0
}

# 毫秒时间戳; busybox 的 date 不保证支持 %N, 因此退化到秒级
tr_now() {
	_n=$(date +%s%N 2>/dev/null)
	case $_n in
	'' | *[!0-9]*) printf '%s000' "$(date +%s 2>/dev/null)" ;;
	*) printf '%s' "$((_n / 1000000))" ;;
	esac
}

# 把一次连接的结果记到 state, 并把 ssh 的 stderr 归类成人话
tr_conn_record() {
	_rc=$1
	_ms0=$2
	_errf=$3
	_reason=${4:-}
	_ok=0
	_msg=""

	if [ "$_rc" = "0" ]; then
		_ok=1
	elif [ "$_reason" = "unconfigured" ]; then
		_msg="尚未配置猫棒地址"
	else
		_e=$(sed -n '1p' "$_errf" 2>/dev/null | tr -d '\r' | cut -c1-200)
		case $_e in
		*"Permission denied"* | *"Authentication failed"* | *"auth"*)
			_msg="认证失败：用户名或密码/密钥不正确"
			;;
		*"Connection timed out"* | *"Operation timed out"* | *"timed out"*)
			_msg="连接超时：$REMOTE_HOST:$REMOTE_PORT 无响应（设备离线或地址不对）"
			;;
		*"Connection refused"*)
			_msg="连接被拒绝：$REMOTE_HOST:$REMOTE_PORT 未开放（SSH 服务未启动）"
			;;
		*"No route to host"* | *"Network is unreachable"*)
			_msg="网络不可达：本机到 $REMOTE_HOST 没有路由（网段/网关不对）"
			;;
		*"Host key verification failed"*)
			_msg="主机密钥校验失败，请清理 known_hosts 后重试"
			;;
		*"Could not resolve"* | *"Name or service not known"*)
			_msg="主机名无法解析：$REMOTE_HOST"
			;;
		*"telnet 登录超时"*)
			_msg="Telnet 登录超时：$REMOTE_HOST:$REMOTE_PORT"
			;;
		*)
			if [ -n "$_e" ]; then
				_msg="执行失败（rc=$_rc）：$_e"
			elif [ "$_rc" = "255" ]; then
				# ssh 只给退出码不给输出时, 255 基本就是连不上或认证不过
				_msg="SSH 连接失败（rc=255）：$REMOTE_HOST:$REMOTE_PORT 不可达，或认证被拒绝"
			elif [ "$_rc" = "127" ]; then
				_msg="远端缺少执行的命令（rc=127）"
			else
				_msg="执行失败（rc=$_rc），无错误输出"
			fi
			;;
		esac
	fi

	_ms=$(($(tr_now) - _ms0))
	[ "$_ms" -ge 0 ] 2>/dev/null || _ms=0
	tr_state_set conn_ok "$_ok"
	tr_state_set conn_ms "$_ms"
	tr_state_set conn_err "$_msg"
	tr_state_set conn_host "$REMOTE_HOST:$REMOTE_PORT"
	tr_state_set conn_at "$(date +%s 2>/dev/null)"
}

# 供 probe/状态页查询
tr_conn_ok() { tr_state_get conn_ok 2>/dev/null || printf '0'; }
tr_conn_err() { tr_state_get conn_err 2>/dev/null; }
tr_conn_ms() { tr_state_get conn_ms 2>/dev/null; }

# 独立的一次连通性测试(系统页「测试连接」按钮用), 不依赖预取
tr_conn_test() {
	tr_remote || { printf 'local'; return 0; }
	tr_cache_init
	if ! tr_configured; then
		tr_conn_record 1 "$(tr_now)" "" unconfigured
		printf 'fail'
		return 1
	fi
	_err="$TR_CACHE/.ctest"
	_ms0=$(tr_now)
	tr_exec "echo __OK__" >"$TR_CACHE/.cout" 2>"$_err"
	_rc=$?
	if [ "$_rc" = "0" ] && grep -q __OK__ "$TR_CACHE/.cout" 2>/dev/null; then
		tr_conn_record 0 "$_ms0" "$_err"
		rm -f "$_err" "$TR_CACHE/.cout" 2>/dev/null
		printf 'ok'
		return 0
	fi
	tr_conn_record "$_rc" "$_ms0" "$_err"
	rm -f "$_err" "$TR_CACHE/.cout" 2>/dev/null
	printf 'fail'
	return 1
}

# 把标记流拆成缓存文件
_tr_split() {
	awk -v dir="$TR_CACHE" -v state="$TR_STATE" '
		/^@@@FILE:/ {
			p = substr($0, 9)
			gsub(/\//, "_", p)
			cur = dir "/" p
			next
		}
		/^@@@END$/ { cur = ""; next }
		/^@@@D:/ {
			sub(/^@@@D:/, "")
			i = index($0, ":")
			if (i > 1) printf "dir:%s=%s\n", substr($0, 1, i - 1), substr($0, i + 1) >> state
			next
		}
		/^@@@C:/ {
			sub(/^@@@C:/, "")
			i = index($0, ":")
			if (i > 1) printf "cmd:%s=%s\n", substr($0, 1, i - 1), substr($0, i + 1) >> state
			next
		}
		cur != "" { print > cur }
	' 2>/dev/null
}

# 传输时为分隔标记补了一个换行, 这里统一规整成"末尾无空行"。
# 幂等, 因此反复"读-改-写"不会让文件越来越长。
_tr_normalize() {
	for _f in "$TR_CACHE"/_*; do
		[ -f "$_f" ] || continue
		awk 'BEGIN { b = 0 }
			/^[[:space:]]*$/ { b++; next }
			{ while (b > 0) { print ""; b-- } print }' "$_f" >"$_f.n" 2>/dev/null &&
			mv -f "$_f.n" "$_f"
	done
}

# ---------------------------------------------------------------- 读: 文件 --
tr_cat() {
	if ! tr_remote; then
		cat "$1" 2>/dev/null
		return $?
	fi
	_p=$(tr_cache_path "$1")
	if [ -f "$_p" ]; then
		cat "$_p"
		return 0
	fi
	# 清单外文件: 现场补取一次
	tr_exec "cat \"$1\" 2>/dev/null" && return 0
	return 1
}

tr_exists() {
	if ! tr_remote; then
		[ -e "$1" ]
		return $?
	fi
	[ -f "$(tr_cache_path "$1")" ] || tr_cat "$1" >/dev/null 2>&1
}

tr_dir_writable() {
	if ! tr_remote; then
		[ -d "$1" ] && [ -w "$1" ]
		return $?
	fi
	_v=$(tr_state_get "dir:$1" 2>/dev/null)
	[ -n "$_v" ] && { [ "$_v" = "1" ]; return $?; }
	[ -d "$1" ] && [ -w "$1" ]
}

tr_has_cmd() {
	if ! tr_remote; then
		command -v "$1" >/dev/null 2>&1
		return $?
	fi
	# 已经连不上就别再逐个探测了, 每个都要等一次超时
	if [ -n "$TR_STATE" ] && [ -f "$TR_STATE" ] && grep -q '^conn_ok=0' "$TR_STATE" 2>/dev/null; then
		return 1
	fi
	_v=$(tr_state_get "cmd:$1" 2>/dev/null)
	[ -n "$_v" ] && { [ "$_v" = "1" ]; return $?; }
	command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------- 写: 文件 --
# 从 stdin 写远端文件; 先写临时名再 mv, 避免留下写一半的配置。
tr_write() {
	if ! tr_remote; then
		cat >"$1.wtmp.$$" && mv -f "$1.wtmp.$$" "$1"
		return $?
	fi
	if [ -n "$TR_STATE" ] && [ -f "$TR_STATE" ] && grep -q '^conn_ok=0' "$TR_STATE" 2>/dev/null; then
		return 1
	fi
	tr_exec "cat > \"$1.wtmp.\$\$\" && mv -f \"$1.wtmp.\$\$\" \"$1\""
}

# 备份: 内容已在本地缓存里, 直接存到本机, 不占猫棒 flash
tr_backup() {
	_p=$(tr_cache_path "$1")
	[ -f "$_p" ] || return 0
	_b="$TR_BACKUP/$(basename "$1").$(date +%s)"
	cp -f "$_p" "$_b" 2>/dev/null || return 1
	log_msg INFO "backup $1 -> $_b"
	return 0
}

# ---------------------------------------------------------------- 执行命令 --
# 命令字符串由调用方构造, 只含内部常量与已校验的值, 不含原始用户输入。
tr_run() {
	if ! tr_remote; then
		sh -c "$1" 2>/dev/null
		return $?
	fi
	if [ -n "$TR_STATE" ] && [ -f "$TR_STATE" ] && grep -q '^conn_ok=0' "$TR_STATE" 2>/dev/null; then
		return 1
	fi
	tr_exec "$1"
}

# 整份 uboot 环境一次取回, 后续 env_get 全部本地解析(避免每键一次往返)
tr_fetch_env() {
	tr_remote || return 0
	[ -s "$TR_CACHE/.env" ] && return 0
	tr_exec 'fw_printenv 2>/dev/null' >"$TR_CACHE/.env" 2>/dev/null
	return 0
}

tr_env_dump() {
	if tr_remote; then
		tr_fetch_env
		cat "$TR_CACHE/.env" 2>/dev/null
	else
		fw_printenv 2>/dev/null
	fi
}

# 写入后刷新单文件缓存
tr_refresh() {
	tr_remote || return 0
	tr_exec "cat \"$1\" 2>/dev/null" >"$(tr_cache_path "$1")" 2>/dev/null
	return 0
}
