use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::Json,
    routing::{delete, get, post},
    Router,
};
use clap::Command;
use futures_util::TryStreamExt;
use idps_network_filter::{FilterConfig, NetworkFilter};
use log::{debug, error, info, warn};
use mongodb::bson::{doc, DateTime as BsonDateTime};
use mongodb::options::{ClientOptions, FindOptions};
use serde::{Deserialize, Serialize};
use std::net::Ipv4Addr;
use std::sync::Arc;
use tokio::net::TcpListener;
use tower_http::cors::{Any, CorsLayer};

#[derive(Debug, Deserialize)]
struct BlockRequest {
    ip: String,
    reason: String,
    #[serde(default = "default_threat_level")]
    threat_level: u32,
    #[serde(default = "default_duration_hours", alias = "durationHours")]
    duration_hours: u64,
    #[serde(default = "default_block_source")]
    source: String,
}

fn default_threat_level() -> u32 {
    3
}
fn default_duration_hours() -> u64 {
    24
}
fn default_block_source() -> String {
    "manual_dashboard".to_string()
}

#[derive(Debug, Deserialize)]
struct UnblockRequest {
    ip: String,
    reason: String,
}

#[derive(Debug, Serialize)]
struct PreventionResponse {
    success: bool,
    message: String,
    timestamp: String,
}

#[derive(Debug, Serialize)]
struct BlockedIpInfo {
    ip: String,
    reason: String,
    threat_level: u32,
    blocked_at: String,
    expires_at: String,
    source: String,
    #[serde(default)]
    dns_names: Vec<String>,
    #[serde(default)]
    associated_domains: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct PersistentBlockedIp {
    ip: String,
    reason: String,
    threat_level: u32,
    blocked_at: String,
    expires_at: String,
    source: String,
    active: bool,
    blocked_at_dt: Option<BsonDateTime>,
    expires_at_dt: Option<BsonDateTime>,
    unblocked_at_dt: Option<BsonDateTime>,
    unblock_reason: Option<String>,
    #[serde(default)]
    dns_names: Vec<String>,
    #[serde(default)]
    associated_domains: Vec<String>,
}

#[derive(Debug, Serialize)]
struct PreventionStats {
    total_blocked: usize,
    total_trusted: usize,
    total_processed: usize,
    blocked_ips: Vec<BlockedIpInfo>,
}

#[derive(Clone)]
struct AppState {
    network_filter: Arc<NetworkFilter>,
    mongo_client: mongodb::Client,
}

fn normalize_ipv4_target(value: &str) -> Option<String> {
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

async fn restore_active_blocks(
    mongo_client: &mongodb::Client,
    network_filter: &Arc<NetworkFilter>,
) -> Result<(), Box<dyn std::error::Error>> {
    let collection = mongo_client
        .database("idps")
        .collection::<PersistentBlockedIp>("blocked_ips");
    let mut cursor = collection.find(doc! { "active": true }).await?;

    while let Some(blocked) = cursor.try_next().await? {
        let blocked_at = blocked
            .blocked_at_dt
            .map(|dt| dt.to_system_time())
            .map(chrono::DateTime::<chrono::Utc>::from)
            .unwrap_or_else(chrono::Utc::now);
        let expires_at = blocked
            .expires_at_dt
            .map(|dt| dt.to_system_time())
            .map(chrono::DateTime::<chrono::Utc>::from)
            .unwrap_or_else(chrono::Utc::now);

        if let Err(e) = network_filter
            .restore_blocked_ip(
                &blocked.ip,
                &blocked.reason,
                blocked.threat_level as u8,
                &blocked.source,
                blocked_at,
                expires_at,
            )
            .await
        {
            error!("Failed to restore active block for {}: {}", blocked.ip, e);
        }
    }
    Ok(())
}

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

    // Build the application
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
        .route("/api/v1/blocked/{ip}", delete(unblock_ip_by_path))
        .route("/api/v1/blocked/{ip}/domains", get(get_ip_domains))
        .layer(cors)
        .with_state(app_state);

    // Start the server
    let listener = TcpListener::bind("0.0.0.0:8092").await?;
    info!("Network Filter service listening on 0.0.0.0:8092");

    axum::serve(listener, app).await?;

    Ok(())
}

/// Perform reverse DNS (PTR) lookup for an IPv4 address using the system resolver.
async fn reverse_dns(ip: &str) -> Vec<String> {
    let ip_owned = ip.to_string();
    tokio::task::spawn_blocking(move || reverse_dns_blocking(&ip_owned))
        .await
        .unwrap_or_default()
}

fn reverse_dns_blocking(ip: &str) -> Vec<String> {
    use std::ffi::CStr;
    use std::mem;
    use std::net::Ipv4Addr;

    let addr: Ipv4Addr = match ip.parse() {
        Ok(a) => a,
        Err(_) => return vec![],
    };

    let octets = addr.octets();

    unsafe {
        let mut sockaddr: libc::sockaddr_in = mem::zeroed();
        sockaddr.sin_family = libc::AF_INET as libc::sa_family_t;
        // s_addr is in network byte order; from_be_bytes gives host order, to_be converts back
        sockaddr.sin_addr.s_addr = u32::from_ne_bytes(octets);

        // Use libc::c_char so the type matches getnameinfo's signature on all platforms
        let mut host = vec![0 as libc::c_char; 1025];

        let ret = libc::getnameinfo(
            &sockaddr as *const libc::sockaddr_in as *const libc::sockaddr,
            mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
            host.as_mut_ptr(),
            1024,
            std::ptr::null_mut(),
            0,
            libc::NI_NAMEREQD,
        );

        if ret == 0 {
            if let Ok(hostname) = CStr::from_ptr(host.as_ptr()).to_str() {
                let name = hostname.to_string();
                if name != ip {
                    return vec![name];
                }
            }
        }
    }

    vec![]
}

async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "healthy",
        "service": "network-filter",
        "timestamp": chrono::Utc::now().to_rfc3339()
    }))
}

async fn block_ip(
    State(state): State<AppState>,
    Json(mut request): Json<BlockRequest>,
) -> Result<Json<PreventionResponse>, StatusCode> {
    let normalized_ip = normalize_ipv4_target(&request.ip).ok_or(StatusCode::BAD_REQUEST)?;
    request.ip = normalized_ip;
    info!(
        "Received block request for IP: {} - {} (duration: {}h, source: {})",
        request.ip, request.reason, request.duration_hours, request.source
    );

    // Block the IP directly using the network filter
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
        error!("Failed to apply block for {}: {}", request.ip, e);
        return Err(StatusCode::BAD_GATEWAY);
    }

    debug!("Successfully blocked IP: {}", request.ip);

    let dns_names = reverse_dns(&request.ip).await;
    if !dns_names.is_empty() {
        debug!("Resolved DNS names for {}: {:?}", request.ip, dns_names);
    }

    let blocked_collection = state
        .mongo_client
        .database("idps")
        .collection::<PersistentBlockedIp>("blocked_ips");
    let blocked_at = chrono::Utc::now();
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
        warn!(
            "Blocked {} in firewall, but failed to persist to MongoDB: {}",
            request.ip, e
        );
    }

    Ok(Json(PreventionResponse {
        success: true,
        message: format!("IP {} blocked successfully", request.ip),
        timestamp: chrono::Utc::now().to_rfc3339(),
    }))
}

async fn unblock_ip(
    State(state): State<AppState>,
    Json(mut request): Json<UnblockRequest>,
) -> Result<Json<PreventionResponse>, StatusCode> {
    let normalized_ip = normalize_ipv4_target(&request.ip).ok_or(StatusCode::BAD_REQUEST)?;
    request.ip = normalized_ip;
    info!(
        "Received unblock request for IP: {} - {}",
        request.ip, request.reason
    );

    // Remove IP from blocked list
    if let Err(e) = state.network_filter.unblock_ip(&request.ip).await {
        error!("Failed to unblock IP {}: {}", request.ip, e);
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }

    let blocked_collection = state
        .mongo_client
        .database("idps")
        .collection::<PersistentBlockedIp>("blocked_ips");
    let now = chrono::Utc::now();
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
        warn!(
            "Unblocked {} in firewall, but failed to persist to MongoDB: {}",
            request.ip, e
        );
    }

    debug!("Successfully unblocked IP: {}", request.ip);

    Ok(Json(PreventionResponse {
        success: true,
        message: format!("IP {} unblocked successfully", request.ip),
        timestamp: chrono::Utc::now().to_rfc3339(),
    }))
}

async fn unblock_ip_by_path(
    State(state): State<AppState>,
    Path(ip): Path<String>,
) -> Result<Json<PreventionResponse>, StatusCode> {
    let ip = normalize_ipv4_target(&ip).ok_or(StatusCode::BAD_REQUEST)?;
    info!("Received unblock request for IP: {}", ip);

    // Remove IP from blocked list
    if let Err(e) = state.network_filter.unblock_ip(&ip).await {
        error!("Failed to unblock IP {}: {}", ip, e);
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }

    let blocked_collection = state
        .mongo_client
        .database("idps")
        .collection::<PersistentBlockedIp>("blocked_ips");
    let now = chrono::Utc::now();
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
        warn!(
            "Unblocked {} via path in firewall, but failed to persist to MongoDB: {}",
            ip, e
        );
    }

    debug!("Successfully unblocked IP: {}", ip);

    Ok(Json(PreventionResponse {
        success: true,
        message: format!("IP {} unblocked successfully", ip),
        timestamp: chrono::Utc::now().to_rfc3339(),
    }))
}

async fn list_blocked_ips(
    State(state): State<AppState>,
) -> Result<Json<Vec<BlockedIpInfo>>, StatusCode> {
    debug!("Listing blocked IPs");

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
            warn!(
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
        error!("Error iterating blocked IP cursor: {}", e);
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

async fn get_prevention_stats(
    State(state): State<AppState>,
) -> Result<Json<PreventionStats>, StatusCode> {
    debug!("Getting prevention statistics");

    let stats = state.network_filter.get_stats().await;

    let Json(blocked_ips) = list_blocked_ips(State(state.clone())).await?;

    Ok(Json(PreventionStats {
        total_blocked: blocked_ips.len(),
        total_trusted: stats.fast_tracked_packets,
        total_processed: stats.total_packets,
        blocked_ips,
    }))
}

#[derive(Debug, Serialize)]
struct IpDomainsResponse {
    ip: String,
    dns_names: Vec<String>,
    associated_domains: Vec<String>,
}

async fn get_ip_domains(
    State(state): State<AppState>,
    Path(ip): Path<String>,
) -> Result<Json<IpDomainsResponse>, StatusCode> {
    let ip = normalize_ipv4_target(&ip).ok_or(StatusCode::BAD_REQUEST)?;
    debug!("Getting domains for IP: {}", ip);

    let blocked_collection = state
        .mongo_client
        .database("idps")
        .collection::<PersistentBlockedIp>("blocked_ips");

    // Try to find the IP in the blocked collection
    if let Ok(Some(record)) = blocked_collection.find_one(doc! { "ip": &ip }).await {
        if !record.dns_names.is_empty() || !record.associated_domains.is_empty() {
            return Ok(Json(IpDomainsResponse {
                ip,
                dns_names: record.dns_names,
                associated_domains: record.associated_domains,
            }));
        }
    }

    // Live reverse DNS lookup
    let dns_names = reverse_dns(&ip).await;
    Ok(Json(IpDomainsResponse {
        ip,
        dns_names,
        associated_domains: vec![],
    }))
}
