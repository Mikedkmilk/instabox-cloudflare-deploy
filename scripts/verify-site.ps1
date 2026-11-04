# 端到端验证：站点 + 隧道 + 保活
#
# 用法：
#   pwsh -File verify-site.ps1 -Domain app.example.com -Machine web-app -WorkerUrl https://instabox-keepalive.xxx.workers.dev -Token <token>
param(
    [Parameter(Mandatory = $true)][string]$Domain,
    [string]$Machine = '',
    [string]$WorkerUrl = '',
    [string]$Token = '',
    [int]$Port = 3000,
    [string[]]$Routes = @('/', '/projects', '/map', '/top', '/submit', '/member', '/stories', '/compare', '/sitemap.xml', '/robots.txt')
)

$ErrorActionPreference = 'Continue'
$fail = 0
$warn = 0

function Ok($m)   { Write-Host "   [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   [WARN] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "   [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Sec($m)  { Write-Host ""; Write-Host "-- $m" -ForegroundColor Cyan }

$base = "https://$Domain"

# ================================================================ 1. 基础路由
Sec "1. 站点路由（$base）"
foreach ($u in $Routes) {
    try {
        $r = Invoke-WebRequest -Uri ($base + $u) -TimeoutSec 30
        if ($r.StatusCode -eq 200) { Ok ("{0,-16} 200  {1} bytes" -f $u, $r.RawContentLength) }
        else { Bad ("{0,-16} {1}" -f $u, $r.StatusCode) }
    } catch {
        Bad ("{0,-16} ERR {1}" -f $u, $_.Exception.Message)
    }
}

# ================================================================ 2. 动态路由
Sec "2. 动态路由（验证 params/searchParams 的 await 是否正确）"
try {
    $h = (Invoke-WebRequest -Uri "$base/projects" -TimeoutSec 30).Content
    $m = [regex]::Match($h, 'href="(/projects/[^"]+)"')
    if ($m.Success) {
        $path = $m.Groups[1].Value
        $r = Invoke-WebRequest -Uri ($base + $path) -TimeoutSec 30
        if ($r.StatusCode -eq 200) { Ok "详情页 $path -> 200" }
        else { Bad "详情页 $path -> $($r.StatusCode)" }
    } else {
        Warn "页面上没抓到详情页链接，跳过"
    }
} catch { Bad "详情页 ERR $($_.Exception.Message)" }

# 目的地专区（Next 15 里 params 变 Promise，漏 await 会 404）
try {
    $r = Invoke-WebRequest -Uri "$base/destinations/%E4%BA%91%E5%8D%97" -TimeoutSec 30
    if ($r.StatusCode -eq 200) { Ok "专区 /destinations/云南 -> 200" }
    else { Bad "专区 /destinations/云南 -> $($r.StatusCode)（Next 15 漏 await params 会 404）" }
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -eq 404) { Bad "专区 404 —— Next 15 漏 await params 的典型症状" }
    else { Warn "专区 ERR $($_.Exception.Message)" }
}

# ================================================================ 3. 图片
Sec "3. 图片服务"
try {
    $h = (Invoke-WebRequest -Uri "$base/" -TimeoutSec 30).Content
    $m = [regex]::Match($h, 'src="(/img/[^"]+)"')
    if ($m.Success) {
        $path = $m.Groups[1].Value
        $r = Invoke-WebRequest -Uri ($base + $path) -TimeoutSec 30
        $ct = ($r.Headers['Content-Type'] -join '')
        if ($r.StatusCode -eq 200 -and $ct -like 'image/*') {
            Ok "$path -> 200  $ct  $([math]::Round($r.RawContentLength/1KB))KB"
        } else {
            Bad "$path -> $($r.StatusCode)  content-type=$ct"
        }
    } else {
        Warn "首页没抓到图片引用，跳过"
    }
} catch { Bad "图片 ERR $($_.Exception.Message)" }

# ================================================================ 4. sitemap 域名
Sec "4. sitemap / robots"
try {
    $sm = (Invoke-WebRequest -Uri "$base/sitemap.xml" -TimeoutSec 60).Content
    $n = ([regex]::Matches($sm, '<url>')).Count
    $first = [regex]::Match($sm, '<loc>([^<]+)</loc>').Groups[1].Value
    Ok "sitemap $n 条 URL"
    if ($first -like "https://$Domain*") { Ok "sitemap 域名正确：$first" }
    else { Bad "sitemap 域名不对：$first（应含 https://$Domain，检查 .env 的 SITE_URL）" }
} catch { Bad "sitemap ERR $($_.Exception.Message)" }

# ================================================================ 5. 表单跳转
Sec "5. 表单 POST → 相对 Location"
try {
    $body = @{ projectId = 'verify-check'; name = 'VERIFY'; wechat = 'verifycheck'; agreement = 'on' }
    $r = Invoke-WebRequest -Uri "$base/api/apply" -Method Post -Body $body `
        -MaximumRedirection 0 -TimeoutSec 30 -SkipHttpErrorCheck
    $loc = $r.Headers['Location']
    if ($r.StatusCode -eq 303) { Ok "HTTP 303  Location: $loc" }
    else { Warn "HTTP $($r.StatusCode)（期望 303）  Location: $loc" }
    if ($loc -like 'http*') {
        Bad "Location 是绝对地址 —— 会跳到 localhost（反代/隧道下必须用相对 Location）"
    } elseif ($loc) {
        Ok "Location 是相对路径 ✓"
    }
} catch {
    # 3xx + MaximumRedirection=0 时 PowerShell 可能抛异常，这里不判失败
    $resp = $_.Exception.Response
    if ($resp) {
        $loc = $resp.Headers['Location']
        Ok "HTTP $([int]$resp.StatusCode)  Location: $loc"
        if ($loc -like 'http*') { Bad "Location 是绝对地址 —— 会跳到 localhost" }
    } else { Warn "表单 POST ERR $($_.Exception.Message)" }
}

# ================================================================ 6. 保活 Worker
Sec "6. 保活 Worker"
if (-not $WorkerUrl) {
    Warn "未指定 -WorkerUrl，跳过（先用 npx wrangler tail <name> 确认 cron 在触发）"
} else {
    try {
        $r = Invoke-WebRequest -Uri "$WorkerUrl/status" -TimeoutSec 30 -SkipHttpErrorCheck
        if ($r.StatusCode -eq 401) { Ok "未带 token 被拒（401）—— 鉴权生效 ✓" }
        else { Bad "未带 token 返回 $($r.StatusCode)，应为 401（TOKEN 没配或失效）" }
    } catch { Warn "Worker 无鉴权探测 ERR $($_.Exception.Message)" }

    if ($Token) {
        try {
            $r = Invoke-WebRequest -Uri "$WorkerUrl/status?token=$Token" -TimeoutSec 30
            $j = $r.Content | ConvertFrom-Json
            if ($r.StatusCode -eq 200) {
                Ok "/status 200"
                foreach ($m in $j.results) {
                    Write-Host ("         {0} [{1}] state={2} 上限={3}min 冷却={4}" -f `
                        $m.machine, $m.id, $m.state, $m.maxRunMinutes, $m.cooldownUntil)
                }
            } else { Bad "/status -> $($r.StatusCode)" }
        } catch { Bad "/status ERR $($_.Exception.Message)" }

        try {
            $r = Invoke-WebRequest -Uri "$WorkerUrl/?token=$Token" -TimeoutSec 30
            $j = $r.Content | ConvertFrom-Json
            if ($j.ok) { Ok "手动续租成功：$($j.results[0].detail)" }
            else { Warn "手动续租未成功：$($j.results[0].detail)" }
        } catch { Bad "手动续租 ERR $($_.Exception.Message)" }
    } else {
        Warn "未指定 -Token，跳过带 token 的检查"
    }
}

# ================================================================ 7. 机器侧
Sec "7. 机器状态"
if ($Machine) {
    $raw = & npx --yes instabox@latest exec $Machine -- bash -lc "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$Port/; echo ''; df -h /data | tail -1; pm2 list --no-color 2>/dev/null | head -6" 2>&1 | Out-String
    Write-Host $raw.TrimEnd()
    if ($raw -match '200') { Ok "机器内首页 200" } else { Warn "机器内首页未返回 200" }
} else {
    Warn "未指定 -Machine，跳过"
}

# ================================================================ 汇总
Write-Host ""
Write-Host "===========================================" -ForegroundColor Cyan
if ($fail -eq 0) {
    Write-Host "✅ 端到端验证通过" -ForegroundColor Green
    Write-Host "===========================================" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "❌ 有 $fail 项未通过（另有 $warn 项警告）" -ForegroundColor Red
    Write-Host "   排查见 references/troubleshooting.md" -ForegroundColor Yellow
    Write-Host "===========================================" -ForegroundColor Cyan
    exit 1
}
