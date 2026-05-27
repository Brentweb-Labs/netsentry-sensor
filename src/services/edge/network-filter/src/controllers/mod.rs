//! HTTP handlers for network-filter service.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::Json,
    routing::{delete, get, post},
    Router,
};
use chrono::Utc;
use futures_util::TryStreamExt;
use mongodb::bson::{doc, DateTime as BsonDateTime};
use mongodb::options::FindOptions;
use serde::Deserialize;
use std::net::Ipv4Addr;
use tower_http::cors::{Any, CorsLayer};

use crate::models::{AppState, BlockedIpInfo, IpDomainsResponse, PersistentBlockedIp, PreventionResponse, PreventionStats};

#[derive(Debug, Deserialize)]
pub struct BlockRequest {
    pub ip: String,
    pub reason: String,
    #[serde(default = "default_threat_level")]
    pub threat_level: u32,
    #[serde(default = "default_duration_hours", alias = "durationHours")]
    pub duration_hours: u64,
    #[serde(default = "default_block_source")]
    pub source: String,
}

fn default_threat_level() -> u32 { 3 }
fn default_duration_hours() -> u64 { 24 }
fn default_block_source() -> String { "manual_dashboard".to_string() }

#[derive(Debug, Deserialize)]
pub struct UnblockRequest {
    pub ip: String,
    pub reason: String,
}

/// Normalize IPv4 address from various input formats.
pub fn normalize_ipv4_target(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if let Ok(ip) = trimmed.parse::<Ipv4Addr>() {
        return Some(ip.to_string());
    }
    let host = if let Some(without_scheme) = trimmed
        .strip_prefix("http://")
        .or_else(|| trimmed.strip_prefix("https://"))
    {
        without_scheme
    } else {
        trimmed
    };
    let host = host.split('/').next().unwrap_or(host);
    let host = host.split(':').next().unwrap_or(host);
    host.parse::<Ipv4Addr>().ok().map(|ip| ip.to_string())
}

/// Reverse DNS lookup for an IP address.
pub async fn reverse_dns(ip: &str) -> Vec<String> {
    let ip_owned = ip.to_string();
    tokio::task::spawn_blocking(move || crate::services::reverse_dns_blocking(&ip_owned))
        .await
        .unwrap_or_default()
}

pub async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "healthy",
        "service": "network-filter",
        "timestamp": Utc::now().to_rfc3339()
    }))
}

pub async fn block_ip(
    State(state): State<AppState>,
    Json(mut request): Json<BlockRequest>,
) -> Result<Json<PreventionResponse>, StatusCode> {
    let normalized_ip = normalize_ipv4_target(&request.ip).ok_or(StatusCode::BAD_REQUEST)?;
    request.ip = normalized_ip;
    log::info!(
        "Received block request for IP: {} - {} (duration: {}h, source: {})",
        request.ip, request.reason, request.duration_hours, request.source
    );

    if let Err(e) = state
        .network_filter
        .block_ip_direct(
            &request.ip,
            &request.reason,
            request.threat_level as u8,
            request.duration_hours,
            &request.source,
        )
        .await
    {
        log::error!("Failed to apply block for {}: {}", request.ip, e);
        return Err(StatusCode::BAD_GATEWAY);
    }

    log::debug!("Successfully blocked IP: {}", request.ip);

    let dns_names = reverse_dns(&request.ip).await;

    let blocked_collection = state
        .mongo_client
        .database("idps")
        .collection::<PersistentBlockedIp>("blocked_ips");
    let blocked_at = Utc::now();
    let expires_at = blocked_at + chrono::Duration::hours(request.duration_hours as i64);
    let blocked_doc = PersistentBlockedIp {
        ip: request.ip.clone(),
        reason: request.reason.clone(),
        threat_level: request.threat_level,
        blocked_at: blocked_at.to_rfc3339(),
        expires_at: expires_at.to_rfc3339(),
        source: request.source.clone(),
        active: true,
        blocked_at_dt: Some(BsonDateTime::from_millis(blocked_at.timestamp_millis())),
        expires_at_dt: Some(BsonDateTime::from_millis(expires_at.timestamp_millis())),
        unblocked_at_dt: None,
        unblock_reason: None,
        dns_names: dns_names.clone(),
        associated_domains: vec![],
    };
    if let Err(e) = blocked_collection.insert_one(blocked_doc).await {
        log::warn!(
            "Blocked {} in firewall, but failed to persist to MongoDB: {}",
            request.ip, e
        );
    }

    Ok(Json(PreventionResponse {
        success: true,
        message: format!("IP {} blocked successfully", request.ip),
        timestamp: Utc::now().to_rfc3339(),
    }))
}

pub async fn unblock_ip(
    State(state): State<AppState>,
    Json(mut request): Json<UnblockRequest>,
) -> Result<Json<PreventionResponse>, StatusCode> {
    let normalized_ip = normalize_ipv4_target(&request.ip).ok_or(StatusCode::BAD_REQUEST)?;
    request.ip = normalized_ip;
    log::info!(
        "Received unblock request for IP: {} - {}",
        request.ip, request.reason
    );

    if let Err(e) = state.network_filter.unblock_ip(&request.ip).await {
        log::error!("Failed to unblock IP {}: {}", request.ip, e);
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }

    let blocked_collection = state
        .mongo_client
        .database("idps")
        .collection::<PersistentBlockedIp>("blocked_ips");
    let now = Utc::now();
    if let Err(e) = blocked_collection
        .update_one(
            doc! {
                "ip": &request.ip,
                "active": true
            },
            doc! {
                "$set": {
                    "active": false,
                    "unblocked_at_dt": BsonDateTime::from_millis(now.timestamp_millis()),
                    "unblock_reason": request.reason.clone()
                }
            },
        )
        .sort(doc! { "blocked_at_dt": -1 })
        .await
    {
        log::warn!(
            "Unblocked {} in firewall, but failed to persist to MongoDB: {}",
            request.ip, e
        );
    }

    Ok(Json(PreventionResponse {
        success: true,
        message: format!("IP {} unblocked successfully", request.ip),
        timestamp: Utc::now().to_rfc3339(),
    }))
}

pub async fn unblock_ip_by_path(
    State(state): State<AppState>,
    Path(ip): Path<String>,
) -> Result<Json<PreventionResponse>, StatusCode> {
    let ip = normalize_ipv4_target(&ip).ok_or(StatusCode::BAD_REQUEST)?;
    log::info!("Received unblock request for IP: {}", ip);

    if let Err(e) = state.network_filter.unblock_ip(&ip).await {
        log::error!("Failed to unblock IP {}: {}", ip, e);
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }

    let blocked_collection = state
        .mongo_client
        .database("idps")
        .collection::<PersistentBlockedIp>("blocked_ips");
    let now = Utc::now();
    if let Err(e) = blocked_collection
        .update_one(
            doc! {
                "ip": &ip,
                "active": true
            },
            doc! {
                "$set": {
                    "active": false,
                    "unblocked_at_dt": BsonDateTime::from_millis(now.timestamp_millis()),
                    "unblock_reason": "path_unblock"
                }
            },
        )
        .sort(doc! { "blocked_at_dt": -1 })
        .await
    {
        log::warn!(
            "Unblocked {} via path in firewall, but failed to persist to MongoDB: {}",
            ip, e
        );
    }

    Ok(Json(PreventionResponse {
        success: true,
        message: format!("IP {} unblocked successfully", ip),
        timestamp: Utc::now().to_rfc3339(),
    }))
}

pub async fn list_blocked_ips(
    State(state): State<AppState>,
) -> Result<Json<Vec<BlockedIpInfo>>, StatusCode> {
    log::debug!("Listing blocked IPs");

    let blocked_collection = state
        .mongo_client
        .database("idps")
        .collection::<PersistentBlockedIp>("blocked_ips");
    let find_options = FindOptions::builder()
        .sort(doc! { "blocked_at_dt": -1 })
        .build();
    let mut cursor = match blocked_collection
        .find(doc! { "active": true })
        .with_options(find_options)
        .await
    {
        Ok(cursor) => cursor,
        Err(e) => {
            log::warn!(
                "Failed to query blocked IPs from MongoDB, falling back to in-memory list: {}",
                e
            );
            let blocked_ips_raw = state.network_filter.get_blocked_ips().await;
            let mut blocked_ips = Vec::new();
            for (ip, reason, threat_level, blocked_at, expires_at, source) in blocked_ips_raw {
                blocked_ips.push(BlockedIpInfo {
                    ip,
                    reason,
                    threat_level: threat_level as u32,
                    blocked_at,
                    expires_at,
                    source,
                    dns_names: vec![],
                    associated_domains: vec![],
                });
            }
            return Ok(Json(blocked_ips));
        }
    };

    let mut blocked_ips = Vec::new();
    while let Some(blocked) = cursor.try_next().await.map_err(|e| {
        log::error!("Error iterating blocked IP cursor: {}", e);
        StatusCode::INTERNAL_SERVER_ERROR
    })? {
        blocked_ips.push(BlockedIpInfo {
            ip: blocked.ip,
            reason: blocked.reason,
            threat_level: blocked.threat_level,
            blocked_at: blocked.blocked_at,
            expires_at: blocked.expires_at,
            source: blocked.source,
            dns_names: blocked.dns_names,
            associated_domains: blocked.associated_domains,
        });
    }

    Ok(Json(blocked_ips))
}

pub async fn get_prevention_stats(
    State(state): State<AppState>,
) -> Result<Json<PreventionStats>, StatusCode> {
    log::debug!("Getting prevention statistics");

    let stats = state.network_filter.get_stats().await;
    let Json(blocked_ips) = list_blocked_ips(State(state.clone())).await?;

    Ok(Json(PreventionStats {
        total_blocked: blocked_ips.len(),
        total_trusted: stats.fast_tracked_packets,
        total_processed: stats.total_packets,
        blocked_ips,
    }))
}

pub async fn get_ip_domains(
    State(state): State<AppState>,
    Path(ip): Path<String>,
) -> Result<Json<IpDomainsResponse>, StatusCode> {
    let ip = normalize_ipv4_target(&ip).ok_or(StatusCode::BAD_REQUEST)?;
    log::debug!("Getting domains for IP: {}", ip);

    let blocked_collection = state
        .mongo_client
        .database("idps")
        .collection::<PersistentBlockedIp>("blocked_ips");

    if let Ok(Some(record)) = blocked_collection.find_one(doc! { "ip": &ip }).await {
        if !record.dns_names.is_empty() || !record.associated_domains.is_empty() {
            return Ok(Json(IpDomainsResponse {
                ip,
                dns_names: record.dns_names,
                associated_domains: record.associated_domains,
            }));
        }
    }

    let dns_names = reverse_dns(&ip).await;
    Ok(Json(IpDomainsResponse {
        ip,
        dns_names,
        associated_domains: vec![],
    }))
}

/// Create the router with all routes.
pub fn create_router(state: AppState) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    Router::new()
        .route("/health", get(health_check))
        .route("/api/v1/block", post(block_ip))
        .route("/api/v1/unblock", post(unblock_ip))
        .route("/api/v1/blocked", get(list_blocked_ips))
        .route("/api/v1/stats", get(get_prevention_stats))
        .route("/api/v1/blocked/{ip}", delete(unblock_ip_by_path))
        .route("/api/v1/blocked/{ip}/domains", get(get_ip_domains))
        .layer(cors)
        .with_state(state)
}
