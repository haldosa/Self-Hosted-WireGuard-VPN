# Self-Hosted WireGuard VPN on Oracle Cloud

A self-hosted VPN server on Oracle Cloud with multiple IP addresses, routing each connected device through a separate public endpoint. Includes automated scripts for setup, key management, and client configuration.

## Features

- Each device gets its own dedicated public IP address
- Automated key generation and config creation per client
- QR code generation for easy mobile setup
- Persistent iptables NAT rules across reboots
- Single-command setup for new clients

## Architecture

```
Device 1 ──┐
Device 2 ──┤                        ┌── Public IP 1
Device 3 ──┼── WireGuard VPN ───────┼── Public IP 2
Device 4 ──┤   (Oracle Cloud VM)    ├── Public IP 3
Device 5 ──┤                        ├── ...
Device 6 ──┘                        └── Public IP N
```

Each device connects to the VPN server and traffic is routed out through its own dedicated public IP via iptables SNAT rules. Oracle Cloud NATs each private IP to its corresponding reserved public IP.

## Requirements

- Oracle Cloud account (Free Tier is sufficient)
- Ubuntu VM on Oracle Cloud
- Reserved public IP addresses (one per device)
- WireGuard installed on the server and client devices

## Server Setup

### 1. Install WireGuard

```bash
sudo apt update && sudo apt install wireguard -y
```

### 2. Configure Secondary Private IPs (Netplan)

Oracle Cloud assigns secondary private IPs in the console, but they need to be configured on the VM. Create `/etc/netplan/99-secondary-ips.yaml`:

```bash
sudo cp netplan/99-secondary-ips.yaml /etc/netplan/99-secondary-ips.yaml
sudo netplan apply
```

Verify all IPs are attached:

```bash
ip addr show ens3 | grep "inet "
```

### 3. Enable IP Forwarding

```bash
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 4. Run the Setup Script

```bash
# Edit the script and fill in your values (see Configuration below)
sudo nano wireguard-setup.sh

# Make executable
chmod +x wireguard-setup.sh

# Run full setup
sudo ./wireguard-setup.sh
```

### 5. Oracle Cloud Security List

In Oracle Cloud Console, add an ingress rule to your VCN Security List:
- **Source CIDR:** `0.0.0.0/0`
- **IP Protocol:** UDP
- **Destination Port:** `51820`

## Configuration

Edit the following variables at the top of `wireguard-setup.sh`:

| Variable | Description | Example |
|----------|-------------|---------|
| `SERVER_PUBLIC_KEY` | Server's WireGuard public key | `Tullw/DR/...` |
| `SERVER_PRIVATE_KEY` | Server's WireGuard private key | `MFwZ7w6w/...` |
| `SERVER_ENDPOINT` | Server's primary public IP | `1.2.3.4` |
| `SERVER_PORT` | WireGuard listen port | `51820` |
| `VPN_SUBNET` | VPN subnet prefix | `10.200.0` |
| `DNS_SERVER` | DNS server for clients | `1.1.1.1` |
| `VPN_IPS` | Last octets matching private IPs | `6 67 133 ...` |
| `PRIVATE_IPS` | Oracle private IPs for SNAT | `10.0.0.6 ...` |

### IP Mapping

VPN IPs are intentionally matched to private IP last octets for easier debugging:

```
VPN IP          Private IP      Public IP
10.200.0.6   -> 10.0.0.6    -> <PUBLIC_IP_1>
10.200.0.67  -> 10.0.0.67   -> <PUBLIC_IP_2>
10.200.0.133 -> 10.0.0.133  -> <PUBLIC_IP_3>
...
```

## Usage

```bash
# Full setup - regenerates all clients
sudo ./wireguard-setup.sh

# Setup a single client by private IP last octet
sudo ./wireguard-setup.sh --6
sudo ./wireguard-setup.sh --67
sudo ./wireguard-setup.sh --133

# Show QR codes for all clients
sudo ./wireguard-setup.sh --qr

# Update iptables rules only
sudo ./wireguard-setup.sh --iptables-only

# Show help
sudo ./wireguard-setup.sh --help
```

## Client Setup

### Desktop (Linux/macOS/Windows)
1. Install WireGuard from [wireguard.com](https://www.wireguard.com/install/)
2. Copy the client config from `/etc/wireguard/clients/clientN_10.0.0.X.conf`
3. Import the config file into WireGuard

### Mobile (iOS/Android)
1. Install the WireGuard app
2. Run `sudo ./wireguard-setup.sh --qr` on the server
3. Scan the QR code with the WireGuard app

## File Structure

```
.
├── README.md
├── wireguard-setup.sh          # Main setup script
├── netplan/
│   └── 99-secondary-ips.yaml  # Netplan config for secondary IPs
└── iptables/
    └── rules.v4.example        # Example iptables rules
```

## Backups

The setup script automatically backs up `wg0.conf` before any changes:

```
/etc/wireguard/wg0.conf.backup.YYYYMMDD_HHMMSS
```

Client configs are stored in `/etc/wireguard/clients/` and named:

```
clientN_10.0.0.X.conf
```

## Troubleshooting

**No handshake:**
- Verify UDP 51820 is open in Oracle Cloud Security List
- Check iptables: `sudo iptables -L INPUT -v -n | grep 51820`
- Verify packets are arriving: `sudo tcpdump -i ens3 udp port 51820 -n`
- Ensure client public key in `wg0.conf` matches the client's private key: `cat client_private.key | wg pubkey`

**Wrong public IP on client:**
- Check SNAT rules: `sudo iptables -t nat -L POSTROUTING -v -n | grep "10.200.0"`
- Clear and rebuild rules: `sudo iptables -t nat -F POSTROUTING && sudo ./wireguard-setup.sh --iptables-only`

**Secondary IPs missing after reboot:**
- Verify netplan config: `cat /etc/netplan/99-secondary-ips.yaml`
- Reapply: `sudo netplan apply`