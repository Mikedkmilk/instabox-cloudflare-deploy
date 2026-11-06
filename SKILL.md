---
name: instabox-cloudflare-deploy
description: Deploy a Node.js or Next.js application to a free InstaBox cloud machine and expose it on the user's own domain via Cloudflare Tunnel, with machine keep-alive moved off the local computer into a Cloudflare Worker cron. Use when the user asks to deploy or 上线 a site to InstaBox, bind a domain through Cloudflare Tunnel, make the site survive the local PC being off, or set up always-on keep-alive. Covers GitHub source pull, SQLite WAL-safe data transfer, image budget under the 20GB /data cap, pm2 process management, Tunnel hostname binding, Worker activity-lease keep-alive, and end-to-end verification. Not for Vercel/Netlify static hosting, Oracle or paid-VPS migration, or pure Cloudflare Workers app development.
---

# InstaBox + Cloudflare Tunnel 部署

把一个 Node/Next.js 应用部署到免费 InstaBox 云主机，用 Cloudflare Tunnel 绑到用户自有域名，
并把「保活」从本机计划任务迁移到 Cloudflare Worker，使网站不依赖个人电脑。

## 何时用 / 何时不用

| 用 | 不用 |
|---|---|
| 上线到免费 InstaBox 云主机（0 元、免备案、4C8G） | 部署到 Vercel / Netlify（静态托管） |
| 已有 Cloudflare 托管的域名，想绑二级域名 | Oracle / 自购 VPS（见下方「决策点」） |
| 要求「电脑关机网站仍在」 | 纯 Cloudflare Workers 应用开发（node:sqlite 在 Workers 是空壳） |

## 执行前必须先确认的四项

缺任何一项**先问用户**，不要猜（详见 `references/prerequisites.md`）：

| # | 需要的信息 | 获取方式 |
|---|---|---|
| 1 | **GitHub 仓库地址** + 分支 | 用户给；私有库需 PAT 或已有 git 凭据 |
| 2 | **InstaBox API Key**（`ibk_` 开头） | instabox.sh → 账户 → API Keys |
| 3 | **Cloudflare 账户** | `wrangler login`（OAuth 窗口仅 120 秒，见下） |
| 4 | **已有域名** + 要绑的二级域名 | 如 `app.example.com`；主域名 NS 必须已在 Cloudflare |

**Cloudflare 认证有 120 秒硬超时**（`wrangler login` 会报 `Timed out waiting for authorization code`）。
超时了不要反复重试，改用这两条之一：
- `npx wrangler login --device`（RFC 8628 设备码，无短超时）
- API Token：设 `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`，完全无交互（推荐，权限见 prerequisites）

## 主流程（按序执行，每步都有验证点）

```
0. 预检      → scripts/preflight.ps1       验证凭证、机器状态、端口占用
1. 打包推送  → scripts/deploy.ps1          本机打包代码 → instabox push → 机器端安装
2. 数据传输  → 见 Step 1c                   SQLite 必须先 checkpoint（否则 malformed）
3. 隧道绑定  → 面板操作 + scripts/setup-tunnel.sh
4. 保活迁移  → scripts/keepalive/deploy-keepalive.ps1
5. 端到端验证 → scripts/verify-site.ps1
```

### Step 0 — 预检

```bash
pwsh -File scripts/preflight.ps1 -Machine <机器名> -Domain <子域名> -Repo <仓库地址>
```

通过标准：机器 `running`、Node ≥ 22.5、`/data` 剩余 ≥ 应用体积 × 2、Cloudflare 已登录。

### Step 1 — 部署到 InstaBox

**1a. 打包代码**（在 GitHub 克隆的本地副本里操作，排除依赖/数据/密钥）

```bash
pwsh -File scripts/stage-code.ps1 -Repo <本地仓库路径> -Stage <输出目录>
```

**1b. 推送 + 机器端安装**

```bash
pwsh -File scripts/deploy.ps1 -Machine <机器名> -Repo <本地仓库路径> -Port 3000
```

机器端脚本 `scripts/deploy-in-machine.sh` 做：装依赖 → 建 `.env` → `npm run build` → pm2 守护 → 自检。

**1c. 数据（若有 SQLite / 大文件）**

> ⚠️ **SQLite 必须先 `PRAGMA wal_checkpoint(TRUNCATE)`**，否则传输后报
> `database disk image is malformed`。WAL 模式下主库与 `-wal` 失配是本流程最高频的坑。
> 详见 `references/data-transfer.md`。

**1d. 图片/静态资源**：`/data` 固定 20 GiB 不可扩容 → **按实际引用裁剪**，不要全量上传。
详见 `references/data-transfer.md` 的「图片预算」。

### Step 2 — Cloudflare Tunnel 绑域名

面板操作（Zero Trust → Networks → Tunnels → Configure → Public Hostnames）：

- Subdomain：`<子域>`　Domain：`<主域名>`　Path：留空
- **Service Type 必须选 `HTTP`**，URL 填 `localhost:<端口>`
- ⚠️ 选 HTTPS 会 502（`tls: first record does not look like a TLS handshake`）——`next start` 是明文 HTTP
- ⚠️ **不要**把域名 CNAME 到 InstaBox 网关：网关按 Host 头路由，自定义 Host 返回 404

细节与截图级步骤见 `references/cloudflare-tunnel.md`。

### Step 3 — 保活迁移到 Cloudflare Worker

免费套餐唯一可用的保活是 **activity lease**（`auto-suspend 0` 无效、`PATCH autoSuspendAfterSeconds` 被静默忽略）。

```bash
pwsh -File scripts/keepalive/deploy-keepalive.ps1 -Machine <机器名> -MachineId <m_xxx>
```

要点（详见 `references/keepalive-worker.md`）：
- lease 端点**只认机器 ID**，用机器名 404
- cron 间隔 180s < TTL 900s，中间不留空窗；免费版最多 3 个触发器
- **wrangler 4 的 cron 必须写在 `[triggers]` 下**，写顶层会被静默忽略
- Worker 除续租外**每轮还要跑一次真实 exec**：免费档运行上限是动态的（每轮 2 小时起步，
  按前 30 分钟真实工作量延长，**续租与唤醒都不算工作**），不跑 exec 就拿不到延长，
  机器会频繁撞上限，且冷却期逐级变长（5–20 → 60–75 → 120–135 分钟）
- 写 Secret 用 `wrangler secret bulk`（JSON 文件），**别用管道喂 `secret put`**——
  管道补的尾换行会让 Worker 永远回「token 不对」

### Step 4 — 端到端验证

```bash
pwsh -File scripts/verify-site.ps1 -Domain <子域名> -Machine <机器名>
```

全部通过才算完成：首页/关键路由 200、动态路由 200（验证 `params` await）、
图片 200 且 content-type 正确、sitemap 域名正确、表单 POST 返回 303 + **相对 Location**、
Worker `/status` 返回 running、Worker cron 有触发日志。

## 决策点

| 情况 | 怎么办 |
|---|---|
| 服务是明文 HTTP（`next start`） | Tunnel Service Type = HTTP |
| 服务自己带 TLS（Nginx/certbot） | Service Type = HTTPS，URL 填 `https://127.0.0.1:<端口>` |
| 机器撞运行上限、需彻底消除中断 | 保活能把每轮从 2 小时延到 8 小时上限，但冷却期消不掉 → 升 InstaBox Pro 或换不限时服务器 |
| 免费额度不够（要 >3 个 cron 或更高 CPU） | 免费版有硬限制，别硬撞 |
| 私有库拉取失败 | 改用 Release 附件分发数据，或配 PAT |

## 硬性纪律

1. **绝不**在生产机直接改代码或 `npm install` 升级依赖 —— 先在本地副本改 + 回归全绿再推
2. **`npm run build` 前必须先停 `next start`** —— 并发会损坏 `.next`，整站 500
3. **`dev` 与 `start` 共用 `.next`**，混用会损坏产物
4. **`.env` 永不入库**，服务器上 `chmod 600`
5. **保活必须在机器外部执行** —— 机器挂起后内部 cron/systemd 全冻结，自己救不了自己

## 参考资料

| 文件 | 内容 |
|---|---|
| `references/prerequisites.md` | 四项前置条件的获取路径、权限清单、OAuth 超时的三种解法 |
| `references/instabox-api.md` | InstaBox API 规格、免费套餐三条硬限制、CLI 命令表 |
| `references/cloudflare-tunnel.md` | 隧道创建/绑定全流程、面板路径、502 排查 |
| `references/keepalive-worker.md` | Worker 保活原理、cron 配置、部署与验证命令 |
| `references/data-transfer.md` | SQLite WAL 安全传输、图片预算计算、Release 分发 |
| `references/troubleshooting.md` | 故障速查表（症状 → 根因 → 修复） |
