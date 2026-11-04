# 打包代码用于推送到 InstaBox
#
# 用法：
#   pwsh -File stage-code.ps1 -Repo D:\path\to\repo -Stage D:\out\app
#
# 排除：依赖/构建产物/数据目录/本地密钥。
# 只含代码，保证「代码源」与「数据源」分离（数据见 data-transfer.md）。
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$Stage,
    [string[]]$ExtraExcludeDirs = @()
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Repo)) { throw "仓库路径不存在: $Repo" }
$Repo = (Resolve-Path -LiteralPath $Repo).Path

# ---- 清理上一次暂存 ----
if (Test-Path -LiteralPath $Stage) {
    Get-ChildItem -LiteralPath $Stage -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
} else {
    New-Item -ItemType Directory -Force -Path $Stage | Out-Null
}

# ---- 精确的排除规则：按顶层目录名判断，避免正则误伤 ----
$excludeDirs = @('node_modules', '.git', '.next', 'data', 'logs', 'backups', 'coverage') + $ExtraExcludeDirs
$copied = 0
$skipped = 0

Get-ChildItem -LiteralPath $Repo -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Substring($Repo.Length).TrimStart('\')
    $parts = $rel -split '\\'
    $top  = $parts[0]

    # 顶层是排除目录 → 跳过
    if ($excludeDirs -contains $top) { $script:skipped++; return }

    # 本地密钥绝不上传
    if ($_.Name -eq '.env' -or $_.Name -like '.env.local' -or $_.Name -like '*.key') {
        $script:skipped++; return
    }

    $dst = Join-Path $Stage $rel
    $parent = Split-Path $dst -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
    $script:copied++
}

Write-Host "已复制 $copied 个代码文件（跳过 $skipped 个：依赖/构建/数据/本地密钥）" -ForegroundColor Green

# ---- 关键文件校验（必须 -LiteralPath，方括号路径会被当通配符）----
# ⚠️ PowerShell 的 Test-Path / Get-Content 对含 [ ] 的路径会按通配符解释，
#    app\img\[[...path]]\route.js 必须用 -LiteralPath。
$required = @('package.json', 'package-lock.json')
$optional = @(
    'next.config.mjs', 'next.config.js',
    'app\page.js', 'app\layout.js'
)
$missing = @()
foreach ($k in $required) {
    if (Test-Path -LiteralPath (Join-Path $Stage $k)) { Write-Host "  OK   $k" }
    else { Write-Host "  缺失 $k" -ForegroundColor Red; $missing += $k }
}
foreach ($k in $optional) {
    if (Test-Path -LiteralPath (Join-Path $Stage $k)) { Write-Host "  OK   $k" }
    else { Write-Host "  --   $k（非框架项目可忽略）" }
}

$all = Get-ChildItem -LiteralPath $Stage -Recurse -File -Force
Write-Host ("代码包体积: {0:N2} MB / {1} 文件" -f (($all | Measure-Object Length -Sum).Sum / 1MB), $all.Count)

if ($missing.Count -gt 0) { throw "关键文件缺失: $($missing -join ', ')" }
Write-Host "✓ 代码暂存完成 -> $Stage" -ForegroundColor Green
