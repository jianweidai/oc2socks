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

# 4. 允许向 VPN 服务器发送拨号请求 (通常是 UDP 或 TCP 443)
# 注意：这里我们放行所有的 DNS 和 HTTPS 拨号基础流量，确保护拨号能成功
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT

# 5. 允许所有通过 vpn 网卡 (tunopen) 的流量
iptables -A OUTPUT -o tunopen -j ACCEPT

# 6. 关键：禁止除上述规则外，所有从物理网卡 (eth0) 出去的流量
# 这样如果 VPN 断了，gost 想走物理网卡出去也会被拦截
# 我们不写死 eth0，而是写非 tunopen 的流量
iptables -P OUTPUT DROP
iptables -A OUTPUT -o tunopen -j ACCEPT # 再次确保 tunopen 是通 be 好的 (冗余保险)
# 允许必要的 ICMP 排错
iptables -A OUTPUT -p icmp -j ACCEPT

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
        --script /bin/true \
        --reconnect-timeout 60 \
        ${VPN_SERVER}
    # 手动激活网卡 (因为 --script /bin/true 跳过了自动激活)
    sleep 2
    ip link set tunopen up 2>/dev/null || true
fi

# --- 启动 gost ---
echo "Starting gost on port ${SOCKS_PORT}..."
# 启动 gost
gost -L "socks5://:${SOCKS_PORT}" &
PID_GOST=$!

# 等待进程
wait $PID_ADMIN $PID_GOST