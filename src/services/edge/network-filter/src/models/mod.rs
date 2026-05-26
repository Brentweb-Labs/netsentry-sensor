//! Shared models for network-filter service.

use mongodb::bson::DateTime as BsonDateTime;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use idps_network_filter::NetworkFilter;

/// Application state shared across handlers.
#[derive(Clone)]
pub struct AppState {
    pub network_filter: Arc<NetworkFilter>,
    pub mongo_client: mongodb::Client,
}

/// Prevention response returned to callers.
#[derive(Debug, Serialize)]
pub struct PreventionResponse {
    pub success: bool,
    pub message: String,
    pub timestamp: String,
}

/// Blocked IP info returned in list responses.
#[derive(Debug, Serialize)]
pub struct BlockedIpInfo {
    pub ip: String,
    pub reason: String,
    pub threat_level: u32,
    pub blocked_at: String,
    pub expires_at: String,
    pub source: String,
    #[serde(default)]
    pub dns_names: Vec<String>,
    #[serde(default)]
    pub associated_domains: Vec<String>,
}

/// Persisted blocked IP document in MongoDB.
#[derive(Debug, Serialize, Deserialize)]
pub struct PersistentBlockedIp {
    pub ip: String,
    pub reason: String,
    pub threat_level: u32,
    pub blocked_at: String,
    pub expires_at: String,
    pub source: String,
    pub active: bool,
    pub blocked_at_dt: Option<BsonDateTime>,
    pub expires_at_dt: Option<BsonDateTime>,
    pub unblocked_at_dt: Option<BsonDateTime>,
    pub unblock_reason: Option<String>,
    #[serde(default)]
    pub dns_names: Vec<String>,
    #[serde(default)]
    pub associated_domains: Vec<String>,
}

/// Prevention statistics response.
#[derive(Debug, Serialize)]
pub struct PreventionStats {
    pub total_blocked: usize,
    pub total_trusted: usize,
    pub total_processed: usize,
    pub blocked_ips: Vec<BlockedIpInfo>,
}

/// IP domains response.
#[derive(Debug, Serialize)]
pub struct IpDomainsResponse {
    pub ip: String,
    pub dns_names: Vec<String>,
    pub associated_domains: Vec<String>,
}
