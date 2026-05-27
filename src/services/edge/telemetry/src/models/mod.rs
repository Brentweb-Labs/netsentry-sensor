//! Application state for the telemetry service.

use std::sync::Arc;
use tokio::sync::RwLock;

use crate::services::SystemMetrics;

/// Application state shared across handlers.
#[derive(Clone)]
pub struct AppState {
    pub latest_metrics: Arc<RwLock<Option<SystemMetrics>>>,
    pub device_id: String,
    pub sensor_id: String,
    pub tenant_id: String,
}

impl AppState {
    /// Create a new application state.
    pub fn new(device_id: String, sensor_id: String, tenant_id: String) -> Self {
        Self {
            latest_metrics: Arc::new(RwLock::new(None)),
            device_id,
            sensor_id,
            tenant_id,
        }
    }
}
