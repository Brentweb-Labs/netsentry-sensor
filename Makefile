.PHONY: help build build-edge build-cloud build-shared test lint format clean dev-setup security-audit docs

help:
	@echo "Available targets:"
	@echo "  build          - Build all services (release)"
	@echo "  build-edge     - Build Pi-side services"
	@echo "  build-cloud    - Build VPS-side services"
	@echo "  build-shared   - Build shared libraries"
	@echo "  test           - Run all tests"
	@echo "  lint           - Run clippy + fmt check"
	@echo "  format         - Format all code"
	@echo "  clean          - Clean build artifacts"
	@echo "  dev-setup      - Install cargo-watch, cargo-audit, cargo-deny"
	@echo "  security-audit - Run cargo audit"
	@echo "  docs           - Generate and open rustdoc"

build:
	cargo build --workspace --release

build-edge:
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
