#!/bin/bash
# Custom vpnc-script for oc2socks
# This script configures the VPN interface without modifying the default route
# Only traffic routed through SOCKS5 proxy will go through VPN

set -e

# Log function
log() {
    echo "[vpnc-script] $1"
}

log "reason: $reason"

case "$reason" in
    pre-init)
        # Called before the tunnel device is opened
        log "Pre-init phase"
        ;;
        
    connect)
        # Called after the tunnel is established
        log "Connect phase - configuring interface $TUNDEV"
        
        # Bring up the interface
        ip link set "$TUNDEV" up
        log "Interface $TUNDEV is UP"
        
        # Configure IPv4 address if provided
        if [ -n "$INTERNAL_IP4_ADDRESS" ]; then
            # Calculate netmask (default to /32 if not provided)
            if [ -n "$INTERNAL_IP4_NETMASK" ]; then
                # Convert netmask to CIDR
                CIDR=$(echo "$INTERNAL_IP4_NETMASK" | awk -F. '{
                    split($0,a,".");
                    for(i=1;i<=4;i++){
                        c+=sprintf("%08d", int(a[i]));
                    }
                    gsub(/0/, "", c);
                    print length(c)
                }')
            else
                CIDR=32
            fi
            
            ip addr add "$INTERNAL_IP4_ADDRESS/$CIDR" dev "$TUNDEV"
            log "Configured IPv4: $INTERNAL_IP4_ADDRESS/$CIDR"
        fi
        
        # Configure IPv6 address if provided
        if [ -n "$INTERNAL_IP6_ADDRESS" ]; then
            CIDR6="${INTERNAL_IP6_NETMASK:-128}"
            ip -6 addr add "$INTERNAL_IP6_ADDRESS/$CIDR6" dev "$TUNDEV"
            log "Configured IPv6: $INTERNAL_IP6_ADDRESS/$CIDR6"
        fi
        
        # Add routes for VPN network
        # DO NOT set default route - we want split tunneling
        
        # Route the VPN internal network through the tunnel
        if [ -n "$INTERNAL_IP4_ADDRESS" ] && [ -n "$INTERNAL_IP4_NETMASK" ]; then
            # Get the network address
            IFS='.' read -r i1 i2 i3 i4 <<< "$INTERNAL_IP4_ADDRESS"
            IFS='.' read -r m1 m2 m3 m4 <<< "$INTERNAL_IP4_NETMASK"
            NETWORK="$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).$((i4 & m4))"
            
            # Add route for the VPN network
            ip route add "$NETWORK/$CIDR" dev "$TUNDEV" 2>/dev/null || true
            log "Added route for network: $NETWORK/$CIDR"
        fi
        
        # Add split tunnel routes if provided by the server
        if [ -n "$CISCO_SPLIT_INC" ]; then
            i=0
            while [ $i -lt "$CISCO_SPLIT_INC" ]; do
                eval NETWORK="\$CISCO_SPLIT_INC_${i}_ADDR"
                eval NETMASK="\$CISCO_SPLIT_INC_${i}_MASK"
                eval MASKLEN="\$CISCO_SPLIT_INC_${i}_MASKLEN"
                
                if [ -n "$NETWORK" ] && [ -n "$MASKLEN" ]; then
                    ip route add "$NETWORK/$MASKLEN" dev "$TUNDEV" 2>/dev/null || true
                    log "Added split route: $NETWORK/$MASKLEN"
                fi
                i=$((i + 1))
            done
        fi
        
        # CRITICAL: Add default route for all traffic through VPN interface
        # This makes gost able to route any destination through VPN
        # We use a lower metric so it doesn't override the physical interface's default route
        # for the container itself, but gost binds to tunopen so it will use this
        ip route add default dev "$TUNDEV" metric 100 2>/dev/null || true
        log "Added default route via $TUNDEV with metric 100"
        
        # Configure MTU if provided
        if [ -n "$INTERNAL_IP4_MTU" ]; then
            ip link set "$TUNDEV" mtu "$INTERNAL_IP4_MTU"
            log "Set MTU to $INTERNAL_IP4_MTU"
        fi
        
        log "VPN interface configuration complete"
        ;;
        
    disconnect)
        # Called before the tunnel is torn down
        log "Disconnect phase - cleaning up"
        
        # Remove routes (they will be removed automatically when interface goes down)
        # Just bring down the interface
        ip link set "$TUNDEV" down 2>/dev/null || true
        log "Interface $TUNDEV is DOWN"
        ;;
        
    reconnect)
        # Called when reconnecting
        log "Reconnect phase"
        # Re-run connect logic
        exec "$0" connect
        ;;
        
    *)
        log "Unknown reason: $reason"
        ;;
esac

exit 0

