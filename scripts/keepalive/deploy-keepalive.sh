#!/usr/bin/env bash
# 部署 InstaBox 保活 Worker（Cloudflare cron）—— Linux / macOS 版
#
# 用法：
#   export INSTABOX_API_KEY='ibk_...'
#   bash deploy-keepalive.sh --machine-id m_xxx [--machine web-app] [--worker-name instabox-keepalive] [--cron '*/3 * * * *'] [--ttl 900] [--work-dir ./wrk]
set -euo pipefail

MACHINE_ID=""
MACHINE=""
WORKER_NAME="instabox-keepalive"
CRON='*/3 * * * *'
TTL=900
WORK_DIR="${TMPDIR:-/tmp}/instabox-keepalive"
TOKEN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --machine-id)   MACHINE_ID="$2"; shift 2 ;;
    --machine)      MACHINE="$2"; shift 2 ;;
    --worker-name)  WORKER_NAME="$2"; shift 2 ;;
    --cron)         CRON="$2"; shift 2 ;;
    --ttl)          TTL="$2"; shift 2 ;;
    --token)        TOKEN="$2"; shift 2 ;;
    --work-dir)     WORK_DIR="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

[ -n "$MACHINE_ID" ] || { echo "缺少 --machine-id" >&2; exit 1; }
[ -n "${INSTABOX_API_KEY:-}" ] || { echo "未设置 INSTABOX_API_KEY" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

step() { printf '\n\033[36m>> %s\033[0m\n' "$1"; }
ok()   { printf '   \033[32m[OK] %s\033[0m\n' "$1"; }
die()  { printf '   \033[31m[FAIL] %s\033[0m\n' "$1"; exit 1; }

# ================================================================ 1. 准备源码
step "1/4 准备 Worker 源码"
mkdir -p "$WORK_DIR"
find "$WORK_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
cp "$SCRIPT_DIR/worker.js" "$WORK_DIR/worker.js"

cat > "$WORK_DIR/wrangler.toml" <<EOF
name = "$WORKER_NAME"
main = "worker.js"
compatibility_date = "2026-10-01"

[triggers]
crons = ["$CRON"]

[vars]
INSTABOX_MACHINE = "$MACHINE_ID"
INSTABOX_TTL = "$TTL"
EOF
ok "已生成 $WORK_DIR（cron=$CRON, ttl=$TTL）"

# ⚠️ crons 必须在 [triggers] 下 —— 写顶层 wrangler 4 会静默忽略
grep -q '^\[triggers\]$' "$WORK_DIR/wrangler.toml" || die "wrangler.toml 缺 [triggers] 段"

# ================================================================ 2. 登录检查
step "2/4 Cloudflare 登录检查"
npx --yes wrangler@latest whoami > /dev/null 2>&1 || \
  die "wrangler 未登录。执行 npx wrangler login --device，或设置 CLOUDFLARE_API_TOKEN"
ok "已登录"

# ================================================================ 3. 部署 + Secret
step "3/4 部署 Worker 并写入 Secret"
cd "$WORK_DIR"
# ⚠️ 必须先 deploy：secret put 要求 Worker 已存在
npx --yes wrangler@latest deploy || die "Worker 部署失败"
ok "Worker 已部署"

[ -n "$TOKEN" ] || TOKEN="$(node -e "console.log(require('crypto').randomBytes(16).toString('hex'))")"
ok "访问口令：$TOKEN"

# ⚠️ 用管道喂值；写空时 wrangler 照样输出 Success，之后必须用 /status 验证
printf '%s' "$INSTABOX_API_KEY" | npx --yes wrangler@latest secret put INSTABOX_API_KEY || die "写 INSTABOX_API_KEY 失败"
printf '%s' "$TOKEN"            | npx --yes wrangler@latest secret put TOKEN || die "写 TOKEN 失败"
ok "Secret 已写入"

# ================================================================ 4. 验证
step "4/4 验证"
url="$(npx --yes wrangler@latest deployments list 2>&1 | grep -oE 'https://[a-z0-9-]+\.[a-z0-9.-]+\.workers\.dev' | head -1 || true)"
if [ -n "$url" ]; then
  ok "Worker 地址：$url"
  echo ""
  echo "   curl \"$url/status?token=$TOKEN\""
  echo "   curl \"$url/?token=$TOKEN\""
else
  echo "   未能自动取到地址，用 npx wrangler deployments list 手动查"
fi

echo ""
echo "   ⚠ 下一步【必须做】：确认 cron 真的在触发"
echo "     npx wrangler tail $WORKER_NAME --format pretty > tail.log 2>&1 &"
echo "     等一个 cron 周期，确认 tail.log 出现 \"$CRON\" 的触发记录"
echo "     没出现 = cron 没生效（检查 wrangler.toml 的 [triggers] 段）"
