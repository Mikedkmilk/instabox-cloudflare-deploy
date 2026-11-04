# Cloudflare Tunnel：把服务绑到自有域名

## 原理

```
访客 → https://<子域>.<主域名>
     → Cloudflare 边缘节点（自动签发证书、免费）
     → 加密隧道（QUIC，机器主动外连，无需公网 IP / 备案）
     → 机器内 cloudflared
     → http://127.0.0.1:<端口>
     → 你的应用（pm2 守护）
```

机器**主动向外**建立隧道，所以：
- 不需要公网 IP、不需要开放入站端口、不需要备案
- 机器在 NAT 后面也能用

---

## 为什么不能用 DNS CNAME 直连 InstaBox

实测三条都堵死：

| 尝试 | 结果 |
|---|---|
| CNAME 到 `<box>.instabox.tech` | 网关按 Host 头路由 → 自定义 Host 返回 **404** |
| 走 80 端口 | **超时**，不通 |
| 证书 | SAN 仅 `*.instabox.tech`，不覆盖自有域名 |

对照实验（同一台机器、同一端口）：

```
SNI=instabox   Host=自定义域名   → 404
SNI=instabox   Host=instabox     → 200
```

**结论：走 Tunnel，别走 CNAME。**

---

## 面板操作全流程

### 1. 确认主域名 NS 已托管到 Cloudflare

```bash
nslookup -type=NS <主域名>
```

返回的 NS 含 `*.ns.cloudflare.com` 才继续。没有的话先去注册商改 NS。

### 2. 创建隧道

Zero Trust → Networks → Tunnels → Create a tunnel → 类型选 **Cloudflared** → 命名（如 `app-web`）。

### 3. 装连接器（在 InstaBox 机器上执行）

面板会给一条安装命令，形如：

```bash
cloudflared service install <TOKEN>
```

在机器上执行（`scripts/setup-tunnel.sh` 已封装）：

```bash
# 脚本方式
instabox push <机器名> ./setup-tunnel.sh /data/home/setup-tunnel.sh
instabox exec <机器名> -- bash -lc 'chmod +x /data/home/setup-tunnel.sh && bash /data/home/setup-tunnel.sh <TOKEN>'
```

手动等价操作：

```bash
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

cat > /etc/systemd/system/cloudflared.service << 'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared service install <TOKEN>
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflared
```

> 服务文件含连接令牌，权限收紧到 `-rw------- root`。
> 用 `service install` 时令牌会直接进 ExecStart，这是官方推荐方式。

### 4. 绑定 Public Hostname（关键一步）

Tunnel → Configure → Public Hostnames → Add a public hostname：

| 字段 | 填什么 |
|---|---|
| Subdomain | `app`（你要的二级名） |
| Domain | 下拉选你的主域名 |
| Path | **留空** |
| Service Type | **`HTTP`** |
| URL | `localhost:3000` |

### 5. 验证

```bash
# 机器内
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/

# 隧道状态：应看到若干条 QUIC 连接
systemctl status cloudflared
journalctl -u cloudflared -n 30 | grep -i -E "registered|connection"

# 公网
curl -s -o /dev/null -w "%{http_code}\n" https://app.example.com/
```

看隧道连了几个边缘节点（`Registered tunnel connection` 的 connIndex 有几条）。

---

## ⚠️ 三个必踩的坑

### 坑 1：Service Type 选 HTTPS → 502

错误日志：

```
Updated to new configuration config="{"ingress":[{"hostname":"app.example.com","service":"https://localhost:3000"}...]}" version=2
X [ERROR] tls: first record does not look like a TLS handshake
```

原因：`next start` 是**明文 HTTP**，Tunnel 按 TLS 客户端去握手必然失败。

**判定规则**：

| 应用 | Service Type | URL |
|---|---|---|
| `next start` / `node server.js` / Express | **HTTP** | `localhost:<port>` |
| 前面有 Nginx + certbot | HTTPS | `https://127.0.0.1:<port>` |

### 坑 2：只建隧道不绑 hostname → 访问不通

绑完 Public Hostname 之前，隧道连接器虽已连上 Cloudflare，但没有任何入口指向它。
面板上必须看到 hostname 记录才生效。

### 坑 3：改了 hostname 配置但没生效

看 `journalctl -u cloudflared`，会打印 `Updated to new configuration ... version=N`。
`version` 不变说明面板改动没下发到连接器。

---

## 与保活的关系

Tunnel 是**长连接**（QUIC），机器挂起时连接断开 → 网站 502。
所以**保活和 Tunnel 必须配套**：Worker 续租让机器不挂起，Tunnel 才能一直在线。

| 组件 | 作用 | 挂起后 |
|---|---|---|
| activity lease（Worker cron） | 防「空闲挂起」 | 失效（lease 到期） |
| cloudflared | 承载流量 | 断开 → 502 |
| 两者配合 | 24 小时在线 | ✓ |

⚠️ 但 **8 小时上限**导致的是「强制暂停 + 冷却期」，此时 Tunnel 必断，Worker 只能在冷却结束后
把机器拉起（`*/3` 的 cron 意味着最长再等 3 分钟）。这段空窗保活解决不了。

---

## 端口策略

InstaBox 直连端口**保持私有**：

```bash
instabox port publish <机器名> 3000 --private
```

Tunnel 走的是机器**内部**的 3000 端口，不经 InstaBox 网关，所以转私有不影响访问。
对外只有 Cloudflare Tunnel 一个入口。

---

## 常见问题

**Q: 域名解析到哪？**
绑好后 `nslookup <子域>.<主域>` 应返回 Cloudflare Anycast IP（`104.x` / `172.64.x` / `103.x`）。

**Q: 证书从哪来？**
Cloudflare 边缘自动签发 + 自动续期，不需要 certbot，不需要在源站装证书。

**Q: 访问慢？**
Cloudflare 免费版**没有中国内地节点**，大陆访客会绕到香港/日本/海外。
实测 colo 可以这样确认访客接入点：

```bash
curl -s https://<子域>.<主域>/cdn-cgi/trace | grep -E '^(ip|loc|colo)='
```

**Q: 回源报 502 但机器内 curl 正常？**
99% 是 Service Type 选成了 HTTPS。见坑 1。

**Q: 要不要绑主域名？**
不要。只加这一条二级域名记录，**主域名 NS 和其他已有记录一律不动**。
