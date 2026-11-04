# 前置条件：四项必需信息

缺任何一项**先问用户**，不要用默认值硬跑。每一项都有明确的获取路径。

---

## 1. GitHub 仓库地址

用户给。确认三件事：

- **仓库 URL**：如 `https://github.com/<owner>/<repo>.git`
- **分支**：默认 `main`；确认不是 `master`
- **可见性**：私有库需要本机已有 git 凭据（credential helper / SSH key / PAT）

```bash
# 克隆
git clone <repo-url> <local-dir>
cd <local-dir> && git checkout <branch>
```

**数据文件通常不在仓库里**：超过 GitHub 单文件 100 MiB 的数据（如 SQLite 主库、图片库）
按 Release 附件分发。见 `data-transfer.md`。

### 拉取子目录 / 单文件

```bash
# 只取某个 tag 的 Release 附件
curl -L -o site.db.gz https://github.com/<owner>/<repo>/releases/download/<tag>/site.db.gz
```

---

## 2. InstaBox API Key

**获取路径**：instabox.sh → 登录 → 账户设置 → API Keys → Create。
形如 `ibk_` 开头的字符串。

**用途**：`instabox` CLI 与保活 Worker 都要用。

```bash
export INSTABOX_API_KEY='ibk_...'
```

**安全要求**：
- 不写进仓库、不进日志、不在回复里明文展示
- 存到文件时收紧权限：

```bash
# Linux/macOS
chmod 600 instabox.key
# Windows (PowerShell)
icacls instabox.key /inheritance:r /grant:r "$env:USERNAME:(R,W)"
```

### 验证

```bash
npx --yes instabox@latest ls --json
```

返回机器列表即凭证有效。空列表 = 账号下还没有机器，需先创建。

### 创建机器

```bash
npx --yes instabox@latest create <机器名> --template agent-browser --json
```

免费套餐：**1 台**，4 vCPU / 8 GiB / 20 GiB（`/data` 固定不可 resize）。

---

## 3. Cloudflare 账户

### 方案 A：`wrangler login --device`（推荐，无短超时）

```bash
npx --yes wrangler@latest login --device
```

设备码流程：打印一个 URL + 一串码，你在浏览器里输入码即可，**没有 120 秒窗口限制**。

### 方案 B：API Token（最稳，完全无交互）

面板 → 账户 → API Tokens → Create Token，权限：

| 范围 | 权限 | 用途 |
|---|---|---|
| Account | Workers Scripts: Edit | 部署 Worker |
| Account | Workers KV Storage: Edit | Worker KV（本流程不用也要给） |
| Account | Account Settings: Read | 读取 Account ID |
| Zone | Workers Routes: Edit | 绑定域名（如果用 Worker 直接绑路由） |
| Zone | Zone: Read | 读取 Zone ID |

然后：

```bash
export CLOUDFLARE_ACCOUNT_ID='<account_id>'
export CLOUDFLARE_API_TOKEN='<token>'
```

### 方案 C：`wrangler login`（OAuth，注意 120 秒硬超时）

```bash
npx --yes wrangler@latest login --browser=false
```

它会打印一个授权 URL，**必须在 120 秒内**在浏览器里点 Allow。
超时报错：`Timed out waiting for authorization code`（日志里 `durationMs 120052`）。

Windows 上后台跑时用 `cmd.exe /c` 调 npx（`npx.cmd` 直接作 ProcessStartInfo 会模块解析失败）：

```powershell
cmd.exe /c "npx --yes wrangler@latest login --browser=false"
```

### 取 Account ID

```bash
npx --yes wrangler@latest whoami
```

输出里的 `Account ID` 就是它。也可用 Cloudflare API：

```bash
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  https://api.cloudflare.com/client/v4/accounts | jq -r '.result[].id'
```

### 验证

```bash
npx --yes wrangler@latest whoami
```

---

## 4. 已有域名

### 前提：主域名的 NS 必须已经指向 Cloudflare

```bash
nslookup -type=NS <主域名>
```

返回的 NS 里有 `*.ns.cloudflare.com` 才算就绪。没就绪的话，先去域名注册商改 NS。

### 需要的两个信息

| 项 | 示例 | 说明 |
|---|---|---|
| 主域名 | `example.com` | NS 已在 Cloudflare |
| 要绑的二级域名 | `app` | 拼成 `app.example.com` |

### 验证域名可解析

```bash
nslookup app.example.com
```

绑完之后应该解析到 Cloudflare 的 Anycast IP（`104.x` / `172.64.x` / `103.x` 段）。

### 主域名 NS 与其他 DNS 记录

**只新增这一条二级域名的记录，不要动主域名 NS 和其他已有记录。**
本流程走 Tunnel，DNS 侧不需要 CNAME —— Public Hostname 绑好后 Cloudflare 自动建记录。

---

## 凭证清单模板

部署前把这些填进 `.env`（`chmod 600`，永不入库）：

```ini
# InstaBox
INSTABOX_API_KEY=ibk_...

# Cloudflare（二选一）
CLOUDFLARE_API_TOKEN=...
CLOUDFLARE_ACCOUNT_ID=...

# 目标信息
INSTABOX_MACHINE_NAME=web-app
INSTABOX_MACHINE_ID=<MACHINE_ID>
TARGET_DOMAIN=app.example.com
BASE_DOMAIN=example.com
```

`INSTABOX_MACHINE_ID` 从 `instabox ls --json` 里取 `id` 字段。
**保活 Worker 必须用 ID**，用机器名会 404。
