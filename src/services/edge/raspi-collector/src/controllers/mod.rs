//! HTTP controllers for the raspi-collector service.

use std::sync::Arc;

use axum::{
    extract::State,
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::models::{AppState, ConnectionStatus};

/// Health check endpoint.
pub async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "healthy",
        "timestamp": Utc::now(),
        "service": "raspi-collector"
    }))
}

/// Debug state endpoint.
pub async fn get_debug_state(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let dbg = state.ws_debug.read().await.clone();
    let metrics = state.metrics.read().await.clone();
    Json(serde_json::json!({
        "ws": {
            "url": dbg.ws_url,
            "connected": dbg.connected,
            "last_connected_at": dbg.last_connected_at,
            "last_disconnected_at": dbg.last_disconnected_at,
            "reconnect_count": dbg.reconnect_count,
            "last_command_at": dbg.last_command_at,
            "commands_received": dbg.commands_received,
            "blocks_applied": dbg.blocks_applied,
            "unblocks_applied": dbg.unblocks_applied,
        },
        "network_filter": {
            "url": dbg.network_filter_url,
            "reachable": dbg.network_filter_reachable,
        },
        "recent_commands": dbg.recent_commands,
        "eve_metrics": {
            "events_collected": metrics.events_collected,
            "events_sent": metrics.events_sent,
            "failed_sends": metrics.failed_sends,
            "last_collection": metrics.last_collection,
        },
        "timestamp": Utc::now(),
    }))
}

/// Status endpoint.
pub async fn get_status(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let metrics = state.metrics.read().await.clone();
    let connection_status = state.connection_monitor.read().await.get_status();

    Json(serde_json::json!({
        "status": "running",
        "timestamp": Utc::now(),
        "service": "raspi-collector",
        "metrics": metrics,
        "vps_connection": connection_status.status,
    }))
}

/// Connection status endpoint.
pub async fn get_connection_status(State(state): State<Arc<AppState>>) -> Json<ConnectionStatus> {
    let connection_status = state.connection_monitor.read().await.get_status();
    Json(connection_status)
}

/// Metrics endpoint.
pub async fn get_metrics(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let metrics = state.metrics.read().await.clone();

    Json(serde_json::json!({
        "events_collected": metrics.events_collected,
        "events_sent": metrics.events_sent,
        "last_collection": metrics.last_collection,
        "collection_rate": metrics.collection_rate,
        "failed_sends": metrics.failed_sends,
        "success_rate": if metrics.events_collected > 0 {
            (metrics.events_sent as f64 / metrics.events_collected as f64) * 100.0
        } else {
            0.0
        }
    }))
}

/// Raw log event input.
#[derive(Debug, Serialize, Deserialize)]
pub struct RawLogEvent {
    pub id: String,
    pub timestamp: chrono::DateTime<Utc>,
    pub source_ip: String,
    pub dest_ip: String,
    pub source_port: u16,
    pub dest_port: u16,
    pub protocol: String,
    pub payload: String,
    pub severity: u8,
    pub event_type: String,
}

/// Collect log event response.
#[derive(Debug, Serialize)]
pub struct CollectorResponse {
    pub success: bool,
    pub message: String,
    pub event_id: String,
    pub forwarded: bool,
}

/// Collect single log event.
pub async fn collect_log(
    State(state): State<Arc<AppState>>,
    Json(log_event): Json<RawLogEvent>,
) -> Result<Json<CollectorResponse>, StatusCode> {
    log::info!(
        "Collecting log event: {} from {} to {}",
        log_event.id, log_event.source_ip, log_event.dest_ip
    );

    // Update metrics
    {
        let mut metrics = state.metrics.write().await;
        metrics.events_collected += 1;
        metrics.last_collection = Some(Utc::now());
        metrics.collection_rate = crate::services::calculate_collection_rate(&metrics).await;
    }

    // Convert to TrafficEvent
    let traffic_event = crate::services::convert_to_traffic_event(log_event).await;
    let event_id_fallback = traffic_event.id.clone();

    // Send to VPS
    match crate::services::send_to_vps(&state, traffic_event).await {
        Ok(event_id) => {
            let mut metrics = state.metrics.write().await;
            metrics.events_sent += 1;

            Ok(Json(CollectorResponse {
                success: true,
                message: "Log collected and forwarded successfully".to_string(),
                event_id,
                forwarded: true,
            }))
        }
        Err(e) => {
            log::error!("Failed to forward log to VPS: {}", e);
            let mut metrics = state.metrics.write().await;
            metrics.failed_sends += 1;

            Ok(Json(CollectorResponse {
                success: false,
                message: format!("Failed to forward: {}", e),
                event_id: event_id_fallback,
                forwarded: false,
            }))
        }
    }
}

/// Collect batch of log events.
pub async fn collect_batch_logs(
    State(state): State<Arc<AppState>>,
    Json(log_events): Json<Vec<RawLogEvent>>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let batch_size = log_events.len();
    log::info!("Collecting batch of {} log events", batch_size);

    // Update metrics
    {
        let mut metrics = state.metrics.write().await;
        metrics.events_collected += batch_size as u64;
        metrics.last_collection = Some(Utc::now());
        metrics.collection_rate = crate::services::calculate_collection_rate(&metrics).await;
    }

    // Convert to TrafficEvents
    let mut traffic_events = Vec::new();
    for log_event in log_events {
        traffic_events.push(crate::services::convert_to_traffic_event(log_event).await);
    }

    // Send batch to VPS
    match crate::services::send_batch_to_vps(&state, traffic_events).await {
        Ok(_) => {
            let mut metrics = state.metrics.write().await;
            metrics.events_sent += batch_size as u64;

            Ok(Json(serde_json::json!({
                "success": true,
                "message": format!("Batch of {} logs collected and forwarded successfully", batch_size),
                "batch_size": batch_size,
                "forwarded": true
            })))
        }
        Err(e) => {
            log::error!("Failed to forward batch to VPS: {}", e);
            let mut metrics = state.metrics.write().await;
            metrics.failed_sends += batch_size as u64;

            Ok(Json(serde_json::json!({
                "success": false,
                "message": format!("Failed to forward batch: {}", e),
                "batch_size": batch_size,
                "forwarded": false
            })))
        }
    }
}

/// Simulate log events for testing.
pub async fn simulate_logs(
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    log::info!("Generating simulated log events");

    let mut simulated_events = Vec::new();
    let now = Utc::now();

    // Generate different types of events
    for i in 0..10 {
        let event_type = match i % 4 {
            0 => "alert",
            1 => "dns",
            2 => "http",
            3 => "tls",
            _ => "alert",
        };

        let (source_ip, dest_ip) = match i % 3 {
            0 => ("192.168.1.100".to_string(), "10.0.0.1".to_string()),
            1 => ("192.168.1.101".to_string(), "8.8.8.8".to_string()),
            2 => ("192.168.1.102".to_string(), "172.16.0.1".to_string()),
            _ => ("192.168.1.100".to_string(), "10.0.0.1".to_string()),
        };

        let payload = match event_type {
            "alert" => {
                r#"{"action": "allowed", "gid": 1, "signature_id": 2000001, "rev": 1, "signature": "Potential security threat", "category": "attempted-recon", "severity": 2}"#
            }
            "dns" => r#"{"queries": [{"rrname": "example.com"}]}"#,
            "http" => {
                r#"{"hostname": "example.com", "url": "/index.html", "http_user_agent": "Mozilla/5.0"}"#
            }
            "tls" => "{}",
            _ => "{}",
        };

        let event = RawLogEvent {
            id: Uuid::new_v4().to_string(),
            timestamp: now - chrono::Duration::seconds(i as i64),
            source_ip,
            dest_ip,
            source_port: 12345 + (i as u16),
            dest_port: match event_type {
                "dns" => 53,
                "http" => 80,
                "tls" => 443,
                _ => 8080,
            },
            protocol: match event_type {
                "dns" => "UDP",
                "http" => "TCP",
                "tls" => "TCP",
                _ => "TCP",
            }
            .to_string(),
            payload: payload.to_string(),
            severity: match event_type {
                "alert" => 2,
                _ => 1,
            },
            event_type: event_type.to_string(),
        };

        simulated_events.push(event);
    }

    let batch_size = simulated_events.len();

    // Update metrics
    {
        let mut metrics = state.metrics.write().await;
        metrics.events_collected += batch_size as u64;
        metrics.last_collection = Some(Utc::now());
        metrics.collection_rate = crate::services::calculate_collection_rate(&metrics).await;
    }

    // Convert to TrafficEvents
    let mut traffic_events = Vec::new();
    for log_event in simulated_events {
        traffic_events.push(crate::services::convert_to_traffic_event(log_event).await);
    }

    // Send batch to VPS
    match crate::services::send_batch_to_vps(&state, traffic_events).await {
        Ok(_) => {
            let mut metrics = state.metrics.write().await;
            metrics.events_sent += batch_size as u64;

            Ok(Json(serde_json::json!({
                "success": true,
                "message": format!("Generated and forwarded {} simulated events", batch_size),
                "events_generated": batch_size,
                "forwarded": true
            })))
        }
        Err(e) => {
            log::error!("Failed to forward simulated events to VPS: {}", e);
            let mut metrics = state.metrics.write().await;
            metrics.failed_sends += batch_size as u64;

            Ok(Json(serde_json::json!({
                "success": false,
                "message": format!("Failed to forward simulated events: {}", e),
                "events_generated": batch_size,
                "forwarded": false
            })))
        }
    }
}

/// Create the router with all controller routes.
pub fn create_router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/", get(health_check))
        .route("/health", get(health_check))
        .route("/status", get(get_status))
        .route("/metrics", get(get_metrics))
        .route("/connection", get(get_connection_status))
        .route("/debug", get(get_debug_state))
        .route("/collect", post(collect_log))
        .route("/collect/batch", post(collect_batch_logs))
        .route("/simulate", post(simulate_logs))
        .with_state(state)
}
