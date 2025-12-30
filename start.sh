#!/bin/bash

# --- 配置 ---
# 从环境变量获取VPN凭据和服务器信息
VPN_SERVER=${VPN_SERVER:?"VPN_SERVER 环境变量未设置"}
# VPN_PASSWORD 不再是强制必填，可以后续通过 Web 注入
VPN_PASSWORD=${VPN_PASSWORD:-""}

VPN_USER_AGENT=${VPN_USER_AGENT:-"AnyConnect Linux_64 4.7.00136"}
VPN_VERSION_STRING=${VPN_VERSION_STRING:-"4.7.00136"}
VPN_PROTOCOL=${VPN_PROTOCOL:-"anyconnect"} # 默认为 anyconnect, 可以是 gp, pulse 等

SOCKS_PORT=${SOCKS_PORT:-"1180"}

# --- 解析 VPN 服务器 IP 地址 ---
# 在设置防火墙规则前，先解析 VPN 服务器的 IP，这样我们可以精确放行
echo "Resolving VPN server IP address..."
VPN_SERVER_IP=$(getent hosts "${VPN_SERVER}" | awk '{print $1}' | head -n1)
if [ -z "$VPN_SERVER_IP" ]; then
    echo "Warning: Could not resolve VPN server IP, falling back to allowing all 443 traffic for dial-up"
    VPN_SERVER_IP=""
fi
echo "VPN Server: ${VPN_SERVER} -> IP: ${VPN_SERVER_IP:-'(unresolved)'}"

# --- 安全：防止流量从 VPS 物理网卡泄露 ---
echo "Configuring firewall rules for safety..."

# 1. 允许所有的回环流量 (Loopback)
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# 2. 允许管理后台端口 (8989) 的流量，确保我们能访问网页
iptables -A OUTPUT -p tcp --sport 8989 -j ACCEPT
iptables -A INPUT -p tcp --dport 8989 -j ACCEPT

# 3. 允许已经建立的连接 (Established/Related)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 4. 允许向 VPN 服务器发送拨号请求
# 关键修改：只允许向 VPN 服务器 IP 的 443 端口发起连接，而不是所有 443 流量
# 这样可以防止 gost 在 VPN 未连接时通过物理网卡泄露流量
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
if [ -n "$VPN_SERVER_IP" ]; then
    # 只允许到 VPN 服务器的 443 端口流量
    iptables -A OUTPUT -p tcp -d "${VPN_SERVER_IP}" --dport 443 -j ACCEPT
    echo "Firewall: Only allowing 443 traffic to VPN server IP: ${VPN_SERVER_IP}"
else
    # 如果解析失败，回退到允许所有 443（不推荐，但保证拨号能成功）
    iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
    echo "Warning: Allowing all 443 traffic (VPN IP resolution failed)"
fi

# 5. 允许所有通过 VPN 网卡 (tunopen) 的流量
iptables -A OUTPUT -o tunopen -j ACCEPT

# 6. 关键：设置默认策略为 DROP
# 这样如果 VPN 断了，gost 想走物理网卡出去会被拦截
iptables -P OUTPUT DROP

# 允许必要的 ICMP 排错
iptables -A OUTPUT -p icmp -j ACCEPT

echo "Firewall rules configured. VPN tunnel traffic allowed, physical NIC traffic blocked."

# --- 进程管理 ---
# 设置 trap 以在接收到 SIGTERM 或 SIGINT 时优雅地关闭子进程
trap 'kill -TERM $PID_ADMIN $PID_GOST' TERM INT

# --- 启动 Admin Server (后台运行) ---
echo "Starting Admin Server on port 8989..."
python3 /admin_server.py &
PID_ADMIN=$!

# --- 确定使用的 VPN Token ---
# 优先从持久化文件读取，如果没有则使用初始环境变量
TOKEN_FILE="/data/vpn.token"
if [ -f "$TOKEN_FILE" ]; then
    VPN_CURRENT_TOKEN=$(cat "$TOKEN_FILE")
    echo "Using persisted token from $TOKEN_FILE"
else
    VPN_CURRENT_TOKEN="${VPN_PASSWORD}"
    echo "Using initial token from environment variable"
    # 保存初始 token 到文件供后续使用
    mkdir -p /data
    echo "${VPN_PASSWORD}" > "$TOKEN_FILE"
fi

# --- 启动 OpenConnect ---
if [ -z "${VPN_CURRENT_TOKEN}" ]; then
    echo "No initial VPN Token found. Please enter it via Web UI."
else
    echo "Starting OpenConnect..."
    echo "${VPN_CURRENT_TOKEN}" | openconnect -b \
        --protocol=${VPN_PROTOCOL} \
        --cookie-on-stdin \
        --useragent="\"${VPN_USER_AGENT}\"" \
        --version-string="${VPN_VERSION_STRING}" \
        --interface=tunopen \
        --script=/vpnc-script-custom.sh \
        --reconnect-timeout 60 \
        ${VPN_SERVER}
    # Wait for custom script to configure the interface
    sleep 3
    echo "VPN interface configuration complete"
fi

# --- 启动 gost ---
echo "Starting gost on port ${SOCKS_PORT}..."
# 启动 gost
gost -L "socks5://:${SOCKS_PORT}" &
PID_GOST=$!

# 等待进程
wait $PID_ADMIN $PID_GOST