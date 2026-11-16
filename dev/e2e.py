#!/usr/bin/env python3
"""端到端交互测试: 通过 UI 修改 PON MAC, 验证保存链路与页面状态"""
import json
import pathlib

from playwright.sync_api import sync_playwright

BASE = "http://127.0.0.1:8080/"
MOCK = pathlib.Path(__file__).resolve().parent.parent / "dev" / "mock_state"
ok = []
fail = []


def check(name, cond, extra=""):
    (ok if cond else fail).append(f"{name} {extra}")


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/usr/bin/chromium", args=["--no-sandbox"])
    pg = b.new_page(viewport={"width": 1440, "height": 1000})
    errs = []
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)

    pg.goto(BASE, wait_until="networkidle")

    # 1) 错误密码
    pg.fill("#loginPass", "wrongpass")
    pg.click("#loginBtn")
    pg.wait_for_timeout(2200)  # 后端对错误密码故意延迟 1 秒(防暴力尝试)
    check("错误密码被拒绝", "错误" in pg.inner_text("#loginMsg"), pg.inner_text("#loginMsg"))

    # 2) 正确登录
    pg.fill("#loginPass", "admin")
    pg.click("#loginBtn")
    pg.wait_for_selector("#appView:not([hidden])", timeout=8000)
    check("登录成功", True)

    # 3) 修改 PON MAC
    pg.click('.nav-item[data-view="pon"]')
    pg.wait_for_timeout(600)
    mac_input = pg.locator('[data-field="pon_mac"]')
    old = mac_input.input_value()
    mac_input.fill("AA:BB:CC:11:22:33")
    pg.wait_for_timeout(200)
    check("输入框标记 dirty", "dirty" in (mac_input.get_attribute("class") or ""))
    pg.click('[data-group="pon"] button[type=submit]')
    pg.wait_for_timeout(900)
    check("保存出现 toast", pg.locator(".toast").count() > 0)
    scfg = (MOCK / "userdata" / "scfg.txt").read_text()
    check("MAC 已写入设备文件", "AA:BB:CC:11:22:33" in scfg)
    check("MAC 回读为原值", mac_input.input_value() == "AA:BB:CC:11:22:33")

    # 4) 非法 MAC 被前端后端拒绝
    mac_input.fill("zz:zz:zz:zz:zz:zz")
    pg.click('[data-group="pon"] button[type=submit]')
    pg.wait_for_timeout(900)
    t = " ".join(x.inner_text() for x in pg.locator(".toast").all())
    check("非法 MAC 报错提示", "格式" in t)

    # 5) 桥接开关
    pg.click('.nav-item[data-view="bridge"]')
    pg.wait_for_timeout(500)
    sw = pg.locator('[data-field="force_bridge"]')
    before = sw.is_checked()
    sw.click()
    pg.click('[data-group="bridge"] button[type=submit]')
    pg.wait_for_timeout(900)
    env = (MOCK / "etc" / "env.txt").read_text()
    newval = "CA8271_FORCE_BRIDGE=0" if before else "CA8271_FORCE_BRIDGE=1"
    check("桥接开关写入 env", newval in env)

    # 6) 备份下载
    pg.click('.nav-item[data-view="tools"]')
    pg.wait_for_timeout(800)
    with pg.expect_download() as dl:
        pg.click("#btnDlConfig")
    d = dl.value
    path = f"/tmp/dl-{d.suggested_filename}"
    d.save_as(path)
    content = pathlib.Path(path).read_text(encoding="utf-8", errors="replace")
    check("配置备份可下载", "CFG_ID_MAC_ADDRESS" in content, d.suggested_filename)

    # 7) 控制台无错误
    check("浏览器无 JS 报错", not errs, "; ".join(errs[:3]))

    b.close()

print("\n".join("PASS  " + x for x in ok))
print("\n".join("FAIL  " + x for x in fail) or "")
print(f"\n{len(ok)} 通过 / {len(fail)} 失败")
raise SystemExit(1 if fail else 0)
