# Raspberry Pi — Bridge & WireGuard Setup

One-time hardware setup to put the Pi inline between the modem and the rest of the network.

```
Modem → Pi eth0 → br0 → Pi eth1 → Router → Clients
```

| Interface | Role |
|---|---|
| `eth0` | WAN (modem) |
| `eth1` | LAN (router/switch) |
| `br0` | Bridge combining eth0 + eth1 |

---

## 1. Prepare OS

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y bridge-utils net-tools
```

---

## 2. Configure network bridge

```bash
sudo ./scripts/setup/setup-bridge-unified.sh
```

To persist across reboots, copy one of the example configs:
```bash
# ifupdown
sudo cp config/network/interfaces-bridge /etc/network/interfaces

# systemd-networkd
sudo cp config/network/systemd-bridge/* /etc/systemd/network/
sudo systemctl enable --now systemd-networkd
```

Add to `/etc/sysctl.d/99-idps.conf`:
```
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
```
```bash
sudo sysctl -p /etc/sysctl.d/99-idps.conf
```

---

## 3. WireGuard key exchange (one-time)

The Pi sits behind NAT and is not directly reachable. The `idps-wireguard` container initiates the tunnel outbound; the VPS reaches the Pi at `10.10.0.2`.

**Generate Pi keypair:**
```bash
wg genkey | tee pi-private.key | wg pubkey
# Save private key as WG_PRIVATE_KEY in .env (never commit it)
# Share the public key with the VPS
```

**Register Pi on VPS:**
```bash
sudo wg set wg0 peer <PI_PUBKEY> allowed-ips 10.10.0.2/32 persistent-keepalive 25
sudo wg-quick save wg0
```

**Get VPS public key:**
```bash
sudo wg show wg0 public-key
# Set as WG_VPS_PUBLIC_KEY in Pi .env
```

**Pi `.env` WireGuard vars:**
```
WG_PRIVATE_KEY=<pi-private-key>
WG_VPS_PUBLIC_KEY=<vps-public-key>
VPS_PUBLIC_IP=178.104.6.176
WG_ADDRESS=10.10.0.2/24
WG_PORT=51820
WG_ALLOWED_IPS=10.10.0.1/32
WG_KEEPALIVE=25
```

**Verify tunnel:**
```bash
docker exec idps-wireguard wg show wg0
docker exec idps-wireguard ping -c 3 10.10.0.1
```

---

## Troubleshooting

**No internet after bridge setup**
```bash
sudo ./scripts/setup/setup-bridge-unified.sh
```

**Bridge not working**
```bash
ip link show && bridge link show
cat /proc/sys/net/ipv4/ip_forward   # must be 1
```

**WireGuard tunnel down**
```bash
docker logs idps-wireguard
grep WG_ /home/brent/idps/.env     # verify keys are set
sudo wg show wg0                    # run on VPS — check Pi peer handshake
```
