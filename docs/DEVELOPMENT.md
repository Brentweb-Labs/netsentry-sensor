# IDPS — Development Guide

## Building

### Rust
```bash
cargo check --workspace                    # fast check, no binaries
cargo build --workspace                    # build everything
cargo build -p idps-api-gateway            # single service
cargo build --workspace --release          # optimised for deployment
```

### Angular dashboard
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
cargo test -p idps-api-gateway
cargo test -- --nocapture
```

---

## Local dev workflow

```bash
export RUST_LOG=debug

# Spin up dependencies
docker run -d -p 27017:27017 --name mongodb mongo:7.0
docker run -d -p 6379:6379 --name redis redis:7.4-alpine

# API Gateway
cargo run -p idps-api-gateway

# Dashboard (separate terminal) — proxies /api/vps → localhost:8080
cd src/tools/dashboard && npm run start
```

Or use the full VPS stack:
```bash
docker compose -f docker-compose.vps.yml up -d
docker compose -f docker-compose.vps.yml logs -f api-gateway
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
