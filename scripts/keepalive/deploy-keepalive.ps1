# 部署 InstaBox 保活 Worker（Cloudflare cron）
#
# 用法：
#   $env:INSTABOX_API_KEY = 'ibk_...'
#   pwsh -File deploy-keepalive.ps1 -Machine web-app -MachineId m_xxx
#
# 参数：
#   -MachineId     必填。机器 ID（m_xxx）。activity-leases 端点只认 ID，用机器名会 404
#   -WorkerName    Worker 名，默认 instabox-keepalive
#   -Cron          cron 表达式，默认 */3 * * * *（每 3 分钟）
#   -Ttl           租约秒数，默认 900（必须 > cron 间隔）
#   -Token         Worker 访问口令；不给则自动生成并打印
#   -WorkDir       工作目录，默认 $env:TEMP\instabox-keepalive
param(
    [Parameter(Mandatory = $true)][string]$MachineId,
    [string]$Machine = '',
    [string]$WorkerName = 'instabox-keepalive',
    [string]$Cron = '*/3 * * * *',
    [int]$Ttl = 900,
    [string]$Token = '',
    [string]$WorkDir = '',
    [string]$ApiKey = ''
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$keepaliveDir = Join-Path $PSScriptRoot ''

if ($ApiKey) { $env:INSTABOX_API_KEY = $ApiKey }
if (-not $env:INSTABOX_API_KEY) { throw "未设置 INSTABOX_API_KEY" }
if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP "instabox-keepalive" }

function Step($m) { Write-Host ""; Write-Host ">> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "   [OK] $m" -ForegroundColor Green }
function Die($m)  { Write-Host "   [FAIL] $m" -ForegroundColor Red; exit 1 }

# ================================================================ 1. 准备 Worker 源码
Step "1/4 准备 Worker 源码"
if (Test-Path -LiteralPath $WorkDir) {
    Get-ChildItem -LiteralPath $WorkDir -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
} else {
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'worker.js') -Destination (Join-Path $WorkDir 'worker.js') -Force
Ok "worker.js 已复制到 $WorkDir"

# 生成 wrangler.toml
$toml = @"
name = "$WorkerName"
main = "worker.js"
compatibility_date = "2026-10-01"

[triggers]
crons = ["$Cron"]

[vars]
INSTABOX_MACHINE = "$MachineId"
INSTABOX_TTL = "$Ttl"
"@
Set-Content -LiteralPath (Join-Path $WorkDir 'wrangler.toml') -Value $toml -Encoding UTF8
Ok "wrangler.toml 已生成（cron=$Cron, ttl=$Ttl）"

# ⚠️ crons 必须在 [triggers] 下 —— 写顶层 wrangler 4 会静默忽略
if (-not (Select-String -LiteralPath (Join-Path $WorkDir 'wrangler.toml') -Pattern '^\[triggers\]$' -Quiet)) {
    Die "wrangler.toml 里没有 [triggers] 段，cron 会不生效"
}

# ================================================================ 2. 登录检查
Step "2/4 Cloudflare 登录检查"
$who = & npx --yes wrangler@latest whoami 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $who -notmatch 'logged in') {
    Die "wrangler 未登录。执行 `npx wrangler login --device`（OAuth 只有 120 秒窗口）或设置 CLOUDFLARE_API_TOKEN"
}
Ok "已登录"
if ($who -match '([0-9a-f]{32})') { Ok "Account ID = $($Matches[1])" }

# ================================================================ 3. 部署 + Secret
Step "3/4 部署 Worker 并写入 Secret"

# ⚠️ 必须先 deploy：secret put 要求 Worker 已存在
Push-Location $WorkDir
try {
    & npx --yes wrangler@latest deploy 2>&1 | Out-String -Width 200 | Write-Host
    if ($LASTEXITCODE -ne 0) { Die "Worker 部署失败" }
} finally { Pop-Location }
Ok "Worker 已部署"

# 口令
if (-not $Token) {
    $Token = node -e "console.log(require('crypto').randomBytes(16).toString('hex'))"
    Ok "自动生成访问口令：$Token"
    Write-Host "   ⚠ 这是访问凭据，保存好；之后 curl 都要带 ?token=$Token" -ForegroundColor Yellow
}

Write-Host "   写入 INSTABOX_API_KEY …"
Push-Location $WorkDir
try {
    # ⚠️ 用管道喂值。若路径/变量写错，wrangler 照样输出 Success 但存的是空值 —— 后面必须验证
    $env:INSTABOX_API_KEY | & npx --yes wrangler@latest secret put INSTABOX_API_KEY 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) { Die "写入 INSTABOX_API_KEY 失败" }

    Write-Host "   写入 TOKEN …"
    $Token | & npx --yes wrangler@latest secret put TOKEN 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) { Die "写入 TOKEN 失败" }
} finally { Pop-Location }
Ok "Secret 已写入"

# ================================================================ 4. 取地址并验证
Step "4/4 验证"
Push-Location $WorkDir
try {
    $list = & npx --yes wrangler@latest deployments list 2>&1 | Out-String
} finally { Pop-Location }

$url = ''
if ($list -match '(https://[a-z0-9\-]+\.[a-z0-9\-\.]+\.workers\.dev)') {
    $url = $Matches[1]
}
if (-not $url) {
    # 从 wrangler 的 deploy 输出里再试一次
    Write-Host $list
    $url = $env:WORKER_URL
}
if (-not $url) {
    Warn "未能自动取到 Worker 地址，请手动执行：npx wrangler deployments list"
} else {
    Ok "Worker 地址：$url"
    Write-Host ""
    Write-Host "   验证命令：" -ForegroundColor DarkGray
    Write-Host "     curl \"$url/status?token=$Token\""
    Write-Host "     curl \"$url/?token=$Token\""
    Write-Host ""
    Write-Host "   ⚠ 下一步【必须做】：确认 cron 真的在触发" -ForegroundColor Yellow
    Write-Host "     cmd.exe /c \"npx --yes wrangler@latest tail $WorkerName --format pretty > tail.log 2>&1\""
    Write-Host "     然后等一个 cron 周期，确认 tail.log 出现 \"$Cron\" 的触发记录"
    Write-Host "     没出现 = cron 没生效（检查 wrangler.toml 的 [triggers] 段）"
}

if ($Machine) {
    Write-Host ""
    Write-Host "   迁移收尾：禁用本机计划任务（禁用而非删除，可随时恢复）" -ForegroundColor DarkGray
    Write-Host "     Disable-ScheduledTask -TaskName '<任务名>'"
}
