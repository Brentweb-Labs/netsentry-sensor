# IDPS — Backlog

## Implementation Status

| Component | Status |
|---|---|
| Core edge services (network-filter, raspi-collector) | COMPLETE |
| Core cloud services (api-gateway, packet-analyzer) | COMPLETE |
| Angular dashboard | COMPLETE |
| Docker configuration (2 compose files) | COMPLETE |
| WireGuard container (Pi side) | COMPLETE |
| shared/utils library | COMPLETE |
| shared/config library | COMPLETE |
| Performance optimizations (connection pooling, async I/O, caching) | COMPLETE |
| Event ingest pipeline (raspi-collector → api-gateway /api/traffic) | COMPLETE |
| packet-processor (pcap capture + WS streaming) | COMPLETE — in docker-compose.raspi.yml |
| rule-engine (Suricata dynamic rule management) | COMPLETE — in docker-compose.raspi.yml |
| Telemetry service (hardware metrics) | RUNNING — streams metrics to VPS `/api/telemetry` |
| ids-pi Python service | RUNNING — minimal (health endpoint only, no IDS logic) |
| threat-intel service | STUBBED — TCP stub, drops all connections |
| WebSocket endpoint authentication | COMPLETE — raspi-collector uses `?api_key=`; dashboard uses `X-API-Key` |
| Blocked IP TTL / expiry | COMPLETE — api-gateway background task expires and broadcasts `unblock_command` |
| Suricata alert feedback loop (VPS side) | PARTIAL — log-processor implemented but not in docker-compose.vps.yml |
| Integration / end-to-end tests | MINIMAL (10%) |
| Production hardening (WS auth, rate limiting) | PARTIAL (60%) — WS auth done, rate limiting done; missing full integration/e2e tests |
| Multi-edge device management | NOT STARTED |

---

## Remaining Work

### Priority 1 — Blocking / security

*(No open blocking items.)*

---

### Priority 2 — Important, not yet blocking

**threat-intel service**
File: `src/services/cloud/threat-intel/src/main.rs`

TCP stub — opens a port and drops every connection. The api-gateway `/api/threat-intel` endpoint works around this with a direct MongoDB aggregate but has no external feed data.

Implement:
- IP/domain reputation lookups from internal MongoDB collection
- Background updater pulling from a public feed (e.g. Abuse.ch Feodo Tracker)
- HTTP API: `GET /threat-intel` → `{ malicious_ips, suspicious_domains, vulnerabilities }`

**Suricata Alert Feedback Loop (VPS side)**
`src/services/cloud/log-processor/` has a full Rust implementation but is not yet added to `docker-compose.vps.yml`. Without it, Suricata alerts from `packet-analyzer` on the VPS are not ingested into MongoDB or shown in the dashboard.

Add log-processor to `docker-compose.vps.yml` and wire it to POST to `/api/alerts/ingest`.

**vps-processor still in workspace**
`src/services/cloud/vps-processor/` is not referenced by any compose file. Either integrate it or remove it from `Cargo.toml` workspace members to keep the build clean.

---

### Priority 3 — Nice to have / operational improvements

**ids-pi IDS logic**
File: `src/services/edge/ids-pi/app.py`

58 lines — only responds to `/health` and `/`. No nuclei scanning or scheduled security checks.

Either implement nuclei scan scheduler and POST results to VPS `/api/alerts/ingest`, or remove the service from compose and docs if Suricata covers this use case.

---

### Priority 4 — Hardening & Production-readiness

**Integration / End-to-end Tests**
No automated tests cover the Pi→VPS event path.

Add:
- Integration test: spin up api-gateway + mock Pi collector, POST a crafted event, assert it appears in MongoDB
- Unit tests for rule-engine parser (valid + malformed Suricata rule strings)
- Unit tests for packet-processor blocked_ips matcher

**Monitoring stack compose**
Prometheus and Grafana configs exist in `ops/monitoring/` but there is no `docker-compose` file to run them. Add a `docker-compose.monitoring.yml` (or extend `docker-compose.vps.yml`) so the monitoring stack is reproducible alongside the IDPS stack.

---

## Known Limitations

| Item | Note |
|---|---|
| `threat-intel` stub | All threat intelligence data comes from MongoDB aggregates only; no external feed |
| `ids-pi` minimal | No IDS logic — just a health endpoint |
| `log-processor` not in compose | `packet-analyzer` alerts on VPS are not ingested into MongoDB/dashboard |
| `vps-processor` dead code | Not referenced by any compose file; still in Cargo workspace |
| No monitoring compose | Prometheus/Grafana configs in `ops/monitoring/` have no docker-compose to run them |
| `raspi-collector` reconnect backoff | Fixed 5 s wait on VPS disconnect — should use exponential backoff with jitter |
| No integration tests | Pi→VPS event path has no automated test coverage |
