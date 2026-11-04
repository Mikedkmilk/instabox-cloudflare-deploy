# 保活 Worker：把保活从本机迁到 Cloudflare

## 为什么必须是 Worker

InstaBox 免费套餐唯一能用的保活是 **activity lease**（见 `instabox-api.md`）。
而 lease 必须由**机器外部**发起——机器挂起后，其内部 cron/systemd 全都冻结，自己救不了自己。

| 方案 | 电脑关机后 | 评价 |
|---|---|---|
| 机器内部 cron | ❌ 冻结 | 无效 |
| 本机 Windows 计划任务 | ❌ 停 | 迁移前的临时方案 |
| **Cloudflare Worker cron** | ✅ | **最终方案**：Cloudflare 永不下线 |

---

## 免费版 Worker 的限制

| 项 | 限制 | 本方案用量 |
|---|---|---|
| cron 触发器 | 每个 Worker 最多 3 个 | 1 个 |
| cron 最小间隔 | 1 分钟 | 3 分钟 |
| 自动重试 | **无** | — |
| 失败告警 | **无** | 靠 `wrangler tail` 手动看 |
| 请求额度 | 100,000/天 | ~480/天 |

**没有重试也没有告警**，所以 Worker 内部必须自己处理异常（下面代码都做了）。

---

## 核心参数

| 参数 | 值 | 理由 |
|---|---|---|
| cron 间隔 | `*/3 * * * *`（180s） | 撞 8 小时上限后，冷却一结束下一次 cron 就能拉起，网站空窗从 9 分钟压到 3 分钟 |
| lease TTL | 900s | 必须 > 间隔（180s），否则两次之间出现空窗 |
| lease 名 | `keepalive` | 固定名字，重复续租即覆盖 |

免费版若要更短间隔，最低 1 分钟；再短没有意义——冷却期本身是 5–20 分钟。

---

## 部署

### 1. 准备 Worker

```bash
cd <skill>/scripts/keepalive
cp worker.js <工作目录>/worker.js
```

编辑 `wrangler.toml`（模板在 `wrangler.toml.template`）：

```toml
name = "instabox-keepalive"
main = "worker.js"
compatibility_date = "2026-10-01"

[triggers]
crons = ["*/3 * * * *"]

[vars]
INSTABOX_MACHINE = "<MACHINE_ID>"
```

> ⚠️ **`crons` 必须写在 `[triggers]` 下**。写在顶层 wrangler 4 只打一条 WARNING，
> **cron 根本不生效**（部署输出里的 `schedule:` 会显示你写的值，容易误判）。
> 见 `scripts/keepalive/wrangler.toml.template`。

### 2. 登录并部署

```bash
npx --yes wrangler@latest whoami          # 确认已登录
npx --yes wrangler@latest deploy          # 先建出 Worker
```

### 3. 写两个 Secret（**必须在 deploy 之后**）

```bash
# InstaBox API Key
echo "$INSTABOX_API_KEY" | npx --yes wrangler@latest secret put INSTABOX_API_KEY

# Worker 访问口令（不设则任何人知道域名就能触发续租）
echo "$TOKEN" | npx --yes wrangler@latest secret put TOKEN
```

> ⚠️ **顺序不能反**：`secret put` 要求 Worker 已存在，否则报错。
> ⚠️ **管道喂空值不会报错**：如果 `type` 路径写错，`wrangler secret put` 照样输出
> "Success!" 但实际存的是空串。写完**务必用 `/status` 验证**，别信那句 Success。

> 🔐 `TOKEN` 等同密码。生成：`node -e "console.log(require('crypto').randomBytes(16).toString('hex'))"`

### 4. 一次性脚本

```bash
pwsh -File scripts/keepalive/deploy-keepalive.ps1 \
  -Machine <机器名> -MachineId <m_xxx> -WorkerName instabox-keepalive
```

---

## 验证

### 鉴权

```bash
# 不带 token → 应返回 401
curl -i "https://<worker>.<subdomain>.workers.dev/status"

# 带 token → 200 + 机器状态
curl "https://<worker>.<subdomain>.workers.dev/status?token=$TOKEN"
```

### 手动续租

```bash
curl "https://<worker>.<subdomain>.workers.dev/?token=$TOKEN"
```

期望返回：

```json
{
  "ok": true,
  "at": "2026-11-01T19:39:26.572Z",
  "count": 1,
  "results": [{
    "ok": true,
    "machine": "web-app",
    "detail": "续租成功，到期 2026-11-01T19:54:26.577Z"
  }]
}
```

### cron 真的在触发（**最关键的一步**）

```bash
npx --yes wrangler@latest tail instabox-keepalive --format pretty
```

等一个 cron 周期，应看到：

```
"*/3 * * * *" @ 2026年11月2日 上午3:39:25 - Ok
  (log) instabox-keepalive: {"ok":true,"at":"2026-11-01T19:39:26.572Z","count":1,
   "results":[{"ok":true,"machine":"web-app","detail":"续租成功，到期 ..."}]}
```

**没看到这条日志 = cron 没生效**，回查 `[triggers]` 写法。

> ⚠️ Windows 上 `wrangler tail` 必须把输出重定向到文件，不要用 `| Out-String`——
> `Out-String` 是聚合器，会等进程结束才输出，而 tail 永不结束，结果永远看不到：
> ```powershell
> cmd.exe /c "npx --yes wrangler@latest tail instabox-keepalive --format pretty > tail.log 2>&1"
> ```

### 改 cron 频率后的过渡期

改完 `deploy` 后，**旧调度器还会多跳最后一跳旧节奏**（日志里仍显示旧表达式），下一跳才切到新节奏。
不影响正确性——租约是同一个 lease 名覆盖写入，重复续租无害。

---

## Worker 的自愈逻辑

| API 返回 | Worker 的处理 |
|---|---|
| 续租成功 | 直接返回 `ok: true` |
| `machine_not_running` | 先 `resume`（失败用 `start` 兜底），轮询等到 `running`，再重试续租 |
| `machine_cooldown` | 读 `retryAfterSeconds`，**本轮跳过**，不算硬失败（那是被动的等待，硬撞会被拒） |
| 其他错误 | 记为失败，日志里留 HTTP 状态和错误码 |

冷却期跳过后，Worker 的 cron 会在下一个周期（≤3 分钟）再试。

---

## 从本机计划任务迁移

```powershell
# 1. 停用本机计划任务（禁用而非删除，可随时恢复）
Disable-ScheduledTask -TaskName "<任务名>"

# 2. 恢复（如果 Worker 出问题）
Enable-ScheduledTask -TaskName "<任务名>"
```

**迁移完成的判定**：
- Worker cron 日志有触发记录 ✓
- Worker `/status` 返回 `running` ✓
- 本机计划任务状态为 `Disabled` ✓

不要两边同时跑——虽然重复续租无害，但会让「到底谁在保活」变得不可追溯。

---

## 安全

| 项 | 要求 |
|---|---|
| `TOKEN` | 32 位随机 hex，等同密码，别外传 |
| `INSTABOX_API_KEY` | 只放 Secret，不放 `[vars]`（vars 会在部署输出里明文显示） |
| Worker 域名 | 本身公开，所以**必须**设 `TOKEN` |
| 无 token 访问 | 必须返回 401 |

---

## Cloudflare API 直接查触发器

排查 cron 是否真的注册：

```bash
curl -s "https://api.cloudflare.com/client/v4/accounts/<account_id>/workers/scripts/<worker_name>/schedules" \
  -H "Authorization: Bearer <oauth_token>" | jq .result
```

期望：

```json
{ "schedules": [ { "cron": "*/3 * * * *", "created_on": "...", "modified_on": "..." } ] }
```

比看 deploy 输出可靠——deploy 输出显示的是**你写的值**，这个显示的是**服务端实际生效的值**。
