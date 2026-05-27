.PHONY: help build build-edge build-cloud build-shared test lint format clean dev-setup security-audit docs build-download-deps

# Configuration
ARCH := $(shell uname -m)
ifeq ($(ARCH),x86_64)
	RUST_TARGET := x86_64-unknown-linux-gnu
	BINARY_PREFIX := netsentry-sensor-x86_64
else ifeq ($(ARCH),aarch64)
	RUST_TARGET := aarch64-unknown-linux-gnu
	BINARY_PREFIX := netsentry-sensor-aarch64
else
	RUST_TARGET := $(shell rustc -vV | grep host | cut -d' ' -f2)
	BINARY_PREFIX := netsentry-sensor-$(ARCH)
endif

# GitHub release URL (update for your org)
RELEASE_URL := https://api.github.com/repos/yourorg/netsentry-sensor/releases/latest

help:
	@echo "Available targets:"
	@echo "  build          - Build all services (release)"
	@echo "  build-edge     - Build Pi-side services"
	@echo "  build-cloud    - Build VPS-side services"
	@echo "  build-shared   - Build shared libraries"
	@echo "  build-download - Download prebuilt binaries (default if available)"
	@echo "  build-local    - Force local build (skip prebuilt)"
	@echo "  test           - Run all tests"
	@echo "  lint           - Run clippy + fmt check"
	@echo "  format         - Format all code"
	@echo "  clean          - Clean build artifacts"
	@echo "  dev-setup      - Install cargo-watch, cargo-audit, cargo-deny"
	@echo "  security-audit - Run cargo audit"
	@echo "  docs           - Generate and open rustdoc"

# Default: use prebuilt if available, otherwise build locally
build:
	@echo "Building NetSentry sensor (using prebuilt binaries if available)..."
	@$(MAKE) build-download DEPLOY_MODE=prebuilt && echo "Using prebuilt binaries" || $(MAKE) build-local

build-download:
	@echo "Checking for prebuilt binaries for $(RUST_TARGET)..."
	@mkdir -p target/release
	@curl -sL $(RELEASE_URL)/assets | grep -o 'https://.*$(BINARY_PREFIX).*\.tar\.gz' | head -1 | xargs -r curl -sL | tar -xzf - -C target/release/ 2>/dev/null && \
		echo "Downloaded prebuilt binaries" || \
		{ echo "No prebuilt binaries found, will build locally"; exit 1; }

build-local:
	@echo "Building locally (this takes ~20-30 minutes on first build)..."
	cargo build --workspace --release

build-edge:
	@echo "Building edge services..."
	@$(MAKE) build-download DEPLOY_MODE=prebuilt 2>/dev/null && echo "Using prebuilt" || \
	cargo build --release \
	  -p idps-packet-processor \
	  -p idps-network-filter \
	  -p idps-rule-engine \
	  -p raspi-collector \
	  -p idps-telemetry

build-cloud:
	cargo build --release \
	  -p idps-api-gateway \
	  -p idps-packet-analyzer \
	  -p idps-threat-intel \
	  -p idps-rule-generator \
	  -p idps-log-processor

build-shared:
	cargo build --release \
	  -p idps-types \
	  -p idps-protocols \
	  -p idps-utils \
	  -p idps-config

test:
	cargo test --workspace

lint:
	cargo clippy --workspace -- -D warnings
	cargo fmt --check

format:
	cargo fmt --all

clean:
	cargo clean

dev-setup:
	cargo install cargo-watch cargo-audit cargo-deny

security-audit:
	cargo audit

docs:
	cargo doc --workspace --open
