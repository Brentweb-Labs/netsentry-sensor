//! Models for packet-processor.

use dashmap::DashMap;
use std::sync::Arc;

/// Application state for packet-processor.
#[derive(Clone)]
pub struct AppState {
    pub blocked_ips: BlockedIps,
}

pub type BlockedIps = Arc<DashMap<String, BlockedIpInfo>>;

#[derive(Debug, Clone)]
pub struct BlockedIpInfo {
    pub blocked_at: std::time::Instant,
    pub expires_at: Option<std::time::Instant>,
}
