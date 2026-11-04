# instabox-cloudflare-deploy

> 一个可复用的 **Agent Skill**：把 Node.js / Next.js 应用部署到免费的 InstaBox 云主机，
> 用 Cloudflare Tunnel 绑到用户自有域名，并把「保活」从本机计划任务迁移到 Cloudflare Worker cron，
> 让网站不再依赖个人电脑。

Skill ID：`instabox-cloudflare-deploy`　版本：`1.0.0`

---

## 目录

- [这是什么](#这是什么)
- [快速开始](#快速开始)
- [能力边界](#能力边界)
- [前置条件](#前置条件)
- [配置项与参数含义](#配置项与参数含义)
- [部署与使用步骤](#部署与使用步骤)
- [典型使用场景](#典型使用场景)
- [常见问题（FAQ）](#常见问题faq)
- [故障排查](#故障排查)
- [注意事项与硬性纪律](#注意事项与硬性纪律)
- [安装方式](#安装方式)
- [仓库结构](#仓库结构)
- [自测](#自测)

---

## 这是什么

这份 Skill 把一整套「个人网站上线」的真实操作流程固化成了可执行的文档 + 脚本，覆盖四段链路：

```
GitHub 源码  ──►  InstaBox 云主机  ──►  Cloudflare Tunnel  ──►  Cloudflare Worker 保活
   (唯一事实源)     (4C8G / 0 元)        (自有二级域名)          (脱离个人电脑)
```

它不是通用教程，而是**一次真实部署踩坑后的复盘**：

- `SKILL.md` 只放工作流、决策点和硬性纪律，具体细节下沉到 `references/`
- 脆弱操作（打包、推送、装依赖、隧道、保活、验收）外部化为 `scripts/`，Windows 与 Linux/macOS 各一套
- 每一条踩过的坑都写成了**可自动检查的断言**（`scripts/test_skill_assets.py`），防止技能静默退回旧坑

---

## 快速开始

**1. 把这份 Skill 放到 agent 能读到的地方**（详见 [安装方式](#安装方式)）

**2. 让 agent 读 `SKILL.md`，它会按流程带你走**

**3. 人工确认四项前置信息**（缺任何一项必须先问用户，不要猜）：

| # | 需要的信息 | 获取方式 |
|---|---|---|
| 1 | **GitHub 仓库地址** + 分支 | 用户给；私有库需 PAT 或已有 git 凭据 |
| 2 | **InstaBox API Key**（`ibk_` 开头） | instabox.sh → 账户 → API Keys |
| 3 | **Cloudflare 账户** | `wrangler login --device` 或 API Token |
| 4 | **已有域名** + 要绑的二级域名 | 主域名 NS 必须已在 Cloudflare |

**4. 五步主流程**，每步都有验证点：

```
0. 预检      → scripts/preflight.ps1          验证凭证、机器状态、端口占用
1. 打包推送  → scripts/deploy.ps1             本机打包代码 → instabox push → 机器端安装
2. 数据传输  → 见 Step 1c                     SQLite 必须先 checkpoint（否则 malformed）
3. 隧道绑定  → 面板操作 + scripts/setup-tunnel.sh
4. 保活迁移  → scripts/keepalive/deploy-keepalive.ps1
5. 端到端验证 → scripts/verify-site.ps1
```

---

## 能力边界

### 用得上

- 上线到免费 InstaBox 云主机（0 元、免备案、4C8G）
- 已有 Cloudflare 托管的域名，想绑二级域名
- 要求「电脑关机网站仍在」
- Node / Next.js / SQLite 这类需要常驻进程的应用

### 用不上

- Vercel / Netlify 等静态托管（没有常驻进程，也就不需要本 Skill）
- Oracle / 自购 VPS 迁移（流程不同，代价模型也不同）
- 纯 Cloudflare Workers 应用开发（`node:sqlite` 在 Workers 里是空壳）
- 需要 24 小时零中断的站点 —— 免费额度有 8 小时硬上限，见下文

---

## 前置条件

### 免费额度实际规格（来自 `instabox get --json` / `instabox usage`）

| 项 | 值 | 是否可改 |
|---|---|---|
| 机器数量 | 1 台 | 付费档可增 |
| 规格 | 4 vCPU / 8 GiB 内存 | 固定（Pro 可到 8/16，Builder 可到 16/32） |
| `/data` 持久盘 | 20 GiB | **免费档不可 resize** |
| 系统盘 | 16 GiB | 模板自带 |
| 空闲挂起 | **固定 1800 秒（30 分钟）** | **改不掉**，`auto-suspend 0` 会被静默忽略 |
| 连续运行上限 | **固定 480 分钟（8 小时）** | 免费档改不了 |
| 冷却期 | 5–20 分钟随机 | — |
| 快照 | 5 个 | — |

> **8 小时上限是免费档最硬的边界**：跑满必被强制暂停，随后进入冷却期，期间任何唤醒方式都返回
> `409 machine_cooldown`。保活只能解决「空闲挂起」，解决不了它。要彻底消除中断只能升 Pro。

### 机器内环境（实测）

| 项 | 值 |
|---|---|
| OS | Debian 13 (trixie) x86_64 |
| Node | v22.23.3（**`node:sqlite` 需 ≥ 22.5**，否则报 `Cannot find module 'node:sqlite'`） |
| home | `/data/home` |
| 已有工具 | `git`、`curl`、`pm2`；**无 ImageMagick** |
| 模板预装 | Docker、Node.js、Bun、Python、Go、Rust、OpenJDK 21、桌面（Chromium / VNC / Xfce） |

### 域名前提

主域名的 NS 必须已经指向 Cloudflare（返回里有 `*.ns.cloudflare.com` 才算就绪）。
如果还没托管到 Cloudflare，得先去域名注册商改 NS，这一步不在本流程内。

---

## 配置项与参数含义

### 环境变量（模板见 `assets/env.example`）

复制成 `.env` 后按需填写。**`.env` 永不入库**，机器上 `chmod 600`。

| 变量 | 必填 | 含义 |
|---|---|---|
| `INSTABOX_API_KEY` | ✅ | InstaBox API Key（`ibk_` 开头）。CLI 与保活都用它 |
| `INSTABOX_MACHINE_NAME` | ✅ | 机器名，CLI 命令用 |
| `INSTABOX_MACHINE_ID` | ✅ | 机器 ID（`m_` 开头的 24 位）。**保活 API 只认 ID，用机器名会 404** |
| `CLOUDFLARE_API_TOKEN` | 二选一 | Cloudflare API Token，权限：Account `Workers Scripts: Edit` / `Workers KV Storage: Edit` / `Account Settings: Read`；Zone `Workers Routes: Edit` / `Zone: Read` |
| `CLOUDFLARE_ACCOUNT_ID` | 二选一 | 同上，Account ID |
| `BASE_DOMAIN` | ✅ | 主域名，NS 须已在 Cloudflare |
| `TARGET_DOMAIN` | ✅ | 要绑的二级域名（完整形式，如 `app.example.com`） |
| `APP_NAME` | — | 应用名，用于 pm2 进程名与日志，默认 `web-app` |
| `PORT` | — | 应用端口，默认 `3000` |
| `SITE_URL` | — | 对外地址，**务必与实际域名一致**，否则 sitemap/robots 里会是错的 |
| `APP_DIR` | — | 应用在机器上的目录，默认 `/data/home/<APP_NAME>` |
| `DATA_DIR` | — | 大目录（图片/数据），建议与 `APP_DIR` 分开便于容量管理 |
| `AMAP_WEB_KEY` | — | 高德地图 Web Key（应用侧需要地图时填） |
| `WECOM_WEBHOOK_URL` | — | 企微群机器人 Webhook。**留空 = 报名只入库不发通知**；此地址等同密码，勿外传 |
| `WORKER_NAME` | — | 保活 Worker 名，默认 `instabox-keepalive` |
| `KEEPALIVE_CRON` | — | cron 表达式，默认 `*/3 * * * *`。**间隔必须小于 TTL** |
| `KEEPALIVE_TTL` | — | 租约秒数，范围 30–3600，默认 `900` |
| `WORKER_TOKEN` | — | Worker 访问口令。**不设则任何人知道域名就能触发续租**。生成：`node -e "console.log(require('crypto').randomBytes(16).toString('hex'))"` |

### 脚本参数

#### `scripts/preflight.ps1` — 部署前体检

```bash
pwsh -File scripts/preflight.ps1 -Machine <机器名> -Domain <子域名> -Repo <仓库地址>
```

| 参数 | 默认 | 含义 |
|---|---|---|
| `-Machine` | `''` | InstaBox 机器名 |
| `-Domain` | `''` | 要绑的域名 |
| `-Repo` | `''` | 本地仓库路径 |
| `-ApiKey` | `''` | 不给则读环境变量 `INSTABOX_API_KEY` |
| `-Port` | `3000` | 应用端口 |
| `-MinFreeGiB` | `8` | `/data` 剩余空间下限，低于则不通过 |

通过标准：机器 `running`、Node ≥ 22.5、`/data` 剩余 ≥ 应用体积 × 2、Cloudflare 已登录。

#### `scripts/stage-code.ps1` — 打包代码（与数据分离）

```bash
pwsh -File scripts/stage-code.ps1 -Repo <本地仓库路径> -Stage <输出目录>
```

| 参数 | 必填 | 含义 |
|---|---|---|
| `-Repo` | ✅ | 本地仓库路径 |
| `-Stage` | ✅ | 输出目录（每次会先清空） |
| `-ExtraExcludeDirs` | — | 追加排除的顶层目录名数组 |

默认排除：`node_modules`、`.git`、`.next`、`data`、`logs`、`backups`、`coverage`。
**只含代码，保证「代码源」与「数据源」分离。**

#### `scripts/deploy.ps1` — 推送 + 机器端安装（Windows 编排）

```bash
pwsh -File scripts/deploy.ps1 -Machine <机器名> -Repo <本地仓库路径> -Port 3000
```

| 参数 | 默认 | 含义 |
|---|---|---|
| `-Machine` | `''` | InstaBox 机器名 |
| `-Repo` | `''` | 本地仓库路径 |
| `-AppName` | `web-app` | 应用名（pm2 进程名） |
| `-Port` | `3000` | 应用端口 |
| `-SiteUrl` | `''` | 对外地址，写进 `.env` 的 `SITE_URL` |
| `-ApiKey` | `''` | 不给则读环境变量 |
| `-Stage` | `''` | 暂存目录，不给则自动建临时目录 |
| `-SkipBuild` | 关 | 跳过本机 build（只推代码，机器端自己 build） |

机器端 `scripts/deploy-in-machine.sh` 做的事：装依赖 → 建 `.env` → `npm run build` → pm2 守护 → 自检。
它支持的机器端环境变量：`APP_NAME`、`APP_DIR`、`DATA_DIR`、`PORT`、`SITE_URL`、`AMAP_WEB_KEY`、`WECOM_WEBHOOK_URL`。

#### `scripts/deploy.sh` — 推送 + 机器端安装（Linux/macOS 编排）

```bash
bash scripts/deploy.sh --machine <机器名> --repo /path/to/repo [--port 3000] [--site-url https://...] [--app-name <名>] [--stage <目录>] [--skip-build]
```

参数与 `deploy.ps1` 一一对应。

#### `scripts/setup-tunnel.sh` — 在机器上装 Cloudflare Tunnel 连接器

```bash
PORT=3000 bash scripts/setup-tunnel.sh
```

`PORT` 为应用在机器内部的端口。

#### `scripts/keepalive/deploy-keepalive.ps1` — 部署保活 Worker（Windows）

```bash
pwsh -File scripts/keepalive/deploy-keepalive.ps1 -Machine <机器名> -MachineId <m_xxx>
```

| 参数 | 默认 | 含义 |
|---|---|---|
| `-MachineId` | **必填** | 机器 ID（`m_xxx`）。activity-leases 端点只认 ID |
| `-Machine` | `''` | 机器名，仅用于日志 |
| `-WorkerName` | `instabox-keepalive` | Worker 名 |
| `-Cron` | `*/3 * * * *` | cron 表达式 |
| `-Ttl` | `900` | 租约秒数，**必须 > cron 间隔** |
| `-Token` | `''` | Worker 访问口令，不给则自动生成并打印 |
| `-WorkDir` | `$env:TEMP\instabox-keepalive` | 工作目录 |
| `-ApiKey` | `''` | 不给则读环境变量 |

#### `scripts/keepalive/deploy-keepalive.sh` — 部署保活 Worker（Linux/macOS）

```bash
bash scripts/keepalive/deploy-keepalive.sh --machine-id m_xxx [--machine <名>] [--worker-name instabox-keepalive] [--cron '*/3 * * * *'] [--ttl 900] [--token <口令>] [--work-dir ./wrk]
```

#### `scripts/verify-site.ps1` — 端到端验收

```bash
pwsh -File scripts/verify-site.ps1 -Domain <子域名> -Machine <机器名>
```

| 参数 | 默认 | 含义 |
|---|---|---|
| `-Machine` | `''` | InstaBox 机器名 |
| `-Domain` | `''` | 要验证的域名 |
| `-WorkerUrl` | `''` | 保活 Worker 地址，如 `https://instabox-keepalive.<sub>.workers.dev` |
| `-Token` | `''` | Worker 访问口令 |
| `-Port` | `3000` | 应用端口 |
| `-Routes` | 见下 | 要检查的路由数组 |

默认路由：`/ /projects /map /top /submit /member /stories /compare /sitemap.xml /robots.txt`
（这是袋鼠义工站的实际路由集合，**换项目请改这个数组**）。

验收项全部通过才算完成：首页/关键路由 200、动态路由 200（验证 `params` await）、
图片 200 且 content-type 正确、sitemap 域名正确、表单 POST 返回 303 + **相对 Location**、
Worker `/status` 返回 running、Worker cron 有触发日志。

### 保活 Worker 的核心参数（`scripts/keepalive/worker.js` + `wrangler.toml.template`）

| 参数 | 值 | 说明 |
|---|---|---|
| `INSTABOX_API_KEY` | Secret | InstaBox API Key |
| `TOKEN` | Secret | Worker 访问口令 |
| `INSTABOX_MACHINE` | Text | 机器 ID（`m_xxx`），留空 = 该 key 名下全部机器 |
| `INSTABOX_TTL` | env | 租约秒数，30–3600，默认 900 |
| `crons` | `[triggers]` 下 | `*/3 * * * *` |

> ⚠️ **wrangler 4 的 cron 必须写在 `[triggers]` 段下面**，写顶层会被静默忽略，只打一条 WARNING，
> cron 根本不生效，但 `wrangler deploy` 照样成功。
> ⚠️ **`secret put` 必须在 `deploy` 之后**——`secret put` 要求 Worker 已存在，顺序反了会报「worker 不存在」。

---

## 部署与使用步骤

### Step 0 — 预检

```bash
pwsh -File scripts/preflight.ps1 -Machine <机器名> -Domain <子域名> -Repo <仓库地址>
```

### Step 1 — 部署到 InstaBox

**1a. 打包代码**（在 GitHub 克隆的本地副本里操作）

```bash
pwsh -File scripts/stage-code.ps1 -Repo <本地仓库路径> -Stage <输出目录>
```

**1b. 推送 + 机器端安装**

```bash
pwsh -File scripts/deploy.ps1 -Machine <机器名> -Repo <本地仓库路径> -Port 3000
```

机器端流程：装依赖 → 建 `.env` → `npm run build` → pm2 守护 → 自检。
**`.env` 若已存在则保留**，不会被线上配置冲掉。

**1c. 数据（若有 SQLite / 大文件）**

> ⚠️ **SQLite 必须先 `PRAGMA wal_checkpoint(TRUNCATE)`**，否则传输后报
> `database disk image is malformed`。WAL 模式下主库与 `-wal` 失配是本流程最高频的坑。
> 详见 `references/data-transfer.md`。

**1d. 图片/静态资源**：`/data` 固定 20 GiB 不可扩容 → **按实际引用裁剪，不要全量上传**。
先算再传：解析数据里所有图片引用路径，得到实际需要的文件清单再复制成一份精简库。

### Step 2 — Cloudflare Tunnel 绑域名

面板路径：Zero Trust → Networks → Tunnels → Configure → Public Hostnames

- Subdomain：`<子域>`　Domain：`<主域名>`　Path：留空
- **Service Type 必须选 `HTTP`**，URL 填 `localhost:<端口>`
- ⚠️ 选 HTTPS 会 502（`tls: first record does not look like a TLS handshake`）——`next start` 是明文 HTTP
- ⚠️ **不要**把域名 CNAME 到 InstaBox 网关：网关按 Host 头路由，自定义 Host 返回 404，80 端口也不通
- 绑定后 DNS 记录由 Cloudflare 自动创建，**不要动主域名 NS 和其他已有记录**

### Step 3 — 保活迁移到 Cloudflare Worker

```bash
pwsh -File scripts/keepalive/deploy-keepalive.ps1 -Machine <机器名> -MachineId <m_xxx>
```

要点：
- lease 端点**只认机器 ID**，用机器名 404
- cron 间隔 540s < TTL 900s，中间不留空窗；免费版最多 3 个触发器
- **wrangler 4 的 cron 必须写在 `[triggers]` 下**
- 迁移时把本机计划任务**禁用**（而非删除），保持单一保活源，随时可回滚

### Step 4 — 端到端验证

```bash
pwsh -File scripts/verify-site.ps1 -Domain <子域名> -Machine <机器名>
```

---

## 典型使用场景

### 场景一：个人项目从笔记本搬到云端

网站原本跑在自己的 Windows 机器上，合盖就下线。
→ 走完整 5 步，最终拿到 `https://<子域>.<主域>`，电脑关机不影响。

### 场景二：给已有应用换一条不依赖本机的保活链路

保活原本靠本机 Windows 计划任务每 9 分钟续租，电脑一关机就断。
→ 只跑 Step 3，把保活搬到 Cloudflare Worker，然后禁用本机计划任务。
Worker 由 Cloudflare 托管，永不下线。

### 场景三：已有 SQLite 数据的应用搬迁

数据在 WAL 模式，直接复制会损坏。
→ 先 `PRAGMA wal_checkpoint(TRUNCATE)` 把 WAL 合并进主库，机器端跑 `integrity_check` 确认 `ok`，
再逐项核对行数与图片零缺失。

### 场景四：图片库远超磁盘容量

原始图片库接近 `/data` 上限。
→ 解析所有引用路径，按需裁剪出精简库再传。这一步通常能省掉 99% 体积。

---

## 常见问题（FAQ）

**Q：需要自购服务器吗？**
不需要。免费额度 4C8G + 20 GiB 持久盘，0 元、免备案。

**Q：网站能 24 小时不断吗？**
免费额度有 **8 小时强制暂停** + 5–20 分钟冷却期的硬限制。保活解决不了这个。
Worker 能让冷却结束后下一跳就把机器拉回来，把空窗压到 3 分钟左右；
要彻底消除中断只能升 Pro（$20/月）。

**Q：为什么不用自购 VPS？**
主要是省事：不用备案、不用管证书（Cloudflare 边缘证书）、不用配 Nginx，
`port publish` 本身就给 HTTPS 地址。代价就是上面那条 8 小时上限。

**Q：`wrangler login` 报 `Timed out waiting for authorization code`？**
OAuth 只有 120 秒窗口。改用 `npx wrangler login --device`（设备码，无短超时）
或直接用 API Token（`CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`，完全无交互）。

**Q：`instabox auto-suspend <机器> 0` 没用？**
免费套餐把阈值锁死在 1800 秒，接口返回 200 但值不变（被静默忽略）。
唯一可用的保活方式是官方的 **activity lease**。

**Q：为什么 Tunnel 的 Service Type 必须选 HTTP？**
`next start` 起的是明文 HTTP。选 HTTPS 时 Cloudflare 拿 TLS 去握手，
报 `tls: first record does not look like a TLS handshake`，表现为 502。
如果你的服务自己带 TLS（Nginx/certbot），才用 HTTPS，URL 填 `https://127.0.0.1:<端口>`。

**Q：访客看到我的 IP 是 Cloudflare 的，是隐私泄露吗？**
不是。Tunnel 架构下访客看到的就是 Cloudflare Anycast IP，与机器出口无关，是正常的。

**Q：能同时部署几个应用？**
免费额度只有 1 台机器 1 个 `maxRunMinutes` 额度。可在同一台上用不同端口 + 不同二级域名跑多个。

**Q：访客访问慢？**
Cloudflare 免费版没有中国内地节点。要快只能换国内服务器并备案。

**Q：可以直接把域名 CNAME 到 InstaBox 吗？**
不行。网关按 Host 头路由，自定义 Host 返回 404，80 端口不通，
且 InstaBox 证书的 SAN 仅覆盖 `*.instabox.tech`。**必须走 Tunnel。**

**Q：`secret put` 显示 Success 但 secret 是空的？**
管道喂了空值（路径写错）。用 `/status` 验证，**别信 Success 输出**。

**Q：`instabox exec` 的输出怎么是空的？**
多行 bash 会被吞。改用单行命令，或把复杂逻辑写成脚本文件 push 上去再执行。

**Q：长时间任务怎么跑？**
`instabox exec --timeout` 上限 600 秒。长任务改用
`instabox exec --background <机器名> -- <命令>` 拿 jobID，再 `instabox jobs wait` / `jobs logs`。

---

## 故障排查

完整四张速查表（症状 → 根因 → 修复）见 **`references/troubleshooting.md`**。
这里只列最高频的几条：

| 症状 | 根因 | 修复 |
|---|---|---|
| `database disk image is malformed` | WAL 模式下只传了主库，与 `-wal` 失配 | 传前 `PRAGMA wal_checkpoint(TRUNCATE)` |
| 公网 502 + `tls: first record...` | Public Hostname 的 Service Type 选了 HTTPS | 改成 **HTTP** |
| lease 续租 404 `machine not found` | 端点只认机器 ID | 用 `m_xxx` |
| lease 续租 409 `machine_cooldown` | 撞 8 小时上限的冷却期 | 读 `retryAfterSeconds`，本轮跳过，**别硬撞** |
| Worker deploy 显示 cron 但不触发 | cron 写在了顶层 | 移到 `[triggers]` 下 |
| `secret put` 报 worker 不存在 | 顺序反了 | 先 `deploy` 再 `secret put` |
| 构建后全站 500 / 裸文本 | `dev` 与 `start` 共用 `.next` 损坏 | 停服 → `rm -rf .next` → 重新 build |
| 动态路由 404（Next 15+） | `params`/`searchParams` 变成 Promise | `const params = await props.params` |
| 表单提交后跳到 localhost | 重定向用了绝对地址 | 用相对 Location |
| `host_unavailable: 502 Bad Gateway` | InstaBox API 瞬时故障 | **重试**，不是凭证错误 |

### 排查手法

- **定位端口占用者（Windows）**：`netstat -ano | findstr :3000` 查 PID
- **确认隧道配置真的生效了**：`journalctl -u cloudflared` 看 `Updated to new configuration` 的 version 是否递增
- **确认保活真的在触发**：`cmd.exe /c "npx --yes wrangler@latest tail <worker> --format pretty > tail.log 2>&1"`
  （⚠️ 不能接 `Out-String`，聚合器会永不输出，必须重定向到文件）
- **确认机器实际状态（含冷却期）**：`instabox get <机器名> --json` 看 `state` / `cooldownUntil` / `runStartedAt`

---

## 注意事项与硬性纪律

1. **绝不**在生产机直接改代码或 `npm install` 升级依赖 —— 先在本地副本改 + 回归全绿再推
2. **`npm run build` 前必须先停 `next start`** —— 并发会损坏 `.next`，整站 500
3. **`dev` 与 `start` 共用 `.next`**，混用会损坏产物
4. **`.env` 永不入库**，服务器上 `chmod 600`；任何 key / token 都不在聊天或日志里明文回显
5. **保活必须在机器外部执行** —— 机器挂起后内部 cron/systemd 全冻结，自己救不了自己
6. **`/data` 只有 20 GiB 且不可 resize** —— 大文件按需裁剪，或走 Release 分发
7. **访客看到的是 Cloudflare Anycast IP**，与机器出口 IP 无关，这是 Tunnel 架构的正常表现
8. **传文件用 `instabox push`，超大目录分批传** —— `instabox push <机器名> <本地路径> <远端路径> --all`；
   目录很大时按 `references/data-transfer.md` 的「分批」方案传，别指望一条命令传完
9. **免费机器别放唯一副本的重要数据** —— 规则随时可能变

---

## 安装方式

### 方式一：克隆到 agent 的 skills 目录

```bash
git clone https://github.com/<owner>/instabox-cloudflare-deploy.git \
  ~/.minimax/skills/instabox-cloudflare-deploy
```

同类 agent 的常见目录：`~/.minimax/skills/`、`~/.claude/skills/`、`~/.codex/skills/`、
`~/.agents/skills/`、`~/.gemini/config/skills/`。放到哪个都行，取决于你用哪个 agent。

### 方式二：下载打包好的 `.skill`

`dist/instabox-cloudflare-deploy.skill` 是打包产物（zip 格式），解压后同样得到完整目录。

### 方式三：只读参考

不想装成 skill，直接读 `SKILL.md` + `references/` 也是完整的操作手册。

---

## 仓库结构

```
instabox-cloudflare-deploy/
├── README.md                          本文件
├── SKILL.md                           主工作流：决策点 + 硬性纪律 + references 索引
├── _meta.json                         Skill 元数据（id / version）
├── assets/
│   └── env.example                    凭据与目标信息模板
├── references/                        细节文档，按需查阅
│   ├── prerequisites.md               四项前置条件的获取路径、权限清单、OAuth 超时的三种解法
│   ├── instabox-api.md                API 规格、免费套餐三条硬限制、CLI 命令表与三个坑
│   ├── cloudflare-tunnel.md           隧道创建/绑定全流程、面板路径、502 排查
│   ├── keepalive-worker.md            Worker 保活原理、cron/TTL 参数、部署与验证
│   ├── data-transfer.md               SQLite WAL 安全传输、图片预算计算、Release 分发
│   └── troubleshooting.md             故障速查表（症状 → 根因 → 修复）
├── scripts/                           可执行脚本
│   ├── preflight.ps1                  Step 0 预检
│   ├── stage-code.ps1                 打包代码（与数据分离）
│   ├── deploy.ps1 / deploy.sh         Step 1 推送 + 机器端安装（Windows / Linux）
│   ├── deploy-in-machine.sh           机器端安装脚本（装依赖→build→pm2→自检）
│   ├── setup-tunnel.sh                机器端装 Cloudflare Tunnel 连接器
│   ├── verify-site.ps1                Step 4 端到端验收
│   ├── keepalive/
│   │   ├── worker.js                  通用化保活 Worker（TTL 可配、Idempotency-Key 已修）
│   │   ├── wrangler.toml.template     Worker 配置模板（cron 必须在 [triggers] 下）
│   │   ├── deploy-keepalive.ps1       保活部署（Windows）
│   │   └── deploy-keepalive.sh        保活部署（Linux/macOS）
│   └── test_skill_assets.py           坑位回归自测（28 项）
└── dist/
    └── instabox-cloudflare-deploy.skill   打包产物
```

---

## 自测

这份 Skill 自带一套「坑位回归」测试：把真实部署里踩过的每个坑写成可自动检查的断言，
防止技能在后续修改中静默退回旧坑。

```bash
cd instabox-cloudflare-deploy
python -m unittest discover -s scripts -p "test_*.py" -v
```

覆盖的坑包括但不限于：

- `crons` 必须在 `[triggers]` 下（写顶层静默失效）
- lease 端点必须用机器 ID（用机器名 404）
- `call()` 必须透传 `Idempotency-Key`
- build 前必须先停 `next start`
- `instabox exec --timeout` ≤ 600 秒
- `secret put` 必须在 `deploy` 之后
- 文档不得出现真实机器 ID / API Key
- 文档里引用的每个路径都必须真实存在

---

## 许可证

本仓库内容按原样提供。若需要明确的授权条款，请添加 `LICENSE` 文件。

---

## 致谢

- [InstaBox](https://instabox.sh) —— 免费云主机
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/) —— 自有域名接入
- [Cloudflare Workers](https://developers.cloudflare.com/workers/) —— 保活 cron 宿主
