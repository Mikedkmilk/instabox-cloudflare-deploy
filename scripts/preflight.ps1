# 部署前预检：凭证、机器状态、磁盘、本机冲突端口
#
# 用法：
#   $env:INSTABOX_API_KEY = 'ibk_...'
#   pwsh -File preflight.ps1 -Machine web-app -Domain app.example.com -Repo D:\path\to\repo
param(
    [string]$Machine = '',
    [string]$Domain = '',
    [string]$Repo = '',
    [string]$ApiKey = '',
    [int]$Port = 3000,
    [int]$MinFreeGiB = 8
)

$ErrorActionPreference = 'Continue'
$fail = 0

function Ok($m)   { Write-Host "   [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   [WARN] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "   [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Sec($m)  { Write-Host ""; Write-Host "-- $m" -ForegroundColor Cyan }

if ($ApiKey) { $env:INSTABOX_API_KEY = $ApiKey }

# ================================================================ InstaBox
Sec "InstaBox 凭证"
if (-not $env:INSTABOX_API_KEY) {
    Bad "未设置 INSTABOX_API_KEY（instabox.sh → 账户 → API Keys）"
} elseif ($env:INSTABOX_API_KEY -notlike 'ibk_*') {
    Bad "INSTABOX_API_KEY 格式不对，应为 ibk_ 开头"
} else {
    Ok "INSTABOX_API_KEY 格式正确（未回显内容）"
}

if (-not $Machine) {
    Bad "未指定 -Machine"
} else {
    $raw = & npx --yes instabox@latest ls --json 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Bad "CLI 调用失败（凭证无效 / 网络不通 / API 瞬时 502）：$($raw.Trim())"
    } else {
        try {
            $machines = $raw | ConvertFrom-Json
            $target = $machines | Where-Object { $_.name -eq $Machine }
            if (-not $target) {
                Bad "找不到机器 '$Machine'（账号下有：$(($machines | ForEach-Object { $_.name }) -join ', ')）"
            } else {
                Ok "机器 $($target.name) [$($target.id)] state=$($target.state)"
                if ($target.state -ne 'running') { Warn "机器非 running，部署脚本会先尝试启动" }
            }
        } catch { Bad "无法解析 CLI 输出：$($raw.Trim())" }
    }
}

# ================================================================ Cloudflare
Sec "Cloudflare 凭证"
$hasToken = [bool]$env:CLOUDFLARE_API_TOKEN
$hasAcct  = [bool]$env:CLOUDFLARE_ACCOUNT_ID
if ($hasToken -and $hasAcct) {
    Ok "已设置 CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID（无交互模式）"
} else {
    $who = & npx --yes wrangler@latest whoami 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $who -match 'logged in') {
        Ok "wrangler 已登录"
        if ($who -match 'Account ID\s*│?\s*([0-9a-f]{32})') {
            Ok "Account ID = $($Matches[1])"
        }
    } else {
        Bad "wrangler 未登录。执行 `npx wrangler login --device`（OAuth 只有 120 秒窗口，用 --device 无超时）或设置 API Token"
    }
}

# ================================================================ 域名
Sec "域名"
if (-not $Domain) {
    Warn "未指定 -Domain，跳过域名检查"
} else {
    $parts = $Domain -split '\.'
    if ($parts.Count -lt 2) {
        Bad "域名格式不对：$Domain"
    } else {
        Ok "目标域名 $Domain"
        $base = $parts[-2..-1] -join '.'
        try {
            $ns = (Resolve-DnsName -Type NS -Name $base -ErrorAction Stop | Where-Object { $_.Type -eq 'NS' }).NameHost
            if ($ns -match 'cloudflare') { Ok "主域名 $base 的 NS 已指向 Cloudflare" }
            else { Bad "主域名 $base 的 NS 未指向 Cloudflare（当前：$($ns -join ', ')）" }
        } catch { Bad "查不到 $base 的 NS 记录" }
    }
}

# ================================================================ 仓库
Sec "代码仓库"
if (-not $Repo) {
    Warn "未指定 -Repo，跳过仓库检查"
} elseif (-not (Test-Path -LiteralPath $Repo)) {
    Bad "仓库路径不存在：$Repo"
} else {
    Ok "仓库存在：$Repo"
    foreach ($f in @('package.json')) {
        $p = Join-Path $Repo $f
        if (Test-Path -LiteralPath $p) { Ok "有 $f" } else { Bad "缺 $f" }
    }
    $lock = Join-Path $Repo 'package-lock.json'
    $yarn = Join-Path $Repo 'yarn.lock'
    if (Test-Path -LiteralPath $lock) { Ok "有 package-lock.json（用 npm ci）" }
    elseif (Test-Path -LiteralPath $yarn) { Ok "有 yarn.lock（用 yarn）" }
    else { Warn "没有 lock 文件，部署时无法用 npm ci --omit=dev" }
}

# ================================================================ 磁盘
Sec "服务器磁盘"
if ($Machine) {
    $disk = & npx --yes instabox@latest disk $Machine 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Host $disk.Trim()
        # 解析 "USED SIZE FREE USE%" 那行的 FREE 列（GiB）
        $line = ($disk -split "`n" | Where-Object { $_ -match '/data' } | Select-Object -First 1)
        if ($line -match '\s(\d+(?:\.\d+)?)\s*GiB\s+\S+\s+(\d+(?:\.\d+)?)\s*GiB\s+(\d+(?:\.\d+)?)%') {
            $free = [double]$Matches[2]
            $pct  = [double]$Matches[3]
            if ($free -lt $MinFreeGiB) { Bad "/data 剩余仅 ${free} GiB，低于建议的 ${MinFreeGiB} GiB" }
            else { Ok "/data 剩余 ${free} GiB（已用 ${pct}%）" }
        } else {
            Warn "无法解析磁盘输出，人工确认余量"
        }
    } else {
        Warn "读磁盘失败：$($disk.Trim())"
    }
}

# ================================================================ 本机端口
Sec "本机端口占用"
$listen = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listen) {
    foreach ($c in $listen) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.OwningProcess)" -ErrorAction SilentlyContinue
        Warn "端口 $Port 被 PID $($c.OwningProcess) 占用（$($p.Name)）"
        if ($p.CommandLine -match 'next.*start') {
            Warn "  ↳ 看起来是 next start。本地跑 QA 前必须先停它，否则测的不是被测副本"
        }
    }
} else {
    Ok "端口 $Port 空闲"
}

# ================================================================ 汇总
Write-Host ""
if ($fail -eq 0) {
    Write-Host "✅ 预检通过" -ForegroundColor Green
    exit 0
} else {
    Write-Host "❌ 预检有 $fail 项未通过" -ForegroundColor Red
    exit 1
}
