# Suricata IDPS Docker image
# Multi-stage build for optimized image size
FROM docker.io/library/debian:bookworm-slim AS builder

# Build arguments
ARG BUILD_TYPE=release

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cargo \
    libpcap-dev \
    libnet1-dev \
    liblua5.1-dev \
    libhiredis-dev \
    libpcre2-dev \
    libnss3-dev \
    libmagic-dev \
    liblz4-dev \
    libzstd-dev \
    rustc \
    cmake \
    pkg-config \
    git \
    curl

WORKDIR /build

# Build Suricata
RUN curl -L -o suricata.tar.gz https://www.openinfosecfoundation.org/download/suricata-7.0.5.tar.gz && \
    tar -xzf suricata.tar.gz && \
    cd suricata-7.0.5 && \
    ./configure --prefix=/usr --enable-luajit --enable-hiredis --enable-nfqueue && \
    make -j$(nproc) && \
    make install && \
    make install-conf && \
    ldconfig

# Final stage - minimal runtime image
FROM docker.io/library/debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcap1 \
    libnet1 \
    libhiredis1 \
    liblua5.1 \
    libpcre2-3 \
    ca-certificates \
    iptables \
    && rm -rf /var/lib/apt/lists/*

# Copy built Suricata from builder
COPY --from=builder /usr/bin/suricata /usr/bin/suricata
COPY --from=builder /usr/bin/suricata-update /usr/bin/suricata-update
COPY --from=builder /etc/suricata /etc/suricata

# Create directories
RUN mkdir -p /var/lib/suricata /var/log/suricata /etc/suricata/rules

# Default configuration
COPY suricata.yaml /etc/suricata/suricata.yaml

# Expose ports
EXPOSE 9001/udp

ENTRYPOINT ["/usr/bin/suricata", "-c", "/etc/suricata/suricata.yaml", "-i", "eth0"]
