#!/bin/bash

# WireGuard Multi-Client Setup Script
# This script generates keys and configs for multiple WireGuard clients

set -e  # Exit on error

# Configuration
SERVER_PUBLIC_KEY=""
SERVER_PRIVATE_KEY=""
SERVER_ENDPOINT=""
SERVER_PORT=""
VPN_SUBNET=""
DNS_SERVER=""

# Working directory
WORK_DIR="/etc/wireguard/clients"
mkdir -p "$WORK_DIR"

# Simple mapping: VPN IP -> Oracle Private IP -> Public IP
# VPN IPs now match private IPs for easier troubleshooting
declare -a VPN_IPS=()

declare -a PRIVATE_IPS=()

declare -a PUBLIC_IPS=()

# Function to find index by last octet
find_index_by_octet() {
    local octet=$1
    for i in "${!VPN_IPS[@]}"; do
        if [ "${VPN_IPS[$i]}" = "$octet" ]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# Function to generate keys for a client
generate_keys() {
    local client_num=$1
    local vpn_ip=$2
    local private_key_file="$WORK_DIR/client${client_num}_private.key"
    local public_key_file="$WORK_DIR/client${client_num}_public.key"

    echo "Generating keys for Client $client_num (${VPN_SUBNET}.${vpn_ip})..."
    wg genkey | tee "$private_key_file" | wg pubkey > "$public_key_file"
    chmod 600 "$private_key_file"
    chmod 644 "$public_key_file"

    echo "  Private key: $private_key_file"
    echo "  Public key: $public_key_file"
    echo ""
}

# Function to create client config
create_client_config() {
    local client_num=$1
    local vpn_ip=$2
    local private_ip=$3
    local public_ip=$4
    local private_key=$(cat "$WORK_DIR/client${client_num}_private.key")
    local config_file="$WORK_DIR/client${client_num}_${private_ip}.conf"

    cat > "$config_file" <<EOF
# Client $client_num
# VPN IP: ${VPN_SUBNET}.${vpn_ip}
# Will appear from: $public_ip (via private IP $private_ip)

[Interface]
PrivateKey = $private_key
Address = ${VPN_SUBNET}.${vpn_ip}/32
DNS = $DNS_SERVER

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = ${SERVER_ENDPOINT}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    chmod 600 "$config_file"
    echo "Created client config: $config_file"
}

# Function to add/update peer in server config
update_server_peer() {
    local vpn_ip=$1
    local private_ip=$2
    local public_ip=$3
    local public_key=$4
    local server_config="/etc/wireguard/wg0.conf"
    
    # Check if peer already exists
    if grep -q "AllowedIPs = ${VPN_SUBNET}.${vpn_ip}/32" "$server_config" 2>/dev/null; then
        echo "Updating existing peer in server config..."
        # Remove old peer block
        sed -i "/# Client.*$private_ip/,/^$/d" "$server_config"
    else
        echo "Adding new peer to server config..."
    fi
    
    # Add peer at the end
    cat >> "$server_config" <<EOF

# Client - Private IP: $private_ip -> Public IP: $public_ip
[Peer]
PublicKey = $public_key
AllowedIPs = ${VPN_SUBNET}.${vpn_ip}/32
EOF
    
    echo "Server configuration updated"
}

# Function to generate server config
generate_server_config() {
    local server_config="/etc/wireguard/wg0.conf"
    local backup_config="/etc/wireguard/wg0.conf.backup.$(date +%Y%m%d_%H%M%S)"

    # Backup existing config
    if [ -f "$server_config" ]; then
        echo "Backing up existing server config to $backup_config"
        cp "$server_config" "$backup_config"
    fi

    echo "Generating new server configuration..."

    cat > "$server_config" <<EOF
[Interface]
Address = ${VPN_SUBNET}.1/24
ListenPort = $SERVER_PORT
PrivateKey = $SERVER_PRIVATE_KEY
SaveConfig = false

EOF

    # Add each peer
    for i in "${!VPN_IPS[@]}"; do
        local client_num=$((i+1))
        local vpn_ip=${VPN_IPS[$i]}
        local private_ip=${PRIVATE_IPS[$i]}
        local public_ip=${PUBLIC_IPS[$i]}
        local public_key=$(cat "$WORK_DIR/client${client_num}_public.key")

        cat >> "$server_config" <<EOF
# Client $client_num - Private IP: $private_ip -> Public IP: $public_ip
[Peer]
PublicKey = $public_key
AllowedIPs = ${VPN_SUBNET}.${vpn_ip}/32

EOF
    done

    chmod 600 "$server_config"
    echo "Server configuration saved to $server_config"
    echo ""
}

# Function to setup iptables rule for a single client
setup_single_iptable() {
    local vpn_ip=$1
    local private_ip=$2
    local public_ip=$3
    
    echo "Setting up iptables rule for ${VPN_SUBNET}.${vpn_ip} -> $private_ip (Public: $public_ip)..."
    
    # Remove if exists, then add
    iptables -t nat -D POSTROUTING -s ${VPN_SUBNET}.${vpn_ip}/32 -o ens3 -j SNAT --to-source $private_ip 2>/dev/null || true
    iptables -t nat -A POSTROUTING -s ${VPN_SUBNET}.${vpn_ip}/32 -o ens3 -j SNAT --to-source $private_ip
    
    echo "  ${VPN_SUBNET}.${vpn_ip} -> $private_ip (Public: $public_ip)"
    
    # Save iptables rules
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save
        echo "Rules saved with netfilter-persistent"
    elif command -v iptables-save &> /dev/null; then
        iptables-save > /etc/iptables/rules.v4
        echo "Rules saved to /etc/iptables/rules.v4"
    fi
}

# Function to display QR code for a single client
display_single_qr() {
    local client_num=$1
    local vpn_ip=$2
    local private_ip=$3
    local public_ip=$4
    local config_file="$WORK_DIR/client${client_num}_${private_ip}.conf"
    
    if ! command -v qrencode &> /dev/null; then
        echo "qrencode not found. Install with: sudo apt install qrencode"
        echo ""
        echo "Config file location: $config_file"
        return
    fi
    
    echo "========================================="
    echo "Client $client_num - Private IP: $private_ip"
    echo "VPN IP: ${VPN_SUBNET}.${vpn_ip}"
    echo "Public IP: $public_ip"
    echo "========================================="
    qrencode -t ansiutf8 < "$config_file"
    echo ""
    echo "Config file: $config_file"
    echo ""
}

# Function to display QR codes for all clients
generate_qr_codes() {
    echo "========================================="
    echo "QR Codes for Mobile Devices"
    echo "========================================="
    echo ""

    if ! command -v qrencode &> /dev/null; then
        echo "qrencode not found. Install with: sudo apt install qrencode"
        echo ""
        return
    fi

    for i in "${!VPN_IPS[@]}"; do
        local client_num=$((i+1))
        local vpn_ip=${VPN_IPS[$i]}
        local private_ip=${PRIVATE_IPS[$i]}
        local public_ip=${PUBLIC_IPS[$i]}
        
        display_single_qr "$client_num" "$vpn_ip" "$private_ip" "$public_ip"
        
        if [ $i -lt $((${#VPN_IPS[@]} - 1)) ]; then
            read -p "Press Enter to continue to next QR code..."
            echo ""
        fi
    done
}

# Function to setup iptables rules for all clients
setup_iptables() {
    echo "========================================="
    echo "Setting up iptables rules"
    echo "========================================="
    echo ""

    # Allow WireGuard port
    echo "Allowing WireGuard port $SERVER_PORT..."
    iptables -C INPUT -p udp --dport $SERVER_PORT -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 5 -p udp --dport $SERVER_PORT -j ACCEPT

    # Allow forwarding
    echo "Setting up FORWARD rules..."
    iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -i wg0 -j ACCEPT
    iptables -C FORWARD -o wg0 -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 2 -o wg0 -j ACCEPT

    # Setup SNAT rules
    echo "Setting up SNAT rules for each client..."
    for i in "${!VPN_IPS[@]}"; do
        local client_num=$((i+1))
        local vpn_ip=${VPN_IPS[$i]}
        local private_ip=${PRIVATE_IPS[$i]}
        local public_ip=${PUBLIC_IPS[$i]}

        # Remove if exists, then add
        iptables -t nat -D POSTROUTING -s ${VPN_SUBNET}.${vpn_ip}/32 -o ens3 -j SNAT --to-source $private_ip 2>/dev/null || true
        iptables -t nat -A POSTROUTING -s ${VPN_SUBNET}.${vpn_ip}/32 -o ens3 -j SNAT --to-source $private_ip
        echo "  Client $client_num: ${VPN_SUBNET}.${vpn_ip} -> $private_ip (Public: $public_ip)"
    done

    # Save iptables rules
    echo ""
    echo "Saving iptables rules..."
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save
        echo "Rules saved with netfilter-persistent"
    elif command -v iptables-save &> /dev/null; then
        iptables-save > /etc/iptables/rules.v4
        echo "Rules saved to /etc/iptables/rules.v4"
    else
        echo "WARNING: Could not save iptables rules automatically"
        echo "Install iptables-persistent: sudo apt install iptables-persistent"
    fi
    echo ""
}

# Function to setup a single client
setup_single_client() {
    local octet=$1
    
    # Find the index for this octet
    local index=$(find_index_by_octet "$octet")
    if [ $? -ne 0 ]; then
        echo "ERROR: Invalid IP octet '$octet'"
        echo "Valid options: ${VPN_IPS[*]}"
        exit 1
    fi
    
    local client_num=$((index+1))
    local vpn_ip=${VPN_IPS[$index]}
    local private_ip=${PRIVATE_IPS[$index]}
    local public_ip=${PUBLIC_IPS[$index]}
    
    echo "========================================="
    echo "Setting up single client"
    echo "========================================="
    echo "Client $client_num"
    echo "VPN IP: ${VPN_SUBNET}.${vpn_ip}"
    echo "Private IP: $private_ip"
    echo "Public IP: $public_ip"
    echo ""
    
    # Generate keys
    generate_keys "$client_num" "$vpn_ip"
    
    # Create client config
    create_client_config "$client_num" "$vpn_ip" "$private_ip" "$public_ip"
    echo ""
    
    # Update server config
    local public_key=$(cat "$WORK_DIR/client${client_num}_public.key")
    update_server_peer "$vpn_ip" "$private_ip" "$public_ip" "$public_key"
    echo ""
    
    # Setup iptables
    setup_single_iptable "$vpn_ip" "$private_ip" "$public_ip"
    echo ""
    
    # Reload WireGuard
    echo "Reloading WireGuard..."
    if systemctl is-active --quiet wg-quick@wg0; then
        wg syncconf wg0 <(wg-quick strip wg0)
        echo "WireGuard configuration reloaded"
    else
        echo "WireGuard is not running. Start it with: sudo wg-quick up wg0"
    fi
    echo ""
    
    # Display QR code
    display_single_qr "$client_num" "$vpn_ip" "$private_ip" "$public_ip"
    
    echo "========================================="
    echo "Setup complete for Client $client_num!"
    echo "========================================="
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  (no args)         Setup all clients (regenerates everything)"
    echo "  --qr              Display QR codes for all clients"
    echo "  --iptables-only   Update iptables rules only"
    echo "  --<octet>         Setup single client by IP octet"
    echo ""
    echo "Single client setup examples:"
    for i in "${!VPN_IPS[@]}"; do
        local client_num=$((i+1))
        local vpn_ip=${VPN_IPS[$i]}
        local private_ip=${PRIVATE_IPS[$i]}
        echo "  --${vpn_ip}             Client $client_num (${VPN_SUBNET}.${vpn_ip} -> $private_ip)"
    done
    echo ""
}

# Main execution
main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (use sudo)"
        exit 1
    fi

    echo "========================================="
    echo "WireGuard Multi-Client Configuration"
    echo "========================================="
    echo ""
    echo "This will configure ${#VPN_IPS[@]} clients:"
    for i in "${!VPN_IPS[@]}"; do
        echo "  Client $((i+1)): VPN ${VPN_SUBNET}.${VPN_IPS[$i]} -> Private ${PRIVATE_IPS[$i]} -> Public ${PUBLIC_IPS[$i]}"
    done
    echo ""

    echo "Step 1: Generating keys for all clients"
    echo "----------------------------------------"
    for i in "${!VPN_IPS[@]}"; do
        local client_num=$((i+1))
        local vpn_ip=${VPN_IPS[$i]}
        generate_keys "$client_num" "$vpn_ip"
    done

    echo "Step 2: Creating client configurations"
    echo "----------------------------------------"
    for i in "${!VPN_IPS[@]}"; do
        local client_num=$((i+1))
        local vpn_ip=${VPN_IPS[$i]}
        local private_ip=${PRIVATE_IPS[$i]}
        local public_ip=${PUBLIC_IPS[$i]}
        create_client_config "$client_num" "$vpn_ip" "$private_ip" "$public_ip"
    done
    echo ""

    echo "Step 3: Generating server configuration"
    echo "----------------------------------------"
    generate_server_config

    echo "Step 4: Setting up iptables"
    echo "----------------------------------------"
    setup_iptables

    echo "Step 5: Restarting WireGuard"
    echo "----------------------------------------"
    if systemctl is-active --quiet wg-quick@wg0; then
        echo "Restarting WireGuard..."
        wg-quick down wg0
        wg-quick up wg0
        echo "WireGuard restarted"
    else
        echo "Starting WireGuard..."
        wg-quick up wg0
        systemctl enable wg-quick@wg0
        echo "WireGuard started and enabled"
    fi
    echo ""

    echo "========================================="
    echo "Setup Complete!"
    echo "========================================="
    echo ""
    echo "Client configurations are in: $WORK_DIR"
    echo ""
    echo "Available configs:"
    for i in "${!VPN_IPS[@]}"; do
        local client_num=$((i+1))
        local private_ip=${PRIVATE_IPS[$i]}
        local public_ip=${PUBLIC_IPS[$i]}
        echo "  - client${client_num}_${private_ip}.conf (Public IP: $public_ip)"
    done
    echo ""
    echo "To view a config: cat $WORK_DIR/client1_10.0.0.6.conf"
    echo "To generate QR codes: sudo $0 --qr"
    echo "To setup single client: sudo $0 --33"
    echo ""
}

# Parse command line arguments
if [ "$1" = "--qr" ]; then
    generate_qr_codes
elif [ "$1" = "--iptables-only" ]; then
    setup_iptables
elif [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    show_usage
elif [[ "$1" =~ ^--([0-9]+)$ ]]; then
    # Single client setup
    octet="${BASH_REMATCH[1]}"
    setup_single_client "$octet"
elif [ -z "$1" ]; then
    main
else
    echo "ERROR: Invalid option '$1'"
    echo ""
    show_usage
    exit 1
fi