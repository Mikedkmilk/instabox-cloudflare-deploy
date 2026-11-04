# 故障速查表

按「症状 → 根因 → 修复」查。

---

## 部署阶段

| 症状 | 根因 | 修复 |
|---|---|---|
| `database disk image is malformed` | WAL 模式下只传了 `site.db`，与 `-wal` 失配 | 传前 `PRAGMA wal_checkpoint(TRUNCATE)`，或三文件同刻一起传。见 `data-transfer.md` |
| 源库一开始就 malformed | 上游仓库里的库本身是坏的 | 换备份源，**不要**抢救损坏的库 |
| `Cannot find module 'node:sqlite'` | Node < 22.5 | 装 Node 22（`node:sqlite` 硬性要求） |
| `npm ci` 报 ERESOLVE | lock 文件与 package.json 不一致 | 先 `npm install` 刷新 lock，再 `npm ci` |
| 构建后全站裸文本 / 500 | `dev` 与 `start` 共用 `.next` 损坏 | 停服 → `rm -rf .next` → 重新 build |
| build 时报「正在运行的 next start」 | 并发构建损坏 `.next` | **必须先停服再 build** |
| `/data` 写满 | 图片全量上传 | 按实际引用裁剪（省 99%） |
| `instabox exec --timeout 900` 报错 | 上限 600 秒 | 改 `--timeout 600`，或用 `--background` + `jobs wait` |
| `instabox exec` 多行 bash 输出为空 | 输出丢失 | 改单行命令，或写成脚本文件 push 后执行 |
| `host_unavailable: 502 Bad Gateway` | InstaBox API 瞬时故障 | **重试**，不是凭证错误 |
| cmd 报 `unexpected EOF while looking for matching` | cmd 吃掉了单引号 | 用 `cmd.exe /c "..."` 且 bash 命令用双引号包，或改用脚本文件 |
| `npx.cmd` 作 ProcessStartInfo 报模块找不到 | Windows 路径解析 | 用 `cmd.exe /c npx ...` |

---

## 隧道阶段

| 症状 | 根因 | 修复 |
|---|---|---|
| 公网 502，日志 `tls: first record does not look like a TLS handshake` | Public Hostname 的 Service Type 选成了 HTTPS，而应用是明文 HTTP | 改成 **HTTP**，URL 填 `localhost:<port>` |
| 隧道已连接但域名打不开 | 没绑 Public Hostname | 面板里加 hostname 记录 |
| 改了 hostname 但 `version=N` 不变 | 配置没下发到连接器 | 看 `journalctl -u cloudflared` 确认 `Updated to new configuration` 的 version 是否递增 |
| DNS CNAME 到 InstaBox 后 404 | 网关按 Host 头路由，自定义 Host 不认 | 改用 Tunnel（CNAME 直连不可行） |
| 80 端口不通 | 网关不提供 | 不需要，Tunnel 走机器内部端口 |
| 证书不匹配 | InstaBox 证书 SAN 仅 `*.instabox.tech` | 用 Cloudflare 边缘证书 |
| 访客 IP 是 Cloudflare 的 | Tunnel 架构使然（**不是 bug**） | 访客看到的是 Cloudflare Anycast IP，与机器出口无关 |
| 访客访问慢 | Cloudflare 免费版无中国内地节点 | 接受，或换国内服务器 + 备案 |
| 改了应用端口后 Tunnel 还指旧端口 | Public Hostname 的 URL 没改 | 面板同步改 URL |

---

## 保活阶段

| 症状 | 根因 | 修复 |
|---|---|---|
| `auto-suspend 0` 无效 | 免费套餐锁死 1800 秒 | 只能用 activity lease |
| lease 续租 404 `machine not found` | 端点只认机器 ID | 用 `m_xxx`，不用机器名 |
| lease 续租 409 `machine_not_running` | 机器被挂起 | 先 `resume`（失败用 `start`），等 running 再续租 |
| lease 续租 409 `machine_cooldown` | 撞 8 小时上限的冷却期 | 读 `retryAfterSeconds`，本轮跳过，**别硬撞** |
| `resume` / `start` 报错 | 缺 Idempotency-Key | 加 `-H "Idempotency-Key: $(uuidgen)"` |
| Worker deploy 显示 `schedule: */3` 但没触发 | cron 写在了顶层 | wrangler 4 必须写在 `[triggers]` 下 |
| `secret put` 报 Success 但 secret 是空的 | 管道喂了空值（路径写错） | 用 `/status` 验证，**别信 Success** |
| `secret put` 报 worker 不存在 | 顺序反了 | 先 `deploy` 再 `secret put` |
| `wrangler login` 报 `Timed out waiting for authorization code` | OAuth 只有 120 秒窗口 | 改用 `--device` 或 API Token |
| `wrangler tail` 一直无输出 | `\| Out-String` 聚合了输出 | 重定向到文件：`cmd.exe /c "... > tail.log 2>&1"` |
| Worker 无重试无告警，失败静默 | 免费版限制 | 定期 `wrangler tail`；或加外部探活 |
| 本机计划任务和 Worker 同时跑 | 迁移没做干净 | 禁用计划任务，保持单一保活源 |

---

## 应用层（Next.js 通用）

| 症状 | 根因 | 修复 |
|---|---|---|
| 动态路由 404 或数据为空（Next 15+） | `params` / `searchParams` 变成 Promise，没 await | `const params = await props.params` |
| 详情页 `?applied=1` 没生效 | `searchParams` 没 await | 同上 |
| 表单提交后跳到 localhost | 重定向用了绝对地址 | 用相对 Location（如 `lib/redirect.js`），反代/隧道下才正确 |
| `npm audit` 报 `postcss` 漏洞 | Next 15 分支的构建期依赖 | 官方修复要到 Next 16.4.3；构建期漏洞，风险低 |
| 图片 404 但页面正常 | 图片目录/环境变量没配对，或 `public/vendor` 被 gitignore 吞掉 | 检查 `IMG_*_DIR` 与文件是否存在 |
| 地图「组件加载失败」 | `public/vendor`（Leaflet）缺失 | `.gitignore` 用 `/dist/` 而不是 `dist/` |
| 端口被别的程序占用 | 临时进程抢占 | `netstat -ano \| findstr :3000` 查 PID；响应头 `X-Powered-By: Express` 说明不是本站 |

---

## 排查手法

### 定位端口占用者（Windows）

```powershell
Get-NetTCPConnection -LocalPort 3000 -State Listen |
  ForEach-Object {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.OwningProcess)"
    "{0}  {1}  {2}" -f $_.OwningProcess, $p.Name, $p.CommandLine
  }
```

### 确认隧道配置真的生效了

```bash
journalctl -u cloudflared -n 50 | grep -E "Updated to new configuration|Registered tunnel connection"
```

### 确认保活真的在触发

```bash
npx --yes wrangler@latest tail instabox-keepalive --format pretty > tail.log 2>&1
# 观察 tail.log
```

### 确认 Worker 的 cron 在服务端注册了

```bash
curl -s "https://api.cloudflare.com/client/v4/accounts/<acct>/workers/scripts/<name>/schedules" \
  -H "Authorization: Bearer <token>" | jq .result
```

### 确认机器实际状态（含冷却期）

```bash
curl -s "https://api.instabox.sh/v1/machines/<m_id>" -H "X-API-Key: $KEY" | jq \
  '{state, runStartedAt, maxRunMinutes, cooldownUntil}'
```

`cooldownUntil` 非 null = 正在冷却期。
