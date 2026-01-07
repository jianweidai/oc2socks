#!/bin/bash
# VPN 连接保活脚本
# 每隔一段时间通过 VPN 隧道发送流量，防止被服务器踢下线

# 保活间隔（秒），默认 60 秒
KEEPALIVE_INTERVAL=${KEEPALIVE_INTERVAL:-60}

# 等待 VPN 连接建立
echo "[keepalive] Waiting for VPN interface to be ready..."
sleep 30

echo "[keepalive] Starting keepalive loop with ${KEEPALIVE_INTERVAL}s interval"

while true; do
    # 检查 VPN 接口是否存在
    if [ -d "/sys/class/net/tunopen" ]; then
        # 方法1: 通过 VPN 接口发送 DNS 查询（轻量级流量）
        # 使用 VPN 分配的 DNS 或 Google DNS
        nslookup google.com > /dev/null 2>&1
        
        # 方法2: 尝试 curl 一个轻量级的页面（如果 nslookup 不可用）
        # curl -s --interface tunopen --max-time 5 https://www.gstatic.com/generate_204 > /dev/null 2>&1
        
        # 方法3: 直接 ping VPN 网关（如果知道内部 IP）
        # ping -c 1 -W 5 -I tunopen <内部网关IP> > /dev/null 2>&1
        
        echo "[keepalive] $(date '+%Y-%m-%d %H:%M:%S') - Heartbeat sent"
    else
        echo "[keepalive] $(date '+%Y-%m-%d %H:%M:%S') - VPN interface not found, skipping..."
    fi
    
    sleep $KEEPALIVE_INTERVAL
done
