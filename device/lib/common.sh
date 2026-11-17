#!/bin/sh
# ============================================================================
#  XE-99S WebUI - 公共基础库 (POSIX sh / busybox ash 兼容)
#  提供: 路径、日志、JSON 构造、表单解析、令牌认证、输入校验
# ============================================================================

WEBUI_ROOT=${WEBUI_ROOT:-/userdata/webui}
WEBUI_ETC="$WEBUI_ROOT/etc"
WEBUI_VAR="$WEBUI_ROOT/var"
WEBUI_LIB="$WEBUI_ROOT/lib"
WEBUI_CONF="$WEBUI_ETC/webui.conf"
WEBUI_PASSWD="$WEBUI_ETC/passwd"
WEBUI_SECRET="$WEBUI_ETC/secret"
WEBUI_LOG="$WEBUI_VAR/webui.log"

mkdir -p "$WEBUI_VAR" "$WEBUI_VAR/tmp" "$WEBUI_VAR/backup" 2>/dev/null
NOW=$(date +%s 2>/dev/null || echo 0)

# ---------------------------------------------------------------- 配置读取 --
conf_get() {
	_k=$1; _d=$2
	if [ -r "$WEBUI_CONF" ]; then
		_v=$(awk -v k="$_k" '
			/^[[:space:]]*#/ { next }
			{
				i = index($0, "=")
				if (i < 2) next
				key = substr($0, 1, i - 1)
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
				if (key != k) next
				val = substr($0, i + 1)
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
				print val
				exit
			}' "$WEBUI_CONF")
		[ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
	fi
	printf '%s' "$_d"
}

log_msg() {
	# 只在日志文件可写且小于 256KB 时追加, 防止写满 overlay
	[ -w "$WEBUI_LOG" ] || return 0
	_sz=$(wc -c <"$WEBUI_LOG" 2>/dev/null || echo 0)
	[ "$_sz" -gt 262144 ] && : >"$WEBUI_LOG"
	printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$WEBUI_LOG"
}

# ---------------------------------------------------------------- JSON 输出 --
# 字符串转义: 反斜杠 / 双引号 / 制表 / 回车, 换行转字面量 \n
json_escape() {
	sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' -e 's/\r//g' |
		awk '{ printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }'
}

# jval 值 -> "带引号的转义字符串"
jval() {
	printf '"%s"' "$(printf '%s' "$1" | json_escape)"
}

# j_str 名称 值   ->  "名称":"值"
j_str() {
	printf '"%s":%s' "$1" "$(jval "$2")"
}

# jnum 值   ->  裸数字 (非数字输出 null)
jnum() {
	case $1 in
	'' | *[!0-9.-]*) printf 'null' ;;
	*) printf '%s' "$1" ;;
	esac
}

# j_num 名称 值   ->  "名称":数字  (非数字输出 null)
j_num() {
	printf '"%s":%s' "$1" "$(jnum "$2")"
}

# j_bool 名称 值(0/1)
j_bool() {
	if [ "$2" = "1" ]; then printf '"%s":true' "$1"; else printf '"%s":false' "$1"; fi
}

# ---------------------------------------------------------------- HTTP 层 --
http_head() {
	printf 'Content-Type: application/json; charset=utf-8\r\n'
	printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
	printf 'Pragma: no-cache\r\n'
	printf 'X-Content-Type-Options: nosniff\r\n'
	printf '\r\n'
}

# 输出统一响应体
# resp_ok '<json body>'   或   resp_err <code> <message>
resp_ok() {
	http_head
	printf '{"ok":true%s}\n' "$1"
	exit 0
}

resp_err() {
	http_head
	printf '{"ok":false,"error":%s,"message":%s}\n' "$(jval "$1")" "$(jval "$2")"
	log_msg WARN "api error: $1 $2"
	exit 0
}

# ---------------------------------------------------------------- 表单解析 --
# 前端统一以 application/x-www-form-urlencoded POST, 后端用 awk 解码为 %XX
FORM_FILE="$WEBUI_VAR/tmp/form.$$"
: >"$FORM_FILE"
trap 'rm -f "$FORM_FILE" "$FORM_FILE.raw"' EXIT

form_init() {
	[ -n "$CONTENT_LENGTH" ] || return 0
	case $CONTENT_LENGTH in '' | *[!0-9]*) return 0 ;; esac
	[ "$CONTENT_LENGTH" -le 65536 ] || return 0
	if command -v dd >/dev/null 2>&1; then
		_body=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
	else
		_body=$(head -c "$CONTENT_LENGTH")
	fi
	[ -n "$_body" ] || return 0
	# 末尾补换行, 否则不带换行的最后一个字段会被 read 丢掉
	{ printf '%s' "$_body" | tr '&' '\n'; echo; } >"$FORM_FILE.raw"
	while IFS= read -r _pair; do
		[ -n "$_pair" ] || continue
		_k=${_pair%%=*}
		_v=${_pair#*=}
		[ "$_k" = "$_pair" ] && _v=""
		_kd=$(urldecode "$_k")
		_vd=$(urldecode "$_v")
		# 键名只允许字母数字下划线
		case $_kd in '' | *[!A-Za-z0-9_]*) continue ;; esac
		case $_kd in *'
'*) continue ;; esac
		printf '%s=%s\n' "$_kd" "$_vd" >>"$FORM_FILE"
	done <"$FORM_FILE.raw"
}

urldecode() {
	printf '%s' "$1" | LC_ALL=C awk -f "$WEBUI_LIB/urldecode.awk"
}

form_get() {
	while IFS= read -r _line; do
		case $_line in
		"$1="*)
			printf '%s' "${_line#"$1="}"
			return 0
			;;
		esac
	done <"$FORM_FILE"
	return 0
}

form_has() {
	while IFS= read -r _line; do
		case $_line in "$1="*) return 0 ;; esac
	done <"$FORM_FILE"
	return 1
}

# ---------------------------------------------------------------- 认证 --
hash_str() {
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$1" | sha256sum | cut -d' ' -f1
	elif command -v openssl >/dev/null 2>&1; then
		printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.*= //'
	elif command -v md5sum >/dev/null 2>&1; then
		printf '%s' "$1" | md5sum | cut -d' ' -f1
	else
		# 最后兜底: 极弱, 仅保证功能可用
		printf '%s' "$1" | cksum | tr -d ' '
	fi
}

rand_hex() {
	if [ -r /dev/urandom ]; then
		dd if=/dev/urandom bs=1 count="${1:-16}" 2>/dev/null | od -An -tx1 | tr -d ' \n'
	fi
}

auth_secret() {
	if [ -r "$WEBUI_SECRET" ]; then
		cat "$WEBUI_SECRET"
	else
		_s=$(rand_hex 16)
		[ -n "$_s" ] || _s="$(date +%s)$$"
		printf '%s' "$_s" >"$WEBUI_SECRET"
		chmod 600 "$WEBUI_SECRET" 2>/dev/null
		printf '%s' "$_s"
	fi
}

# 生成令牌: 过期时间.签名
issue_token() {
	_exp=$(($(date +%s) + $(conf_get SESSION_TTL 3600)))
	_sig=$(hash_str "$(auth_secret)|$1|$_exp")
	printf '%s.%s' "$_exp" "$_sig"
}

token_valid() {
	_t=$1
	[ -n "$_t" ] || return 1
	_exp=${_t%%.*}
	_sig=${_t#*.}
	[ "$_exp" != "$_t" ] || return 1
	case $_exp in '' | *[!0-9]*) return 1 ;; esac
	[ "$_exp" -gt "$(date +%s)" ] || return 1
	_cur=$(hash_str "$(auth_secret)|$(conf_get WEBUI_USER admin)|$_exp")
	[ "$_sig" = "$_cur" ] || return 1
	return 0
}

require_auth() {
	_tok="$HTTP_X_AUTH_TOKEN"
	[ -n "$_tok" ] || _tok=$(form_get token)
	[ -n "$_tok" ] || _tok=$(printf '%s' "$QUERY_STRING" | tr '&' '\n' |
		awk '{
			i = index($0, "=")
			if (i < 2) next
			if (substr($0, 1, i - 1) == "token") { print substr($0, i + 1); exit }
		}')
	token_valid "$_tok" || resp_err need_auth "登录状态已失效，请重新登录"
}

# ---------------------------------------------------------------- 校验规则 --
# 逐字段白名单校验, 任何写入前必须过这一关
valid_mac() {
	case $1 in
	'') printf '%s' "00:00:00:00:00:00"; return 0 ;;
	esac
	printf '%s' "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' || return 1
	printf '%s' "$1" | tr 'a-f' 'A-F'
}

valid_ipv4() {
	printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
	_o=$(printf '%s' "$1" | tr '.' ' ')
	for _n in $_o; do [ "$_n" -le 255 ] || return 1; done
	printf '%s' "$1"
}

valid_text() {
	# 字符集 + 长度限制, 拒绝反引号/美元符/分号等 shell 元字符
	case $1 in *[\`\$\;\&\|\<\>\(\)\{\}\[\]\!\*\'\"\\]*) return 1 ;; esac
	_l=$(printf '%s' "$1" | wc -c)
	[ "$_l" -le "${2:-64}" ] || return 1
}

valid_enum() {
	case " $2 " in *" $1 "*) printf '%s' "$1" ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- 工具 --
bytes_human() {
	awk -v b="${1:-0}" 'BEGIN{
		split("B KB MB GB TB", u, " "); i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
	}'
}
