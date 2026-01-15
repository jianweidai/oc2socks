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
        # 真实 HTTP 请求：访问 Google 的轻量级 204 页面
        # 这比 DNS 查询更能模拟真实用户流量，有效防止被踢下线
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --interface tunopen --max-time 10 https://www.gstatic.com/generate_204 2>/dev/null)
        
        if [ "$HTTP_CODE" = "204" ]; then
            echo "[keepalive] $(date '+%Y-%m-%d %H:%M:%S') - HTTP heartbeat OK (204)"
        elif [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]; then
            echo "[keepalive] $(date '+%Y-%m-%d %H:%M:%S') - HTTP response: $HTTP_CODE (expected 204)"
        else
            # HTTP 请求失败，回退到 DNS 查询作为备用方案
            echo "[keepalive] $(date '+%Y-%m-%d %H:%M:%S') - HTTP failed, trying DNS fallback..."
            nslookup google.com > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo "[keepalive] $(date '+%Y-%m-%d %H:%M:%S') - DNS heartbeat OK"
            else
                echo "[keepalive] $(date '+%Y-%m-%d %H:%M:%S') - DNS heartbeat failed"
            fi
        fi
    else
        echo "[keepalive] $(date '+%Y-%m-%d %H:%M:%S') - VPN interface not found, skipping..."
    fi
    
    sleep $KEEPALIVE_INTERVAL
done
