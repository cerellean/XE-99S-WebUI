#!/bin/sh
# Alpine 依赖判定回归: 重点验证"只有 busybox 不等于有 httpd"这个坑,
# 以及安装清单里确实会补 busybox-extras。不落地、不启服务, 可随时跑。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/install-alpine.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ok=0
bad=0

chk() {
	if [ "$2" = "1" ]; then ok=$((ok + 1)); printf 'PASS  %s\n' "$1"
	else bad=$((bad + 1)); printf 'FAIL  %s  [%s]\n' "$1" "${3:-}"; fi
}

# 从安装脚本里抠出 has_httpd 原样执行, 保证测的是真代码而不是复制品
awk '/^has_httpd\(\) \{/,/^\}/' "$SCRIPT" >"$TMP/has_httpd.sh"
[ -s "$TMP/has_httpd.sh" ] || { echo "FAIL 无法提取 has_httpd"; exit 1; }

# 场景 A: Alpine 原样 —— 有 busybox, applet 列表里没有 httpd
mkdir -p "$TMP/a"
cat >"$TMP/a/busybox" <<'EOF'
#!/bin/sh
[ "$1" = "--list" ] && { printf 'sh\nawk\nsed\nwget\ntimeout\n'; exit 0; }
exit 127
EOF
chmod +x "$TMP/a/busybox"
if PATH="$TMP/a:/usr/bin:/bin" sh -c ". '$TMP/has_httpd.sh'; has_httpd"; then r=1; else r=0; fi
chk "只有 busybox(无 httpd applet) 判为缺" "$([ "$r" = "0" ] && echo 1 || echo 0)" "rc=$r"

# 场景 B: busybox 里编进了 httpd applet
mkdir -p "$TMP/b"
cat >"$TMP/b/busybox" <<'EOF'
#!/bin/sh
[ "$1" = "--list" ] && { printf 'sh\nawk\nhttpd\n'; exit 0; }
exit 127
EOF
chmod +x "$TMP/b/busybox"
if PATH="$TMP/b:/usr/bin:/bin" sh -c ". '$TMP/has_httpd.sh'; has_httpd"; then r=1; else r=0; fi
chk "busybox 自带 httpd applet 判为有" "$r" "rc=$r"

# 场景 C: busybox-extras 装好后有独立 httpd 可执行
mkdir -p "$TMP/c"
printf '#!/bin/sh\nexit 0\n' >"$TMP/c/httpd"
printf '#!/bin/sh\n[ "$1" = "--list" ] && { printf "sh\\nawk\\n"; exit 0; }\nexit 127\n' >"$TMP/c/busybox"
chmod +x "$TMP/c/httpd" "$TMP/c/busybox"
if PATH="$TMP/c:/usr/bin:/bin" sh -c ". '$TMP/has_httpd.sh'; has_httpd"; then r=1; else r=0; fi
chk "独立 httpd 命令判为有" "$r" "rc=$r"

# 安装清单必须包含 busybox-extras, 并且缺 httpd 时会 die
grep -q 'busybox-extras' "$SCRIPT" && chk "缺 httpd 时补装 busybox-extras" 1 || chk "缺 httpd 时补装 busybox-extras" 0
grep -q 'die "缺少 httpd' "$SCRIPT" && chk "装完仍缺 httpd 则明确报错" 1 || chk "装完仍缺 httpd 则明确报错" 0

# 自检不该硬依赖 curl(Alpine 最小安装没有 curl)
if awk '/_probe=2/,/^fi$/' "$SCRIPT" | grep -q 'command -v wget'; then
	chk "自检对 curl 无硬依赖(有 wget 兜底)" 1
else
	chk "自检对 curl 无硬依赖(有 wget 兜底)" 0
fi

# busybox httpd 默认自行 daemonize, 必须 -f 前台运行才和 pidfile 对得上
grep -q 'exec /usr/sbin/httpd -- -f -h' "$SCRIPT" && chk "服务以 -f 前台运行(pidfile 才有意义)" 1 ||
	chk "服务以 -f 前台运行(pidfile 才有意义)" 0

# 运行期只依赖 busybox 自带命令 + ssh/sshpass, 不该出现 npm/python/php
if grep -rEq '\b(npm|node|python3?|php|perl)\b' "$ROOT/device/lib" "$ROOT/device/www"; then
	chk "运行期无解释器依赖" 0 "发现解释器调用"
else
	chk "运行期无解释器依赖" 1
fi

printf '\n通过 %d / 失败 %d\n' "$ok" "$bad"
[ "$bad" = "0" ]
