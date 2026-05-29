# NetSentry Sensor — Operations

## Environment Variables

### Sensor — `docker-compose.raspi.yml`

| Variable | Default | Description |
|---|---|---|
| `VPS_API_URL` | *(required)* | Public cloud API URL — `https://<your-domain>/api/vps` |
| `VPS_WS_URL` | *(required)* | WebSocket for block/rule commands from cloud |
| `PACKET_STREAM_WS_URL` | *(required)* | WebSocket for raw packet streaming to cloud |
| `API_KEY` | *(required)* | Sent as `X-API-Key` on all cloud requests |
| `WG_PRIVATE_KEY` | *(required)* | Sensor WireGuard private key (base64) |
| `WG_VPS_PUBLIC_KEY` | *(required)* | Cloud WireGuard public key (base64) |
| `VPS_PUBLIC_IP` | *(required)* | Cloud server public IP for WireGuard endpoint |
| `WG_ADDRESS` | `10.10.0.2/24` | Sensor WireGuard interface address |
| `CAPTURE_INTERFACE` | `eth0` | Interface packet-processor and Suricata monitor |
| `SURICATA_IFACE` | `eth0` | Interface Suricata monitors (set `br0` for inline bridge) |
| `DEVICE_ID` | `sensor-node-01` | Unique sensor name shown in cloud dashboard |
| `MONGO_ROOT_PASSWORD` | — | **Change before deploying** |
| `REDIS_PASSWORD` | — | **Change before deploying** |
| `MONGO_IMAGE` | `mongo:4.4.18` | Override for x86_64 hosts: set to `mongo:7.0` |

### Cloud — `docker-compose.yml`

| Variable | Default | Description |
|---|---|---|
| `SENSOR_ENDPOINT` | `http://10.10.0.2:8080` | Sensor collector URL (over WireGuard tunnel) |
| `AUTO_BLOCK_ENABLED` | `false` | Set `true` to auto-apply iptables rules on sensor |
| `API_KEY` | *(required)* | API key for all authenticated endpoints |
| `JWT_SECRET` | *(required)* | JWT signing secret |
| `ADMIN_PASSWORD` | *(required)* | Admin account password |
| `DOMAIN` | *(required)* | Your domain (used in Traefik routing labels) |
| `ALLOWED_IP` | *(required)* | Your management IP for dashboard IP allowlist |
| `MONGO_ROOT_PASSWORD` | — | **Change before deploying** |
| `THREAT_INTEL_URL` | `http://threat-intel:8094` | Internal IP reputation service URL |
| `STRIPE_SECRET_KEY` | *(required for billing)* | Stripe secret key |
| `STRIPE_PRICE_ID` | *(required for billing)* | Stripe price ID |
| `STRIPE_WEBHOOK_SECRET` | *(required for billing)* | Stripe webhook signing secret |
| `SMTP_HOST` | — | SMTP server for email alerts |
| `SMTP_PORT` | `587` | SMTP port |
| `SMTP_USERNAME` | — | SMTP login |
| `SMTP_PASSWORD` | — | SMTP password |
| `TWILIO_ACCOUNT_SID` | — | Twilio SID for SMS alerts |
| `TWILIO_AUTH_TOKEN` | — | Twilio auth token |
| `TWILIO_FROM_NUMBER` | — | Twilio sender number (E.164) |

---

## Access

| Resource | URL |
|---|---|
| Cloud dashboard | `https://<your-domain>` |
| Cloud API | `https://<your-domain>/api/vps` |
| WebSocket | `wss://<your-domain>/ws` |
| Grafana (if deployed) | `https://grafana.<your-domain>` |
| Local sensor dashboard | `http://<sensor-lan-ip>` |

---

## API Endpoints

All endpoints require `X-API-Key: <API_KEY>` except `/health`. JWT (`Authorization: Bearer <token>`) is accepted on all authenticated endpoints.

| Method | Endpoint | Auth | Description |
|---|---|---|---|
| GET | `/health` | none | Health check |
| GET | `/api/status` | key | Event pipeline status |
| GET | `/api/events` | key | Security events (paginated, tenant-scoped) |
| GET | `/api/alerts/statistics` | key | Alert statistics |
| GET | `/api/metrics` | key | System metrics |
| GET | `/api/services/status` | key | All service health |
| GET | `/api/connection/sensor-cloud` | key | Sensor↔cloud connection status |
| POST | `/api/traffic` | key | Ingest single Suricata event from sensor |
| POST | `/api/traffic/batch` | key | Ingest batch of events from sensor |
| POST | `/api/prevention/block` | key | Manually block an IP |
| POST | `/api/prevention/unblock` | key | Manually unblock an IP |
| GET | `/api/prevention/blocked` | key | List blocked IPs |
| DELETE | `/api/prevention/blocked/{ip}` | key | Unblock specific IP |
| GET | `/api/prevention/stats` | key | Prevention statistics |
| POST | `/api/suricata/reload` | key | Reload Suricata rules |
| GET | `/api/billing/status` | key | Stripe subscription status |
| POST | `/api/billing/checkout` | key | Create Stripe Checkout session |
| POST | `/api/billing/webhook` | none | Stripe webhook (HMAC-verified) |
| GET | `/api/alerts/rules` | key | List alert rules (email/SMS) |
| POST | `/api/alerts/rules` | key | Create alert rule |
| DELETE | `/api/alerts/rules/{id}` | key | Delete alert rule |
| GET | `/api/reports/weekly` | key | Download weekly PDF report |
| GET | `/api/reports/history` | key | List generated reports |
| POST | `/api/login` | none | Exchange API key for JWT |
| WS | `/ws` | key | Dashboard real-time updates |
| WS | `/ws/raspi` | key | Sensor command channel (block/rule) |
| WS | `/ws/packets` | key | Raw packet stream from sensor |

---

## Day-to-day Commands

```bash
# Live logs
docker compose -f docker-compose.yml logs -f api-gateway          # cloud
docker compose -f docker-compose.raspi.yml logs -f raspi-collector  # sensor
tail -f ./data/logs/suricata/eve.json

# Restart a service
docker compose -f docker-compose.raspi.yml restart network-filter

# List active iptables blocks on sensor
sudo iptables -L INPUT -n --line-numbers | grep DROP

# Manually unblock an IP (sensor-side)
curl -X POST http://localhost:8092/api/v1/unblock \
  -H "Content-Type: application/json" -d '{"ip": "1.2.3.4"}'

# Check WireGuard tunnel
sudo wg show wg0                                    # cloud server
docker exec idps-wireguard wg show wg0              # sensor

# Enable auto-blocking (off by default)
# Set AUTO_BLOCK_ENABLED=true in cloud .env, then:
docker compose -f docker-compose.yml up -d api-gateway

# Update sensor
git pull
docker compose -f docker-compose.raspi.yml up -d --build

# Update cloud
git pull
docker compose -f docker-compose.yml up -d --build
```

---

## WireGuard Key Rotation

Run in order — tunnel will be down ~30 seconds.

```bash
# 1. Generate new keypair on sensor
wg genkey | tee /tmp/sensor-new.key | wg pubkey   # prints new public key

# 2. Remove old sensor peer on cloud
sudo wg show wg0 peers                             # get old public key
sudo wg set wg0 peer <OLD_SENSOR_PUBKEY> remove
sudo wg-quick save wg0

# 3. Add new sensor peer on cloud
sudo wg set wg0 peer <NEW_SENSOR_PUBKEY> allowed-ips 10.10.0.2/32 persistent-keepalive 25
sudo wg-quick save wg0

# 4. Update sensor .env with new WG_PRIVATE_KEY, restart WireGuard
docker compose -f docker-compose.raspi.yml restart wireguard

# 5. Verify
ping -c 2 10.10.0.2        # from cloud — should reply
sudo wg show wg0            # new peer should show a recent handshake
```

---

## Troubleshooting

**Sensor not appearing in cloud dashboard**
```bash
docker exec idps-wireguard wg show wg0             # check handshake timestamp
docker logs idps-raspi-collector-pi --tail 30      # check cloud connection
grep VPS_API_URL .env                              # verify URL is correct
```

**Suricata shows as stopped**
```bash
docker logs idps-suricata-pi --tail 20
tail -5 ./data/logs/suricata/eve.json
docker logs idps-raspi-collector-pi --tail 30 | grep -i traffic
```

**MongoDB connection refused**
```bash
docker exec idps-mongodb-pi mongosh --eval "db.adminCommand('ping')"
```

**Traefik returns 404 on /api/vps/***
```bash
# Traefik v3: middlewares must have @docker suffix
docker inspect idps-api-gateway-vps | grep -i middleware
docker logs traefik 2>&1 | grep -i "idps\|404"
```

---

## Open Ports

| Port | Protocol | Service | Host |
|---|---|---|---|
| 22 | TCP | SSH | both |
| 80/443 | TCP | Traefik | cloud |
| 51820 | UDP | WireGuard | cloud |
| 8080 | TCP | raspi-collector API (WireGuard-only) | sensor |
| 9100 | TCP | Node Exporter | sensor |
| 8096 | TCP | Telemetry | sensor |
