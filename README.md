# XE-99S WebUI

为 **CIG XE-99S**（10G-EPON SFP+ 光猫棒，Cortina CA8271S）编写的 Web 控制台。
**只支持原厂 SIEPON Package-C 固件（CTC20220901，中国电信 CTC 标准）**——
v2.0 起，TLV 伪装与「桥接与转发」两个页面已删除：原厂固件根本没有读取/执行
这两组配置的代码，留着只会误导。

支持两种安装形态，同一套代码：
- **装在猫棒上**（本机模式）：直接管理本机
- **装在局域网内任意小主机上**（远端模式，Alpine 已验证）：猫棒可以插在交换机、
  路由器或任何有 SFP+ 口的机器上，只要小主机能通过网络访问猫棒的 SSH 端口即可。
  WebUI 跑在小主机，所有设备操作经 SSH（或 Telnet）转发到猫棒执行——猫棒侧零安装、零改动。
  登录后首次使用会在控制台里引导填写猫棒地址/账号/密码并自动连接（之后随时在
  「系统 → 设备连接」里改）；连不上时页面直接告诉你原因

零依赖：后端是纯 POSIX shell + awk 的 CGI（跑在设备自带的 busybox httpd 上），前端是原生 HTML/CSS/JS 单页应用，**没有任何 CDN、npm、Python 依赖**——因为这台棒子桥接模式下根本出不了网。

```
CIG XE-99S · Cortina CA8271S (MIPS) · Linux 4.4 · 128MB NAND (A/B 双分区) · 128MB RAM
固件: SIEPON Package-C (原厂 CTC, root/admin)
资料: hack-gpon.org/epon/CIG_XE-99S
```

---

## 功能一览

| 模块 | 说明 | 落点（真实存储位置） |
|---|---|---|
| **总览** | PON 注册 / 认证 / LLID / OLT MAC、光功率（RX/TX/温度/电压/偏置）、系统信息、数据通路模式 | 实时查询设备内置 `iros`、`/proc` |
| **PON 与认证** | PON MAC、LOID、LOID 密码、PON 模式、Report 模式；只读展示当前链路（MPCP LLID、去注册原因、重试次数）、固件实际生效参数、mfginfo 出厂标识 | `/config/scfg.txt`（LOID 24 字节、密码 12 字节 HEX 数组） |
| **网络** | 管理地址/掩码、接口速率与流量、管理口 MAC、VLAN 透传说明 | `/etc/network/interfaces` eth0 段 |
| **工具与诊断** | 配置备份下载、NAND 分区表与原始镜像导出、7 类原始诊断输出（PON / scfg / DOM / 分区 / 网络 / env / 日志） | `/proc/mtd`、`nanddump` |
| **系统** | 改密码（改完吊销所有会话）、**环境自检**、`ca_epon_reset_pon_mac` 在线重注册、重启 / 恢复 overlay | `/userdata/webui/etc/*` |

**VLAN**：原厂固件是桥接型 SFU，802.1Q 帧在 PON 与 UNI 之间原样透传，OLT 下发的
VLAN 规则照常生效，猫棒侧无需也不能再配 VLAN（网络页有说明）。

---

## 快速部署

### 前提

- 设备管理地址 `192.168.0.1`，SSH 与 Telnet 均为 `root` / **`admin`**
  （少数老批次原厂为空密码，用 `SSH_PASS=''`）
- PC 与棒子同网段（PC 设为 `192.168.0.5/24`）
- PC 上有 `ssh`、`tar`（Linux/macOS/WSL 均可）
- 装了 `sshpass` 可全自动（脚本会自动用 `admin` 登录）：
  `sudo apt install sshpass` / `brew install hudochenkov/sshpass/sshpass`
- 没装也能用：脚本会提示手动输一次密码，并通过 SSH 连接复用让整轮部署只问一次

### 一键安装

```sh
cd xe99s-webui
sh install.sh                    # 默认 root@192.168.0.1, 自动尝试密码 admin
sh install.sh 192.168.0.1        # 指定地址
SSH_PASS='其它密码' sh install.sh  # 改过 root 密码时(需 sshpass 免交互)
```

脚本会把 `device/` 推到棒子的 `/userdata/webui`（持久分区，重启不丢），
生成账号 `admin / admin`，探测可用的 httpd 并启动，最后自动注册开机自启。

安装完成后访问 **http://192.168.0.1:8080**，登录后请立即在「系统」页改密码。

### 手动安装（SSH 不通时）

先用 UART（115200 8N1，TTL 3.3V）或 `telnet 192.168.0.1`（root / admin）拿到 root shell，然后：

```sh
# 在 PC 上打包
tar czf /tmp/webui.tgz -C device .
# 在 PC 上传 (棒子自带 tftp 客户端, 把文件放到 TFTP 服务器根目录后:)
tftp -r webui.tgz -g 192.168.0.5
mkdir -p /userdata/webui && tar xzf /tmp/webui.tgz -C /userdata/webui
sh /userdata/webui/install-remote.sh
```

### 装在 Alpine 小主机上（远程管理猫棒）

适合：猫棒不在自己手边（插在交换机/别人的机器上），但 Alpine 小主机能通过网络
访问它的 SSH 端口。WebUI 跑在小主机上，LAN 里的手机/电脑都能打开它管理猫棒；
猫棒侧只开 SSH，什么都不装。不要求猫棒直插小主机。

在 Alpine 上以 root 执行（**不需要知道猫棒地址**）：

```sh
sh install-alpine.sh            # 落文件 + 生成密钥 + 注册 OpenRC 自启, 无任何交互
rc-service xe99s-webui status   # 服务管理
```

然后浏览器打开 `http://<小主机IP>:8080`，用 `admin / admin` 登录控制台。
登录页只认 WebUI 自己的账号；登录后若还没配置过猫棒，会自动弹出
「首次配置」向导，在控制台里填**猫棒的**地址、账号、密码（原厂固件默认
`192.168.0.1 / root / admin`），点「连接」即自动保存并连上：

- 连接成功后自动把小主机的公钥推给猫棒（写不进 `/root/.ssh` 时自动改用
  `/etc/dropbear/authorized_keys`），之后免密登录，密码只用这一次
- 点「先看看界面」跳过也行——顶部会有「尚未连接猫棒」横幅，点「去连接」随时
  重新打开向导
- 已配置过则登录后直接进控制台，不再打扰；连接失败的原因（超时/拒绝/认证失败）
  显示在顶部横幅与向导内，点「去修改地址」直达表单
- **换地址/改密码不用回后台**：向导或「系统 → 设备连接」里改完点保存立即生效
- 每次 API 请求用一次 SSH 往返批量预取设备文件，读写都在本地解析后推回，
  页面响应通常 100~300ms（连接复用生效时）
- 备份存在小主机本地（`/opt/xe99s-webui/var/backup/`），不占猫棒 flash
- SSH 实在用不了时，`REMOTE_TRANSPORT=telnet sh install-alpine.sh` 可走 Telnet
  （原厂 root/admin，实验性，需 `apk add expect`；无退出码，可靠性不如 SSH，优先用 SSH）
- 进阶（可跳过）：`sh install-alpine.sh 192.168.0.1` 会预先把地址写进配置；
  `REMOTE_PASS=admin sh install-alpine.sh 192.168.0.1` 则在安装阶段就推好公钥
- 卸载：`rc-service xe99s-webui stop && rc-update del xe99s-webui && rm -rf /opt/xe99s-webui /etc/init.d/xe99s-webui`

#### Alpine 上到底需要哪些包

只有 **3 个**，都可以由 `install-alpine.sh` 自动 `apk add`：

| 包 | 提供什么 | 必需性 | 说明 |
|---|---|---|---|
| `busybox-extras` | `httpd`（Web 服务器 + CGI） | **必需** | Alpine 把 busybox 拆过包：系统里的 `busybox` **不含** httpd applet，只装基础包会报 `httpd: applet not found`。脚本会按 applet 实检并补装 |
| `openssh-client` | `ssh`、`ssh-keygen` | **必需** | 远端模式下所有设备操作都经它转发；同时用于生成专用密钥 |
| `sshpass` | 非交互密码登录 | 建议 | OpenSSH 不支持从管道喂密码。首次连接靠它用密码登录并推送公钥，之后走免密就不再需要；`community` 仓库 |
| `expect` | telnet 后端 | 可选 | 只有 `REMOTE_TRANSPORT=telnet` 才用；SSH 可用时不必装 |

其余全部来自 busybox 自带（`ash`、`awk`、`sed`、`grep`、`cut`、`tr`、`wget`、`sha256sum`、`od`、`dd`、`ip` 等），
**不需要** nginx / lighttpd / apache、Python、Node、PHP、数据库，也不需要联网拉 CDN。

```sh
# 手动装也就这一行
apk add busybox-extras openssh-client sshpass
```

两个容易踩的点，脚本已经处理：

- **别指望 `command -v busybox` 能代表有 httpd**：Alpine 的 `busybox --list` 里没有 `httpd` 时，
  启动会直接 `applet not found`。安装脚本按 applet 真检测，缺就装 `busybox-extras`，装完再验一次。
- **自检不用 curl**：Alpine 最小安装没有 curl，脚本按 curl → wget → 进程存活 逐级降级判断。

端口默认 8080，被占用时 `WEBUI_PORT=9090 sh install-alpine.sh` 换一个。

> **网页能打开、登录却报 404？** 说明 CGI 放错了位置。busybox httpd 有个硬约定：
> URL `/cgi-bin/*` 只会映射到 **Web 根目录内** 的 `cgi-bin/`，放在 `www/` 平级永远 404
> （静态页正常、API 全挂）。重新跑一遍 `sh install-alpine.sh` 覆盖安装即可，其余不用动。

### 卸载（装在猫棒上时）

```sh
sh uninstall.sh 192.168.0.1
```

只删 `/userdata/webui` 与自启项，不影响 PON 业务。

---

## 这些参数是从哪来的（对照原厂固件）

v2.0 的每一条读写路径都对照原厂固件里的真实文件校准过，不是猜的：

| 本控制台的做法 | 原厂固件里的依据 |
|---|---|
| PON 状态用 `iros` 而不是 `ca-iros` | `/usr/bin/iros` 就是 `ca-iros /etc/ca-iros.rc`；只有经过这个 rc 才会加载 `wca_*` 命令库，直接调 `ca-iros` 拿不到 `wca_epon_*` 命令 |
| 一次 iros 会话取回注册 + LLID + DOM | 原厂自带 WebUI 的 `status.sh` 同样在一个会话里连发三条命令 |
| DOM 用 `cap_i2c_read 0 0xa2`（A2h 页） | 原厂 `BOSA.tcl` 的读法。温度/Vcc/偏置/收发光在 A2h 页（8 位地址 0xa2），读 0x50 只会拿到 A0h 页的厂商字符串 |
| scfg 只写 `/config/scfg.txt` 这一个文件 | 原厂 WebUI 的 `set_ponmac_set.sh` 就改这个；多写几份反而不可预测。rootfs 只读时 overlay 会把写入 copy-up 到 `/overlay/upper/config/scfg.txt`，从 `/config` 侧看依然可写 |
| 改 PON MAC 时同步 `CFG_ID_NE_MAC_ADDR0` | CTC 定制配置里两个键出厂就是同一个值，主机侧（eth0）用的是后者；不同步会造成 PON 侧与主机侧 MAC 不一致，部分省份的 MAC 绑定认证会失败（仅当两者原本相同才同步） |
| PON 口固定 `0x20007` | 原厂脚本的 classifier 规则（UNI `0x30006` → PON `0x20007`）与注册查询都用的这个值 |
| 「重新注册」用 `ca_epon_reset_pon_mac 0` | 原厂 iROS 自带的复位 API，比 `kill ca-app` 温和，也不会把管理口一起断掉 |
| 序列号只读展示 | 原厂 scfg（默认/定制）里**都没有**可写的 SN 键；SN 在产线写入的 `mfginfo` 分区（mtd9），固件没有任何 scfg/env 通路可改它 |
| 版本号读 `/etc/8271version` 与 `/etc/version` | 原厂自带 WebUI 的 `status.sh` 读的正是这两个文件 |
| Report 模式 0–5 的含义 | 来自 `default_scfg.txt` 的注释（2QS_8Q-0 … 4QS_1Q-4，NTT-5） |

**为什么删除 TLV 伪装**：D7/xx 上报值在原厂 `libca-oam.so` 里是编译期写死的，
原厂固件没有 `liboam_patch.sh`，改 uboot-env 不会有任何程序去读。写进去的
`CA8271_*` 变量是死数据，还会在刷 SIEPON-A 时“复活”成错误的上报身份。
**为什么删除「桥接与转发」**：原厂出厂即为桥接型 SFU（scfg 的
`CFG_ID_DATAPATH_MODE = 1`），OLT 下发的就是二层透传规则，没有可切换的路由模式；
强制桥接/强制业务依赖 SIEPON-A 的 `Background_API.sh`，原厂没有这个脚本。
两个页面对应的只是原厂固件里“不存在的能力”，删除比锁定更诚实。

---

## 设计与安全

这台棒子写错一个字节就可能变砖，所以整个实现围绕**保守**两个字：

1. **先探测，再动手**：`lib/probe.sh` 实测 scfg.txt 读写路径（含 `/overlay/upper/config/`
   这类 overlay 上层）、iROS 可用性、可用工具、出厂标识。原厂固件 rootfs 只读时
   会自动把写入落到 overlay 上层，不会对着只读路径白写。
2. **写入全部走白名单校验**：字段名白名单 + 值格式校验。前端传任何 `; rm -rf`、`` `id` ``、
   `$(...)` 都会在校验层被拒——已实测注入样本全部拦截。
3. **只允许写已知键**：`scfg.txt` 的写入是「删同名键旧行 + 追加一行」，其他行原样保留；
   绝不重写整个文件，也绝不碰 `default_scfg.txt`。
4. **每次写入前自动备份**：被改的文件先存到 `/userdata/webui/var/backup/`（带时间戳）。
5. **能力缺失就明说**：iROS 缺失、DOM 读取失败、`nanddump` 缺失时逐项降级，界面如实显示“无数据”而不是假成功。
6. **改密码即轮换签名密钥**：所有旧登录态立即失效。
7. **无任意命令执行接口**：诊断页只输出预设命令（pon / scfg / ddm / mtd / net / env / log / sys）。
8. 令牌为 HMAC 签名，存 sessionStorage，过期自动登出。

### 已知的硬件不确定点（都做了降级）

| 功能 | 依赖 | 若设备上不可用 |
|---|---|---|
| PON 状态 / DOM | `iros`（或 `ca-iros` + `/etc/ca-iros.rc`） | 显示「无 DDM 数据」「iROS 无返回」 |
| 出厂标识 | `nanddump` 或 `dd` 读 mfginfo | 显示「未读到 mfginfo 分区」 |
| 重新触发 PON 注册 | iROS 的 `ca_epon_reset_pon_mac` | 按钮报错并建议重启设备 |
| 分区导出 | `nanddump` | 按钮报错提示 |

以上参数都可在 `/userdata/webui/etc/webui.conf` 里人工覆盖
（`PON_PORT_ID`、`SCFG_WRITE_OVERRIDE`）。

---

## 目录结构

```
xe99s-webui/
├── install.sh              # PC 侧一键部署到猫棒 (ssh/tar)
├── install-alpine.sh       # Alpine 小主机侧安装(远端模式, 自动补 busybox-extras/sshpass)
├── uninstall.sh            # 卸载
├── device/                 # 部署到棒子 /userdata/webui 的全部内容
│   ├── www/                # 前端 (index.html + app.css + app.js)
│   │   └── cgi-bin/        # CGI 必须在 httpd 根目录内, 否则 busybox httpd 404
│   │       ├── api.cgi     # API 路由 (单一入口)
│   │       └── backup.cgi  # 配置/分区下载
│   ├── lib/common.sh       # JSON、表单解析、认证、校验
│   ├── lib/transport.sh    # 传输层: 本机/SSH/Telnet 三种后端的统一原语
│   ├── lib/device.sh       # 设备抽象层 (iros/scfg/ddm/mfg/mtd)
│   ├── lib/probe.sh        # 环境探测 (读写路径/iROS/工具/出厂标识)
│   ├── lib/actions.sh      # 业务逻辑与 JSON 组装
│   ├── lib/mock.sh         # 本地模拟层 (仅开发, 不会部署到设备)
│   ├── lib/urldecode.awk   # 表单解码 (LC_ALL=C 按字节, 兼容 busybox)
│   ├── etc/webui.conf      # 端口、PON 通道等运行配置
│   ├── etc/httpd.conf      # busybox httpd CGI 配置
│   ├── init.d/S99webui     # 服务管理 {start|stop|restart|status}
│   └── install-remote.sh   # 设备端初始化
└── dev/
    ├── serve.py            # 本地开发服务器 (模拟 busybox httpd 的 CGI 环境)
    ├── shots.py            # Playwright 截图脚本
    ├── test_remote.sh      # 远端模式自测 (模拟设备目录 + 等价 SSH 执行器)
    ├── test_iros.sh        # iROS 调用与 DOM 解析自测 (假 iros 记录发出的脚本)
    ├── test_conn.sh        # 连接状态归类 (认证失败/超时/拒绝/不可达)
    ├── test_alpine.sh      # Alpine 依赖判定 (busybox 无 httpd 的坑)
    ├── e2e.py              # 本机模式端到端
    ├── e2e_setup.py        # 登录 -> 首次配置向导 -> 自动连接 端到端
    └── mock_state/         # 模拟设备状态 (运行时生成)
```

## 本地预览（不插棒子也能看）

```sh
python3 dev/serve.py --port 8080
# 打开 http://127.0.0.1:8080  账号 admin / admin
```

`dev/serve.py` 用和 busybox httpd 相同的方式 fork shell 执行 CGI，
所以你看到的就是设备上跑的同一套代码（`lib/mock.sh` 提供虚拟硬件，
模拟数据的结构照抄原厂 `scfg.txt` / `default_scfg.txt`）。

---

## 常见问题

**Q: TLV 伪装去哪了？**
原厂固件不会读这些配置（D7/xx 编译期写死），删了。要改上报身份只能刷 SIEPON-A
自定义固件，那是另一个项目的功能，不要在本控制台上尝试二进制 patch。

**Q: 桥接/强制业务去哪了？**
原厂出厂就是桥接型 SFU，没有模式可切；强制业务依赖自定义固件的后台脚本。删了。
scfg 里的 `CFG_ID_DATAPATH_MODE` 在「PON 与认证 → 实际生效参数」里以只读方式展示。

**Q: 能改 SN 吗？**
不能。原厂 scfg 没有可写的 SN 键，SN 在 mfginfo 分区（mtd9），产线写入。
本控制台只读展示出厂标识，不提供 mfginfo 写入——写坏它会失去设备身份。

**Q: 设备 root 密码怎么改？**
本项目不碰设备账号。要改的话 SSH 进去执行 `passwd`；改动后记得同步 `SSH_PASS` 再跑部署脚本。
WebUI 自己的登录密码和它是两套东西，在「系统」页单独改。

**Q: 我是原厂 C 固件，80 端口能用吗？**
可以。原厂固件没有自带 WebUI，把 `webui.conf` 的 `PORT` 改成 80 即可；
保持 8080 也完全没问题。

**Q: 运营商到底要填 LOID 还是 SN？**
中国电信以 LOID + LOID 密码为主，联通常见 LOID 或 SN，移动常见 SN，部分省份都绑 PON MAC。
PON 页有速查卡；最可靠的来源是原光猫背面标签或其管理页面。

**Q: 保存后要重启吗？**
PON 参数都是固件开机时读的，改完需要重启（约 180 秒）；
「重新触发 PON 注册」不重启整机，只复位 PON MAC，管理连接不会断。

**Q: 改坏了怎么恢复？**
所有被改文件都有时间戳备份在 `/userdata/webui/var/backup/`；
配置文本备份可随时在「工具」页下载；分区原始镜像也支持导出（参考 hack-gpon 的 nandwrite 流程刷回）。

**Q: 想加字段？**
三层各改一处：前端加 `data-field` 输入框 → `actions.sh` 的 `act_set` 加 case 与校验 →
`device.sh` 落到 `scfg_write`。加之前先确认固件真的会读这个键（对照 `default_scfg.txt`
的注释或原厂脚本），否则就是又一个“写了不生效”的假开关。

---

## ⚠️ 使用须知

- 本项目只在本机配置层面读写，**不提供刷固件功能**；写坏分区需自行用编程器/nandwrite 恢复。
- 修改 ONT 标识（MAC/LOID）用于与运营商 OLT 互通时，请确认你有权使用该线路；
  由此导致的服务中止或违约风险自负。
- 不要把 WebUI 暴露到公网：它面向的是管理网段（192.168.0.x）。
