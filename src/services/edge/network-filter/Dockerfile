FROM rust:1.94-bookworm AS chef

RUN apt-get update && apt-get install -y \
    libpcap-dev \
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

# ── Cache-compile all dependencies ───────────────────────────────────────────
FROM chef AS builder
ARG BUILD_MODE=debug
COPY --from=planner /app/recipe.json recipe.json
RUN if [ "$BUILD_MODE" = "release" ]; then \
      cargo chef cook --release --recipe-path recipe.json; \
    else \
      cargo chef cook --recipe-path recipe.json; \
    fi

# ── Build only application source ────────────────────────────────────────────
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN if [ "$BUILD_MODE" = "release" ]; then \
      cargo build --release -p idps-network-filter; \
    else \
      cargo build -p idps-network-filter; \
    fi

FROM debian:bookworm-slim

# Install runtime dependencies including iptables
RUN apt-get update && apt-get install -y \
    libpcap-dev \
    iptables \
    iproute2 \
    util-linux \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user (but will run as root for iptables)
RUN useradd -m -u 1000 networkfilter

WORKDIR /app

ARG BUILD_MODE=debug
COPY --from=builder /app/target/${BUILD_MODE}/idps-network-filter /usr/local/bin/idps-network-filter

# Set permissions
RUN chmod +x /usr/local/bin/idps-network-filter

# Create log directory
RUN mkdir -p /var/log/network-filter && \
    chown -R networkfilter:networkfilter /var/log/network-filter

# Expose port for API
EXPOSE 8092

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8092/health || exit 1

# Run as root for iptables operations
USER root

CMD ["idps-network-filter"]
