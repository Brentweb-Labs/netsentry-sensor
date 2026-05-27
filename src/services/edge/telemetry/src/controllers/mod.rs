//! HTTP controllers for the telemetry service.

use axum::{extract::State, http::StatusCode, response::Json, routing::get, Router};
use chrono::Utc;
use std::sync::Arc;

use crate::models::AppState;

/// Health check endpoint.
pub async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "healthy",
        "service": "idps-telemetry",
        "timestamp": Utc::now(),
    }))
}

/// Get current system metrics.
pub async fn get_metrics(
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let lock = state.latest_metrics.read().await;
    match lock.as_ref() {
        Some(metrics) => Ok(Json(serde_json::to_value(metrics).unwrap_or_default())),
        None => Ok(Json(serde_json::json!({
            "status": "no_data",
            "message": "First collection cycle has not completed yet"
        }))),
    }
}

/// Get service status.
pub async fn get_status(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let lock = state.latest_metrics.read().await;
    let has_data = lock.is_some();
    let last_collected = lock.as_ref().map(|m| m.timestamp.to_rfc3339());
    Json(serde_json::json!({
        "status": "running",
        "device_id": state.device_id,
        "has_data": has_data,
        "last_collected": last_collected,
        "service": "idps-telemetry",
        "timestamp": Utc::now(),
    }))
}

/// Create the router with all controller routes.
pub fn create_router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/", get(health_check))
        .route("/health", get(health_check))
        .route("/status", get(get_status))
        .route("/metrics", get(get_metrics))
        .with_state(state)
}
