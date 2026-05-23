# IDPS — Development Guide

## Building

### Rust (sensor services)

The sensor (`netsentry-sensor`) is a separate Rust workspace from the cloud. Build from within this repo:

```bash
cargo check --workspace                    # fast type-check, no binaries
cargo build --workspace                    # build all edge services
cargo build -p idps-raspi-collector        # single service
cargo build -p idps-network-filter
cargo build -p idps-rule-engine
cargo build --workspace --release          # optimised — used by Dockerfiles
```

Cross-compiling for ARM64 on x86 host:
```bash
rustup target add aarch64-unknown-linux-gnu
cargo build --workspace --release --target aarch64-unknown-linux-gnu
```

> Cloud services (`api-gateway`, `threat-intel`, etc.) live in the `netsentry-cloud` repo and have their own workspace.

### Angular edge dashboard

```bash
cd src/tools/dashboard
npm install          # first time only
npm run start        # dev server at http://localhost:4200
npm run build        # production build → dist/ng-tailadmin/browser/
```

> Production build **must** use `npm run build` (not `ng serve`) — it activates `fileReplacements` in `angular.json` that swaps `environment.ts` for `environment.prod.ts`. Without this, `localhost` URLs ship to production.

---

## Testing

```bash
cargo test --workspace
cargo test -p idps-raspi-collector
cargo test -- --nocapture
```

---

## Local dev workflow

```bash
export RUST_LOG=debug

# Local MongoDB for raspi-collector (Pi stack uses mongo 4.4.18 in prod)
docker run -d -p 27017:27017 --name mongodb mongo:7.0

# Run collector against a local VPS (point to your cloud instance or localhost)
export VPS_API_URL=http://localhost:8080
cargo run -p idps-raspi-collector

# Dashboard (separate terminal)
cd src/tools/dashboard && npm run start
```

Or bring up the full Pi stack:
```bash
docker compose -f docker-compose.raspi.yml up -d
docker compose -f docker-compose.raspi.yml logs -f raspi-collector
```

---

## Code quality

```bash
cargo fmt --all
cargo clippy --workspace -- -D warnings
cargo audit
```

---

## Adding a new service

1. Create `src/services/edge/my-service/` or `src/services/cloud/my-service/`
2. Add `Cargo.toml` with `{ workspace = true }` deps
3. Add path to `[workspace] members` in root `Cargo.toml`
4. Add a `Dockerfile` (copy from a similar service)
5. Add to the relevant compose file with `networks: - idps-net`
6. If publicly reachable: add `- proxy` network + Traefik labels

---

## Gotchas

**Axum 0.8**
- Route params use `{param}` syntax, not `:param`
- `Message::Text` requires `Utf8Bytes` — use `.into()` on `String`
- Middleware state is separate from app state — use `from_fn_with_state`

**Tailwind CSS v4 `@apply` in component styles**
Any component `.css` using `@apply` must start with:
```css
@reference "../../../../styles.css";
```
Without this the build fails with `Cannot apply unknown utility class`.
