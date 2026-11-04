#!/usr/bin/env bash
# 本机编排：把代码部署到 InstaBox 机器（Linux / macOS）
#
# 用法：
#   export INSTABOX_API_KEY='ibk_...'
#   bash deploy.sh --machine web-app --repo /path/to/repo [--port 3000] [--site-url https://...]
set -euo pipefail

MACHINE=""
REPO=""
APP_NAME="web-app"
PORT=3000
SITE_URL=""
STAGE=""
SKIP_BUILD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --machine)    MACHINE="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --app-name)  APP_NAME="$2"; shift 2 ;;
    --port)      PORT="$2"; shift 2 ;;
    --site-url)  SITE_URL="$2"; shift 2 ;;
    --stage)     STAGE="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

[ -n "$MACHINE" ] || { echo "缺少 --machine" >&2; exit 1; }
[ -n "$REPO" ]    || { echo "缺少 --repo" >&2; exit 1; }
[ -n "${INSTABOX_API_KEY:-}" ] || { echo "未设置 INSTABOX_API_KEY" >&2; exit 1; }
[ -n "$STAGE" ] || STAGE="${TMPDIR:-/tmp}/instabox-deploy-$APP_NAME"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

step() { printf '\n\033[36m>> %s\033[0m\n' "$1"; }
ok()   { printf '   \033[32m[OK] %s\033[0m\n' "$1"; }
die()  { printf '   \033[31m[FAIL] %s\033[0m\n' "$1"; exit 1; }

# ================================================================ 1. 预检
step "1/4 预检"
raw="$(npx --yes instabox@latest ls --json 2>&1)" || die "CLI 调用失败：$raw"
machine_id="$(printf '%s' "$raw" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const a=JSON.parse(s); const m=a.find(x=>x.name===process.argv[1]);
  if(!m){process.exit(1)} console.log(m.id);
});' "$MACHINE")" || die "找不到机器 '$MACHINE'"
state="$(printf '%s' "$raw" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const a=JSON.parse(s); const m=a.find(x=>x.name===process.argv[1]);
  console.log(m?m.state:"?");
});' "$MACHINE")"
ok "机器 $MACHINE [$machine_id] 状态=$state"

if [ "$state" != "running" ]; then
  echo "   机器非 running，尝试启动…" >&2
  npx --yes instabox@latest start "$MACHINE" > /dev/null || true
  sleep 20
fi

# ================================================================ 2. 打包
step "2/4 打包代码"
mkdir -p "$STAGE"
find "$STAGE" -type f -delete 2>/dev/null || true
( cd "$REPO" && tar -cf - \
    --exclude=./node_modules --exclude=./.git --exclude=./.next \
    --exclude=./data --exclude=./logs --exclude=./backups \
    --exclude=./.env --exclude='*.key' \
    . ) | ( cd "$STAGE" && tar -xf - )
count="$(find "$STAGE" -type f | wc -l | tr -d ' ')"
ok "$count 个文件已暂存 -> $STAGE"

# ================================================================ 3. 推送 + 安装
step "3/4 推送并安装"
npx --yes instabox@latest push "$MACHINE" "$STAGE/" "/data/home/$APP_NAME" --all || die "代码推送失败"
ok "代码已到位"

npx --yes instabox@latest push "$MACHINE" "$SCRIPT_DIR/deploy-in-machine.sh" "/data/home/deploy-in-machine.sh" || die "安装脚本推送失败"
ok "安装脚本已到位"

remote="chmod +x /data/home/deploy-in-machine.sh && APP_NAME='$APP_NAME' PORT=$PORT SITE_URL='$SITE_URL' bash /data/home/deploy-in-machine.sh"
# ⚠️ exec 的 --timeout 上限是 600 秒
npx --yes instabox@latest exec "$MACHINE" --timeout 600 -- bash -lc "$remote" || die "机器端安装失败"

# ================================================================ 4. 收尾
step "4/4 收尾自检"
code="$(npx --yes instabox@latest exec "$MACHINE" -- bash -lc "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/")"
[ "$code" = "200" ] && ok "首页返回 200" || die "首页未返回 200（得到 $code）"

printf '\n\033[32m===========================================\n✅ 部署完成 —— 下一步\n===========================================\033[0m\n'
echo "  1) 绑定 Cloudflare Tunnel（Service Type 必须 HTTP）"
echo "     详见 references/cloudflare-tunnel.md"
echo "  2) 配置 Worker 保活（cron */3，TTL 900）"
echo "     bash $SCRIPT_DIR/keepalive/deploy-keepalive.sh --machine $MACHINE --machine-id $machine_id"
echo "  3) 端到端验证"
echo "     bash $SCRIPT_DIR/verify-site.sh --machine $MACHINE --domain <你的子域名>"
