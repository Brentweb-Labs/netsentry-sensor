# Project Structure (trimmed)

A quick tour of the repo after cleanup. Use this as the source of truth for where to put things.

```
.
├── docker-compose.raspi.yml        # Edge stack (Pi bridge + Suricata + collectors)
├── docker-compose.vps.yml          # Cloud stack (API gateway + processors + dashboard)
├── src/                            # Rust workspace (services share crates in shared/)
│   ├── services/
│   │   ├── cloud/                  # VPS-side services (api-gateway, processors)
│   │   └── edge/                   # Pi-side services (collector, network-filter)
│   └── shared/                     # Common types, config, protocols
├── scripts/                        # Human-facing entrypoints (prefer these)
│   ├── idps-manager.sh             # Single CLI for deploy/status/fix/menu
│   ├── setup/                      # One-time setup helpers
│   │   ├── setup-bridge-unified.sh # Create/inspect br0 (eth0↔eth1)
│   │   ├── setup-wireguard-pi.sh   # Pi WireGuard peer helper
│   │   └── setup-wireguard-vps.sh  # VPS WireGuard peer helper
│   ├── diagnostics/                # Targeted health/fix scripts (dns, iptables, suricata)
│   └── deployment/                 # Legacy deploy wrappers (prefer manager)
├── config/                         # Configuration shipped with the repo
│   ├── network/                    # Bridge/systemd configs examples
│   ├── nginx/                      # Nginx reverse proxy snippets
│   ├── suricata/                   # Suricata rules + suricata.yaml
│   └── tls/                        # TLS notes/placeholders
├── docs/                           # Documentation (start here)
│   ├── SETUP.md                    # Quick deploy runbook (VPS + Pi)
│   ├── PROJECT_STRUCTURE.md        # This file
│   ├── ARCHITECTURE.md             # Deep dive: components, flows, diagrams
│   ├── OPERATIONS.md               # Day-2 ops, endpoints, troubleshooting
│   ├── DEVELOPMENT.md              # Contributor workflow
│   ├── PI_BRIDGE_SETUP.md          # Bridge + WireGuard pairing guide
│   └── BACKLOG.md / TODO.md        # Open work items
├── ops/                            # Advanced ops (Prom/Grafana configs — no compose yet)
│   ├── config/                     # Alt configs (logrotate, suricata, nginx)
│   ├── monitoring/                 # Prometheus scrape config + Grafana dashboards/datasources
│   └── scripts/                    # Older deploy/maintenance scripts (reference docker-compose.yml — stale, use manager)
├── rules/                          # Custom Suricata rules (bind-mounted)
├── generate-env.sh                 # Generates .env with random secrets from .env.example
├── setup-raspi.sh                  # Legacy setup script (root) — superseded by idps-manager.sh
└── .env.example                    # Canonical environment template
```

## Scripts you should use
- `scripts/idps-manager.sh` — single entrypoint for deploy/status/fix commands.
- `scripts/setup/setup-bridge-unified.sh` — one-time Pi bridge creation (eth0↔eth1).
- `scripts/setup/setup-wireguard-{pi,vps}.sh` — helper for WireGuard peer config.

## Scripts still at repo root (legacy)
- `setup-raspi.sh` — legacy all-in-one setup script; superseded by `scripts/idps-manager.sh`. Keep for reference or delete if no longer needed.
- `generate-env.sh` — generates a `.env` file from `.env.example` with random secrets; still useful.
- `validate-raspi-pi.sh` and `test-data-flow.sh` were deleted. Use `idps-manager.sh` for equivalent operations.

## When in doubt
1. Check [SETUP.md](SETUP.md) for deployment.
2. Use `idps-manager.sh` for anything operational.
3. If you need a diagram or component explanation, read [ARCHITECTURE.md](ARCHITECTURE.md).
