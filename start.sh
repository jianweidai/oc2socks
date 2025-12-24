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
# 启动 gost 时强制指定出口网卡为 tunopen，防止流量从 VPS 物理网卡泄露
gost -L "socks5://:${SOCKS_PORT}?interface=tunopen" &
PID_GOST=$!

# 等待进程
wait $PID_ADMIN $PID_GOST