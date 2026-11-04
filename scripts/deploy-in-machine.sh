#!/usr/bin/env bash
# InstaBox 机器端 · 应用安装脚本
#
# 在 InstaBox 机器（Debian 13, /data 持久盘）上执行。
# 由 deploy.ps1 / deploy.sh 推送后调用，也可手动执行：
#   bash /data/home/deploy-in-machine.sh
#
# ⚠️ .env 处理：若机器上已存在 .env，本脚本【保留不覆盖】（见第 4 步），
#    线上配置不会被冲掉；需要重建时请先备份并删除：
#      cp /data/home/<app>/.env /data/home/<app>/.env.keep && rm /data/home/<app>/.env
#
# 环境变量（可选，均有默认值）：
#   APP_DIR        应用目录，默认 /data/home/<app>
#   PORT           监听端口，默认 3000
#   SITE_URL       对外地址，用于 sitemap/robots 的绝对 URL
#   APP_NAME       应用名（用于日志），默认 web-app
set -euo pipefail

APP_NAME="${APP_NAME:-web-app}"
APP_DIR="${APP_DIR:-/data/home/$APP_NAME}"
DATA_DIR="${DATA_DIR:-/data/home/$APP_NAME-data}"
PORT="${PORT:-3000}"
SITE_URL="${SITE_URL:-}"
AMAP_WEB_KEY="${AMAP_WEB_KEY:-}"
WECOM_WEBHOOK_URL="${WECOM_WEBHOOK_URL:-}"

echo "=========================================="
echo " $APP_NAME · InstaBox 部署"
echo "=========================================="

# ---------------------------------------------------------------- 1. Node 版本
echo "== 1/7 Node 版本 =="
NODE_MAJOR=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 || echo 0)
NODE_MINOR=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f2 || echo 0)
if [ "$NODE_MAJOR" -lt 22 ] || { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -lt 5 ]; }; then
  echo "   ⚠ Node $(node -v 2>&1) 过低（node:sqlite 需 >=22.5），安装 Node 22…"
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - > /dev/null 2>&1
  sudo apt-get install -y -qq nodejs > /dev/null 2>&1
  hash -r
  echo "   已安装: $(node -v)"
else
  echo "   ✓ Node $(node -v) 满足要求（node:sqlite 需 >=22.5）"
fi

# ---------------------------------------------------------------- 2. 目录
echo "== 2/7 目录 =="
mkdir -p "$APP_DIR" "$DATA_DIR"
cd "$APP_DIR"
echo "   APP_DIR=$APP_DIR"
echo "   DATA_DIR=$DATA_DIR"

# ---------------------------------------------------------------- 3. 依赖
echo "== 3/7 安装依赖 =="
if [ -f package.json ]; then
  npm ci --omit=dev --silent 2>&1 | tail -3 || npm install --omit=dev --silent 2>&1 | tail -3
  echo "   ✓ 依赖安装完成 ($(du -sh node_modules 2>/dev/null | cut -f1))"
else
  echo "   ⚠ 未找到 package.json，跳过（代码尚未上传？）"
  exit 1
fi

# ---------------------------------------------------------------- 4. 环境变量
echo "== 4/7 环境变量 =="
if [ -f "$APP_DIR/.env" ]; then
  echo "   ⚠ .env 已存在，保留不覆盖（如需重建请先删除）"
else
  cat > "$APP_DIR/.env" <<EOF
NODE_ENV=production
PORT=$PORT
SITE_URL=$SITE_URL
IMG_WEBP_DIR=$DATA_DIR/imgs-webp
IMG_DIR=$DATA_DIR/imgs
AMAP_WEB_KEY=$AMAP_WEB_KEY
WECOM_WEBHOOK_URL=$WECOM_WEBHOOK_URL
EOF
  chmod 600 "$APP_DIR/.env"
  echo "   ✓ .env 已写入（权限 600）"
fi

# ---------------------------------------------------------------- 5. 构建
echo "== 5/7 构建 =="
# ⚠️ 必须先停掉正在跑的 next start，否则并发构建会损坏 .next（整站 500）
if command -v pm2 > /dev/null 2>&1; then
  pm2 stop "$APP_NAME" > /dev/null 2>&1 || true
fi
# 跨大版本升级时清掉旧产物
rm -rf .next

BUILD_OK=0
if npm run build > /tmp/build.log 2>&1; then
  BUILD_OK=1
  echo "   ✓ 构建完成"
else
  echo "   ✗ 构建失败，日志末尾 40 行："
  tail -40 /tmp/build.log
fi
if [ "$BUILD_OK" -ne 1 ]; then
  echo "   ⚠ 尝试用旧进程恢复服务"
  if command -v pm2 > /dev/null 2>&1; then
    pm2 delete "$APP_NAME" > /dev/null 2>&1 || true
    PORT="$PORT" pm2 start npm --name "$APP_NAME" -- start > /dev/null 2>&1 || true
  fi
  exit 1
fi

# ---------------------------------------------------------------- 6. 启动
echo "== 6/7 启动（pm2 守护）=="
if ! command -v pm2 > /dev/null 2>&1; then
  npm i -g pm2 --silent
fi
echo "   pm2 $(pm2 -v 2>&1 | tail -1)"

pm2 delete "$APP_NAME" > /dev/null 2>&1 || true
PORT="$PORT" pm2 start npm --name "$APP_NAME" -- start > /dev/null 2>&1
pm2 save > /dev/null 2>&1 || true

# ---------------------------------------------------------------- 7. 自检
echo "== 7/7 自检 =="
sleep 6
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/" || echo 000)
echo "   首页 HTTP $CODE"

# 抽查几个路由
for u in /projects /map /top /sitemap.xml /robots.txt; do
  C=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT$u" || echo 000)
  echo "   $u -> $C"
done

echo ""
echo "--- pm2 ---"
pm2 status --no-color 2>/dev/null | head -12
echo "--- 磁盘 ---"
df -h /data 2>/dev/null | tail -1
echo "--- 磁盘/目录占用 ---"
du -sh "$APP_DIR" "$DATA_DIR" 2>/dev/null

if [ "$CODE" != "200" ]; then
  echo ""
  echo "   ⚠ 首页未返回 200，pm2 日志末尾："
  pm2 logs "$APP_NAME" --lines 30 --nostream 2>&1 | tail -30
  exit 1
fi

echo ""
echo "==========================================="
echo "✅ 部署完成"
echo "==========================================="
echo "   应用目录 : $APP_DIR"
echo "   数据目录 : $DATA_DIR"
echo "   监听端口 : $PORT"
echo ""
echo "   进程状态 : instabox exec <box> -- pm2 status"
echo "   实时日志 : instabox exec <box> -- pm2 logs $APP_NAME"
echo "   磁盘占用 : instabox exec <box> -- df -h /data"
echo "==========================================="
