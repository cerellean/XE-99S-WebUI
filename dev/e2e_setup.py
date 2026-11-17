#!/usr/bin/env python3
"""「登录控制台 -> 控制台里填猫棒连接 -> 自动连上」全流程验证 (mock 远端模式)

对应产品选择: 登录只验 WebUI 自己的账号; 猫棒地址/账号/密码属于设备连接,
第一次登录后由向导索取, 之后随时在「系统 -> 设备连接」改。
"""
import pathlib
import sys

from playwright.sync_api import sync_playwright

BASE = "http://127.0.0.1:8080/"
ROOT = pathlib.Path(__file__).resolve().parent.parent
CONF = ROOT / "device" / "etc" / "remote.conf"
ok, fail = [], []

# 模拟「install-alpine.sh 刚装完、还没填地址」的状态:
# 安装脚本总会写 remote.conf 并把 REMOTE_HOST 留空, 此时 WEBUI_REMOTE=1
# 但未配置, 登录后就该弹向导。
CONF.parent.mkdir(parents=True, exist_ok=True)
CONF.write_text(
    "# 由 install-alpine.sh 生成（测试夹具）\n"
    "WEBUI_REMOTE=1\nREMOTE_HOST=\nREMOTE_PORT=22\nREMOTE_USER=root\n"
    "REMOTE_TRANSPORT=ssh\nREMOTE_AUTH=\nREMOTE_KEY=\nREMOTE_PASS=\n"
)
CONF.chmod(0o600)


def check(name, cond, extra=""):
    (ok if cond else fail).append(f"{name} {extra}")
    print(("PASS  " if cond else "FAIL  ") + name + (f"  [{extra}]" if extra else ""))


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/usr/bin/chromium", args=["--no-sandbox"])
    pg = b.new_page(viewport={"width": 1440, "height": 1000})
    errs = []
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.on("pageerror", lambda e: errs.append(str(e)))

    pg.goto(BASE, wait_until="networkidle")
    pg.wait_for_timeout(600)

    # 1) 登录页保持"只登录"：没有猫棒字段, 按钮就是登录
    check("登录页无猫棒字段", pg.query_selector("#loginBridge") is None)
    check("登录按钮文案", pg.inner_text("#loginBtn").strip() == "登录控制台", pg.inner_text("#loginBtn"))
    check("登录页无 lbHost 输入框", pg.query_selector("#lbHost") is None)

    # 2) 登录 -> 未配置, 控制台里直接弹「首次配置」向导
    pg.fill("#loginPass", "admin")
    pg.click("#loginBtn")
    pg.wait_for_selector("#appView:not([hidden])", timeout=12000)
    pg.wait_for_selector("#setupModal:not([hidden])", timeout=8000)
    check("登录后进入控制台", True)
    check("自动弹出连接向导", pg.is_visible("#setupModal"))
    check("向导标题正确", "猫棒" in pg.inner_text("#setupModal"))
    check("地址可预填默认值", pg.input_value("#setupHost") == "192.168.0.1", pg.input_value("#setupHost"))
    check("账号预填 root", pg.input_value("#setupUser") == "root", pg.input_value("#setupUser"))
    check("背景有未连接横幅", pg.is_visible("#connBanner"), pg.inner_text("#connBannerTitle"))

    # 3) 先填一个连不上的地址: 向导不关, 明确报错
    pg.fill("#setupHost", "10.0.0.9")
    pg.click("#setupGo")
    pg.wait_for_timeout(2500)
    check("连不上时向导保持打开", pg.is_visible("#setupModal"))
    check("向导内状态=连不上", "连不上" in pg.inner_text("#setupStateText"), pg.inner_text("#setupStateText"))
    check("向导内给出原因", len(pg.inner_text("#setupMsg")) > 4, pg.inner_text("#setupMsg")[:60])
    # 连不上也落盘: 刷新后横幅能指名道姓说"是 10.0.0.9 连不上", 而不是回到"未配置"
    _t = CONF.read_text() if CONF.exists() else ""
    check("失败的地址也已记录(便于重试)", "REMOTE_HOST=10.0.0.9" in _t, _t.replace("\n", " | ")[:80])

    # 4) 改成可达地址: 保存 + 试连 + 推公钥, 然后自动关闭并加载数据
    pg.fill("#setupHost", "127.0.0.1")
    pg.click("#setupGo")
    pg.wait_for_timeout(3000)
    check("连上后向导关闭", pg.is_hidden("#setupModal"))
    check("顶部横幅消失", pg.is_hidden("#connBanner"))

    text = CONF.read_text() if CONF.exists() else ""
    check("remote.conf 已写盘", "REMOTE_HOST=127.0.0.1" in text, text.replace("\n", " | ")[:90])
    check("记录了认证方式", ("REMOTE_AUTH=key" in text) or ("REMOTE_AUTH=pass" in text))

    dash = pg.inner_text(".view.active")
    check("总览已加载真实数据", len(dash) > 200, str(len(dash)))

    pg.click('.nav-item[data-view="system"]')
    pg.wait_for_timeout(900)
    st = pg.inner_text("#connStateText")
    check("连接卡片显示已连接", "127.0.0.1" in st and "ms" in st, st)

    # 5) 刷新页面: 会话仍在, 直接进控制台, 不再打扰
    pg.reload(wait_until="networkidle")
    pg.wait_for_timeout(1600)
    check("刷新后直接进控制台", pg.is_visible("#appView"))
    check("刷新后不再弹向导", pg.is_hidden("#setupModal"))

    # 6) 登出重登: 已配置过, 也不该再弹向导
    if pg.query_selector("#btnLogout"):
        pg.click("#btnLogout")
        pg.wait_for_timeout(500)
    pg.evaluate("sessionStorage.clear()")
    pg.reload(wait_until="networkidle")
    pg.fill("#loginPass", "admin")
    pg.click("#loginBtn")
    pg.wait_for_selector("#appView:not([hidden])", timeout=12000)
    pg.wait_for_timeout(1500)
    check("已配置账号重登不弹向导", pg.is_hidden("#setupModal"))

    # 7) 改坏地址: 登录与使用都不受影响, 但顶部横幅说明原因
    pg.click('.nav-item[data-view="system"]')
    pg.wait_for_timeout(600)
    pg.fill("#connHost", "10.0.0.9")
    pg.fill("#connPass", "")
    pg.click("#btnConnSave")
    pg.wait_for_timeout(2600)
    check("改坏地址后横幅出现", pg.is_visible("#connBanner"))
    check("横幅文案含地址", "10.0.0.9" in pg.inner_text("#connBanner"), pg.inner_text("#connBanner")[:70])

    # 8) 横幅「去修改地址」-> 改回, 恢复
    pg.click("#btnBannerFix")
    pg.wait_for_timeout(700)
    pg.fill("#connHost", "127.0.0.1")
    pg.fill("#connPass", "")
    pg.click("#btnConnSave")
    pg.wait_for_timeout(2600)
    check("改回后横幅消失", pg.is_hidden("#connBanner"), pg.inner_text("#connStateText"))

    check("无 JS 报错", not errs, "; ".join(errs[:3]))

    # 截图: 登录页 + 向导态 (重新造一次未配置)
    pg.evaluate("sessionStorage.clear()")
    pg.screenshot(path=str(ROOT / "preview" / "login-simple.png"))
    b.close()

print(f"\n通过 {len(ok)} / 失败 {len(fail)}")
sys.exit(1 if fail else 0)
