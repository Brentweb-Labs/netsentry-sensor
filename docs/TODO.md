# NetSentry Sensor - Technical Roadmap

This document serves as the basis for GitHub issue creation. Each section corresponds to an issue title, with bullet points forming the issue description.

---

## Critical (Must Fix)

### 1. Automatic Blocking Implementation
- Add `AUTO_BLOCK_THRESHOLD` and `AUTO_BLOCK_ENABLED` environment variables
- Implement automatic iptables block when threat score exceeds configured threshold
- Add block duration TTL with exponential backoff for repeated offenders
- Implement fail-open mode when network-filter service is unreachable

### 2. Shell Script Consolidation
- Consolidate setup scripts (`scripts/setup-bridge*.sh`) into container entrypoint
- Make all configuration declarative via environment variables
- Ensure idempotent execution for repeatable deployments

### 3. BYO Cloud (Bring Your Own Cloud) Support
- Add support for custom cloud endpoint configuration per sensor
- Implement multi-endpoint failover mechanism (primary to backup)
- Add tenant and organization isolation for MSP (Managed Service Provider) support

---

## High (Important)

### 4. Threat Intelligence Service
- Implement threat-intel service with external feed integration (Abuse.ch Feodo Tracker)
- Add IP and domain reputation lookups against MongoDB collection
- Implement background updater for automated feed refresh

### 5. Log-Processor Deployment
- Add log-processor service to docker-compose.vps.yml
- Ensure packet-analyzer alerts reach MongoDB and dashboard

### 6. Performance Optimization for Pi
- Add memory limits tuning for Suricata on Pi 4GB configuration
- Optimize MongoDB indexing for query performance
- Implement batch event posting to reduce HTTP overhead

### 7. Dev-Test Environment Integration
- Verify Docker dev-test environment connects to actual service implementations
- Test complete edge service stack without physical hardware

---

## Medium (Nice to Have)

### 8. Integration Test Suite
- Implement testcontainers for MongoDB and Redis
- Create mock VPS for cloud integration testing

### 9. Monitoring Stack Compose
- Add docker-compose.monitoring.yml for Prometheus and Grafana

### 10. IDS-Pi Service Resolution
- Implement nuclei scanning functionality or remove service from compose

---

## Completed

- Basic edge services (network-filter, raspi-collector, rule-engine)
- Docker compose configuration for Pi and VPS
- WireGuard VPN tunnel
- Event ingest pipeline (Pi to VPS to MongoDB)
- WebSocket real-time updates
- Block and unblock command infrastructure
- Basic telemetry service

---

## Next Sprint - Quick Wins

1. Add `AUTO_BLOCK_ENABLED` environment variable to raspi-collector
2. Add block duration configuration
3. Consolidate setup scripts into single entrypoint
4. Document BYOC API specification for business integrations
