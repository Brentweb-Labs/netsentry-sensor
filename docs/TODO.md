# IDPS TODO

Generated from codebase + docs audit on 2026-04-19. Updated 2026-05-06.
Priority order: Critical → High → Medium → Low.

---

## Critical

### 1. `threat-intel` service is a stub
**File:** `src/services/cloud/threat-intel/src/main.rs` — line 16 `// TODO: Implement actual service logic`

The service opens a TCP socket on port 8092 and drops every connection. The api-gateway's `/api/threat-intel` endpoint works around this by aggregating directly from MongoDB, but it has no external feed data, no reputation scores, and no enrichment.

**Implement:**
- IP/domain reputation lookups against internal MongoDB collection
- Background updater that pulls from at least one public feed (e.g., Abuse.ch, Feodo Tracker)
- HTTP API returning `{ malicious_ips, suspicious_domains, vulnerabilities }` — matching the shape api-gateway already expects

---

### 2. `log-processor` implemented but not deployed
`src/services/cloud/log-processor/src/main.rs` has a full implementation (watches Suricata eve.json, ingests alerts into MongoDB). It is in the Cargo workspace but **not** in `docker-compose.vps.yml`, so VPS-side packet-analyzer alerts never reach the dashboard.

**Fix:** Add `log-processor` to `docker-compose.vps.yml` with the correct `MONGODB_URI` and `SURICATA_EVE_PATH` env vars. Verify it writes to the same `alerts` collection the api-gateway reads from.

---

## High

### 3. `packet-analyzer` alerts do not reach MongoDB/dashboard
`packet-analyzer` runs on the VPS but its detections never POST to `/api/alerts/ingest`. This is separate from log-processor (item #2); packet-analyzer should emit alerts directly when it detects a threat.

**Fix:** Add an HTTP client call in `packet-analyzer` to POST detections to `http://api-gateway:8080/api/alerts/ingest` on the VPS internal network.

---

## Medium

### 4. `ids-pi` Python service is minimal
**File:** `src/services/edge/ids-pi/app.py` (58 lines)

Responds to `/health` only. No IDS logic.

**Fix:** Either implement the nuclei scan scheduler and POST results to `/api/alerts/ingest` on the VPS, or remove the service from compose and docs if Suricata covers this use case.

---

## Low

### 5. No integration tests for the Pi→VPS pipeline
No test verifies: raspi-collector POST → api-gateway ingest → MongoDB write → WebSocket broadcast.

**Fix:** Add at least one integration test using `testcontainers-rs` for MongoDB and a mock HTTP server.

### 6. `vps-processor` is dead code in the workspace
`src/services/cloud/vps-processor/` has a Rust service but is not referenced by any compose file. Decide: integrate it into `docker-compose.vps.yml` or remove it from `Cargo.toml` workspace members.

### 7. No docker-compose for the monitoring stack
Prometheus and Grafana configs live in `ops/monitoring/` but have no compose file. The monitoring stack cannot be reproduced without manual steps.

**Fix:** Add `docker-compose.monitoring.yml` referencing `ops/monitoring/prometheus.yml` and the Grafana provisioning directories, or merge prometheus + grafana + mongodb-exporter into `docker-compose.vps.yml`.

---

## Completed (do not re-implement)

- `shared/utils` and `shared/config` libraries
- `raspi-collector` → `/api/traffic` + `/api/traffic/batch` wiring (2026-04-19)
- api-gateway `/api/health` auth bypass for raspi-collector health checks (2026-04-19)
- `X-API-Key` header added to raspi-collector HTTP requests (2026-04-19)
- WireGuard container and `docker-compose.raspi.yml` integration
- `get_vps_status` replaced with direct MongoDB query (vps-processor removed)
- Axum 0.8 route param syntax fixed (`{ip}` not `:ip`)
- `Message::Text` Utf8Bytes fix (4 occurrences)
- Background connection cache (30 s poll, instant reads)
- Suricata removed from VPS compose
- `get_all_services_status` vps-processor reference removed
- Docs updated to reflect current architecture (2026-04-19)
- **WS auth** — raspi-collector appends `?api_key=` to `/ws/raspi` URL (2026-04-19)
- **WS auth** — Angular dashboard HTTP interceptor adds `X-API-Key`; WS reads key from localStorage (2026-04-19)
- **packet-processor + rule-engine** added to `docker-compose.raspi.yml` (2026-04-19)
- **Grafana real data** — api-gateway `/metrics` Prometheus endpoint (2026-04-19)
- **Grafana real data** — `prometheus.yml` fixed: Pi node-exporter at `10.10.0.2:9100`, removed stub scrape jobs (2026-04-19)
- **Grafana real data** — `mongodb-exporter` planned for `docker-compose.vps.yml` (config in `ops/monitoring/prometheus.yml`) — **not yet added to compose** (see TODO #7)
- **Grafana real data** — `ops/monitoring/grafana/dashboards/idps-overview.json` created (2026-04-19)
- `/api/config` endpoint (no auth) — dashboard can discover whether API key is required (2026-04-19)
- **Blocked IP expiry** — api-gateway background task expires `blocked_ips` every 60 s, broadcasts `unblock_command` to Raspi (2026-04-19)
- **Rate-limiting `/ws/packets`** — token-bucket per-connection enforces `MAX_PACKETS_PER_SECOND` (2026-04-19)
- **Env var dedup** — removed duplicate `VPS_PACKETS_WS_URL` from `.env` (2026-04-19)
- **Telemetry VPS_URL** — removed wrong fallback `http://api-gateway:8080` in `docker-compose.raspi.yml`; telemetry already pushes to VPS (2026-04-19)
- **CIDR dedup** — replaced inline `cidr_contains()` in api-gateway with `idps_utils::is_in_cidr()` (2026-04-19)
- **Dead code** — removed `vps_client`, `vps_endpoint`, `is_eve_json_recent()` from api-gateway (2026-04-19)
- **WireGuard key rotation runbook** added to `docs/OPERATIONS.md` (2026-04-19)
