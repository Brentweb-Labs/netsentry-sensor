//! Network Filter Service - IP blocking with iptables integration.

use std::sync::Arc;

use clap::Command;
use idps_network_filter::{FilterConfig, NetworkFilter};
use log::{info, warn};
use mongodb::options::ClientOptions;

mod controllers;
mod models;
mod services;

use controllers::create_router;
use models::AppState;
use services::restore_active_blocks;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::init();

    let _matches = Command::new("edge-network-filter")
        .version("1.0")
        .about("Edge network filtering and caching service")
        .get_matches();

    let filter_config = FilterConfig {
        vps_timeout_ms: 50,
        block_duration_hours: 24,
        trust_duration_minutes: 60,
        trust_threshold_packets: 100,
        max_processing_time_ms: 30,
        enable_adaptive_learning: true,
    };

    let network_filter = Arc::new(NetworkFilter::new(filter_config));

    let mongo_uri =
        std::env::var("MONGODB_URI").unwrap_or_else(|_| "mongodb://mongo:27017/idps".to_string());
    let mut client_options = ClientOptions::parse(&mongo_uri)
        .await
        .map_err(|e| format!("Failed to parse MongoDB URI: {}", e))?;
    client_options.max_pool_size = Some(10);
    let mongo_client = mongodb::Client::with_options(client_options)
        .map_err(|e| format!("Failed to initialize MongoDB client: {}", e))?;

    if let Err(e) = restore_active_blocks(&mongo_client, &network_filter).await {
        warn!("Failed to restore active block rules from MongoDB: {}", e);
    }

    // Start cleanup task
    let filter_clone = network_filter.clone();
    tokio::spawn(async move {
        filter_clone.start_cleanup_task().await;
    });

    let app_state = AppState {
        network_filter,
        mongo_client,
    };

    let app = create_router(app_state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8092").await?;
    info!("Network Filter service listening on 0.0.0.0:8092");

    axum::serve(listener, app).await?;

    Ok(())
}
