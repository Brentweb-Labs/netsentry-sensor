//! IDPS Telemetry Service
//!
//! Collects hardware metrics from the edge device (Raspberry Pi) and streams
//! them to the VPS API Gateway. Exposes a local HTTP API for health checks.

use std::sync::Arc;

mod controllers;
mod models;
mod services;

use controllers::create_router;
use models::AppState;
use services::run_collection_loop;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let device_id = std::env::var("DEVICE_ID").unwrap_or_else(|_| {
        hostname::get()
            .map(|h| h.to_string_lossy().to_string())
            .unwrap_or_else(|_| "raspi-edge".to_string())
    });

    let sensor_id = std::env::var("SENSOR_ID").unwrap_or_else(|_| "default".to_string());
    let tenant_id = std::env::var("TENANT_ID").unwrap_or_else(|_| "default".to_string());

    let vps_url =
        std::env::var("VPS_URL").unwrap_or_else(|_| "http://api-gateway:8080".to_string());

    let api_key = std::env::var("API_KEY").unwrap_or_default();

    let collection_interval_secs: u64 = std::env::var("COLLECTION_INTERVAL_SECS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(10);

    let service_port: u16 = std::env::var("TELEMETRY_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8096);

    tracing::info!(
        "Starting IDPS Telemetry Service — sensor_id={}, tenant_id={}, port={}, vps={}",
        sensor_id,
        tenant_id,
        service_port,
        vps_url
    );

    let state = Arc::new(AppState::new(
        device_id.clone(),
        sensor_id.clone(),
        tenant_id.clone(),
    ));

    // Spawn background collection loop
    let state_bg = state.clone();
    tokio::spawn(run_collection_loop(
        state_bg,
        vps_url,
        api_key,
        collection_interval_secs,
    ));

    // HTTP API
    let app = create_router(state);

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", service_port)).await?;
    tracing::info!(
        "Telemetry HTTP server listening on 0.0.0.0:{}",
        service_port
    );

    axum::serve(listener, app).await?;

    Ok(())
}
