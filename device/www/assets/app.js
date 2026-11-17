/* ============================================================================
   XE-99S WebUI 前端逻辑 · 原生 JS, 无框架无依赖
   适用固件: SIEPON Package-C（原厂 CTC）, 功能范围只覆盖该固件真实可读写的项
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
	conn: null,
	connFilled: false,
	setupOpen: false,
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
/* 登录只做一件事: 校验控制台账号。猫棒的地址/账号/密码在控制台里填,
   因为那是"设备连接"而不是"登录"——两件事混在一张卡片上很容易让人
   把两套密码搞混。 */
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

	// 先探一次环境: 远端模式下连不上就没必要再拉设备数据,
	// 否则页面会铺满"—", 看起来像设备坏了而不是网络断了
	const probed = await loadProbe(false);
	const remote = probed && state.conn && state.conn.mode === "remote";
	const unset = remote && state.conn.configured === false;
	const offline = remote && !state.conn.reachable;

	if (unset) {
		// 还没填过地址: 登录后第一件事就是把向导推到眼前, 不用去系统页翻卡片。
		// 关掉向导后横幅还在, 点「去连接」可以再打开。
		openSetup();
	}

	if (!offline) {
		try {
			await Promise.all([refreshStatus(), loadConfig()]);
		} catch (e) {
			toast(e.message, "err");
		}
	}

	clearInterval(state.timer);
	// iROS 查询在猫棒的 400MHz CPU 上要一两秒, 轮询间隔不必太密
	state.timer = setInterval(async () => {
		if (document.hidden) return;
		if (state.conn && state.conn.mode === "remote" && !state.conn.reachable) {
			// 掉线状态: 只轻量重探连接, 恢复后自动补齐数据
			const ok = await loadProbe(false);
			if (ok && state.conn && state.conn.reachable) {
				await Promise.all([refreshStatus(), loadConfig()]).catch(() => {});
				toast("设备已恢复连接", "ok");
			}
			return;
		}
		try {
			await refreshStatus();
		} catch (e) {
			if (e.code === "device_unreachable") {
				showOffline(e.message, state.conn && state.conn.host);
				if (state.conn) state.conn.reachable = false;
			}
		}
	}, 15000);
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

function yesNo(v, yes, no) {
	if (v === "1") return yes;
	if (v === "" || v == null) return "—";
	return no;
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
	elPon.textContent = pon.registered ? "已注册" : pon.reg_state === "" ? "无数据" : "未注册";
	const elAuth = $("#dashAuth");
	elAuth.className = "srow-v " + (pon.authenticated ? "ok" : "bad");
	elAuth.textContent = pon.authenticated ? "已认证" : "未认证";
	$("#dashLlid").textContent = pon.llid || "—";
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
	$("#dashBfw").textContent = sys.fw_build;
	$("#dashKern").textContent = sys.kernel || "—";
	$("#dashUp").textContent = sys.uptime_text;
	$("#dashMem").textContent = `${fmtBytes(sys.mem_total_kb * 1024)} · 已用 ${sys.mem_used_pct}%`;
	$("#dashIp").textContent = sys.ip;

	// 身份
	$("#dashMac").textContent = pon.pon_mac || "—";
	$("#dashPonMode").textContent = pon.mode_text;
	$("#dashDatapath").textContent = s.run?.datapath_text || "—";
	$("#dashSpeed").textContent = fmtSpeed(iface.speed);
	$("#dashRxB").textContent = fmtBytes(iface.rx_bytes);
	$("#dashTxB").textContent = fmtBytes(iface.tx_bytes);

	// PON 详情
	$("#ponReg").textContent = pon.registered ? "已注册（reg_state = 1）" : pon.reg_state === "" ? "读不到（iROS 无返回）" : `未注册（reg_state = ${pon.reg_state}）`;
	$("#ponLlid").textContent = pon.llid || "—";
	$("#ponOlt").textContent = pon.olt_mac || "—";
	$("#ponUs").textContent = yesNo(pon.upstream, "已使能", "未使能");
	$("#ponDs").textContent = yesNo(pon.downstream, "已使能", "未使能");
	$("#ponCause").textContent = pon.dereg_cause == null || pon.dereg_cause === "" ? "—" : pon.dereg_cause;
	$("#ponRetry").textContent = pon.retry == null || pon.retry === "" ? "—" : pon.retry;
	$("#ponPort").textContent = s.run?.port_id || "—";

	// 网络页
	$("#netMac").textContent = iface.mac || "—";
	$("#netSpeed").textContent = fmtSpeed(iface.speed);
	$("#netRx").textContent = fmtBytes(iface.rx_bytes);
	$("#netTx").textContent = fmtBytes(iface.tx_bytes);
	$("#netDatapath").textContent = s.run?.datapath_text || "—";

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
		pon_mode: normPonMode(c.pon.pon_mode),
		report_mode: normHexNum(c.pon.report_mode),
	});

	fillForm("net", {
		net_ip: c.net.ip || "",
		net_mask: c.net.mask || "",
	});
	$("#netGw").value = c.net.gw || "（未配置）";
	$("#netConfPath").textContent = c.net.conf || "（未找到配置文件）";
	$("#netMac").textContent = c.net.mac || "—";

	// 只读区: 固件实际生效的参数。scfg 里的 CHAR 值可能写成 1 也可能写成
	// 0x01, 统一按十六进制转回十进制再映射, 两边都要认。
	const f = c.fwcfg || {};
	const dec = (v) => (v == null || v === "" ? "" : String(parseInt(v, 16) || 0));
	$("#fcDatapath").textContent = datapathText(dec(f.datapath));
	$("#fcLlidMode").textContent =
		f.llid_mode == null || f.llid_mode === ""
			? "—"
			: dec(f.llid_mode) === "1"
				? "多 LLID（1）"
				: "单 LLID（0）";
	$("#fcLlidNum").textContent = f.llid_num || "—";
	$("#fcOam").textContent = oamText(dec(f.oam_mode));
	$("#fcEnc").textContent = encText(f.encrypt_mode);
	$("#fcReg").textContent = regText(dec(f.register_mode));
	$("#fcBcmc").textContent =
		f.bcmc == null || f.bcmc === ""
			? "—"
			: dec(f.bcmc) === "1"
				? "始终转发（1）"
				: "去注册后停止（0）";
	$("#fcHw").textContent = f.hw_version || "—";
	$("#pathNote").textContent = c.paths?.write
		? `以上参数读自 ${c.paths.read || "scfg.txt"}；本页保存时写入 ${c.paths.write}。`
		: "未找到可写的 scfg.txt，保存会失败——请到「系统 → 环境自检」查看原因。";

	$("#ponPathHint").textContent = c.paths?.write ? `写入 ${c.paths.write}` : "未找到可写的 scfg.txt";
	$("#ponVariantTag").textContent = `原厂 CTC · ${c.fw?.build || "版本未知"}`;

	renderIdent(c.ident?.raw || "");
}

function renderIdent(raw) {
	const box = $("#identChips");
	const items = String(raw || "").split("|").filter(Boolean);
	if (!items.length) {
		box.innerHTML = `<span class="chip muted">未读到 mfginfo 分区</span>`;
		return;
	}
	box.innerHTML = items
		.map((t) => {
			const label = /^XE-9/i.test(t) ? "型号" : /^CIG/i.test(t) ? "厂商" : /^\d+\.\d+$/.test(t) ? "硬件/版本" : "标识";
			return `<span class="chip"><em>${label}</em>${esc(t)}</span>`;
		})
		.join("");
}

function datapathText(v) {
	if (v === "1") return "桥接（SFU，1）";
	if (v === "0") return "路由（R/G，0）";
	return v ? `未知（${v}）` : "—";
}

function oamText(v) {
	return { "0": "CTC（0）", "1": "DPoE（1）", "2": "KT（2）" }[v] || (v ? `其他（${v}）` : "—");
}

function encText(v) {
	const n = String(parseInt(v, 16) || 0);
	return {
		0: "关闭",
		1: "AES-CTR",
		2: "AES-CFB",
		3: "MACSEC",
		4: "SW CTC 搅动",
		5: "HW CTC 搅动",
	}[n] || (v ? `未知（${v}）` : "—");
}

function regText(v) {
	return { "0": "手动", "1": "开机自动", "2": "OAM 触发" }[v] || (v ? `其他（${v}）` : "—");
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
		toast(`已保存 ${okCount} 项，重启后生效`, "ok");
	}
	await loadConfig();
	refreshStatus().catch(() => {});
}

/* ------------------------------------------------------------------ 路由 -- */
const VIEWS = {
	dashboard: ["总览", "设备状态与光链路"],
	pon: ["PON 与认证", "PON MAC / LOID / 模式 / 链路详情"],
	network: ["网络", "管理地址与接口状态"],
	tools: ["工具与诊断", "分区、备份与原始输出"],
	system: ["系统", "账号、环境自检与危险操作"],
};

function goto(view) {
	if (!VIEWS[view]) view = "dashboard";
	$$(".nav-item").forEach((b) => b.classList.toggle("active", b.dataset.view === view));
	$$(".view").forEach((v) => v.classList.toggle("active", v.dataset.view === view));
	const meta = VIEWS[view];
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
		const env = d.env || {};
		renderProbe(env);
		renderConn(env.conn || null);
		return true;
	} catch (e) {
		/* 探测失败不影响主流程, 页面保留占位符 */
		return false;
	}
}

/* ------------------------------------------------------------ 设备连接 -- */
/* 远端模式下设备可能随时掉线。这里把"连不上"的原因直接摆到页面上,
   而不是让用户对着一屏横杠去猜是掉电、地址变了还是密码错了。 */
function renderConn(c) {
	state.conn = c;
	const card = $("#connCard");
	const box = $("#connState");
	const txt = $("#connStateText");
	if (!card || !box || !txt) return;

	box.classList.remove("ok", "bad", "warn");

	if (!c || c.mode !== "remote") {
		// 本机模式(直接装在设备上)不显示这张卡
		card.hidden = true;
		box.classList.add("ok");
		txt.textContent = "本机";
		hideOffline();
		return;
	}
	card.hidden = false;

	if (c.configured === false) {
		// 远端模式但还没填地址: 这不是"故障", 是还没配置
		box.classList.add("warn");
		txt.textContent = "未配置";
		showOffline("还没填猫棒地址，填好才能读取设备数据", "", true);
		return;
	}

	if (c.reachable) {
		box.classList.add("ok");
		txt.textContent = `${c.host} · ${c.ms || 0}ms`;
		hideOffline();
	} else {
		box.classList.add("bad");
		txt.textContent = "未连接";
		showOffline(c.error || "连接失败", c.host);
	}

	// 只填一次: 用户开始编辑后不能被轮询覆盖
	if (!state.connFilled) {
		const host = String(c.host || "");
		const i = host.lastIndexOf(":");
		$("#connHost").value = i > 0 ? host.slice(0, i) : host;
		$("#connPort").value = i > 0 ? host.slice(i + 1) : "22";
		$("#connUser").value = c.user || "root";
		$("#connTransport").value = c.transport || "ssh";
		$("#connKey").value = c.key || "";
		$("#connPassHint").textContent = c.has_pass ? "已保存密码，留空表示不修改" : "尚未保存密码（原厂固件为 admin）";
		state.connFilled = true;
	}

	// 认证方式提示: "为什么每次都要密码"和"缺 sshpass"是两回事, 分开说
	const kbtn = $("#btnConnKey");
	if (kbtn) kbtn.hidden = !(c.has_pass && c.auth === "pass" && c.sshpass !== false);
	const hint = $("#connHint");
	if (hint) {
		if (c.auth === "key") hint.textContent = "当前为免密登录，密码只在推送公钥时用过一次";
		else if (c.auth === "pass" && c.sshpass === false) hint.textContent = "本机缺少 sshpass，密码登录不可用：apk add sshpass";
		else if (c.auth === "pass") hint.textContent = "当前为密码登录，点「推送公钥」可改成免密";
		else hint.textContent = "改动保存后立即生效，无需重启服务";
	}
}

function showOffline(msg, host, unset) {
	const b = $("#connBanner");
	if (!b) return;
	$("#connBannerTitle").textContent = unset
		? "尚未连接猫棒"
		: host
			? `无法连接设备 ${host}`
			: "无法连接设备";
	$("#connBannerMsg").textContent = msg;
	const fix = $("#btnBannerFix");
	if (fix) fix.textContent = unset ? "去连接" : "去修改地址";
	$("#btnBannerRetry").hidden = !!unset;
	b.hidden = false;
}

function hideOffline() {
	const b = $("#connBanner");
	if (b) b.hidden = true;
}

/* -------------------------------------------------- 首次连接向导 -- */
/* 装在小主机上的场景, 登录后第一件事就是告诉它猫棒在哪。做成向导而不是
   让用户去系统页翻卡片, 是因为大多数人装完根本不知道要填什么。 */
function openSetup() {
	const m = $("#setupModal");
	if (!m) return;
	state.setupOpen = true;

	const c = state.conn || {};
	const host = String(c.host || "");
	const i = host.lastIndexOf(":");
	if (c.configured !== false && i > 0) {
		$("#setupHost").value = host.slice(0, i);
		$("#setupPort").value = host.slice(i + 1);
	}
	if (c.user) $("#setupUser").value = c.user;
	if (c.transport) $("#setupTransport").value = c.transport;
	// 已经存过密码就不回显, 留空表示沿用
	$("#setupPass").value = c.has_pass ? "" : "admin";
	$("#setupPass").placeholder = c.has_pass ? "已保存，留空表示不修改" : "原厂默认 admin";

	$("#setupMsg").textContent = "";
	setSetupState("", "等待连接");
	m.hidden = false;
	setTimeout(() => $("#setupHost").focus(), 80);
}

function closeSetup() {
	state.setupOpen = false;
	const m = $("#setupModal");
	if (m) m.hidden = true;
}

function setSetupState(kind, text) {
	const box = $("#setupState");
	if (!box) return;
	box.classList.remove("ok", "bad", "run");
	if (kind) box.classList.add(kind);
	$("#setupStateText").textContent = text;
}

async function setupConnect() {
	const host = $("#setupHost").value.trim();
	const msg = $("#setupMsg");
	msg.textContent = "";
	if (!host) {
		msg.textContent = "请填写猫棒地址";
		return;
	}
	const btn = $("#setupGo");
	busy(btn, true);
	setSetupState("run", "正在连接…");
	try {
		const d = await api("conn_save", {
			host,
			port: $("#setupPort").value.trim() || "22",
			user: $("#setupUser").value.trim() || "root",
			pass: $("#setupPass").value,
			transport: $("#setupTransport").value,
		});
		state.connFilled = false; // 让系统页按新配置重填
		renderConn(d.conn);
		if (d.conn && d.conn.reachable) {
			setSetupState("ok", `${d.conn.host} · ${d.conn.ms || 0}ms`);
			$("#setupPass").value = "";
			toast(d.pushed ? "已连接，并已配置免密登录" : "已连接", "ok");
			await new Promise((r) => setTimeout(r, 450));
			closeSetup();
			await Promise.all([loadProbe(true), refreshStatus(), loadConfig()]).catch(() => {});
		} else {
			setSetupState("bad", "连不上");
			msg.textContent = (d.conn && d.conn.error) || "连接失败，请检查地址与账号";
		}
	} catch (e) {
		setSetupState("bad", "连接失败");
		msg.textContent = e.message;
	}
	busy(btn, false);
}

async function testConn() {
	const btn = $("#btnConnTest");
	// 把表单里的值一起发过去: 用户改完地址想先试一下, 不该强制先保存
	const params = { transport: $("#connTransport").value };
	const host = $("#connHost").value.trim();
	if (host) {
		params.host = host;
		params.port = $("#connPort").value.trim() || "22";
		params.user = $("#connUser").value.trim() || "root";
		params.pass = $("#connPass").value;
		params.key = $("#connKey").value.trim();
	}
	busy(btn, true);
	try {
		const d = await api("conn_test", params);
		renderConn(d.conn);
		state.connFilled = true;
		if (d.conn && d.conn.reachable) toast(`连接正常 · ${d.conn.ms || 0}ms`, "ok");
		else toast((d.conn && d.conn.error) || "连接失败", "err");
	} catch (e) {
		toast(e.message, "err");
	}
	busy(btn, false);
}

async function saveConn() {
	const host = $("#connHost").value.trim();
	if (!host) return toast("请填写设备地址", "err");
	const btn = $("#btnConnSave");
	busy(btn, true);
	try {
		const d = await api("conn_save", {
			host,
			port: $("#connPort").value.trim() || "22",
			user: $("#connUser").value.trim() || "root",
			pass: $("#connPass").value,
			key: $("#connKey").value.trim(),
			transport: $("#connTransport").value,
		});
		$("#connPass").value = "";
		renderConn(d.conn);
		state.connFilled = true;
		if (d.conn && d.conn.reachable) {
			toast(d.pushed ? "已保存，连接正常（已配置免密登录）" : "已保存，连接正常", "ok");
			hideOffline();
			// 换了设备就把数据重新拉一遍
			await Promise.all([loadProbe(true), refreshStatus(), loadConfig()]).catch(() => {});
		} else {
			toast("已保存，但连不上：" + ((d.conn && d.conn.error) || "未知原因"), "err");
		}
	} catch (e) {
		toast(e.message, "err");
	}
	busy(btn, false);
}

// 手动把公钥推给猫棒, 之后免密登录(密码只在这时候用一次)
async function pushKey() {
	const btn = $("#btnConnKey");
	if (btn) busy(btn, true);
	try {
		const d = await api("conn_key", {});
		renderConn(d.conn);
		toast("已推送公钥，后续免密登录", "ok");
	} catch (e) {
		toast(e.message, "err");
	}
	if (btn) busy(btn, false);
}

function renderProbe(e) {
	const set = (id, txt) => {
		const el = $(id);
		if (el) el.textContent = txt;
	};

	set("#pbMode", e.mode === "remote" ? "远端（本机代理，经 SSH 管理猫棒）" : "本机（直接装在猫棒上）");
	const ver = [];
	if (e.fw_version && e.fw_version !== "unknown") ver.push(e.fw_version);
	if (e.fw_build && e.fw_build !== "unknown" && e.fw_build !== e.fw_version) ver.push("构建 " + e.fw_build);
	set("#pbVersion", ver.join(" · ") || "—");
	set("#pbIros", e.iros === "1" ? e.iros_cmd || "iros" : "不可用（读不到 PON 状态）");
	set("#pbPort", e.port_id || "—");
	set("#pbRead", e.read_targets || "（未找到 scfg.txt，配置页可能读到空值）");
	set("#pbWrite", e.write_targets || "（无可写目标，保存会失败）");
	set("#pbMfg", e.mfg ? e.mfg.split("|").slice(0, 3).join(" · ") : "未读到 mfginfo");
	set("#pbTools", e.tools || "（无可用的调试命令）");
	set("#pbKernel", e.kernel || "—");

	const tag = $("#probeTag");
	if (tag) {
		tag.textContent = e.iros === "1" ? "iROS 正常" : "iROS 缺失";
		tag.className = "tag" + (e.iros === "1" ? "" : " warn");
	}
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
		tbody.innerHTML = d.parts
			.map(
				(p) => `<tr>
					<td>${p.id}</td>
					<td class="mono">${esc(p.name)}</td>
					<td>${fmtBytes(p.size)}</td>
					<td class="mono">${p.erase ? (p.erase / 1024).toFixed(0) + " KB" : "—"}</td>
					<td><button class="btn sm ghost" data-dump="${p.id}" data-name="${esc(p.name)}">导出</button></td>
				</tr>`,
			)
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

	// 设备连接
	$("#btnConnTest").addEventListener("click", testConn);
	$("#btnConnSave").addEventListener("click", saveConn);
	$("#connForm").addEventListener("submit", (e) => e.preventDefault());
	if ($("#btnConnKey")) $("#btnConnKey").addEventListener("click", pushKey);

	// 首次连接向导
	$("#setupForm").addEventListener("submit", (e) => {
		e.preventDefault();
		setupConnect();
	});
	$("#setupGo").addEventListener("click", setupConnect);
	$("#setupSkip").addEventListener("click", () => {
		closeSetup();
		if (state.conn && state.conn.configured === false) {
			showOffline("还没填猫棒地址，填好才能读取设备数据", "", true);
		}
	});
	$("#setupModal").addEventListener("click", (e) => {
		if (e.target === $("#setupModal")) $("#setupSkip").click();
	});

	$("#btnBannerRetry").addEventListener("click", async () => {
		const ok = await loadProbe(true);
		if (ok && state.conn && state.conn.reachable) {
			toast("设备已恢复连接", "ok");
			await Promise.all([refreshStatus(), loadConfig()]).catch(() => {});
		} else if (!ok) {
			toast("重试失败", "err");
		}
	});
	$("#btnBannerFix").addEventListener("click", () => {
		if (state.conn && state.conn.mode === "remote" && state.conn.configured === false) {
			// 还没配置过: 复用向导, 比把用户丢到系统页更快
			openSetup();
			return;
		}
		state.connFilled = true;
		goto("system");
		setTimeout(() => {
			const el = $("#connHost");
			if (el) {
				el.focus();
				el.select();
			}
		}, 120);
	});

	// 危险操作
	$$("[data-action]").forEach((b) => b.addEventListener("click", () => doAction(b.dataset.action, b)));

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
}

/* ------------------------------------------------------------------ 动作 -- */
const ACTIONS = {
	reboot: ["重启设备", "设备将重启，约 180 秒后恢复。期间光链路和网络都会中断，确认继续？", "重启中…"],
	factory_reset: [
		"恢复出厂配置",
		"会清空 <code>/overlay/upper/*</code> 下的全部配置（含本控制台的设置与密码），且不可撤销。确认继续？",
		"已清空，请重启设备",
	],
	pon_reset: [
		"重新触发 PON 注册",
		"调用固件内置的 <code>ca_epon_reset_pon_mac</code> 复位 PON MAC，ONU 会重新走一遍 MPCP 注册。管理连接不会中断，但业务会闪断几秒。确认继续？",
		"已下发重注册指令",
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
		if (name === "pon_reset") setTimeout(() => refreshStatus().catch(() => {}), 4000);
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
