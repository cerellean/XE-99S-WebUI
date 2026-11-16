/* ============================================================================
   XE-99S WebUI 前端逻辑 · 原生 JS, 无框架无依赖
   ========================================================================== */
"use strict";

const API = "cgi-bin/api.cgi";
const BK = "cgi-bin/backup.cgi";
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

const state = {
	token: sessionStorage.getItem("xe99s_token") || "",
	user: sessionStorage.getItem("xe99s_user") || "",
	status: null,
	config: null,
	timer: null,
	diagCmd: "pon",
};

/* ------------------------------------------------------------------ 请求 -- */
async function api(action, params = null, opts = {}) {
	const url = `${API}?r=${encodeURIComponent(action)}${opts.qs ? "&" + opts.qs : ""}`;
	const init = {
		method: params ? "POST" : "GET",
		headers: { "X-Auth-Token": state.token },
		cache: "no-store",
	};
	if (params) {
		init.headers["Content-Type"] = "application/x-www-form-urlencoded";
		init.body = new URLSearchParams(params).toString();
	}
	let res;
	try {
		res = await fetch(url, init);
	} catch (e) {
		throw new Error("无法连接设备，请检查网络");
	}
	let data;
	try {
		data = await res.json();
	} catch (e) {
		throw new Error(`设备返回异常 (HTTP ${res.status})`);
	}
	if (!data.ok) {
		if (data.error === "need_auth") {
			logout(true);
		}
		const err = new Error(data.message || "操作失败");
		err.code = data.error;
		throw err;
	}
	return data;
}

/* ------------------------------------------------------------------ 提示 -- */
function toast(msg, type = "ok", ms = 3200) {
	const el = document.createElement("div");
	el.className = `toast ${type}`;
	el.innerHTML = `<i></i><span></span>`;
	el.querySelector("span").textContent = msg;
	$("#toasts").appendChild(el);
	setTimeout(() => {
		el.classList.add("out");
		setTimeout(() => el.remove(), 220);
	}, ms);
}

function confirmBox(title, text) {
	return new Promise((resolve) => {
		const m = $("#modal");
		$("#modalTitle").textContent = title;
		$("#modalText").innerHTML = text;
		m.hidden = false;
		const done = (v) => {
			m.hidden = true;
			$("#modalOk").onclick = null;
			$("#modalCancel").onclick = null;
			resolve(v);
		};
		$("#modalOk").onclick = () => done(true);
		$("#modalCancel").onclick = () => done(false);
	});
}

function busy(btn, on) {
	if (!btn) return;
	btn.classList.toggle("loading", on);
	btn.disabled = on;
}

/* ------------------------------------------------------------------ 登录 -- */
async function doLogin(e) {
	e.preventDefault();
	const btn = $("#loginBtn");
	const msg = $("#loginMsg");
	msg.textContent = "";
	busy(btn, true);
	try {
		const d = await api("login", { user: $("#loginUser").value.trim(), pass: $("#loginPass").value });
		state.token = d.token;
		state.user = d.user;
		sessionStorage.setItem("xe99s_token", d.token);
		sessionStorage.setItem("xe99s_user", d.user);
		await boot();
	} catch (err) {
		msg.textContent = err.message;
	} finally {
		busy(btn, false);
	}
}

function logout(silent) {
	state.token = "";
	sessionStorage.removeItem("xe99s_token");
	clearInterval(state.timer);
	$("#appView").hidden = true;
	$("#loginView").hidden = false;
	$("#loginPass").value = "";
	if (!silent) toast("已退出登录");
}

/* ------------------------------------------------------------------ 启动 -- */
async function boot() {
	$("#loginView").hidden = true;
	$("#appView").hidden = false;
	try {
		await Promise.all([refreshStatus(), loadConfig(), loadProbe(false)]);
	} catch (e) {
		toast(e.message, "err");
	}
	clearInterval(state.timer);
	state.timer = setInterval(() => {
		if (document.hidden) return;
		refreshStatus().catch(() => {});
	}, 10000);
}

/* ------------------------------------------------------------------ 状态 -- */
async function refreshStatus() {
	const s = await api("status");
	state.status = s;
	renderStatus(s);
	return s;
}

function fmtBytes(n) {
	if (!n && n !== 0) return "—";
	const u = ["B", "KB", "MB", "GB", "TB"];
	let i = 0;
	let v = Number(n);
	while (v >= 1024 && i < u.length - 1) {
		v /= 1024;
		i++;
	}
	return `${i === 0 ? v : v.toFixed(1)} ${u[i]}`;
}

function fmtSpeed(mbps) {
	if (!mbps) return "未协商";
	return mbps >= 1000 ? `${(mbps / 1000).toFixed(0)} Gb/s` : `${mbps} Mb/s`;
}

function setPill(id, ok, text) {
	const el = $(id);
	el.classList.remove("on", "off");
	el.classList.add(ok === null ? "" : ok ? "on" : "off");
	el.querySelector("em").textContent = text;
}

function renderStatus(s) {
	const { sys, pon, optics, iface } = s;

	// 顶部胶囊
	const ponOk = pon.registered === true ? true : pon.reg_state === "" ? null : false;
	setPill("#pillPon", ponOk, pon.registered ? "OK" : pon.reg_state === "" ? "N/A" : "DOWN");
	setPill("#pillAuth", pon.authenticated ? true : false, pon.authenticated ? "OK" : "FAIL");
	const linkOk = iface.speed >= 1000 ? true : iface.speed > 0 ? null : false;
	setPill("#pillLink", linkOk, iface.speed ? fmtSpeed(iface.speed) : "N/C");

	// 侧栏
	const dot = $("#sideDot");
	dot.className = "dot " + (pon.authenticated ? "ok" : pon.registered ? "warn" : "bad");
	$("#sideText").textContent = pon.authenticated ? "链路已认证" : pon.registered ? "已注册未认证" : "链路未注册";

	// 总览
	$("#dashMode").textContent = pon.mode_text || "—";
	const elPon = $("#dashPon");
	elPon.className = "srow-v " + (pon.registered ? "ok" : "bad");
	elPon.textContent = pon.registered ? "已注册" : "未注册";
	const elAuth = $("#dashAuth");
	elAuth.className = "srow-v " + (pon.authenticated ? "ok" : "bad");
	elAuth.textContent = pon.authenticated ? "已认证" : "未认证";
	$("#dashOlt").textContent = pon.olt_mac || "—";

	// 光链路
	const hasO = optics.available;
	$("#dashDdmTag").textContent = hasO ? "DDM 在线" : "无 DDM 数据";
	if (hasO) {
		$("#dashRx").textContent = optics.rx_power.toFixed(2);
		$("#dashTx").textContent = optics.tx_power.toFixed(2);
		$("#dashTemp").textContent = optics.temp.toFixed(1) + " °C";
		$("#dashVcc").textContent = optics.vcc.toFixed(2) + " V";
		$("#dashBias").textContent = optics.bias.toFixed(1) + " mA";
		const pct = Math.min(100, Math.max(0, ((optics.rx_power + 30) / 23) * 100));
		$("#rxPtr").style.left = `calc(${pct}% - 1.5px)`;
		$("#dashRx").style.color = optics.rx_power < -27 ? "var(--bad)" : optics.rx_power > -8 ? "var(--warn)" : "var(--ok)";
	} else {
		["#dashRx", "#dashTx", "#dashTemp", "#dashVcc", "#dashBias"].forEach((k) => ($(k).textContent = "—"));
		$("#rxPtr").style.left = "0";
	}

	// 设备信息
	$("#dashFw").textContent = sys.fw;
	$("#dashBfw").textContent = sys.base_fw;
	$("#dashKern").textContent = sys.kernel || "—";
	$("#dashUp").textContent = sys.uptime_text;
	$("#dashMem").textContent = `${fmtBytes(sys.mem_total_kb * 1024)} · 已用 ${sys.mem_used_pct}%`;
	$("#dashIp").textContent = sys.ip;

	// 身份
	$("#dashMac").textContent = pon.pon_mac || "—";
	$("#dashPonMode").textContent = pon.mode_text;
	$("#dashBridge").textContent = state.config?.bridge?.force_bridge === "1" ? "已开启" : "关闭";
	$("#dashSpeed").textContent = fmtSpeed(iface.speed);
	$("#dashRxB").textContent = fmtBytes(iface.rx_bytes);
	$("#dashTxB").textContent = fmtBytes(iface.tx_bytes);

	// 网络页
	$("#netSpeed").textContent = fmtSpeed(iface.speed);
	$("#netRx").textContent = fmtBytes(iface.rx_bytes);
	$("#netTx").textContent = fmtBytes(iface.tx_bytes);

	// 关于
	$("#aboutVer").textContent = sys.webui;
}

/* ------------------------------------------------------------------ 配置 -- */
async function loadConfig() {
	const c = await api("config");
	state.config = c;

	fillForm("pon", {
		pon_mac: c.pon.pon_mac || "",
		loid: c.pon.loid || "",
		loid_pwd: c.pon.loid_pwd || "",
		sn: c.pon.sn || "",
		pon_mode: normPonMode(c.pon.pon_mode),
		report_mode: normHexNum(c.pon.report_mode),
	});

	// 固件没有可写的 SN 位置时, 直接禁用输入框而不是让用户白填一遍
	const snEl = document.querySelector('[data-group="pon"] [data-field="sn"]');
	if (snEl) {
		const rw = c.pon.sn_rw || "";
		if (!rw) {
			snEl.disabled = true;
			snEl.placeholder = "当前固件未找到可写的序列号位置";
			snEl.title = "请在「系统 → 环境自检」确认可写位置；或在 webui.conf 指定 SCFG_WRITE_OVERRIDE";
		} else {
			snEl.placeholder = rw === "scfg" ? "写入 scfg.txt" : "写入 uboot env";
		}
	}

	fillForm("tlv", {
		fw_bootver: c.tlv.fw_bootver,
		fw_bootcrc: c.tlv.fw_bootcrc,
		fw_fwver: c.tlv.fw_fwver,
		fw_fwcrc: c.tlv.fw_fwcrc,
		chip_id: c.tlv.chip_id,
		chip_model: c.tlv.chip_model,
		manu_year: c.tlv.manu_year,
		manu_mon: c.tlv.manu_mon,
		ven_name: c.tlv.ven_name,
		model: c.tlv.model,
		hw_ver: c.tlv.hw_ver,
		manu_info: c.tlv.manu_info,
	});

	fillForm("bridge", {
		force_bridge: c.bridge.force_bridge === "1",
		force_bridge_mac: c.bridge.force_bridge_mac || "00:00:00:00:00:00",
		force_traffic: c.bridge.force_traffic === "1",
	});

	fillForm("net", {
		net_ip: c.net.ip || "",
		net_mask: c.net.mask || "",
	});
	$("#netGw").value = c.net.gw || "（未配置）";
	$("#netConfPath").textContent = c.net.conf || "（未找到配置文件）";

	const bridge = c.bridge.force_bridge === "1" ? "已开启" : "关闭";
	$("#dashBridge").textContent = bridge;
	refreshTplList();
}

function normPonMode(v) {
	if (!v) return "";
	const n = parseInt(v.replace(/^0x/i, ""), 10);
	if (n === 1) return "0x01";
	if (n === 2) return "0x02";
	return v;
}

function normHexNum(v) {
	if (!v) return "0";
	return String(parseInt(v.replace(/^0x/i, ""), 16) || 0);
}

function fillForm(group, values) {
	$$(`[data-group="${group}"] [data-field]`).forEach((el) => {
		const key = el.dataset.field;
		let v = values[key];
		if (el.type === "checkbox") {
			el.checked = v === true || v === "1";
			el.dataset.orig = el.checked ? "1" : "0";
		} else {
			el.value = v == null ? "" : v;
			el.dataset.orig = el.value;
		}
		el.classList.remove("dirty");
	});
}

function markDirty(el) {
	const cur = el.type === "checkbox" ? (el.checked ? "1" : "0") : el.value;
	el.classList.toggle("dirty", cur !== el.dataset.orig);
}

/* 保存: 只提交发生变化的字段 */
async function saveGroup(form, btn) {
	const els = $$("[data-field]", form);
	const changed = els.filter((el) => {
		const cur = el.type === "checkbox" ? (el.checked ? "1" : "0") : el.value.trim();
		return cur !== el.dataset.orig;
	});
	if (!changed.length) {
		toast("没有需要保存的改动", "ok", 1800);
		return;
	}
	busy(btn, true);
	let okCount = 0;
	let firstErr = null;
	for (const el of changed) {
		const v = el.type === "checkbox" ? (el.checked ? "1" : "0") : el.value.trim();
		try {
			await api("set", { field: el.dataset.field, value: v });
			okCount++;
		} catch (e) {
			firstErr = e;
			break;
		}
	}
	busy(btn, false);
	if (firstErr) {
		toast(`已保存 ${okCount} 项，后续失败：${firstErr.message}`, "err", 5200);
	} else {
		toast(`已保存 ${okCount} 项配置`, "ok");
	}
	await loadConfig();
	refreshStatus().catch(() => {});
}

/* ------------------------------------------------------------------ 路由 -- */
const VIEWS = {
	dashboard: ["总览", "设备状态与光链路"],
	pon: ["PON 与认证", "PON MAC / LOID / 模式"],
	tlv: ["TLV 伪装", "上报给 OLT 的设备标识"],
	bridge: ["桥接与转发", "强制桥接 / MAC 过滤 / 强制业务"],
	network: ["网络", "管理地址与接口流量"],
	tools: ["工具与诊断", "分区、备份与原始输出"],
	system: ["系统", "账号、环境自检与危险操作"],
};

function goto(view) {
	$$(".nav-item").forEach((b) => b.classList.toggle("active", b.dataset.view === view));
	$$(".view").forEach((v) => v.classList.toggle("active", v.dataset.view === view));
	const meta = VIEWS[view] || VIEWS.dashboard;
	$("#pageTitle").textContent = meta[0];
	$("#pageSub").textContent = meta[1];
	location.hash = view;
	if (view === "tools") {
		loadMtd();
		runDiag();
	}
	if (view === "system") {
		loadProbe(false);
	}
	window.scrollTo({ top: 0, behavior: "smooth" });
}

/* -------------------------------------------------------------- 环境自检 -- */
// 探测结果决定"这套控制台在这台设备上到底能写哪里", 所以界面必须如实展示,
// 而不是假装写成功。force=true 时清缓存重跑。
async function loadProbe(force) {
	try {
		const d = await api(force ? "probe" : "probe_cached");
		renderProbe(d.env || {});
	} catch (e) {
		/* 探测失败不影响主流程, 页面保留占位符 */
	}
}

function renderProbe(e) {
	const variant = e.fw_variant || "unknown";
	const vName = { A: "Package-A · 自定义固件", C: "Package-C · 原厂 CTC 固件", unknown: "未能确定" }[variant] || variant;

	const set = (id, txt) => {
		const el = $(id);
		if (el) el.textContent = txt;
	};

	set("#pbVariant", vName);
	const ver = [];
	if (e.fw_version && e.fw_version !== "unknown") ver.push(e.fw_version);
	if (e.fw_base && e.fw_base !== "unknown" && e.fw_base !== e.fw_version) ver.push("基础 " + e.fw_base);
	set("#pbVersion", ver.join(" · ") || "—");
	set("#pbWeb", e.builtin_web === "1" ? "存在（与本控制台并存）" : "无");
	set("#pbRead", e.read_targets || "（未找到 scfg.txt，配置页可能读到空值）");
	set("#pbWrite", e.write_targets || "（无可写目标，保存会失败）");
	set("#pbPort", e.port_id || "—");
	set("#pbTools", e.tools || "（无可用的调试命令）");
	set("#pbBusy", e.busy_ports ? e.busy_ports.split(" ").map((p) => ":" + p).join("  ") : "80 / 88 均空闲");
	set("#pbKernel", e.kernel || "—");

	const tag = $("#probeTag");
	if (tag) {
		tag.textContent = variant === "C" ? "CTC 原厂" : variant === "A" ? "自定义 A" : "未识别";
		tag.className = "tag" + (variant === "unknown" ? " warn" : "");
	}
	set("#ponVariantTag", "已识别：" + vName);
}

/* ------------------------------------------------------------------ 工具 -- */
async function loadMtd() {
	const tbody = $("#mtdTable tbody");
	tbody.innerHTML = `<tr><td colspan="5" class="muted">加载中…</td></tr>`;
	try {
		const d = await api("mtd");
		if (!d.parts.length) {
			tbody.innerHTML = `<tr><td colspan="5" class="muted">未读取到分区表</td></tr>`;
			return;
		}
		const bootA = d.boot != null ? String(d.boot) : null;
		tbody.innerHTML = d.parts
			.map((p) => {
				const isBoot = bootA !== null && p.id === bootA;
				return `<tr>
					<td>${p.id}${isBoot ? ' <span class="tag">当前</span>' : ""}</td>
					<td class="mono">${esc(p.name)}</td>
					<td>${fmtBytes(p.size)}</td>
					<td class="mono">${p.erase ? (p.erase / 1024).toFixed(0) + " KB" : "—"}</td>
					<td><button class="btn sm ghost" data-dump="${p.id}" data-name="${esc(p.name)}">导出</button></td>
				</tr>`;
			})
			.join("");
	} catch (e) {
		tbody.innerHTML = `<tr><td colspan="5" class="muted">${esc(e.message)}</td></tr>`;
	}
}

function esc(s) {
	return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

async function runDiag() {
	const out = $("#diagOut");
	out.textContent = "执行中…";
	try {
		const d = await api("diag", null, { qs: `cmd=${state.diagCmd}` });
		out.textContent = d.output || "(无输出)";
	} catch (e) {
		out.textContent = "执行失败：" + e.message;
	}
}

async function download(path, filename) {
	const res = await fetch(path, { headers: { "X-Auth-Token": state.token } });
	if (!res.ok) {
		toast("下载失败：HTTP " + res.status, "err");
		return;
	}
	const blob = await res.blob();
	const a = document.createElement("a");
	a.href = URL.createObjectURL(blob);
	a.download = filename;
	a.click();
	setTimeout(() => URL.revokeObjectURL(a.href), 4000);
}

/* ------------------------------------------------------------- TLV 模板 -- */
const TPL_KEY = "xe99s_tlv_templates";

function getTpls() {
	try {
		return JSON.parse(localStorage.getItem(TPL_KEY) || "{}");
	} catch {
		return {};
	}
}

function refreshTplList() {
	const sel = $("#tlvTplSelect");
	const tpls = getTpls();
	const names = Object.keys(tpls);
	sel.innerHTML =
		`<option value="">应用模板…</option>` + names.map((n) => `<option value="${esc(n)}">${esc(n)}</option>`).join("");
}

/* ------------------------------------------------------------------ 事件 -- */
function bind() {
	$("#loginForm").addEventListener("submit", doLogin);
	$("#btnLogout").addEventListener("click", () => logout(false));

	$("#nav").addEventListener("click", (e) => {
		const b = e.target.closest(".nav-item");
		if (b) goto(b.dataset.view);
	});

	$$("[data-goto]").forEach((b) => b.addEventListener("click", () => goto(b.dataset.goto)));

	$("#btnRefresh").addEventListener("click", async (e) => {
		busy(e.currentTarget, true);
		try {
			await Promise.all([refreshStatus(), loadConfig(), loadProbe(false)]);
			toast("已刷新", "ok", 1500);
		} catch (err) {
			toast(err.message, "err");
		}
		busy(e.currentTarget, false);
	});

	$("#btnReboot").addEventListener("click", () => doAction("reboot"));
	$("#btnProbe").addEventListener("click", async (e) => {
		busy(e.currentTarget, true);
		try {
			await loadProbe(true);
			toast("探测完成", "ok", 1500);
		} catch (err) {
			toast(err.message, "err");
		}
		busy(e.currentTarget, false);
	});
	$("#btnQuickBackup").addEventListener("click", () => download(`${BK}?t=config`, "xe99s-config.txt"));
	$("#btnDlConfig").addEventListener("click", () => download(`${BK}?t=config`, "xe99s-config.txt"));

	// 表单提交
	$$("form[data-group]").forEach((form) => {
		form.addEventListener("submit", (e) => {
			e.preventDefault();
			saveGroup(form, form.querySelector("button[type=submit]"));
		});
		form.addEventListener("input", (e) => {
			if (e.target.dataset.field) markDirty(e.target);
		});
		form.addEventListener("change", (e) => {
			if (e.target.dataset.field) markDirty(e.target);
		});
	});

	// 修改密码
	$("#pwdForm").addEventListener("submit", async (e) => {
		e.preventDefault();
		const n1 = $("#pwdNew").value;
		const n2 = $("#pwdNew2").value;
		if (n1.length < 6) return toast("新密码至少 6 位", "err");
		if (n1 !== n2) return toast("两次输入的新密码不一致", "err");
		const btn = e.target.querySelector("button[type=submit]");
		busy(btn, true);
		try {
			await api("password", { old: $("#pwdOld").value, new: n1 });
			toast("密码已更新，请重新登录", "ok");
			["#pwdOld", "#pwdNew", "#pwdNew2"].forEach((k) => ($(k).value = ""));
			setTimeout(() => logout(true), 1200);
		} catch (err) {
			toast(err.message, "err");
		}
		busy(btn, false);
	});

	// 危险操作
	$$("[data-action]").forEach((b) =>
		b.addEventListener("click", () => doAction(b.dataset.action, b)),
	);

	// 诊断
	$("#diagTabs").addEventListener("click", (e) => {
		const b = e.target.closest(".seg-item");
		if (!b) return;
		$$("#diagTabs .seg-item").forEach((x) => x.classList.toggle("active", x === b));
		state.diagCmd = b.dataset.diag;
		runDiag();
	});
	$("#btnDiagReload").addEventListener("click", runDiag);

	// 分区导出
	$("#mtdTable").addEventListener("click", (e) => {
		const b = e.target.closest("[data-dump]");
		if (!b) return;
		download(`${BK}?t=mtd&n=${b.dataset.dump}`, `${b.dataset.name}.bin`);
		toast("开始下载，分区较大时请耐心等待", "ok");
	});

	// TLV 模板
	$("#btnTlvSaveTpl").addEventListener("click", () => {
		const name = prompt("模板名称（例如：某运营商型号A）");
		if (!name) return;
		const tpls = getTpls();
		tpls[name] = collectGroup("tlv");
		localStorage.setItem(TPL_KEY, JSON.stringify(tpls));
		refreshTplList();
		toast("模板已保存到本机浏览器", "ok");
	});
	$("#tlvTplSelect").addEventListener("change", (e) => {
		const name = e.target.value;
		if (!name) return;
		const tpls = getTpls();
		if (!tpls[name]) return;
		fillForm("tlv", tpls[name]);
		$$(`[data-group="tlv"] [data-field]`).forEach((el) => markDirty(el));
		toast("已填入模板，确认后逐个保存", "ok");
	});
	$("#btnTlvDelTpl").addEventListener("click", () => {
		const name = $("#tlvTplSelect").value;
		if (!name) return toast("请先选择一个模板", "err");
		const tpls = getTpls();
		delete tpls[name];
		localStorage.setItem(TPL_KEY, JSON.stringify(tpls));
		refreshTplList();
		toast("模板已删除", "ok");
	});
}

function collectGroup(group) {
	const o = {};
	$$(`[data-group="${group}"] [data-field]`).forEach((el) => {
		o[el.dataset.field] = el.type === "checkbox" ? (el.checked ? "1" : "0") : el.value;
	});
	return o;
}

/* ------------------------------------------------------------------ 动作 -- */
const ACTIONS = {
	reboot: ["重启设备", "设备将重启，约 180 秒后恢复。期间光链路和网络都会中断，确认继续？", "重启中…"],
	factory_reset: [
		"恢复出厂配置",
		"会清空 <code>/overlay/upper/*</code> 下的全部配置（含本控制台的设置与密码），且不可撤销。确认继续？",
		"已清空，请重启设备",
	],
	restart_webui: ["重启 WebUI 服务", "只重启控制台进程，不影响 PON 业务。确认继续？", "服务已重启"],
};

async function doAction(name, btn) {
	const conf = ACTIONS[name];
	if (!conf) return;
	if (!(await confirmBox(conf[0], conf[1]))) return;
	busy(btn, true);
	try {
		await api("action", { name });
		toast(conf[2], "ok");
		if (name === "reboot") waitReboot();
	} catch (e) {
		toast(e.message, "err");
	}
	busy(btn, false);
}

async function waitReboot() {
	clearInterval(state.timer);
	$("#appView").style.opacity = "0.4";
	$("#appView").style.pointerEvents = "none";
	let tries = 0;
	const t = setInterval(async () => {
		tries++;
		try {
			const r = await fetch(`${API}?r=ping`, { cache: "no-store" });
			if (r.ok) {
				clearInterval(t);
				location.reload();
			}
		} catch (e) {
			/* 还没起来, 继续等 */
		}
		if (tries > 90) {
			clearInterval(t);
			toast("设备长时间未响应，请手动刷新页面", "err", 6000);
		}
	}, 3000);
}

/* ------------------------------------------------------------------ 初始化 -- */
(async function init() {
	bind();
	const hash = location.hash.replace("#", "");
	if (state.token) {
		try {
			await boot();
			goto(VIEWS[hash] ? hash : "dashboard");
			return;
		} catch (e) {
			state.token = "";
		}
	}
	$("#loginView").hidden = false;
	$("#appView").hidden = true;
})();
