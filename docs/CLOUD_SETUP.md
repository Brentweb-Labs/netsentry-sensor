# Cloud Infrastructure Requirements

This document describes what you need to run your own NetSentry Cloud backend — for businesses that want to self-host the full stack, build their own SaaS on top, or operate in air-gapped environments.

> The cloud repository (`netsentry-cloud`) is currently **private**. To request early access, contact [brentweb.eu@gmail.com](mailto:brentweb.eu@gmail.com) or open an issue on the sensor repo.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    NetSentry Cloud Server                    │
│                                                             │
│  ┌────────────┐   ┌────────────┐   ┌────────────────────┐  │
│  │  Traefik   │   │  MongoDB   │   │  Prometheus/Grafana │  │
│  │ (TLS/proxy)│   │  (6.0+)    │   │  (optional)         │  │
│  └─────┬──────┘   └─────┬──────┘   └────────────────────┘  │
│        │                │                                   │
│  ┌─────▼──────────────────────────────────────────────┐     │
│  │                  idps-net (bridge)                  │     │
│  │  api-gateway  threat-intel  vps-processor           │     │
│  │  packet-analyzer  console-api  console-frontend     │     │
│  │  vps-dashboard  log-processor                       │     │
│  └────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
                          │
                    WireGuard tunnel
                          │
              ┌───────────▼──────────┐
              │    Sensor Node(s)     │
              │ (netsentry-sensor)   │
              └──────────────────────┘
```

---

## Server Requirements

| Component | Minimum | Recommended |
|---|---|---|
| CPU | 2 vCPU | 4+ vCPU |
| RAM | 4 GB | 8–16 GB |
| Disk | 20 GB SSD | 50 GB+ SSD |
| OS | Ubuntu 22.04 / Debian 12 | Same |
| Docker | 24+ with Compose plugin | Same |
| Network | 1 public IPv4, port 443 + 51820 open | Dedicated IP recommended |

**Cloud providers tested:** Hetzner Cloud (CPX21/CPX42), DigitalOcean Droplets, Vultr, Linode. Any VPS with a public IP works.

---

## DNS Requirements

You need a domain (or subdomain) pointing at your server's public IP:

| Record | Example | Purpose |
|---|---|---|
| A | `netsentry.example.com` | Main API + dashboard |
| A | `grafana.netsentry.example.com` | Grafana (optional) |

Traefik handles TLS automatically via Let's Encrypt. All you need is the A record.

---

## External Traefik Stack

The cloud compose stack uses Traefik for TLS and routing, but Traefik is managed in a **separate** stack so it can be shared across multiple application stacks on the same host.

```bash
# Create the shared proxy network (once per host)
docker network create proxy

# Run Traefik (example — adapt to your setup)
docker run -d \
  --name traefik \
  --network proxy \
  -p 80:80 -p 443:443 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v ./traefik/acme.json:/acme.json \
  traefik:v3 \
    --providers.docker=true \
    --providers.docker.exposedbydefault=false \
    --entrypoints.web.address=:80 \
    --entrypoints.websecure.address=:443 \
    --certificatesresolvers.letsencrypt.acme.email=you@example.com \
    --certificatesresolvers.letsencrypt.acme.storage=/acme.json \
    --certificatesresolvers.letsencrypt.acme.tlschallenge=true \
    --entrypoints.web.http.redirections.entrypoint.to=websecure
```

The `proxy` network must exist before the cloud stack starts.

---

## WireGuard on the Cloud Server

The cloud server needs a WireGuard interface to communicate with sensors over the tunnel.

```bash
# Install WireGuard
apt-get install -y wireguard

# Generate cloud keypair
wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
chmod 600 /etc/wireguard/privatekey

# Create /etc/wireguard/wg0.conf
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.10.0.1/24
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/privatekey)
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# Add a [Peer] block for each sensor:
# [Peer]
# PublicKey = <sensor-wg-public-key>
# AllowedIPs = 10.10.0.2/32
# PersistentKeepalive = 25
EOF

# Enable and start
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Open WireGuard port (adjust for your firewall)
ufw allow 51820/udp
```

Assign each sensor a unique WireGuard IP from the `10.10.0.0/24` range (e.g., `.2`, `.3`, `.4`, …).

---

## Cloud Environment Variables

Minimum required variables for the cloud `.env`:

```bash
# Domain
DOMAIN=netsentry.example.com
ALLOWED_IP=<your-management-ip>   # IP allowlist for the operator dashboard

# Secrets — generate with: openssl rand -hex 32
MONGO_ROOT_PASSWORD=<random>
JWT_SECRET=<random>

# Admin account
ADMIN_USERNAME=admin
ADMIN_PASSWORD=<strong-password>

# Sensor connectivity
SENSOR_ENDPOINT=http://10.10.0.2:8080   # sensor WireGuard IP:port

# Internal services
THREAT_INTEL_URL=http://threat-intel:8094

# Optional: Stripe billing
STRIPE_SECRET_KEY=sk_live_...
STRIPE_PRICE_ID=price_...
STRIPE_WEBHOOK_SECRET=whsec_...

# Optional: Email alerts
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=alerts@example.com
SMTP_PASSWORD=...

# Optional: SMS alerts
TWILIO_ACCOUNT_SID=ACxxxxxxxx
TWILIO_AUTH_TOKEN=...
TWILIO_FROM_NUMBER=+1xxxxxxxxxx
```

---

## Starting the Cloud Stack

```bash
cd netsentry-cloud
cp .env.example .env
# Fill in the variables above
./install.sh   # interactive — generates JWT secret, hashes admin password

docker compose -f docker-compose.yml up -d

# Verify
docker compose ps
curl https://<DOMAIN>/health
```

---

## Multi-Sensor Deployments

Each sensor gets:
1. A unique WireGuard IP (e.g. `10.10.0.2`, `10.10.0.3`, …)
2. A unique `API_KEY` (generate with `openssl rand -hex 32`)
3. A unique `DEVICE_ID` in its `.env`

On the cloud side, register each sensor in the console under **Sensors → Add Sensor**.

For multi-tenant SaaS deployments, each tenant is isolated by `tenant_id` in MongoDB and in JWT claims. The console-api handles tenant/user/API-key management.

---

## Building a SaaS on NetSentry

If you are building a managed security service using NetSentry as the foundation:

1. **Keep the sensor public** — your customers clone this repo and deploy it themselves.
2. **Host the cloud privately** — your cloud instance is the backend that customers' sensors connect to.
3. **Issue API keys per customer** — use the console-api to create tenant accounts and generate per-sensor API keys.
4. **Configure the sensor `.env`** for your cloud URLs — override `VPS_API_URL`, `VPS_WS_URL`, and `PACKET_STREAM_WS_URL` to point at your domain instead of the default SaaS endpoints.

The sensor is fully generic. Any `VPS_API_URL` that implements the NetSentry cloud API contract will work.

---

## Hardware Sizing Reference

| Sensors | Events/sec (est.) | Cloud RAM | Cloud CPU |
|---|---|---|---|
| 1–5 | 100–500 | 4 GB | 2 vCPU |
| 5–20 | 500–2 000 | 8 GB | 4 vCPU |
| 20–100 | 2 000–10 000 | 16 GB | 8 vCPU |
| 100+ | 10 000+ | 32 GB+ | 16+ vCPU |

MongoDB is the primary bottleneck at scale. Use a dedicated MongoDB instance (Atlas, self-managed replica set) for large deployments.
