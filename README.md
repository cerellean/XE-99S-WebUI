# XE-99S WebUI（未验证）

为 **CIG XE-99S**（10G-EPON SFP+ 光猫棒，Cortina CA8271S）编写的 Web 控制台。
默认按 **SIEPON Package-C 原厂固件（CTC20220901，中国电信 CTC 标准）** 校准，
同时兼容 SIEPON Package-A 自定义固件——两者的差异由运行时**实测探测**决定，不靠猜。

零依赖：后端是纯 POSIX shell + awk 的 CGI（跑在设备自带的 busybox httpd 上），前端是原生 HTML/CSS/JS 单页应用，**没有任何 CDN、npm、Python 依赖**——因为这台棒子桥接模式下根本出不了网。

```
CIG XE-99S · Cortina CA8271S (MIPS) · Linux 4.4 · 128MB NAND (A/B 双分区) · 128MB RAM
固件: SIEPON Package-C (原厂 CTC) / Package-A (YuukiJapanTech/CA8271x v1.1.0+)
资料: hack-gpon.org/epon/CIG_XE-99S
```

---

## 两种固件，一套控制台

|              | SIEPON Package-C（原厂）               | SIEPON Package-A（自定义）            |
| ------------ | -------------------------------------- | ------------------------------------- |
| 版本         | CTC20220901（中国电信 CTC 标准）       | v1.0.0 ~ v1.3.0                       |
| 自带 WebUI   | ❌ 没有（本项目的价值所在）             | ✅ 自带（本控制台与之并存，8080 端口） |
| SSH / Telnet | `root` / **`admin`**                   | `root` / `ca8271`                     |
| rootfs       | 多为只读 squashfs，写入落 overlay 上层 | `/userdata` 可写                      |
| 认证生态     | CTC：LOID + LOID 密码 / SN / MAC       | 通用 DPoE TLV                         |

**不用告诉程序你用的是哪种固件**：装好后打开「系统 → 环境自检」，它会实测并告诉你
固件类型、scfg.txt 的真实读写路径（含 overlay 上层）、可用的工具、ca-iros 端口号。
所有写入都落在自检页列出的路径上；某项能力不存在时界面会禁用并说明原因，而不是假装成功。

---

## 功能一览

| 模块           | 说明                                                         | 落点（真实存储位置）                                         |
| -------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| **总览**       | PON 注册 / 认证状态、OLT MAC、光功率（RX/TX/温度/电压/偏置）、系统信息、流量 | 实时查询 `ca-iros`、i2c DDM、`/proc`                         |
| **PON 与认证** | PON MAC、LOID、LOID 密码、**序列号 SN**、PON 模式、Report 模式，附国内三大运营商认证方式速查 | `scfg.txt`（LOID 24 字节 HEX 数组、密码 12 字节）或 uboot env |
| **TLV 伪装**   | DPoE D7/03~D7/13 全套（固件/芯片/生产日期/厂商/型号/硬件版本） | `fw_setenv`（`CA8271_*`）与 `onu_manu_modle.ini`             |
| **桥接与转发** | 强制桥接、MAC 过滤、强制业务                                 | `CA8271_FORCE_BRIDGE` 等 uboot 环境变量                      |
| **网络**       | 管理地址/掩码、接口流量                                      | `/etc/network/interfaces` eth0 段                            |
| **工具与诊断** | 配置备份下载、NAND 分区表与原始镜像导出、7 类原始诊断输出、日志 | `/proc/mtd`、`nanddump`                                      |
| **系统**       | 改密码（改完吊销所有会话）、**环境自检**、重新触发 PON 注册、重启 / 恢复 overlay | `/userdata/webui/etc/*`                                      |

---

## 快速部署

### 前提

- 设备管理地址 `192.168.0.1`，SSH 与 Telnet 均为 `root` / **`admin`**
  （Package-A 自定义固件：密码 `ca8271`；少数老批次原厂为空密码，用 `SSH_PASS=''`）
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

### 卸载

```sh
sh uninstall.sh 192.168.0.1
```

只删 `/userdata/webui` 与自启项，不影响 PON 业务。

---

## 设计与安全

这台棒子写错一个字节就可能变砖，所以整个实现围绕**保守**两个字：

1. **先探测，再动手**：`lib/probe.sh` 实测 scfg.txt 读写路径（含 `/overlay/upper/config/`
   这类 overlay 上层）、可用工具、被占用端口、ca-iros 的 port_id。原厂固件 rootfs 只读时
   会自动把写入落到 overlay 上层，不会对着只读路径白写。
2. **写入全部走白名单校验**：字段名白名单 + 值格式校验。前端传任何 `; rm -rf`、`` `id` ``、
   `$(...)` 都会在校验层被拒——已实测注入样本全部拦截。
3. **只允许写已知键**：`scfg.txt` 的写入是「删同名键旧行 + 追加一行」，其他行原样保留；
   绝不重写整个文件，也绝不碰 `default_scfg.txt`。
4. **每次写入前自动备份**：被改的文件先存到 `/userdata/webui/var/backup/`（带时间戳）。
5. **能力缺失就明说**：固件没有可写的 SN 位置时输入框直接禁用并给出原因；
   DDM、`fw_setenv`、`nanddump` 缺失时逐项降级。
6. **改密码即轮换签名密钥**：所有旧登录态立即失效。
7. **无任意命令执行接口**：诊断页只输出预设命令（scfg / env / pon / mtd / net / ddm / log / sys）。
8. 令牌为 HMAC 签名，存 sessionStorage，过期自动登出。

### 已知的硬件不确定点（都做了降级）

| 功能              | 依赖                                    | 若设备上不可用             |
| ----------------- | --------------------------------------- | -------------------------- |
| 光功率 DDM        | `i2cget` + `/dev/i2c-N`（SFF-8472 A2h） | 显示「无 DDM 数据」        |
| TLV / 桥接写入    | `fw_setenv` / `fw_printenv`             | 保存时报错并提示原因       |
| SN 写入           | scfg 键或 `fw_setenv`                   | 输入框禁用，自检页说明     |
| 重新触发 PON 注册 | PON/OMCI 服务脚本                       | 按钮报错提示（可改用重启） |
| 分区导出          | `nanddump`                              | 按钮报错提示               |

以上参数都可在 `/userdata/webui/etc/webui.conf` 里人工覆盖
（`I2C_BUS`、`I2C_ADDR`、`PON_PORT_ID`、`SCFG_WRITE_OVERRIDE`）。

---

## 目录结构

```
xe99s-webui/
├── install.sh              # PC 侧一键部署 (ssh/tar)
├── uninstall.sh            # 卸载
├── device/                 # 部署到棒子 /userdata/webui 的全部内容
│   ├── www/                # 前端 (index.html + app.css + app.js)
│   ├── cgi-bin/api.cgi     # API 路由 (单一入口)
│   ├── cgi-bin/backup.cgi  # 配置/分区下载
│   ├── lib/common.sh       # JSON、表单解析、认证、校验
│   ├── lib/device.sh       # 设备抽象层 (scfg/env/sn/ddm/mtd 读写)
│   ├── lib/probe.sh        # 环境探测 (固件类型/读写路径/工具/port_id)
│   ├── lib/actions.sh      # 业务逻辑与 JSON 组装
│   ├── lib/mock.sh         # 本地模拟层 (仅开发, 不会部署到设备)
│   ├── lib/urldecode.awk   # 表单解码 (LC_ALL=C 按字节, 兼容 busybox)
│   ├── etc/webui.conf      # 端口、i2c 总线等运行配置
│   ├── etc/httpd.conf      # busybox httpd CGI 配置
│   ├── init.d/S99webui     # 服务管理 {start|stop|restart|status}
│   └── install-remote.sh   # 设备端初始化
└── dev/
    ├── serve.py            # 本地开发服务器 (模拟 busybox httpd 的 CGI 环境)
    ├── shots.py            # Playwright 截图脚本
    └── mock_state/         # 模拟设备状态 (运行时生成)
```

## 本地预览（不插棒子也能看）

```sh
python3 dev/serve.py --port 8080
# 打开 http://127.0.0.1:8080  账号 admin / admin
# WEBUI_MOCK_FW=A python3 dev/serve.py   # 想预览 Package-A 固件形态时
```

`dev/serve.py` 用和 busybox httpd 相同的方式 fork shell 执行 CGI，
所以你看到的就是设备上跑的同一套代码（`lib/mock.sh` 提供虚拟硬件）。

---

## 常见问题

**Q: 设备 root 密码怎么改？**
本项目不碰设备账号。要改的话 SSH 进去执行 `passwd`；改动后记得同步 `SSH_PASS` 再跑部署脚本。
WebUI 自己的登录密码和它是两套东西，在「系统」页单独改。

**Q: 我是原厂 C 固件，80 端口能用吗？**
可以。原厂固件没有自带 WebUI，把 `webui.conf` 的 `PORT` 改成 80 即可；
自检页的「已被占用」一栏会告诉你哪些端口真的空闲。保持 8080 也完全没问题。

**Q: 运营商到底要填 LOID 还是 SN？**
中国电信以 LOID + LOID 密码为主，联通常见 LOID 或 SN，移动常见 SN，部分省份都绑 PON MAC。
PON 页有速查卡；最可靠的来源是原光猫背面标签或其管理页面。

**Q: 保存后要重启吗？**
PON 参数、TLV、桥接开关都是开机时由固件读取的，改完需要重启（约 180 秒）；
「重新触发 PON 注册」不重启整机，只重启 PON 服务，管理连接不会断。

**Q: 改坏了怎么恢复？**
所有被改文件都有时间戳备份在 `/userdata/webui/var/backup/`；
配置文本备份可随时在「工具」页下载；分区原始镜像也支持导出（参考 hack-gpon 的 nandwrite 流程刷回）。

**Q: 想加字段？**
三层各改一处：前端加 `data-field` 输入框 → `actions.sh` 的 `act_set` 加 case 与校验 →
`device.sh` 落到 `scfg_write` / `env_set` / `ini_set`。

---

## ⚠️ 使用须知

- 本项目只在本机配置层面读写，**不提供刷固件功能**；写坏分区需自行用编程器/nandwrite 恢复。
- 修改 ONT 标识（MAC/LOID/SN/TLV）用于与运营商 OLT 互通时，请确认你有权使用该线路；
  由此导致的服务中止或违约风险自负。这一点与上游 CA8271x 项目的声明一致。
- 不要把 WebUI 暴露到公网：它面向的是管理网段（192.168.0.x）。
