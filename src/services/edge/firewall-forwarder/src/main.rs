use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::Json,
    routing::{delete, get, post},
    Router,
};
use log::{info, warn};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::net::Ipv4Addr;
use std::sync::Arc;
use tokio::sync::RwLock;
use tower_http::cors::{Any, CorsLayer};

/// Firewall Forwarder - Routes block/unblock requests to the router/firewall
///
/// In the SPAN/mirror port topology, this service replaces direct iptables blocking.
/// Instead, it forwards block requests to the router's management API (e.g., TP-Link Archer).
///
/// This service maintains a local cache of blocked IPs for fast lookups by packet-processor,
/// while the actual enforcement is done via the router's API.

#[derive(Clone)]
struct AppState {
    client: Client,
    firewall_url: String,
    firewall_api_key: String,
    blocked_ips: Arc<RwLock<std::collections::HashMap<String, BlockedIpInfo>>>,
}

#[derive(Debug, Deserialize)]
pub struct BlockRequest {
    pub ip: String,
    pub reason: String,
    #[serde(default = "default_threat_level")]
    pub threat_level: u32,
    #[serde(default = "default_duration_hours")]
    pub duration_hours: u64,
    #[serde(default = "default_source")]
    pub source: String,
}

fn default_threat_level() -> u32 {
    3
}

fn default_duration_hours() -> u64 {
    24
}

fn default_source() -> String {
    "vps_auto".to_string()
}

#[derive(Debug, Deserialize)]
pub struct UnblockRequest {
    pub ip: String,
    #[serde(default)]
    pub reason: String,
}

#[derive(Debug, Clone, Serialize)]
struct PreventionResponse {
    success: bool,
    message: String,
    timestamp: String,
}

#[derive(Debug, Clone, Serialize)]
struct BlockedIpInfo {
    ip: String,
    reason: String,
    threat_level: u32,
    blocked_at: String,
    expires_at: String,
    source: String,
    #[serde(default)]
    firewall_enforced: bool,
}

#[derive(Debug, Serialize)]
struct PreventionStats {
    total_blocked: usize,
    firewall_configured: bool,
    blocked_ips: Vec<BlockedIpInfo>,
}

/// Normalize IPv4 address from various input formats
fn normalize_ipv4_target(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if let Ok(ip) = trimmed.parse::<Ipv4Addr>() {
        return Some(ip.to_string());
    }
    // Handle URLs like http://192.168.1.100
    let host = trimmed
        .strip_prefix("http://")
        .or_else(|| trimmed.strip_prefix("https://"))
        .unwrap_or(trimmed);
    let host = host.split('/').next().unwrap_or(host);
    let host = host.split(':').next().unwrap_or(host);
    host.parse::<Ipv4Addr>().ok().map(|ip| ip.to_string())
}

/// Forward a block request to the router's firewall API
async fn forward_block_to_firewall(
    client: &Client,
    firewall_url: &str,
    api_key: &str,
    ip: &str,
    reason: &str,
    duration_hours: u64,
) -> Result<(), String> {
    // TP-Link Archer API endpoint (adjust for your router model)
    let block_url = format!("{}/api/firewall/block", firewall_url.trim_end_matches('/'));

    // Try the router API
    let response = client
        .post(&block_url)
        .header("Authorization", format!("Bearer {}", api_key))
        .json(&serde_json::json!({
            "ip": ip,
            "reason": reason,
            "duration_hours": duration_hours,
            "action": "block"
        }))
        .send()
        .await
        .map_err(|e| format!("Failed to connect to firewall: {}", e))?;

    if response.status().is_success() {
        info!("Successfully forwarded block request for {} to firewall", ip);
        Ok(())
    } else {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        warn!("Firewall API returned {}: {}", status, body);
        // Don't fail - still cache locally
        Err(format!("Firewall API returned {}", status))
    }
}

/// Forward an unblock request to the router's firewall API
async fn forward_unblock_to_firewall(
    client: &Client,
    firewall_url: &str,
    api_key: &str,
    ip: &str,
) -> Result<(), String> {
    let unblock_url = format!("{}/api/firewall/unblock", firewall_url.trim_end_matches('/'));

    let response = client
        .post(&unblock_url)
        .header("Authorization", format!("Bearer {}", api_key))
        .json(&serde_json::json!({
            "ip": ip,
            "action": "unblock"
        }))
        .send()
        .await
        .map_err(|e| format!("Failed to connect to firewall: {}", e))?;

    if response.status().is_success() {
        info!("Successfully forwarded unblock request for {} to firewall", ip);
        Ok(())
    } else {
        let status = response.status();
        warn!("Firewall API returned {} for unblock", status);
        Err(format!("Firewall API returned {}", status))
    }
}

async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "healthy",
        "service": "firewall-forwarder",
        "timestamp": chrono::Utc::now().to_rfc3339()
    }))
}

async fn block_ip(
    State(state): State<AppState>,
    Json(mut request): Json<BlockRequest>,
) -> Result<Json<PreventionResponse>, StatusCode> {
    let normalized_ip = normalize_ipv4_target(&request.ip).ok_or(StatusCode::BAD_REQUEST)?;
    request.ip = normalized_ip.clone();

    info!(
        "Received block request for IP: {} - {} (duration: {}h)",
        request.ip, request.reason, request.duration_hours
    );

    // Forward to firewall (best effort - we still cache locally)
    let firewall_enforced = if let Err(e) = forward_block_to_firewall(
        &state.client,
        &state.firewall_url,
        &state.firewall_api_key,
        &request.ip,
        &request.reason,
        request.duration_hours,
    )
    .await {
        warn!("Firewall API forward failed (blocking locally): {}", e);
        // Note: In SPAN topology, we can't actually block without firewall API
        // The system becomes monitoring-only without router integration
        false
    } else {
        true
    };

    // Cache locally for fast lookups
    let blocked_at = chrono::Utc::now();
    let expires_at = blocked_at + chrono::Duration::hours(request.duration_hours as i64);

    let info = BlockedIpInfo {
        ip: request.ip.clone(),
        reason: request.reason.clone(),
        threat_level: request.threat_level,
        blocked_at: blocked_at.to_rfc3339(),
        expires_at: expires_at.to_rfc3339(),
        source: request.source.clone(),
        firewall_enforced,
    };

    {
        let mut blocked = state.blocked_ips.write().await;
        blocked.insert(request.ip.clone(), info);
    }

    Ok(Json(PreventionResponse {
        success: true,
        message: if firewall_enforced {
            format!("IP {} blocked on firewall and cached locally", request.ip)
        } else {
            format!(
                "IP {} cached locally (firewall API unavailable - monitoring only)",
                request.ip
            )
        },
        timestamp: chrono::Utc::now().to_rfc3339(),
    }))
}

async fn unblock_ip(
    State(state): State<AppState>,
    Json(request): Json<UnblockRequest>,
) -> Result<Json<PreventionResponse>, StatusCode> {
    let normalized_ip = normalize_ipv4_target(&request.ip).ok_or(StatusCode::BAD_REQUEST)?;

    info!("Received unblock request for IP: {}", normalized_ip);

    // Forward to firewall (best effort)
    let _ = forward_unblock_to_firewall(
        &state.client,
        &state.firewall_url,
        &state.firewall_api_key,
        &normalized_ip,
    )
    .await;

    // Remove from local cache
    {
        let mut blocked = state.blocked_ips.write().await;
        blocked.remove(&normalized_ip);
    }

    Ok(Json(PreventionResponse {
        success: true,
        message: format!("IP {} unblocked", normalized_ip),
        timestamp: chrono::Utc::now().to_rfc3339(),
    }))
}

async fn unblock_ip_by_path(
    State(state): State<AppState>,
    Path(ip): Path<String>,
) -> Result<Json<PreventionResponse>, StatusCode> {
    let normalized_ip = normalize_ipv4_target(&ip).ok_or(StatusCode::BAD_REQUEST)?;

    info!("Received unblock request for IP: {}", normalized_ip);

    let _ = forward_unblock_to_firewall(
        &state.client,
        &state.firewall_url,
        &state.firewall_api_key,
        &normalized_ip,
    )
    .await;

    {
        let mut blocked = state.blocked_ips.write().await;
        blocked.remove(&normalized_ip);
    }

    Ok(Json(PreventionResponse {
        success: true,
        message: format!("IP {} unblocked", normalized_ip),
        timestamp: chrono::Utc::now().to_rfc3339(),
    }))
}

async fn list_blocked_ips(
    State(state): State<AppState>,
) -> Result<Json<Vec<BlockedIpInfo>>, StatusCode> {
    let blocked = state.blocked_ips.read().await;
    let now = chrono::Utc::now();

    let mut result: Vec<BlockedIpInfo> = blocked
        .iter()
        .filter_map(|(_, info)| {
            if let Ok(expires_at) = chrono::DateTime::parse_from_rfc3339(&info.expires_at) {
                if expires_at.with_timezone(&chrono::Utc) > now {
                    return Some(info.clone());
                }
            }
            None
        })
        .collect();

    // Sort by blocked_at descending
    result.sort_by(|a, b| b.blocked_at.cmp(&a.blocked_at));

    Ok(Json(result))
}

async fn get_prevention_stats(
    State(state): State<AppState>,
) -> Result<Json<PreventionStats>, StatusCode> {
    let blocked = state.blocked_ips.read().await;
    let now = chrono::Utc::now();

    let blocked_ips: Vec<BlockedIpInfo> = blocked
        .iter()
        .filter_map(|(_, info)| {
            if let Ok(expires_at) = chrono::DateTime::parse_from_rfc3339(&info.expires_at) {
                if expires_at.with_timezone(&chrono::Utc) > now {
                    return Some(info.clone());
                }
            }
            None
        })
        .collect();

    // Check if firewall is reachable
    let firewall_configured = !state.firewall_url.is_empty();

    Ok(Json(PreventionStats {
        total_blocked: blocked_ips.len(),
        firewall_configured,
        blocked_ips,
    }))
}

/// Get the blocked IPs as a simple list (for packet-processor sync)
async fn get_blocked_simple(
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let blocked = state.blocked_ips.read().await;
    let now = chrono::Utc::now();

    let ips: Vec<serde_json::Value> = blocked
        .iter()
        .filter_map(|(_, info)| {
            if let Ok(expires_at) = chrono::DateTime::parse_from_rfc3339(&info.expires_at) {
                if expires_at.with_timezone(&chrono::Utc) > now {
                    return Some(serde_json::json!({
                        "ip": info.ip,
                        "expires_at": info.expires_at
                    }));
                }
            }
            None
        })
        .collect();

    Ok(Json(serde_json::json!({ "data": ips })))
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::init();

    info!("Starting NetSentry Firewall Forwarder (SPAN Topology)");

    // Load configuration
    let firewall_url = std::env::var("FIREWALL_API_URL")
        .unwrap_or_else(|_| "http://192.168.1.1".to_string());
    let firewall_api_key = std::env::var("FIREWALL_API_KEY")
        .unwrap_or_else(|_| "".to_string());

    info!("Firewall URL: {}", firewall_url);

    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .expect("Failed to build HTTP client");

    let state = AppState {
        client,
        firewall_url,
        firewall_api_key,
        blocked_ips: Arc::new(RwLock::new(std::collections::HashMap::new())),
    };

    // CORS
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = Router::new()
        .route("/health", get(health_check))
        .route("/api/v1/block", post(block_ip))
        .route("/api/v1/unblock", post(unblock_ip))
        .route("/api/v1/blocked", get(list_blocked_ips))
        .route("/api/v1/stats", get(get_prevention_stats))
        .route("/blocked", get(get_blocked_simple))
        .route("/api/v1/blocked/{ip}", delete(unblock_ip_by_path))
        .layer(cors)
        .with_state(state.clone());

    // Start cleanup task for expired entries
    let state_for_cleanup = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
        loop {
            interval.tick().await;

            let now = chrono::Utc::now();
            let mut expired = Vec::new();

            {
                let blocked = state_for_cleanup.blocked_ips.read().await;
                for (ip, info) in blocked.iter() {
                    if let Ok(expires_at) = chrono::DateTime::parse_from_rfc3339(&info.expires_at) {
                        if expires_at.with_timezone(&chrono::Utc) <= now {
                            expired.push(ip.clone());
                        }
                    }
                }
            }

            if !expired.is_empty() {
                let mut blocked = state_for_cleanup.blocked_ips.write().await;
                for ip in expired {
                    info!("Cleaning up expired block for {}", ip);
                    blocked.remove(&ip);
                }
            }
        }
    });

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8092").await?;
    info!("Firewall Forwarder listening on 0.0.0.0:8092");
    info!("Health endpoint: http://localhost:8092/health");

    axum::serve(listener, app).await?;

    Ok(())
}
