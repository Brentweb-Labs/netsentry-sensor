# NetSentry Sensor — Development Guide

## Building

### Rust workspace

```bash
cargo check --workspace                    # fast type-check
cargo build --workspace                    # debug build
cargo build -p idps-raspi-collector        # single crate
cargo build -p idps-network-filter
cargo build -p idps-rule-engine
cargo build --workspace --release          # optimised — used by Dockerfiles
```

**Cross-compiling for arm64 on an x86_64 host:**

```bash
rustup target add aarch64-unknown-linux-gnu
# Install the linker: apt install gcc-aarch64-linux-gnu
cargo build --workspace --release --target aarch64-unknown-linux-gnu
```

> Cloud services (`api-gateway`, `threat-intel`, etc.) live in `netsentry-cloud` and have their own workspace.

### Local edge Angular dashboard

```bash
cd src/tools/dashboard
npm install
npm run start     # dev server — http://localhost:4200
npm run build     # production build → dist/ng-tailadmin/browser/
```

> Always use `npm run build` for production — it activates `fileReplacements` in `angular.json` that substitutes `environment.ts` with `environment.prod.ts`. Without this, localhost API URLs ship to production.

---

## Testing

```bash
cargo test --workspace
cargo test -p idps-raspi-collector
cargo test -- --nocapture          # show println! output
```

---

## Local Dev Workflow

```bash
export RUST_LOG=debug

# Start a local MongoDB (the edge stack uses mongo:4.4.18 for ARM64 compatibility)
docker run -d -p 27017:27017 --name mongodb mongo:7.0

# Run collector against your cloud instance (or a local mock)
export VPS_API_URL=http://localhost:8080
cargo run -p idps-raspi-collector

# Local dashboard in a separate terminal
cd src/tools/dashboard && npm run start
```

Or bring up the full edge stack:

```bash
cp .env.example .env  # fill in required vars
docker compose -f docker-compose.raspi.yml up -d
docker compose -f docker-compose.raspi.yml logs -f raspi-collector
```

---

## Code Quality

```bash
cargo fmt --all
cargo clippy --workspace -- -D warnings
cargo audit
```

---

## Adding a New Service

1. Create `src/services/edge/my-service/` or `src/services/cloud/my-service/`
2. Add a `Cargo.toml` using `{ workspace = true }` for shared deps
3. Add the path to `[workspace] members` in the root `Cargo.toml`
4. Add a `Dockerfile` (copy from a similar service, e.g. `raspi-collector`)
5. Add the service to the relevant compose file with `networks: - idps-net`
6. If publicly reachable, also add the `proxy` network + Traefik labels

---

## Gotchas

**Axum 0.8**
- Route params use `{param}` syntax, not `:param`
- `Message::Text` requires `Utf8Bytes` — use `.into()` on `String`
- Middleware state is separate from app state — use `from_fn_with_state`

**Tailwind CSS v4 `@apply` in component styles**
Any component `.css` file using `@apply` must start with:
```css
@reference "../../../../styles.css";
```
Without this line the build fails with `Cannot apply unknown utility class`.

**ARM64 MongoDB**
The compose file defaults to `mongo:4.4.18` for ARM64 compatibility (Cortex-A72 lacks AVX). x86_64 dev machines should override this:
```bash
MONGO_IMAGE=mongo:7.0 docker compose -f docker-compose.raspi.yml up -d
```

**`CAPTURE_INTERFACE` vs `SURICATA_IFACE`**
Both must be set to the same interface in `.env`. `CAPTURE_INTERFACE` is used by `packet-processor`; `SURICATA_IFACE` is used by the Suricata container entrypoint. They are intentionally separate to allow future divergence.

**`docker-compose.raspi.yml` — no `platform:` directives**
The compose file does not pin `platform:`. Docker auto-detects the host architecture. On ARM64 hosts Docker pulls ARM64 images; on x86_64 it pulls amd64 images. The `mongo:4.4.18` image is available for both.
