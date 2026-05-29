# Project Structure

A quick tour of the repository. Use this as the source of truth for where to put things.

```
netsentry-sensor/
│
├── setup.sh                           ← MAIN ENTRY POINT — all setup & runtime commands
│
├── docker-compose.raspi.yml           # Full sensor stack (all edge services)
├── docker-compose.span.yml            # SPAN topology overrides (compose alongside raspi.yml)
│
├── .env.example                       # Environment template — copy to .env
├── .gitignore
│
├── src/                               # Rust workspace
│   ├── shared/
│   │   ├── types/                     # Core structs (Packet, AlertEvent, SecurityRule…)
│   │   ├── protocols/                 # WebSocket message types (BlockCommand, RuleUpdate…)
│   │   ├── utils/                     # IP/CIDR, retry, logging, time utilities
│   │   └── config/                    # EdgeConfig, CloudConfig with env-var loading
│   ├── services/
│   │   └── edge/
│   │       ├── packet-processor/      # libpcap capture → fail-open WebSocket stream
│   │       ├── raspi-collector/       # Tails eve.json + cloud command bridge
│   │       ├── network-filter/        # iptables DROP enforcement (inline mode)
│   │       ├── firewall-forwarder/    # Router API relay (SPAN mode)
│   │       ├── rule-engine/           # Suricata dynamic rule management
│   │       └── telemetry/             # Hardware metrics reporter
│   └── tools/
│       └── dashboard/                 # Angular local dashboard
│
├── scripts/
│   ├── build.sh                       # Build Rust services (local or download prebuilt)
│   ├── netsentry.service              # systemd unit for auto-start on boot
│   ├── idps-bridge.service            # systemd unit for inline bridge (optional)
│   ├── mongo-init.js                  # MongoDB initialisation (used by docker compose)
│   └── setup/
│       ├── setup.sh                   # One-line remote installer (curl | bash target)
│       ├── setup-wireguard-pi.sh      # Interactive WireGuard setup — sensor side
│       ├── setup-wireguard-vps.sh     # Interactive WireGuard setup — cloud server side
│       ├── setup-bridge-unified.sh    # Inline bridge setup (eth0 → eth1)
│       └── setup-span-port.sh         # SPAN mirror port verification
│
├── config/
│   └── suricata/
│       └── suricata.yaml              # Suricata engine configuration
│
└── docs/
    ├── README.md                      # Docs index
    ├── SETUP.md                       # Step-by-step deploy guide
    ├── ARCHITECTURE.md                # System design, topologies, event flows
    ├── SPAN_TOPOLOGY.md               # SPAN / out-of-band monitoring (default)
    ├── PI_BRIDGE_SETUP.md             # Inline bridge (alternative topology)
    ├── WIREGUARD_SETUP.md             # WireGuard key exchange guide
    ├── OPERATIONS.md                  # Env vars, API endpoints, day-2 commands
    ├── DEVELOPMENT.md                 # Build, test, contribute
    └── CLOUD_SETUP.md                 # Self-hosting the cloud backend
```

---

## The one script to know

```bash
./setup.sh help
```

`setup.sh` at the repo root is the single entry point for everything:

| Command | What it does |
|---|---|
| `./setup.sh install` | Install Docker, start the stack, register systemd service |
| `./setup.sh wireguard` | Interactive WireGuard setup for this sensor node |
| `./setup.sh wireguard-cloud` | Interactive WireGuard setup for the cloud server |
| `./setup.sh bridge [revert\|status]` | Inline bridge setup / management |
| `./setup.sh span [status]` | Verify SPAN / switch port mirroring |
| `./setup.sh up` | `docker compose up -d` |
| `./setup.sh down` | `docker compose down` |
| `./setup.sh restart [service]` | Restart all or one service |
| `./setup.sh logs [service]` | Follow logs |
| `./setup.sh status` | Health overview (containers + WireGuard + eve.json) |
| `./setup.sh diagnose` | Full diagnostic run |
| `./setup.sh build` | Build Rust services from source |

The scripts in `scripts/setup/` are invoked by `setup.sh` — you normally don't call them directly.

---

## When in doubt

1. Read [SETUP.md](SETUP.md) for deployment.
2. Run `./setup.sh status` or `./setup.sh diagnose` for operational issues.
3. Read [ARCHITECTURE.md](ARCHITECTURE.md) for component diagrams.
