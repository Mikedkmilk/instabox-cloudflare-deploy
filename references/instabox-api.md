# InstaBox API 规格与免费套餐硬限制

Base URL：`https://api.instabox.sh`
认证头：`X-API-Key: ibk_...`

---

## 免费套餐的三条硬限制

这三条决定了整个流程的设计，任何 workaround 都绕不过去。

### 1. 空闲挂起固定 1800 秒 —— 改不了

官方文档《Machines → Auto-pause》：

> On the free plan it is fixed at 30 minutes, and another value is refused.

`GET /v1/me` 会返回 `"fixedAutoSuspendSeconds": 1800`。

**两条无效路径**（实测）：

```bash
# ❌ CLI 静默忽略/拒绝
instabox auto-suspend <机器名> 0

# ❌ API 返回 200 但值不变（被静默忽略）
curl -X PATCH https://api.instabox.sh/v1/machines/<id> \
  -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"autoSuspendAfterSeconds":0}'
```

**唯一可用口子：activity lease**。见 `keepalive-worker.md`。

### 2. 连续运行上限固定 480 分钟（8 小时）

撞上限 → 机器被强制暂停 → 进入 **5–20 分钟冷却期**（随机）。

冷却期任何唤醒方式全部返回 `409 machine_cooldown`，带 `retryAfterSeconds`：
`exec` / `SSH` / 文件读 / 公开端口 / `wake` / `resume` / `start` 全部被拒。

**保活只能解决空闲挂起，解决不了 8 小时上限。**
彻底解决 → 升 InstaBox Pro（$20/月，可自设空闲时间含关闭、可设 maxRun）。

### 3. `/data` 固定 20 GiB，不可 resize

home 在 `/data/home`。系统盘 `/` 是 16 GiB（模板自带，admin 才能改）。

**推论：图片/静态资源不能全量上传**，必须按实际引用裁剪。见 `data-transfer.md`。

---

## 机器信息查询

```bash
# 列表
curl -s "https://api.instabox.sh/v1/machines" -H "X-API-Key: $KEY"

# 详情（机器名和 ID 都能用这里）
curl -s "https://api.instabox.sh/v1/machines/web-app" -H "X-API-Key: $KEY"
curl -s "https://api.instabox.sh/v1/machines/m_xxx"      -H "X-API-Key: $KEY"
```

返回里有用的字段：

```json
{
  "id": "<MACHINE_ID>",
  "name": "web-app",
  "state": "running",
  "desiredState": "running",
  "autoSuspendAfterSeconds": 1800,
  "maxRunMinutes": 480,
  "runStartedAt": "2026-11-01T16:01:54.206873Z",
  "cooldownUntil": null,
  "storage": { "sizeGiB": 20, "mountPath": "/data", "persistent": true },
  "runtime": { "ready": true },
  "spec": { "vcpus": 4, "memMiB": 8192, "persistentDiskGiB": 20, "rootDiskGiB": 16 }
}
```

> `runStartedAt` + `maxRunMinutes` 算得出下次撞 8 小时上限的时点。
> ⚠️ 用 `Invoke-RestMethod` 解析这个 JSON 时 PowerShell 会把 ISO 时间自动转成 DateTime，
> 再做二次解析会得到错误的月份。**要精确计算就用 `curl` 取原始文本 + `DateTimeOffset::Parse`。**

---

## Activity Lease（保活的唯一口子）

### 续租

```bash
curl -X PUT "https://api.instabox.sh/v1/machines/m_xxx/activity-leases/keepalive" \
  -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"ttlSeconds":900}'
```

| 约束 | 值 |
|---|---|
| 端点路径里的机器标识 | **只能是机器 ID（`m_xxx`）** |
| `ttlSeconds` 范围 | 30 – 3600 |
| Idempotency-Key | 不需要 |
| 所需 scope | `machines:write` 或 `machines:exec` |
| lease 名 | 任意字符串，同名即覆盖（重复续租无害） |

**用机器名会 404 `machine not found`。**

### 错误码

| HTTP | code | 含义与处理 |
|---|---|---|
| 409 | `machine_not_running` | 机器被挂起/停掉了。先 `resume`（失败用 `start` 兜底），等 `running` 再续租 |
| 409 | `machine_cooldown` | 撞 8 小时上限的冷却期。读 `retryAfterSeconds`，**本轮跳过，不要硬撞** |
| 401 | `invalid_key` / `malformed_key` | 凭证错了 |
| 403 | `spec_not_allowed` | 免费套餐改了不该改的参数（如 autoSuspendAfterSeconds） |

### 唤醒

```bash
# resume（从暂停恢复）
curl -X POST "https://api.instabox.sh/v1/machines/m_xxx/resume" \
  -H "X-API-Key: $KEY" -H "Idempotency-Key: $(uuidgen)"

# start（stopped 状态兜底）
curl -X POST "https://api.instabox.sh/v1/machines/m_xxx/start" \
  -H "X-API-Key: $KEY" -H "Idempotency-Key: $(uuidgen)"
```

⚠️ `resume` / `start` **需要 `Idempotency-Key` 头**，否则报错。

⚠️ `GET` 单个 lease / 列表端点**不支持**（返回 404）。想确认租约到期时间，只能靠续租返回值里的 `expiresAt`。

---

## CLI 命令表

```bash
# 机器
instabox ls --json                    # 列表
instabox get <机器名> --json          # 详情
instabox create <机器名> --template agent-browser --json
instabox start <机器名> / stop <机器名>
instabox disk <机器名>                # 磁盘用量
instabox resize <机器名> ...          # 免费套餐不可用

# 执行命令
instabox exec <机器名> -- bash -lc '命令'
instabox exec <机器名> --timeout 600 -- bash -lc '长任务'

# 文件传输
instabox push <机器名> <本地路径> <远端路径> --all

# 端口
instabox port publish <机器名> 3000 --private   # 私有端口
instabox port ls <机器名>
instabox port unpublish <机器名> 3000
```

### CLI 的三个坑

1. **`exec --timeout` 上限 600 秒**。超时报错：
   `the maximum of 600 seconds (10m0s); for a longer command use instabox exec --background`
   → 长任务改用 `--background <sandbox>` + `instabox jobs wait`。

2. **多行 bash 命令的输出会丢失**。传单行命令，或把脚本写成文件再 push 上去执行。

3. **API 偶发 502**：
   `host_unavailable: 502 Bad Gateway from the load balancer ... the API server did not answer`
   这是瞬时的，**重试即可**，不要当成凭证错误。

### 在机器上执行复杂命令的稳妥姿势

```bash
# 本机：写脚本 → push → 执行
instabox push <机器名> ./setup.sh /data/home/setup.sh
instabox exec <机器名> -- bash -lc 'chmod +x /data/home/setup.sh && bash /data/home/setup.sh'
```

比在命令行里拼多层引号可靠得多（Windows 上 cmd 会吃掉单引号，bash 会吃掉双引号）。

---

## 机器环境（实测）

| 项 | 值 |
|---|---|
| OS | Debian 13 (trixie) x86_64 |
| Node | v22.23.3（**`node:sqlite` 需 ≥ 22.5**） |
| home | `/data/home` |
| 用户 | 在 `docker` + `sudo` 组，可免密 sudo |
| systemd | 257 |
| 已有工具 | `git`、`curl`、`pm2`；**无 ImageMagick** |

Node < 22.5 时 `node:sqlite` 不可用，报 `Cannot find module 'node:sqlite'`。
装法：

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y -qq nodejs
```

---

## 端口与网关

- `port publish` **默认是公开的**，任何拿到 URL 的人都能访问 → 显式加 `--private`
- 网关**按 Host 头路由**：发自定义 Host 头会返回 404；发 `instabox` 才对
- 80 端口不通
- 证书 SAN 仅 `*.instabox.tech` → **DNS CNAME 直连不可行**，必须用 Cloudflare Tunnel

---

## 关机/挂起行为

| 场景 | 结果 |
|---|---|
| 空闲 30 分钟 | 机器挂起（保活可防） |
| 连续运行满 8 小时 | 强制暂停 + 5–20 分钟冷却（保活防不了） |
| 保活请求来自机器**内部** | 无效 —— 挂起后内部 cron/systemd 全冻结 |

**保活必须在机器外部执行**（Cloudflare Worker / 本机计划任务 / VPS / NAS）。
