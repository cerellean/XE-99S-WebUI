#!/usr/bin/env python3
"""端到端交互测试: 通过 UI 修改 PON MAC, 验证保存链路、只读区与页面状态

覆盖的重点（都对着原厂 SIEPON-C 固件的真实行为）:
  · 五个页面齐全, 且不再有 TLV / 桥接页
  · PON MAC 落到 /config/scfg.txt, 并同步 CFG_ID_NE_MAC_ADDR0
  · 非法 MAC 被拒
  · 只读区显示固件实际生效参数（数据通路/OAM/加密/LLID）
  · 配置备份可下载
"""
import json
import pathlib

from playwright.sync_api import sync_playwright

BASE = "http://127.0.0.1:8080/"
ROOT = pathlib.Path(__file__).resolve().parent.parent
MOCK = ROOT / "dev" / "mock_state"
SCFG = MOCK / "config" / "scfg.txt"
ok = []
fail = []


def reset_mock():
    """把上一轮写进去的值恢复成出厂值, 保证用例可重复。"""
    if not SCFG.exists():
        return
    t = SCFG.read_text()
    t = t.replace("AA:BB:CC:11:22:33", "00:19:C7:00:00:00")
    t = t.replace("ZZDX99887766", "LOID12345678")
    SCFG.write_text(t)


reset_mock()

# 向导 e2e 会把连接配置写进 device/etc/remote.conf; 留着会让本机模式误入远端链路,
# 表现为所有写入报 "需要 sshpass"。本机 e2e 要求干净环境。
_rc = ROOT / "device" / "etc" / "remote.conf"
if _rc.exists():
    _rc.unlink()


def check(name, cond, extra=""):
    (ok if cond else fail).append(f"{name} {extra}")


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/usr/bin/chromium", args=["--no-sandbox"])
    pg = b.new_page(viewport={"width": 1440, "height": 1000})
    errs = []
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.on("pageerror", lambda e: errs.append(str(e)))

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

    # 3) 页面结构: 只有五个视图, TLV/桥接已移除
    views = pg.eval_on_selector_all(".nav-item", "els => els.map(e => e.dataset.view)")
    check("导航为五页", views == ["dashboard", "pon", "network", "tools", "system"], str(views))
    check("无 TLV 页", pg.query_selector('.view[data-view="tlv"]') is None)
    check("无桥接页", pg.query_selector('.view[data-view="bridge"]') is None)

    # 4) 总览: 链路字段来自 iROS (等首屏数据回来)
    pg.wait_for_function("document.querySelector('#dashDatapath').textContent !== '—'", timeout=10000)
    dash = pg.inner_text(".view.active")
    check("总览含 LLID", "LLID" in dash)
    check("总览显示数据通路", "桥接" in pg.inner_text("#dashDatapath"), pg.inner_text("#dashDatapath"))
    check("PON 已注册", "已注册" in pg.inner_text("#dashPon"), pg.inner_text("#dashPon"))

    # 5) PON 页: 只读区与出厂标识
    pg.click('.nav-item[data-view="pon"]')
    pg.wait_for_timeout(700)
    check("数据通路只读值", "桥接" in pg.inner_text("#fcDatapath"), pg.inner_text("#fcDatapath"))
    check("OAM 模式=CTC", "CTC" in pg.inner_text("#fcOam"), pg.inner_text("#fcOam"))
    check("加密模式=HW CTC", "CTC" in pg.inner_text("#fcEnc"), pg.inner_text("#fcEnc"))
    check("出厂标识已渲染", "XE-99S" in pg.inner_text("#identChips"), pg.inner_text("#identChips")[:80])
    check("PON 链路 OLT MAC", ":" in pg.inner_text("#ponOlt"), pg.inner_text("#ponOlt"))
    check("PON 链路 LLID", pg.inner_text("#ponLlid") != "—", pg.inner_text("#ponLlid"))
    check("写入路径提示", "scfg" in pg.inner_text("#ponPathHint"), pg.inner_text("#ponPathHint"))

    # 6) 修改 PON MAC
    mac_input = pg.locator('[data-field="pon_mac"]')
    mac_input.fill("AA:BB:CC:11:22:33")
    pg.wait_for_timeout(200)
    check("输入框标记 dirty", "dirty" in (mac_input.get_attribute("class") or ""))
    pg.click('[data-group="pon"] button[type=submit]')
    pg.wait_for_timeout(1000)
    check("保存出现 toast", pg.locator(".toast").count() > 0)
    scfg = SCFG.read_text()
    check("PON MAC 已写入 /config/scfg.txt", "CFG_ID_MAC_ADDRESS" in scfg and "AA:BB:CC:11:22:33" in scfg)
    check("NE_MAC_ADDR0 已同步", "CFG_ID_NE_MAC_ADDR0" in scfg and scfg.count("AA:BB:CC:11:22:33") == 2)
    check("MAC 回读为新值", mac_input.input_value() == "AA:BB:CC:11:22:33")

    # 7) 非法 MAC 被后端拒绝, 且不写坏文件
    mac_input.fill("zz:zz:zz:zz:zz:zz")
    pg.click('[data-group="pon"] button[type=submit]')
    pg.wait_for_timeout(1000)
    t = " ".join(x.inner_text() for x in pg.locator(".toast").all())
    check("非法 MAC 报错提示", "格式" in t, t[:80])
    check("非法值未落盘", "zz:zz" not in SCFG.read_text())

    # 8) 固件不再提供的字段一律拒绝（旧版 TLV / 桥接字段名）
    rej = pg.evaluate(
        """async () => {
            const t = sessionStorage.getItem('xe99s_token');
            const out = [];
            for (const f of ['force_bridge','force_traffic','fw_fwver','manu_info']) {
                const r = await fetch('cgi-bin/api.cgi?r=set', {
                    method:'POST',
                    headers:{'X-Auth-Token': t, 'Content-Type':'application/x-www-form-urlencoded'},
                    body: new URLSearchParams({field:f, value:'1'}).toString()
                });
                out.push((await r.json()).ok);
            }
            return out;
        }"""
    )
    check("旧字段全部被拒绝", rej == [False, False, False, False], str(rej))

    # 9) 网络页
    pg.click('.nav-item[data-view="network"]')
    pg.wait_for_timeout(600)
    check("网络页显示 MAC", ":" in pg.inner_text("#netMac"), pg.inner_text("#netMac"))
    check("网络页显示数据通路", "桥接" in pg.inner_text("#netDatapath"), pg.inner_text("#netDatapath"))

    # 10) 备份下载
    pg.click('.nav-item[data-view="tools"]')
    pg.wait_for_timeout(900)
    with pg.expect_download() as dl:
        pg.click("#btnDlConfig")
    d = dl.value
    path = f"/tmp/dl-{d.suggested_filename}"
    d.save_as(path)
    content = pathlib.Path(path).read_text(encoding="utf-8", errors="replace")
    check("配置备份可下载", "CFG_ID_MAC_ADDRESS" in content, d.suggested_filename)
    check("备份含出厂标识", "XE-99S" in content)
    check("备份不再含 env 段", "CA8271_" not in content)

    # 11) 诊断: PON 原始输出走 iros
    out = pg.inner_text("#diagOut")
    check("诊断默认显示 PON", "reg_state" in out, out[:60])

    # 12) 系统页自检
    pg.click('.nav-item[data-view="system"]')
    pg.wait_for_timeout(900)
    check("自检显示 iROS 正常", "iros" in pg.inner_text("#pbIros"), pg.inner_text("#pbIros"))
    check("自检显示写入目标", "scfg.txt" in pg.inner_text("#pbWrite"), pg.inner_text("#pbWrite"))

    # 13) 控制台无错误
    check("浏览器无 JS 报错", not errs, "; ".join(errs[:3]))

    b.close()

print("\n".join("PASS  " + x for x in ok))
print("\n".join("FAIL  " + x for x in fail) or "")
print(f"\n{len(ok)} 通过 / {len(fail)} 失败")
raise SystemExit(1 if fail else 0)
