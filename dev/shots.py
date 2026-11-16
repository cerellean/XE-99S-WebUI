#!/usr/bin/env python3
"""用 Playwright 打开本地预览并截取各页面, 用于检查排版"""
import sys
from playwright.sync_api import sync_playwright

BASE = "http://127.0.0.1:8080/"
OUT = "/tmp/shots"
import os
os.makedirs(OUT, exist_ok=True)

VIEWS = [
    ("dashboard", "总览"),
    ("pon", "PON 与认证"),
    ("tlv", "TLV 伪装"),
    ("bridge", "桥接与转发"),
    ("network", "网络"),
    ("tools", "工具与诊断"),
    ("system", "系统"),
]

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/usr/bin/chromium", args=["--no-sandbox"])
    pg = b.new_page(viewport={"width": 1440, "height": 1000}, device_scale_factor=2)

    # 登录页
    pg.goto(BASE, wait_until="networkidle")
    pg.screenshot(path=f"{OUT}/00-login.png")

    # 登录
    pg.fill("#loginPass", "admin")
    pg.click("#loginBtn")
    pg.wait_for_selector("#appView:not([hidden])", timeout=8000)
    pg.wait_for_timeout(1200)

    for i, (view, _) in enumerate(VIEWS, start=1):
        pg.click(f'.nav-item[data-view="{view}"]')
        pg.wait_for_timeout(900)
        pg.screenshot(path=f"{OUT}/{i:02d}-{view}.png", full_page=True)

    # 移动端
    m = b.new_page(viewport={"width": 390, "height": 844}, device_scale_factor=2)
    m.goto(BASE, wait_until="networkidle")
    m.fill("#loginPass", "admin")
    m.click("#loginBtn")
    m.wait_for_selector("#appView:not([hidden])", timeout=8000)
    m.wait_for_timeout(1500)
    m.screenshot(path=f"{OUT}/10-mobile.png", full_page=True)

    # 控制台错误
    errs = []
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.reload(wait_until="networkidle")
    print("console errors:", errs or "none")
    b.close()
print("done")
