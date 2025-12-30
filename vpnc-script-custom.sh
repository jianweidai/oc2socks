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
        
        # Function to convert netmask to CIDR
        netmask_to_cidr() {
            local mask=$1
            local cidr=0
            local IFS='.'
            read -r o1 o2 o3 o4 <<< "$mask"
            for octet in $o1 $o2 $o3 $o4; do
                case $octet in
                    255) cidr=$((cidr + 8));;
                    254) cidr=$((cidr + 7));;
                    252) cidr=$((cidr + 6));;
                    248) cidr=$((cidr + 5));;
                    240) cidr=$((cidr + 4));;
                    224) cidr=$((cidr + 3));;
                    192) cidr=$((cidr + 2));;
                    128) cidr=$((cidr + 1));;
                    0) ;;
                    *) log "Warning: Invalid netmask octet: $octet";;
                esac
            done
            echo $cidr
        }
        
        # Configure IPv4 address if provided
        if [ -n "$INTERNAL_IP4_ADDRESS" ]; then
            # Calculate netmask (default to /32 if not provided)
            if [ -n "$INTERNAL_IP4_NETMASK" ]; then
                CIDR=$(netmask_to_cidr "$INTERNAL_IP4_NETMASK")
                log "Netmask $INTERNAL_IP4_NETMASK -> CIDR /$CIDR"
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
        
        # Log all environment variables for debugging
        log "INTERNAL_IP4_ADDRESS=$INTERNAL_IP4_ADDRESS"
        log "INTERNAL_IP4_NETMASK=$INTERNAL_IP4_NETMASK"
        log "INTERNAL_IP4_NETMASKLEN=$INTERNAL_IP4_NETMASKLEN"
        log "INTERNAL_IP4_DNS=$INTERNAL_IP4_DNS"
        log "VPNGATEWAY=$VPNGATEWAY"
        log "CISCO_SPLIT_INC=$CISCO_SPLIT_INC"
        
        # Add routes for VPN network
        # Route the VPN internal network through the tunnel
        if [ -n "$INTERNAL_IP4_ADDRESS" ] && [ -n "$INTERNAL_IP4_NETMASK" ]; then
            # Calculate CIDR for route (use the same function)
            ROUTE_CIDR=$(netmask_to_cidr "$INTERNAL_IP4_NETMASK")
            
            # Get the network address
            IFS='.' read -r i1 i2 i3 i4 <<< "$INTERNAL_IP4_ADDRESS"
            IFS='.' read -r m1 m2 m3 m4 <<< "$INTERNAL_IP4_NETMASK"
            NETWORK="$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).$((i4 & m4))"
            
            # Add route for the VPN network
            ip route add "$NETWORK/$ROUTE_CIDR" dev "$TUNDEV" 2>/dev/null || true
            log "Added route for VPN network: $NETWORK/$ROUTE_CIDR"
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
        
        # CRITICAL: Replace default route to force all traffic through VPN interface
        # This makes gost able to route any destination through VPN
        
        # Step 1: Save the original gateway for VPN server access
        ORIGINAL_GW=$(ip route show default | grep -v tunopen | awk '{print $3}' | head -n1)
        ORIGINAL_DEV=$(ip route show default | grep -v tunopen | awk '{print $5}' | head -n1)
        log "Original gateway: $ORIGINAL_GW via $ORIGINAL_DEV"
        
        # Step 2: Add explicit route to VPN server through original gateway
        # This ensures VPN tunnel traffic itself can still reach the VPN server
        if [ -n "$VPNGATEWAY" ] && [ -n "$ORIGINAL_GW" ]; then
            ip route add "$VPNGATEWAY/32" via "$ORIGINAL_GW" dev "$ORIGINAL_DEV" 2>/dev/null || true
            log "Added explicit route: $VPNGATEWAY via $ORIGINAL_GW"
        fi
        
        # Step 3: Preserve Docker bridge network route for admin server (port 8989)
        # Without this, the container cannot respond to requests from the host
        if [ -n "$ORIGINAL_DEV" ]; then
            # Get the Docker network CIDR from the eth0 interface
            DOCKER_NET=$(ip addr show "$ORIGINAL_DEV" 2>/dev/null | grep 'inet ' | awk '{print $2}')
            if [ -n "$DOCKER_NET" ]; then
                # Extract network address (e.g., 172.18.0.6/16 -> we need to route 172.18.0.0/16)
                # Add explicit route for the Docker bridge network
                ip route add "${DOCKER_NET%.*}.0/16" dev "$ORIGINAL_DEV" 2>/dev/null || true
                log "Preserved Docker network route: ${DOCKER_NET%.*}.0/16 via $ORIGINAL_DEV"
            fi
        fi
        
        # Step 4: Delete old default route(s) through physical interface
        # This is the key fix - remove competing routes
        ip route del default via "$ORIGINAL_GW" 2>/dev/null || true
        log "Deleted original default route via $ORIGINAL_GW"
        
        # Step 5: Add new default route through VPN tunnel
        ip route add default dev "$TUNDEV" 2>/dev/null || true
        log "Added default route via $TUNDEV (VPN tunnel)"
        
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

