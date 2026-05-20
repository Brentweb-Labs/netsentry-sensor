FROM rust:1.94-bookworm AS chef
RUN apt-get update && apt-get install -y libpcap-dev libssl-dev pkg-config && rm -rf /var/lib/apt/lists/*
RUN cargo install cargo-chef --locked
WORKDIR /app

FROM chef AS planner
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
ARG BUILD_MODE=debug
COPY --from=planner /app/recipe.json recipe.json
RUN if [ "$BUILD_MODE" = "release" ]; then \
      cargo chef cook --release --recipe-path recipe.json; \
    else \
      cargo chef cook --recipe-path recipe.json; \
    fi
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN if [ "$BUILD_MODE" = "release" ]; then \
      cargo build --release -p idps-packet-processor; \
    else \
      cargo build -p idps-packet-processor; \
    fi

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    libpcap0.8 \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ARG BUILD_MODE=debug
COPY --from=builder /app/target/${BUILD_MODE}/idps-packet-processor /usr/local/bin/idps-packet-processor

EXPOSE 8091

CMD ["idps-packet-processor"]
