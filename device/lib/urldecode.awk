# URL 解码 (application/x-www-form-urlencoded)
# 直接用 sprintf("%c") 输出原始字节, 调用方需设置 LC_ALL=C 保证按字节处理。
# 不使用 shell 的 printf %b, 因为它会把 "\072" 和后续数字粘连成错误字节。
{
	line = $0; out = ""; n = length(line)
	for (i = 1; i <= n; i++) {
		c = substr(line, i, 1)
		if (c == "+") {
			out = out " "
		} else if (c == "%" && i + 2 <= n) {
			h = substr(line, i + 1, 2)
			if (h ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) {
				v = hexval(substr(h, 1, 1)) * 16 + hexval(substr(h, 2, 1))
				# NUL 无法在 shell 变量中传递, 用空格替代
				if (v == 0) v = 32
				out = out sprintf("%c", v)
				i += 2
			} else {
				out = out c
			}
		} else {
			out = out c
		}
	}
	printf "%s", out
}
function hexval(ch) { return index("0123456789abcdef", tolower(ch)) - 1 }
