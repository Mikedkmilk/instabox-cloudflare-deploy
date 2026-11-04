#!/usr/bin/env bash
# InstaBox 机器端 · 安装并启动 Cloudflare Tunnel 连接器
#
# 用法：
#   bash setup-tunnel.sh <TUNNEL_TOKEN>
#
# 面板路径：Zero Trust → Networks → Tunnels → 你的隧道 → Configure
#   页面会给一条 `cloudflared service install <TOKEN>` 命令，
#   TOKEN 从那里复制（等价于服务器密码，别公开）。
#
# 装完之后还必须在面板绑 Public Hostname：
#   Subdomain=<子域>  Domain=<主域名>  Path=留空
#   Service Type=HTTP   URL=localhost:<端口>
# ⚠️ Service Type 选 HTTPS 会 502 —— next start 是明文 HTTP。
set -euo pipefail

TOKEN="${1:-}"
BIN=/usr/local/bin/cloudflared
SERVICE=/etc/systemd/system/cloudflared.service

if [ -z "$TOKEN" ]; then
  echo "用法: $0 <TUNNEL_TOKEN>"
  echo "  TOKEN 从 Cloudflare Zero Trust → Networks → Tunnels → Configure 复制"
  exit 1
fi

echo "=========================================="
echo " Cloudflare Tunnel 连接器安装"
echo "=========================================="

# ---------------------------------------------------------------- 1. 下载
echo "== 1/4 下载 cloudflared =="
if [ ! -x "$BIN" ]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ASSET="cloudflared-linux-amd64" ;;
    aarch64|arm64) ASSET="cloudflared-linux-arm64" ;;
    *) echo "不支持的架构: $ARCH"; exit 1 ;;
  esac
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/$ASSET" -o "$BIN"
  chmod +x "$BIN"
  echo "   ✓ 已安装 $("$BIN" --version 2>&1 | head -1)"
else
  echo "   ✓ 已存在 $("$BIN" --version 2>&1 | head -1)"
fi

# ---------------------------------------------------------------- 2. systemd 服务
echo "== 2/4 配置 systemd 服务 =="
# 服务文件含连接令牌，权限收紧
cat > "$SERVICE" <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN service install $TOKEN
Restart=always
RestartSec=5
LimitNOFILE=49152

[Install]
WantedBy=multi-user.target
EOF

chmod 600 "$SERVICE"
chown root:root "$SERVICE"
systemctl daemon-reload
systemctl enable cloudflared > /dev/null 2>&1
echo "   ✓ 服务已写入（权限 600，root）"

# ---------------------------------------------------------------- 3. 启动
echo "== 3/4 启动服务 =="
systemctl restart cloudflared
sleep 6
systemctl is-active cloudflared > /dev/null 2>&1 && echo "   ✓ active" || {
  echo "   ✗ 服务未起来，日志："
  journalctl -u cloudflared -n 30 --no-pager
  exit 1
}
systemctl is-enabled cloudflared > /dev/null 2>&1 && echo "   ✓ 已设为开机自启"

# ---------------------------------------------------------------- 4. 验证
echo "== 4/4 验证 =="
echo "   --- 隧道连接（应有若干条 QUIC）---"
journalctl -u cloudflared -n 60 --no-pager | grep -iE "registered tunnel connection|connection.*registered" | tail -5 || true
echo ""
echo "   --- 最近配置 ---"
journalctl -u cloudflared -n 60 --no-pager | grep -i "Updated to new configuration" | tail -2 || true
echo ""
echo "   --- 应用本地自检 ---"
PORT="${PORT:-3000}"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/" || echo 000)
echo "   http://127.0.0.1:$PORT/ -> $CODE"

echo ""
echo "==========================================="
echo "✅ 连接器已就绪"
echo "==========================================="
echo "   状态   : systemctl status cloudflared"
echo "   日志   : journalctl -u cloudflared -f"
echo ""
echo "   ⚠ 下一步必须在【面板】完成（脚本做不到）："
echo "     Public Hostname → Subdomain=<子域> Domain=<主域名>"
echo "     Service Type=HTTP  URL=localhost:$PORT"
echo "==========================================="
