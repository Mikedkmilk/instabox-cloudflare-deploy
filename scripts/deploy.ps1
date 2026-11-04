# 本机编排：把代码部署到 InstaBox 机器（Windows PowerShell）
#
# 用法：
#   $env:INSTABOX_API_KEY = 'ibk_...'
#   pwsh -File deploy.ps1 -Machine web-app -Repo D:\path\to\repo -Port 3000
param(
    [Parameter(Mandatory = $true)][string]$Machine,
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$AppName = 'web-app',
    [int]$Port = 3000,
    [string]$SiteUrl = '',
    [string]$ApiKey = '',
    [string]$Stage = '',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot

if ($ApiKey) { $env:INSTABOX_API_KEY = $ApiKey }
if (-not $env:INSTABOX_API_KEY) { throw "未设置 INSTABOX_API_KEY" }
if (-not $Stage) { $Stage = Join-Path $env:TEMP "instabox-deploy-$AppName" }

function Step($m) { Write-Host ""; Write-Host ">> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "   [OK] $m" -ForegroundColor Green }
function Die($m)  { Write-Host "   [FAIL] $m" -ForegroundColor Red; exit 1 }

# ================================================================ 1. 预检
Step "1/4 预检"
$raw = & npx --yes instabox@latest ls --json 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Die "CLI 调用失败（凭证无效或网络不通）：$raw" }
try { $machines = $raw | ConvertFrom-Json } catch { Die "无法解析 CLI 输出：$raw" }
$target = $machines | Where-Object { $_.name -eq $Machine }
if (-not $target) { Die "找不到机器 '$Machine'（账号下有：$(($machines | ForEach-Object { $_.name }) -join ', ')）" }
Ok "机器 $($target.name) [$($target.id)] 状态=$($target.state)"

if ($target.state -ne 'running') {
    Write-Host "   机器非 running，尝试启动…" -ForegroundColor Yellow
    & npx --yes instabox@latest start $Machine | Out-Null
    Start-Sleep -Seconds 20
    Ok "已启动"
}

# ================================================================ 2. 打包
Step "2/4 打包代码"
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'stage-code.ps1') -Repo $Repo -Stage $Stage
if ($LASTEXITCODE -ne 0) { Die "代码打包失败" }
$files = Get-ChildItem -LiteralPath $Stage -Recurse -File -Force
Ok ("{0} 个文件 / {1:N2} MB" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB))

# ================================================================ 3. 推送 + 机器端安装
Step "3/4 推送并安装"
& npx --yes instabox@latest push $Machine "$Stage/" "/data/home/$AppName" --all 2>&1 | Out-String | Write-Host
if ($LASTEXITCODE -ne 0) { Die "代码推送失败" }
Ok "代码已到位"

& npx --yes instabox@latest push $Machine (Join-Path $PSScriptRoot 'deploy-in-machine.sh') "/data/home/deploy-in-machine.sh" 2>&1 | Out-String | Write-Host
if ($LASTEXITCODE -ne 0) { Die "安装脚本推送失败" }
Ok "安装脚本已到位"

# ⚠️ exec 的 --timeout 上限是 600 秒
$remote = "chmod +x /data/home/deploy-in-machine.sh && APP_NAME='$AppName' PORT=$Port SITE_URL='$SiteUrl' bash /data/home/deploy-in-machine.sh"
& npx --yes instabox@latest exec $Machine --timeout 600 -- bash -lc $remote 2>&1 | Out-String -Width 220 | Write-Host
if ($LASTEXITCODE -ne 0) { Die "机器端安装失败（见上方输出）" }

# ================================================================ 4. 收尾自检
Step "4/4 收尾自检"
$check = & npx --yes instabox@latest exec $Machine -- bash -lc "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$Port/ ; echo ''; df -h /data | tail -1" 2>&1 | Out-String
Write-Host $check
if ($check -match '200') { Ok "首页返回 200" } else { Die "首页未返回 200" }

Write-Host ""
Write-Host "===========================================" -ForegroundColor Green
Write-Host "✅ 部署完成 —— 下一步" -ForegroundColor Green
Write-Host "===========================================" -ForegroundColor Green
Write-Host "  1) 绑定 Cloudflare Tunnel（Service Type 必须 HTTP）"
Write-Host "     详见 references/cloudflare-tunnel.md"
Write-Host "  2) 配置 Worker 保活（cron */3，TTL 900）"
Write-Host "     pwsh -File scripts/keepalive/deploy-keepalive.ps1 -Machine $Machine -MachineId $($target.id)"
Write-Host "  3) 端到端验证"
Write-Host "     pwsh -File scripts/verify-site.ps1 -Machine $Machine -Domain <你的子域名>"
