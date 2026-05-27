//! Raspi Collector Service - coordinates between VPS and local services.

use std::sync::Arc;

use reqwest::Client;
use log::info;

mod controllers;
mod models;
mod services;

use controllers::create_router;
use models::{AppState, CollectorMetrics, ConnectionMonitor, WsDebugState};
use services::{run_vps_command_listener, start_connection_monitoring, tail_eve_json};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    env_logger::init();

    info!("Starting Raspi Collector Service");

    let vps_endpoint =
        std::env::var("VPS_ENDPOINT").unwrap_or_else(|_| "http://vps-processor:8093".to_string());
    let api_key = std::env::var("API_KEY").unwrap_or_default();

    let vps_client = Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;

    let vps_ws_url_for_debug = std::env::var("VPS_WS_URL")
        .unwrap_or_else(|_| "wss://idps.brentweb.eu/ws/raspi".to_string());
    let network_filter_url_for_debug = std::env::var("NETWORK_FILTER_URL")
        .unwrap_or_else(|_| "http://localhost:8092/api/v1".to_string());

    let state = Arc::new(AppState::new(
        vps_client.clone(),
        CollectorMetrics::default(),
        vps_endpoint.clone(),
        api_key.clone(),
        ConnectionMonitor::default(),
        WsDebugState::new(&vps_ws_url_for_debug, &network_filter_url_for_debug),
    ));

    let app = create_router(state.clone());

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
    info!("Raspi Collector listening on 0.0.0.0:8080");
    info!("Forwarding events to VPS at: {}", vps_endpoint);

    // Spawn background tasks
    let vps_ws_url = std::env::var("VPS_WS_URL")
        .unwrap_or_else(|_| "wss://idps.brentweb.eu/ws/raspi".to_string());
    let network_filter_url = std::env::var("NETWORK_FILTER_URL")
        .unwrap_or_else(|_| "http://localhost:8092/api/v1".to_string());
    let ws_http_client = Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;

    let vps_ws_url_auth = if state.api_key.is_empty() {
        vps_ws_url
    } else {
        format!("{}?api_key={}", vps_ws_url, state.api_key)
    };

    let connection_monitor = state.connection_monitor.clone();
    let vps_client_for_monitor = vps_client.clone();
    let vps_endpoint_for_monitor = vps_endpoint.clone();
    tokio::spawn(start_connection_monitoring(
        connection_monitor,
        vps_client_for_monitor,
        vps_endpoint_for_monitor,
    ));

    tokio::spawn(run_vps_command_listener(
        vps_ws_url_auth,
        network_filter_url,
        ws_http_client,
        state.ws_debug.clone(),
    ));

    let eve_path = std::env::var("SURICATA_EVE_PATH")
        .unwrap_or_else(|_| "/var/log/suricata/eve.json".to_string());
    tokio::spawn(tail_eve_json(state.clone(), eve_path));

    axum::serve(listener, app).await?;

    Ok(())
}
