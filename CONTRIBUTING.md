# Contributing to NetSentry Sensor

Thank you for your interest in contributing. This document covers how to get set up, what areas need work, and how to submit changes.

---

## What this repo contains

NetSentry Sensor is the **open-source edge component** of the NetSentry platform. It is a Rust workspace containing:

- **Shared libraries** (`src/shared/`): types, protocols, config, utilities
- **Edge services** (`src/services/edge/`): Rust binaries that run on the sensor node
- **Local dashboard** (`src/tools/dashboard/`): Angular app served from the sensor
- **Setup scripts** (`scripts/`): shell scripts for deployment and bridge configuration
- **Config templates** (`config/suricata/`): Suricata configuration

The cloud backend lives in a **private** repository and is not part of this codebase.

---

## Getting Started

### Prerequisites

- Rust toolchain (stable, via [rustup](https://rustup.rs/))
- Docker 24+ with the Compose plugin
- Node.js 20+ (for the Angular dashboard only)
- A Linux system for packet capture development (libpcap headers: `apt install libpcap-dev`)

### Build

```bash
git clone https://github.com/yourorg/netsentry-sensor.git
cd netsentry-sensor

# Check everything compiles
cargo check --workspace

# Run tests
cargo test --workspace

# Build all services
cargo build --workspace --release
```

### Local dev environment

```bash
cp .env.example .env
# Set VPS_API_URL to your cloud instance or a local mock

# Bring up only the infrastructure (MongoDB + Redis)
docker compose -f docker-compose.raspi.yml up -d mongodb redis

# Run a service directly
export RUST_LOG=debug
cargo run -p idps-raspi-collector
```

---

## Code Structure

```
src/
├── shared/
│   ├── types/       Core structs — Packet, AlertEvent, SecurityRule, etc.
│   ├── protocols/   WebSocket message types — BlockCommand, RuleUpdate, CommandAck
│   ├── utils/       Shared utilities — IP/CIDR, retry, logging, time
│   └── config/      EdgeConfig and CloudConfig with env-var loading
└── services/
    └── edge/
        ├── packet-processor/  libpcap capture → WebSocket stream
        ├── raspi-collector/   eve.json tailer + cloud command bridge
        ├── network-filter/    iptables enforcement (inline mode)
        ├── firewall-forwarder/ router API relay (SPAN mode)
        ├── rule-engine/       Suricata rule management
        └── telemetry/         hardware metrics
```

Each service follows the same structure:
- `src/main.rs` — entry point, spawns async tasks, starts HTTP server
- `src/services/mod.rs` — core background tasks
- `src/controllers/mod.rs` — HTTP route handlers
- `src/models/mod.rs` — service-specific state structs
- `Dockerfile` — multi-stage build producing a minimal binary

---

## Development Guidelines

**Correctness over completeness.** If something doesn't work reliably, it's a bug — fix it before adding new features.

**Fail-open.** Any change to the packet path must preserve the fail-open guarantee: sensor failures must never disrupt user network traffic.

**No platform-specific assumptions.** The sensor must run on any Linux system — x86_64 or arm64. Avoid Raspberry Pi-specific code or ARM-only paths without a fallback.

**Minimal dependencies.** Add a new crate only when the standard library or an existing dependency can't do the job.

**No comments explaining what the code does.** Name things clearly instead. Only comment *why* something is done in a non-obvious way.

---

## Adding a New Edge Service

1. Create `src/services/edge/my-service/Cargo.toml`:
   ```toml
   [package]
   name = "idps-my-service"
   version.workspace = true
   edition.workspace = true

   [[bin]]
   name = "idps-my-service"
   path = "src/main.rs"

   [dependencies]
   # Use workspace = true for shared deps
   ```
2. Add `"src/services/edge/my-service"` to `[workspace] members` in the root `Cargo.toml`
3. Copy a `Dockerfile` from a similar service (e.g. `raspi-collector`)
4. Add a service entry to `docker-compose.raspi.yml`
5. Add a health check endpoint at `GET /health`

---

## Pull Request Process

1. Fork the repository and create a branch: `git checkout -b feature/my-feature`
2. Make your changes and ensure `cargo check --workspace`, `cargo test --workspace`, and `cargo clippy --workspace -- -D warnings` all pass
3. Format: `cargo fmt --all`
4. Open a PR against `main` with a clear description of what changed and why
5. For bug fixes, include a minimal reproduction case in the PR description

PRs that break the fail-open guarantee, introduce hardcoded IPs/domains, or remove multi-arch support will not be merged.

---

## Reporting Bugs

Open a GitHub issue with:
- What you expected to happen
- What actually happened
- Your OS and architecture (`uname -m`)
- Docker version (`docker compose version`)
- Relevant logs (`docker compose -f docker-compose.raspi.yml logs --tail=50 <service>`)

---

## Areas That Need Work

- [ ] GitHub Actions CI pipeline (build + test on push, Docker image releases for amd64 + arm64)
- [ ] Automated integration tests against a mock cloud API
- [ ] Suricata rule validation in `rule-engine` before writing to disk
- [ ] Graceful shutdown handling in all services
- [ ] `raspi-collector` batch event buffering with configurable flush interval
- [ ] Dashboard: real-time charts for packet rates and blocked IPs
- [ ] Helm chart / Kubernetes deployment option for datacenter deployments

---

## License

By contributing you agree that your contributions are licensed under the same [MIT License](LICENSE) as the project.
