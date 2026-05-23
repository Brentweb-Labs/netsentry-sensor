FROM rust:1.94-bookworm AS chef

RUN apt-get update && apt-get install -y \
    libssl-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*
RUN cargo install cargo-chef --locked

WORKDIR /app

# ── Compute dependency recipe ─────────────────────────────────────────────────
FROM chef AS planner
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo chef prepare --recipe-path recipe.json

# ── Cache-compile all dependencies ────────────────────────────────────────────
FROM chef AS builder
ARG BUILD_MODE=debug
COPY --from=planner /app/recipe.json recipe.json
RUN if [ "$BUILD_MODE" = "release" ]; then \
      cargo chef cook --release --recipe-path recipe.json; \
    else \
      cargo chef cook --recipe-path recipe.json; \
    fi

# ── Build only application source ─────────────────────────────────────────────
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN if [ "$BUILD_MODE" = "release" ]; then \
      cargo build --release -p idps-rule-engine; \
    else \
      cargo build -p idps-rule-engine; \
    fi

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ARG BUILD_MODE=debug
COPY --from=builder /app/target/${BUILD_MODE}/idps-rule-engine /usr/local/bin/idps-rule-engine

RUN chmod +x /usr/local/bin/idps-rule-engine

RUN mkdir -p /etc/suricata/rules /var/log/idps/rule-engine

EXPOSE 8094

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8094/health || exit 1

USER root

CMD ["idps-rule-engine"]
