# Base Dockerfile for Rust edge services
# Supports both prebuilt binaries and local build
#
# Build args:
#   SERVICE_NAME: name of the service (e.g., idps-network-filter)
#   GITHUB_ORG: GitHub organization (default: yourorg)
#   USE_PREBUILT: true/false - whether to try downloading prebuilt first

FROM rust:1.94-bookworm AS chef

RUN apt-get update && apt-get install -y \
    libpcap-dev \
    libssl-dev \
    pkg-config \
    curl \
    && rm -rf /var/lib/apt/lists/*
RUN cargo install cargo-chef --locked

WORKDIR /app

# ── Compute dependency recipe ─────────────────────────────────────────────────
FROM chef AS planner
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY Makefile ./
RUN cargo chef prepare --recipe-path recipe.json

# ── Cache-compile all dependencies ───────────────────────────────────────────
FROM chef AS builder
ARG BUILD_MODE=release
ARG SERVICE_NAME=""
ARG GITHUB_ORG=yourorg
ARG USE_PREBUILT=true

# Try to download prebuilt binary first
RUN if [ "$USE_PREBUILT" = "true" ]; then \
    ARCH=$(echo $(rustc -vV | grep host | cut -d' ' -f2) | tr '-' '_'); \
    curl -sL "https://github.com/${GITHUB_ORG}/netsentry-sensor/releases/latest/download/${SERVICE_NAME}-${ARCH}.tar.gz" | tar -xzf - -C /tmp/prebuilt 2>/dev/null && echo "Downloaded prebuilt for ${SERVICE_NAME}" || echo "No prebuilt found, building locally"; \
    fi

COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json

# ── Build only application source ────────────────────────────────────────────
COPY Cargo.toml Cargo.lock ./
COPY src ./src

# Check if we got prebuilt - if so, just touch the source to update timestamps
RUN if [ -f /tmp/prebuilt/${SERVICE_NAME} ]; then \
    echo "Using prebuilt binary" && cp /tmp/prebuilt/${SERVICE_NAME} /app/target/release/${SERVICE_NAME}; \
  else \
    cargo build --release -p ${SERVICE_NAME}; \
  fi

# Final minimal runtime image
FROM debian:bookworm-slim

ARG SERVICE_NAME=""

RUN apt-get update && apt-get install -y \
    libpcap1 \
    iptables \
    iproute2 \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy binary (either from prebuilt or built)
COPY --from=builder /app/target/release/${SERVICE_NAME} /usr/local/bin/${SERVICE_NAME}

RUN chmod +x /usr/local/bin/${SERVICE_NAME}

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

CMD ["${SERVICE_NAME}"]
