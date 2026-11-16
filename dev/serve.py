#!/usr/bin/env python3
"""
本地开发服务器: 模拟 busybox httpd 的 CGI 执行环境
  - /            静态文件 (device/www)
  - /cgi-bin/*   fork 一个 sh 执行, 与设备上行为一致
用法: python3 dev/serve.py [--port 8080]
"""
import os
import sys
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

BASE = os.path.dirname(os.path.abspath(__file__))
DEVICE = os.path.normpath(os.path.join(BASE, "..", "device"))
WWW = os.path.join(DEVICE, "www")
PORT = 8080
HOST = "0.0.0.0"
if "--port" in sys.argv:
    PORT = int(sys.argv[sys.argv.index("--port") + 1])
if "--host" in sys.argv:
    HOST = sys.argv[sys.argv.index("--host") + 1]

MIME = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".json": "application/json",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "xe99s-devhttpd"

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s %s\n" % (self.command, self.path))

    # ---------------------------------------------------------------- CGI --
    def run_cgi(self, body=b""):
        parsed = urlparse(self.path)
        rel = unquote(parsed.path)
        script = os.path.normpath(os.path.join(DEVICE, rel.lstrip("/")))
        if not script.startswith(DEVICE) or not os.path.isfile(script):
            self.send_error(404, "cgi not found")
            return
        env = dict(os.environ)
        env.update({
            "WEBUI_MOCK": "1",
            "REQUEST_METHOD": self.command,
            "QUERY_STRING": parsed.query,
            "SCRIPT_NAME": rel,
            "PATH_INFO": "",
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)) if body else "",
            "REMOTE_ADDR": self.client_address[0],
            "SERVER_PROTOCOL": "HTTP/1.1",
            "GATEWAY_INTERFACE": "CGI/1.1",
        })
        for k, v in self.headers.items():
            key = "HTTP_" + k.upper().replace("-", "_")
            env[key] = v
        try:
            p = subprocess.run(["sh", script], input=body, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        except subprocess.TimeoutExpired:
            self.send_error(504, "cgi timeout")
            return
        out = p.stdout
        if p.stderr:
            sys.stderr.write("[cgi stderr] " + p.stderr.decode("utf-8", "replace") + "\n")
        # 分离头部与正文
        sep = out.find(b"\r\n\r\n")
        sep_len = 4
        if sep < 0:
            sep = out.find(b"\n\n")
            sep_len = 2
        if sep < 0:
            self.send_response(500)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"[CGI raw output, no headers]\n" + out)
            return
        head = out[:sep].decode("utf-8", "replace")
        payload = out[sep + sep_len:]
        status = 200
        headers = []
        for line in head.splitlines():
            if not line.strip():
                continue
            if ":" not in line:
                continue
            k, v = line.split(":", 1)
            k, v = k.strip(), v.strip()
            if k.lower() == "status":
                status = int(v.split()[0])
                continue
            headers.append((k, v))
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    # ------------------------------------------------------------ 静态资源 --
    def serve_static(self):
        parsed = urlparse(self.path)
        rel = unquote(parsed.path)
        if rel == "/":
            rel = "/index.html"
        path = os.path.normpath(os.path.join(WWW, rel.lstrip("/")))
        if not path.startswith(WWW) or not os.path.isfile(path):
            self.send_error(404, "not found")
            return
        ext = os.path.splitext(path)[1].lower()
        ctype = MIME.get(ext, "application/octet-stream")
        with open(path, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    # ---------------------------------------------------------------- 路由 --
    def do_GET(self):
        if self.path.startswith("/cgi-bin/"):
            self.run_cgi()
        else:
            self.serve_static()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.path.startswith("/cgi-bin/"):
            self.run_cgi(body)
        else:
            self.send_error(405)


if __name__ == "__main__":
    print(f"XE-99S WebUI 开发预览  ->  http://{HOST}:{PORT}")
    print(f"  device root : {DEVICE}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
