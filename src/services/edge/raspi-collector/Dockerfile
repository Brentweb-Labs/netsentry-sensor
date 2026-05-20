FROM rust:1.94-bookworm AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy Cargo files
COPY Cargo.toml ./
COPY Cargo.lock* ./

# Copy source code
COPY src ./src

# Build the application
ARG BUILD_MODE=debug
RUN if [ "$BUILD_MODE" = "release" ]; then \
      cargo build --release -p raspi-collector; \
    else \
      cargo build -p raspi-collector; \
    fi

# Runtime stage
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create app user
RUN useradd -r -s /bin/false appuser

# Copy binary from builder stage
ARG BUILD_MODE=debug
COPY --from=builder /app/target/${BUILD_MODE}/raspi-collector /usr/local/bin/

# Create log directory
RUN mkdir -p /var/log/raspi-collector && chown appuser:appuser /var/log/raspi-collector

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 8091

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8091/health || exit 1

# Run the application
CMD ["raspi-collector"]
