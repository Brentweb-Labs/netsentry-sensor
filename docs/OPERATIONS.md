# IDPS — Operations

## Environment variables

### Pi — `docker-compose.raspi.yml`

| Variable | Default | Description |
|---|---|---|
| `VPS_API_URL` | *(required)* | Public VPS API URL — `https://idps.brentweb.eu/api/vps` |
| `VPS_ENDPOINT` | `http://10.10.0.1:8080` | Direct VPS address over WireGuard (health checks, traffic forwarding) |
| `VPS_WS_URL` | `wss://idps.brentweb.eu/ws/raspi` | WebSocket for block/rule commands from VPS |
| `PACKET_STREAM_WS_URL` | `wss://idps.brentweb.eu/ws/packets` | WebSocket for raw packet streaming to VPS |
| `API_KEY` | *(required)* | Sent as `X-API-Key` on all VPS requests |
| `WG_PRIVATE_KEY` | *(required)* | Pi WireGuard private key (base64) |
| `WG_VPS_PUBLIC_KEY` | *(required)* | VPS WireGuard public key (base64) |
| `VPS_PUBLIC_IP` | `178.104.6.176` | VPS public IP for WireGuard endpoint |
| `WG_ADDRESS` | `10.10.0.2/24` | Pi WireGuard interface address |
| `SURICATA_IFACE` | `eth0` | Interface Suricata monitors |
| `MONGO_ROOT_PASSWORD` | `SecurePassword123!` | **Change in production** |
| `REDIS_PASSWORD` | `RedisSecure123!` | **Change in production** |

### VPS — `docker-compose.vps.yml`

| Variable | Default | Description |
|---|---|---|
| `RASPI_ENDPOINT` | `http://10.10.0.2:8080` | Pi raspi-collector URL (WireGuard tunnel) |
| `AUTO_BLOCK_ENABLED` | `false` | Set `true` to auto-apply iptables rules on Pi |
| `API_KEY` | *(required)* | API key for all authenticated endpoints |
| `VPS_API_KEY` | *(required)* | Used by packet-processor when connecting to VPS WebSocket |
| `MONGO_ROOT_PASSWORD` | `SecurePassword123!` | **Change in production** |
| `GRAFANA_PASSWORD` | `Admin123!` | **Change in production** |
| `TENANT_ID` | `default` | Tenant ID embedded in JWT; leave `default` for single-tenant |
| `THREAT_INTEL_URL` | `http://threat-intel:8094` | Internal URL for IP reputation lookups |
| `STRIPE_SECRET_KEY` | *(required for billing)* | Stripe secret key from dashboard.stripe.com |
| `STRIPE_PRICE_ID` | *(required for billing)* | Stripe price ID for the Cloud plan |
| `STRIPE_WEBHOOK_SECRET` | *(required for billing)* | Stripe webhook signing secret |
| `SMTP_HOST` | — | SMTP server for email alerts |
| `SMTP_PORT` | `587` | SMTP port (STARTTLS) |
| `SMTP_USERNAME` | — | SMTP login |
| `SMTP_PASSWORD` | — | SMTP password |
| `SMTP_FROM` | `alerts@netsentry.io` | Alert sender address |
| `TWILIO_ACCOUNT_SID` | — | Twilio account SID for SMS alerts |
| `TWILIO_AUTH_TOKEN` | — | Twilio auth token |
| `TWILIO_FROM_NUMBER` | — | Twilio sender number (E.164) |

---

## Access

| Resource | URL / address |
|---|---|
| Dashboard | https://idps.brentweb.eu |
| API | https://idps.brentweb.eu/api/vps |
| WebSocket | wss://idps.brentweb.eu/ws |
| Grafana | https://grafana.idps.brentweb.eu |
| VPS SSH | `root@178.104.6.176` |
| Pi SSH (LAN) | `brent@192.168.1.47` |
| Pi SSH (VPS → WireGuard) | `ssh brent@10.10.0.2` |

---

## API endpoints

All endpoints require `X-API-Key: <API_KEY>` except `/health`.

| Method | Endpoint | Auth | Description |
|---|---|---|---|
| GET | `/health` | none | Health check |
| GET | `/api/status` | key | Event pipeline status |
| GET | `/api/events` | key | Security events (paginated, tenant-scoped) |
| GET | `/api/alerts/statistics` | key | Alert statistics (tenant-scoped) |
| GET | `/api/metrics` | key | System metrics |
| GET | `/api/services/status` | key | All service health |
| GET | `/api/connection/raspi-vps` | key | Pi↔VPS connection status |
| POST | `/api/traffic` | key | Ingest single Suricata event from Pi |
| POST | `/api/traffic/batch` | key | Ingest batch of events from Pi |
| POST | `/api/prevention/block` | key | Manually block an IP |
| POST | `/api/prevention/unblock` | key | Manually unblock an IP |
| GET | `/api/prevention/blocked` | key | List blocked IPs (tenant-scoped) |
| DELETE | `/api/prevention/blocked/{ip}` | key | Unblock specific IP |
| GET | `/api/prevention/stats` | key | Prevention statistics |
| POST | `/api/suricata/start` | key | Send start command to Suricata |
| POST | `/api/suricata/stop` | key | Send stop command to Suricata |
| POST | `/api/suricata/reload` | key | Reload Suricata rules |
| GET | `/api/billing/status` | key | Stripe subscription status |
| POST | `/api/billing/checkout` | key | Create Stripe Checkout session |
| POST | `/api/billing/webhook` | none | Stripe webhook receiver (HMAC-verified) |
| GET | `/api/alerts/rules` | key | List alert rules (email/SMS) |
| POST | `/api/alerts/rules` | key | Create alert rule |
| DELETE | `/api/alerts/rules/{id}` | key | Delete alert rule |
| GET | `/api/reports/weekly` | key | Download latest weekly PDF report |
| GET | `/api/reports/history` | key | List generated reports (metadata only) |
| PUT | `/api/reports/config` | key | Update PDF branding config |
| POST | `/api/login` | none | Exchange API key for JWT |
| WS | `/ws` | key | Dashboard real-time updates |
| WS | `/ws/raspi` | key | Pi command channel (block/rule) |
| WS | `/ws/packets` | key | Raw packet stream from Pi |

`auth: key` means `X-API-Key: <API_KEY>` header. JWT (`Authorization: Bearer <token>`) is accepted on all `key` endpoints as an alternative.

---

## Day-to-day commands

```bash
# Live logs
docker compose -f docker-compose.vps.yml logs -f api-gateway
docker compose -f docker-compose.raspi.yml logs -f raspi-collector
tail -f /home/brent/idps/data/logs/suricata/eve.json

# Restart a service
docker compose -f docker-compose.raspi.yml restart network-filter

# Active iptables blocks
sudo iptables -L INPUT -n --line-numbers | grep DROP

# Manually unblock an IP
curl -X POST http://localhost:8092/api/v1/unblock \
  -H "Content-Type: application/json" -d '{"ip": "1.2.3.4"}'

# Check WireGuard tunnel
sudo wg show wg0                              # on VPS
docker exec idps-wireguard wg show wg0        # on Pi

# Enable auto-blocking (off by default)
# Set AUTO_BLOCK_ENABLED=true in .env, then:
docker compose -f docker-compose.vps.yml up -d api-gateway

# Update deployment
git pull
docker compose -f docker-compose.vps.yml up -d --build    # VPS
docker compose -f docker-compose.raspi.yml up -d --build  # Pi
```

---

## WireGuard key rotation

Run in order — tunnel will be down ~30 seconds.

```bash
# 1. Generate new keypair on Pi
docker run --rm alpine sh -c "apk add --no-cache wireguard-tools -q && wg genkey | tee /tmp/pi-new.key | wg pubkey"

# 2. Remove old Pi peer on VPS
sudo wg show wg0 peers                                      # get old public key
sudo wg set wg0 peer <OLD_PI_PUBKEY> remove
sudo wg-quick save wg0

# 3. Add new Pi peer on VPS
sudo wg set wg0 peer <NEW_PI_PUBKEY> allowed-ips 10.10.0.2/32 persistent-keepalive 25
sudo wg-quick save wg0

# 4. Update Pi .env with new WG_PRIVATE_KEY, restart WireGuard
docker compose -f docker-compose.raspi.yml restart wireguard

# 5. Verify
ping -c 2 10.10.0.2        # from VPS
sudo wg show wg0            # should show new peer with recent handshake
```

---

## Troubleshooting

**Service not reachable via domain**
```bash
docker inspect idps-api-gateway-vps | grep -A5 Networks
docker logs traefik 2>&1 | grep idps
dig idps.brentweb.eu
```

**Pi shows as disconnected in dashboard**
```bash
sudo wg show wg0                                             # check handshake on VPS
docker compose -f docker-compose.raspi.yml restart wireguard
grep RASPI_ENDPOINT /home/brent/idps/.env                   # should be http://10.10.0.2:8080
```

**Suricata shows as stopped**
```bash
docker logs idps-suricata-pi --tail 20
tail -5 /home/brent/idps/data/logs/suricata/eve.json
docker logs idps-raspi-collector-pi --tail 30 | grep -i traffic
```

**MongoDB connection refused**
```bash
docker exec idps-mongodb-pi mongosh --eval "db.adminCommand('ping')"     # Pi
docker exec idps-mongodb-vps mongosh --eval "db.adminCommand('ping')"    # VPS
```

**Traefik returns 404 on /api/vps/***
```bash
# Middleware must use @docker suffix in Traefik v3
docker inspect idps-api-gateway-vps | grep -i middleware
docker logs traefik 2>&1 | grep -i "idps\|404"
```

---

## Open ports

| Port | Protocol | Service | Host |
|---|---|---|---|
| 22 | TCP | SSH | both |
| 80/443 | TCP | Traefik | VPS |
| 51820 | UDP | WireGuard | VPS |
| 8080 | TCP | raspi-collector API (WireGuard only) | Pi |
| 9100 | TCP | Node Exporter | Pi |
| 8096 | TCP | Telemetry | Pi |
