//! Packet processor controllers.

use axum::{
    extract::State,
    response::Json,
    routing::get,
    Router,
};
use chrono::Utc;
use std::sync::Arc;

use crate::models::AppState;

pub async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "healthy",
        "timestamp": Utc::now(),
        "service": "packet-processor"
    }))
}

pub fn create_router(state: Arc<AppState>) -> Router {
    let health = axum::routing::get(health_check);
    Router::new().route("/health", health).with_state(state)
}
