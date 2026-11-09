#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# Simular Box 一键恢复脚本
# 适用环境：已提供 silkd 服务和 cbonline 网卡的 Ubuntu Simular Box
# 上游 HTTP 代理：127.0.0.1:3128
# Tailscale 代理入口：Tailscale_IP:18080
# ==========================================================

TSIP=""
TS_AUTH_KEY=""

log() {
    echo
    echo "=================================================="
    echo "$1"
    echo "=================================================="
}

fail() {
    echo "[错误] $1" >&2
    exit 1
}

# 必须使用 root 执行
if [[ "$(id -u)" -ne 0 ]]; then
    fail "请使用 root 权限执行：sudo -i 后再运行本脚本"
fi

# 检查操作系统
if [[ ! -f /etc/os-release ]]; then
    fail "无法识别操作系统"
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    fail "本脚本目前仅适用于 Ubuntu"
fi

echo "系统版本：${PRETTY_NAME:-未知}"

# 检查 Simular Box 自带代理
log "1. 检查 Simular Box 上游代理"

if ! systemctl list-unit-files silkd.service --no-legend 2>/dev/null | grep -q 'silkd.service'; then
    fail "没有找到 silkd.service；为避免修改非 Simular Box 环境，脚本停止"
fi

systemctl start silkd

for _ in $(seq 1 30); do
    if ss -lnt 2>/dev/null | grep -q '127.0.0.1:3128'; then
        break
    fi
    sleep 1
done

ss -lnt 2>/dev/null | grep -q '127.0.0.1:3128' \
    || fail "silkd 没有监听 127.0.0.1:3128"

echo "[正常] silkd HTTP 代理已经就绪"

# 配置 APT 使用 Simular Box 本机代理
log "2. 配置 APT 本机代理"

mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/80proxy <<'EOF'
Acquire::http::Proxy "http://127.0.0.1:3128";
Acquire::https::Proxy "http://127.0.0.1:3128";
EOF

# 安装必要组件
log "3. 检查并安装基础组件"

export http_proxy="http://127.0.0.1:3128"
export https_proxy="http://127.0.0.1:3128"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="$no_proxy"

for cmd in curl nft systemctl ss; do
    command -v "$cmd" >/dev/null 2>&1 || fail "系统缺少必要命令：$cmd"
done

if ! command -v socat >/dev/null 2>&1; then
    echo "正在通过本机代理安装 socat..."
    apt-get update
    apt-get install -y socat
fi

# 检查并配置 cbonline
log "4. 配置 Simular Box 虚拟网络"

if ! ip link show cbonline >/dev/null 2>&1; then
    fail "没有发现 cbonline 网卡，当前实例网络结构与已验证环境不同"
fi

systemctl enable systemd-networkd
systemctl start systemd-networkd

mkdir -p /etc/systemd/network
NETWORK_FILE="/etc/systemd/network/05-cocoonbox-online.network"

if [[ -f "$NETWORK_FILE" ]]; then
    cp -a "$NETWORK_FILE" "${NETWORK_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi

cat > "$NETWORK_FILE" <<'EOF'
[Match]
Name=cbonline

[Network]
LinkLocalAddressing=ipv6
LLMNR=no

[Address]
Address=169.254.1.1/32
DuplicateAddressDetection=none

[Address]
Address=192.0.2.10/32
DuplicateAddressDetection=none

[Route]
Destination=0.0.0.0/0
Scope=link
Metric=5000
EOF

networkctl reload
networkctl reconfigure cbonline

for _ in $(seq 1 30); do
    if ip -4 -o addr show dev cbonline 2>/dev/null | grep -q '192\.0\.2\.10/32' \
       && ip route show default | grep -q '^default dev cbonline .*metric 5000'; then
        break
    fi
    sleep 1
done

ip -4 -o addr show dev cbonline | grep -q '192\.0\.2\.10/32' \
    || fail "cbonline 辅助地址配置失败"

ip route show default | grep -q '^default dev cbonline .*metric 5000' \
    || fail "cbonline 默认路由配置失败"

echo "[正常] cbonline 地址和默认路由已配置"

# 创建 Tailscale 启动前检查脚本
log "5. 创建 Tailscale 网络等待脚本"

cat > /usr/local/sbin/wait-simular-network.sh <<'EOF'
#!/usr/bin/env bash

# 最多等待 120 秒，直到网络和本地代理准备完成
for _ in $(seq 1 120); do
    if ip -4 -o addr show dev cbonline 2>/dev/null | grep -q '192\.0\.2\.10/32' \
       && ip route show default | grep -q '^default dev cbonline .*metric 5000' \
       && ss -lnt 2>/dev/null | grep -q '127.0.0.1:3128'; then
        echo "网络接口、默认路由和本地代理均已就绪"
        exit 0
    fi
    sleep 1
done

echo "等待网络或本地代理超时" >&2
exit 1
EOF

chmod 0755 /usr/local/sbin/wait-simular-network.sh

# 配置 Tailscale systemd 代理环境和启动依赖
log "6. 配置 Tailscale 启动依赖"

mkdir -p /etc/systemd/system/tailscaled.service.d

cat > /etc/systemd/system/tailscaled.service.d/proxy.conf <<'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:3128"
Environment="HTTPS_PROXY=http://127.0.0.1:3128"
Environment="http_proxy=http://127.0.0.1:3128"
Environment="https_proxy=http://127.0.0.1:3128"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
Environment="no_proxy=localhost,127.0.0.1,::1"
EOF

cat > /etc/systemd/system/tailscaled.service.d/startup.conf <<'EOF'
[Unit]
Requires=systemd-networkd.service silkd.service
After=systemd-networkd.service silkd.service

[Service]
ExecStartPre=/usr/local/sbin/wait-simular-network.sh
EOF

# 安装 Tailscale
log "7. 安装 Tailscale"

if ! command -v tailscale >/dev/null 2>&1; then
    echo "正在通过本机代理下载并安装 Tailscale..."
    curl --proxy http://127.0.0.1:3128 -fsSL https://tailscale.com/install.sh | sh
fi

systemctl daemon-reload
systemctl enable --now tailscaled

# 授权
log "8. Tailscale 节点授权"

echo "可以输入 Tailscale Auth Key 自动授权。"
echo "直接回车则尝试网页登录授权。"
if [[ -r /dev/tty ]]; then
    read -r -s -p "请输入 Auth Key（直接回车跳过）：" TS_AUTH_KEY </dev/tty
    echo
else
    fail "当前没有可交互终端，无法输入 Auth Key；请在终端中运行本脚本"
fi

if [[ -n "$TS_AUTH_KEY" ]]; then
    tailscale up --auth-key="$TS_AUTH_KEY" --accept-dns=false
    unset TS_AUTH_KEY
else
    echo "未提供 Auth Key，启动网页登录授权流程。"
    tailscale up --accept-dns=false || true
    echo "如上方显示登录链接，请在浏览器中打开并完成授权。"
fi

# 等待 Tailscale 获取 IPv4
log "9. 等待 Tailscale 获取 IPv4"

for _ in $(seq 1 120); do
    TSIP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    if [[ "$TSIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
    sleep 2
done

if [[ ! "$TSIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "尚未获取到 Tailscale IPv4。请完成网页登录后重新执行本脚本"
fi

echo "[正常] Tailscale IP：$TSIP"

# 创建代理转发脚本
log "10. 创建代理转发服务"

cat > /usr/local/sbin/simular-proxy-relay.sh <<'EOF'
#!/usr/bin/env bash

# 等待 Tailscale 获取 IPv4 地址
for _ in $(seq 1 120); do
    TSIP="$(tailscale ip -4 2>/dev/null | head -n 1)"
    if [[ "$TSIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
    sleep 2
done

if [[ ! "$TSIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "等待 Tailscale IPv4 超时" >&2
    exit 1
fi

# 等待 Simular Box nftables 规则链创建
for _ in $(seq 1 60); do
    if nft list chain inet cocoonbox input >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! nft list chain inet cocoonbox input >/dev/null 2>&1; then
    echo "找不到 nftables 规则链 inet cocoonbox input" >&2
    exit 1
fi

# 放行 Tailscale 接口访问 18080，避免重复添加
if ! nft list chain inet cocoonbox input | grep -q 'tailscale0.*tcp dport 18080 accept'; then
    nft add rule inet cocoonbox input iifname "tailscale0" tcp dport 18080 accept
fi

echo "Tailscale IP: $TSIP"
echo "HTTP proxy relay: $TSIP:18080 -> 127.0.0.1:3128"

exec /usr/bin/socat TCP-LISTEN:18080,bind="$TSIP",reuseaddr,fork TCP:127.0.0.1:3128
EOF

chmod 0755 /usr/local/sbin/simular-proxy-relay.sh

cat > /etc/systemd/system/simular-proxy-relay.service <<'EOF'
[Unit]
Description=Simular Box Tailscale HTTP Proxy Relay
Wants=tailscaled.service
Requires=silkd.service
After=tailscaled.service silkd.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/simular-proxy-relay.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now simular-proxy-relay.service

# 等待代理端口监听
log "11. 检查代理转发"

for _ in $(seq 1 30); do
    if ss -lnt 2>/dev/null | grep -q "${TSIP}:18080"; then
        break
    fi
    sleep 1
done

ss -lnt 2>/dev/null | grep -q "${TSIP}:18080" \
    || fail "代理转发端口没有成功监听"

# 输出最终状态
log "12. 恢复完成"

echo "Tailscale IP：$TSIP"
echo "HTTP 代理地址：$TSIP:18080"
echo "上游代理地址：127.0.0.1:3128"

echo
echo "===== 服务状态 ====="
systemctl is-active silkd
systemctl is-active tailscaled
systemctl is-active simular-proxy-relay

echo
echo "===== 代理监听 ====="
ss -lntp | grep -E '127.0.0.1:3128|:18080' || true

echo
echo "===== Tailscale 状态 ====="
tailscale status

echo
echo "===== 公网出口检测 ====="
curl --proxy http://127.0.0.1:3128 -fsS --max-time 20 https://api.ipify.org || \
    echo "[提示] 出口检测失败，请稍后单独检查"

echo
echo "=================================================="
echo "Simular Box 代理节点恢复完成"
echo "代理入口：$TSIP:18080"
echo "=================================================="
