use axum::{
    extract::State,
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use chrono::{DateTime, Utc};
use futures_util::StreamExt;
use log::{debug, error, info, warn};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::RwLock;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use uuid::Uuid;

#[derive(Clone)]
struct AppState {
    vps_client: Client,
    metrics: Arc<RwLock<CollectorMetrics>>,
    vps_endpoint: String,
    api_key: String,
    connection_monitor: Arc<RwLock<ConnectionMonitor>>,
    ws_debug: Arc<RwLock<WsDebugState>>,
}

#[derive(Debug, Clone, Serialize)]
struct WsDebugState {
    ws_url: String,
    connected: bool,
    last_connected_at: Option<DateTime<Utc>>,
    last_disconnected_at: Option<DateTime<Utc>>,
    reconnect_count: u32,
    last_command_at: Option<DateTime<Utc>>,
    commands_received: u64,
    blocks_applied: u64,
    unblocks_applied: u64,
    network_filter_url: String,
    network_filter_reachable: Option<bool>,
    recent_commands: VecDeque<DebugCommand>,
}

#[derive(Debug, Clone, Serialize)]
struct DebugCommand {
    received_at: DateTime<Utc>,
    cmd_type: String,
    ip: String,
    reason: String,
    success: bool,
}

impl WsDebugState {
    fn new(ws_url: &str, network_filter_url: &str) -> Self {
        Self {
            ws_url: ws_url.to_string(),
            connected: false,
            last_connected_at: None,
            last_disconnected_at: None,
            reconnect_count: 0,
            last_command_at: None,
            commands_received: 0,
            blocks_applied: 0,
            unblocks_applied: 0,
            network_filter_url: network_filter_url.to_string(),
            network_filter_reachable: None,
            recent_commands: VecDeque::with_capacity(50),
        }
    }

    fn record_command(&mut self, cmd_type: &str, ip: &str, reason: &str, success: bool) {
        self.commands_received += 1;
        self.last_command_at = Some(Utc::now());
        if cmd_type == "block_command" && success {
            self.blocks_applied += 1;
        }
        if cmd_type == "unblock_command" && success {
            self.unblocks_applied += 1;
        }
        if self.recent_commands.len() >= 50 {
            self.recent_commands.pop_front();
        }
        self.recent_commands.push_back(DebugCommand {
            received_at: Utc::now(),
            cmd_type: cmd_type.to_string(),
            ip: ip.to_string(),
            reason: reason.to_string(),
            success,
        });
    }
}

#[derive(Debug, Default, Clone, Serialize)]
struct CollectorMetrics {
    events_collected: u64,
    events_sent: u64,
    last_collection: Option<DateTime<Utc>>,
    collection_rate: f64,
    failed_sends: u64,
}

#[derive(Debug, Clone, Serialize)]
struct ConnectionStatus {
    status: String,         // "connected", "disconnected", "degraded"
    uptime_duration: u64,   // seconds
    uptime_percentage: f64, // 0-100
    last_connected: Option<DateTime<Utc>>,
    last_disconnected: Option<DateTime<Utc>>,
    total_checks: u64,
    successful_checks: u64,
    failed_checks: u64,
    average_response_time: f64,    // milliseconds
    response_time_last_check: f64, // milliseconds
    consecutive_failures: u64,
    longest_uptime: u64,    // seconds
    shortest_downtime: u64, // seconds
}

#[derive(Debug, Clone)]
struct ConnectionMonitor {
    current_status: String,
    start_time: DateTime<Utc>,
    last_connected: Option<DateTime<Utc>>,
    last_disconnected: Option<DateTime<Utc>>,
    total_uptime: u64,   // seconds
    total_downtime: u64, // seconds
    total_checks: u64,
    successful_checks: u64,
    failed_checks: u64,
    response_times: VecDeque<f64>, // last 100 response times
    consecutive_failures: u64,
    longest_uptime: u64,
    shortest_downtime: u64,
    current_uptime_start: Option<DateTime<Utc>>,
    current_downtime_start: Option<DateTime<Utc>>,
}

impl Default for ConnectionMonitor {
    fn default() -> Self {
        Self {
            current_status: "disconnected".to_string(),
            start_time: Utc::now(),
            last_connected: None,
            last_disconnected: None,
            total_uptime: 0,
            total_downtime: 0,
            total_checks: 0,
            successful_checks: 0,
            failed_checks: 0,
            response_times: VecDeque::with_capacity(100),
            consecutive_failures: 0,
            longest_uptime: 0,
            shortest_downtime: u64::MAX,
            current_uptime_start: None,
            current_downtime_start: Some(Utc::now()),
        }
    }
}

impl ConnectionMonitor {
    fn update_check(&mut self, success: bool, response_time: f64) {
        let now = Utc::now();
        self.total_checks += 1;

        // Track response times (keep last 100)
        if self.response_times.len() >= 100 {
            self.response_times.pop_front();
        }
        self.response_times.push_back(response_time);

        if success {
            self.successful_checks += 1;
            self.consecutive_failures = 0;

            // Update connected state
            if self.current_status != "connected" {
                self.current_status = "connected".to_string();
                self.last_connected = Some(now);

                // Calculate downtime period
                if let Some(downtime_start) = self.current_downtime_start {
                    let downtime_duration = (now - downtime_start).num_seconds() as u64;
                    self.total_downtime += downtime_duration;
                    if downtime_duration < self.shortest_downtime {
                        self.shortest_downtime = downtime_duration;
                    }
                    self.current_downtime_start = None;
                }

                self.current_uptime_start = Some(now);
            }
        } else {
            self.failed_checks += 1;
            self.consecutive_failures += 1;

            // Update disconnected state
            if self.current_status != "disconnected" {
                self.current_status = "disconnected".to_string();
                self.last_disconnected = Some(now);

                // Calculate uptime period
                if let Some(uptime_start) = self.current_uptime_start {
                    let uptime_duration = (now - uptime_start).num_seconds() as u64;
                    self.total_uptime += uptime_duration;
                    if uptime_duration > self.longest_uptime {
                        self.longest_uptime = uptime_duration;
                    }
                    self.current_uptime_start = None;
                }

                self.current_downtime_start = Some(now);
            }
        }

        // Update current periods
        let now = Utc::now();
        if let Some(uptime_start) = self.current_uptime_start {
            let current_uptime = (now - uptime_start).num_seconds() as u64;
            if current_uptime > self.longest_uptime {
                self.longest_uptime = current_uptime;
            }
        }

        if let Some(downtime_start) = self.current_downtime_start {
            let current_downtime = (now - downtime_start).num_seconds() as u64;
            if current_downtime < self.shortest_downtime && current_downtime > 0 {
                self.shortest_downtime = current_downtime;
            }
        }
    }

    fn get_status(&self) -> ConnectionStatus {
        let now = Utc::now();
        let total_time = (now - self.start_time).num_seconds() as u64;

        // Include the current open session so percentage isn't 0 while connected
        let current_session = if let Some(start) = self.current_uptime_start {
            (now - start).num_seconds().max(0) as u64
        } else {
            0
        };
        let uptime_percentage = if total_time > 0 {
            ((self.total_uptime + current_session) as f64 / total_time as f64 * 100.0).min(100.0)
        } else {
            0.0
        };

        let current_uptime = if let Some(uptime_start) = self.current_uptime_start {
            (now - uptime_start).num_seconds() as u64
        } else {
            0
        };

        let average_response_time = if self.response_times.is_empty() {
            0.0
        } else {
            self.response_times.iter().sum::<f64>() / self.response_times.len() as f64
        };

        let response_time_last_check = self.response_times.back().copied().unwrap_or(0.0);

        // Determine status based on recent performance
        let status = if self.consecutive_failures >= 3 {
            "disconnected".to_string()
        } else if self.consecutive_failures >= 1 || response_time_last_check > 1000.0 {
            "degraded".to_string()
        } else {
            self.current_status.clone()
        };

        ConnectionStatus {
            status,
            uptime_duration: current_uptime,
            uptime_percentage,
            last_connected: self.last_connected,
            last_disconnected: self.last_disconnected,
            total_checks: self.total_checks,
            successful_checks: self.successful_checks,
            failed_checks: self.failed_checks,
            average_response_time,
            response_time_last_check,
            consecutive_failures: self.consecutive_failures,
            longest_uptime: self.longest_uptime,
            shortest_downtime: if self.shortest_downtime == u64::MAX {
                0
            } else {
                self.shortest_downtime
            },
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct RawLogEvent {
    id: String,
    timestamp: DateTime<Utc>,
    source_ip: String,
    dest_ip: String,
    source_port: u16,
    dest_port: u16,
    protocol: String,
    payload: String,
    severity: u8,
    event_type: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct TrafficEvent {
    id: String,
    timestamp: DateTime<Utc>,
    source_ip: String,
    dest_ip: String,
    source_port: u16,
    dest_port: u16,
    protocol: String,
    payload: serde_json::Value,
    threat_level: u8,
    event_type: String,
}

#[derive(Debug, Serialize)]
struct CollectorResponse {
    success: bool,
    message: String,
    event_id: String,
    forwarded: bool,
}

#[derive(Debug, Serialize)]
struct StatusResponse {
    status: String,
    timestamp: DateTime<Utc>,
    service: String,
    metrics: CollectorMetrics,
    vps_connection: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    env_logger::init();

    info!("Starting Raspi Collector Service");

    // Get VPS endpoint from environment
    let vps_endpoint =
        std::env::var("VPS_ENDPOINT").unwrap_or_else(|_| "http://vps-processor:8093".to_string());
    let api_key = std::env::var("API_KEY").unwrap_or_default();

    let vps_client = Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;

    let vps_ws_url_for_debug = std::env::var("VPS_WS_URL")
        .unwrap_or_else(|_| "wss://idps.brentweb.eu/ws/raspi".to_string());
    let network_filter_url_for_debug = std::env::var("NETWORK_FILTER_URL")
        .unwrap_or_else(|_| "http://localhost:8092/api/v1".to_string());

    let state = Arc::new(AppState {
        vps_client: vps_client.clone(),
        metrics: Arc::new(RwLock::new(CollectorMetrics::default())),
        vps_endpoint: vps_endpoint.clone(),
        api_key,
        connection_monitor: Arc::new(RwLock::new(ConnectionMonitor::default())),
        ws_debug: Arc::new(RwLock::new(WsDebugState::new(
            &vps_ws_url_for_debug,
            &network_filter_url_for_debug,
        ))),
    });

    let app = Router::new()
        .route("/", get(health_check))
        .route("/health", get(health_check))
        .route("/status", get(get_status))
        .route("/metrics", get(get_metrics))
        .route("/connection", get(get_connection_status))
        .route("/debug", get(get_debug_state))
        .route("/collect", post(collect_log))
        .route("/collect/batch", post(collect_batch_logs))
        .route("/simulate", post(simulate_logs))
        .with_state(state.clone());

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
    info!("Raspi Collector listening on 0.0.0.0:8080");
    info!("Forwarding events to VPS at: {}", vps_endpoint);

    // Spawn background task: maintain WebSocket connection to VPS API Gateway,
    // receive block_command / unblock_command messages and forward them to the
    // local network-filter service which applies iptables rules on this device.
    let vps_ws_url = std::env::var("VPS_WS_URL")
        .unwrap_or_else(|_| "wss://idps.brentweb.eu/ws/raspi".to_string());
    let network_filter_url = std::env::var("NETWORK_FILTER_URL")
        .unwrap_or_else(|_| "http://localhost:8092/api/v1".to_string());
    let ws_http_client = Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;

    // Append api_key query param so VPS middleware accepts the connection
    let vps_ws_url_auth = if state.api_key.is_empty() {
        vps_ws_url
    } else {
        format!("{}?api_key={}", vps_ws_url, state.api_key)
    };

    // Spawn connection monitoring task
    let connection_monitor = state.connection_monitor.clone();
    let vps_client_for_monitor = vps_client.clone();
    let vps_endpoint_for_monitor = vps_endpoint.clone();
    tokio::spawn(start_connection_monitoring(
        connection_monitor,
        vps_client_for_monitor,
        vps_endpoint_for_monitor,
    ));

    tokio::spawn(run_vps_command_listener(
        vps_ws_url_auth,
        network_filter_url,
        ws_http_client,
        state.ws_debug.clone(),
    ));

    // Spawn background task: tail Suricata eve.json and forward events to VPS
    let eve_path = std::env::var("SURICATA_EVE_PATH")
        .unwrap_or_else(|_| "/var/log/suricata/eve.json".to_string());
    tokio::spawn(tail_eve_json(state.clone(), eve_path));

    axum::serve(listener, app).await?;

    Ok(())
}

/// Connects to the VPS API Gateway WebSocket endpoint and listens for
/// `block_command` and `unblock_command` messages, forwarding each to the
/// local network-filter service so iptables rules are applied on this device.
/// On each (re)connect, fetch all active blocked IPs from the VPS and re-apply them
/// to the local network-filter so blocks issued while offline are not lost.
async fn sync_active_blocks(
    vps_api_url: &str,
    network_filter_url: &str,
    api_key: &str,
    client: &Client,
) {
    let url = format!("{}/prevention/blocked", vps_api_url.trim_end_matches('/'));
    let resp = match client.get(&url).header("X-API-Key", api_key).send().await {
        Ok(r) => r,
        Err(e) => {
            warn!("sync_active_blocks: failed to reach VPS: {}", e);
            return;
        }
    };
    if !resp.status().is_success() {
        warn!("sync_active_blocks: VPS returned {}", resp.status());
        return;
    }
    let body: serde_json::Value = match resp.json().await {
        Ok(v) => v,
        Err(e) => {
            warn!("sync_active_blocks: failed to parse response: {}", e);
            return;
        }
    };
    let blocks = body
        .get("data")
        .and_then(|d| d.as_array())
        .cloned()
        .unwrap_or_default();
    info!(
        "sync_active_blocks: syncing {} active blocks from VPS",
        blocks.len()
    );
    for block in &blocks {
        let ip = block.get("ip").and_then(|v| v.as_str()).unwrap_or("");
        let reason = block
            .get("reason")
            .and_then(|v| v.as_str())
            .unwrap_or("vps_sync");
        let severity = block.get("severity").and_then(|v| v.as_u64()).unwrap_or(5);
        if ip.is_empty() {
            continue;
        }
        let body = serde_json::json!({
            "ip": ip,
            "reason": reason,
            "duration_hours": 24,
            "threat_level": severity,
            "source": "vps_sync"
        });
        let block_url = format!("{}/block", network_filter_url);
        if let Err(e) = client.post(&block_url).json(&body).send().await {
            warn!(
                "sync_active_blocks: failed to apply block for {}: {}",
                ip, e
            );
        }
    }
}

async fn run_vps_command_listener(
    vps_ws_url: String,
    network_filter_url: String,
    client: Client,
    ws_debug: Arc<RwLock<WsDebugState>>,
) {
    let vps_api_url = std::env::var("VPS_ENDPOINT")
        .unwrap_or_else(|_| "https://idps.brentweb.eu/api/vps".to_string());
    let api_key = std::env::var("API_KEY").unwrap_or_default();
    loop {
        info!("Connecting to VPS WebSocket at {}", vps_ws_url);
        {
            let mut dbg = ws_debug.write().await;
            dbg.connected = false;
            dbg.last_disconnected_at = Some(Utc::now());
            dbg.reconnect_count += 1;
        }
        match connect_async(&vps_ws_url).await {
            Ok((ws_stream, _)) => {
                info!("Connected to VPS WebSocket");
                {
                    let mut dbg = ws_debug.write().await;
                    dbg.connected = true;
                    dbg.last_connected_at = Some(Utc::now());
                }

                // Send sensor registration to VPS
                let sensor_id = std::env::var("SENSOR_ID").unwrap_or_else(|_| "default".to_string());
                let tenant_id = std::env::var("TENANT_ID").unwrap_or_else(|_| "default".to_string());
                let hostname = hostname::get().map(|h| h.to_string_lossy().to_string()).unwrap_or_default();

                let registration = serde_json::json!({
                    "type": "sensor_register",
                    "sensor_id": sensor_id,
                    "tenant_id": tenant_id,
                    "hostname": hostname,
                    "capabilities": ["ids", "ips", "packet-capture"],
                });

                if let Err(e) = ws_stream.send(Message::Text(registration.to_string())).await {
                    warn!("Failed to send sensor registration: {}", e);
                }

                // Replay all active blocks so offline-issued blocks take effect
                sync_active_blocks(&vps_api_url, &network_filter_url, &api_key, &client).await;
                // Probe network-filter reachability
                let nf_ok = client
                    .get(format!("{}/health", &network_filter_url))
                    .timeout(std::time::Duration::from_secs(3))
                    .send()
                    .await
                    .map(|r| r.status().is_success())
                    .unwrap_or(false);
                {
                    ws_debug.write().await.network_filter_reachable = Some(nf_ok);
                }

                let (_, mut read) = ws_stream.split();
                while let Some(msg) = read.next().await {
                    match msg {
                        Ok(Message::Text(text)) => {
                            let success =
                                handle_vps_command(&text, &network_filter_url, &client, &ws_debug)
                                    .await
                                    .is_ok();
                            if !success {
                                warn!(
                                    "Failed to handle VPS command: {}",
                                    text.chars().take(120).collect::<String>()
                                );
                            }
                        }
                        Ok(Message::Close(_)) => {
                            info!("VPS WebSocket connection closed, reconnecting…");
                            break;
                        }
                        Err(e) => {
                            warn!("VPS WebSocket error: {}, reconnecting…", e);
                            break;
                        }
                        _ => {}
                    }
                }
                {
                    ws_debug.write().await.connected = false;
                }
            }
            Err(e) => {
                warn!(
                    "Failed to connect to VPS WebSocket at {}: {}",
                    vps_ws_url, e
                );
            }
        }
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    }
}

/// Parses a JSON command received from the VPS and forwards it to the local
/// network-filter and rule-engine services.
async fn handle_vps_command(
    text: &str,
    network_filter_url: &str,
    client: &Client,
    ws_debug: &Arc<RwLock<WsDebugState>>,
) -> Result<(), Box<dyn std::error::Error>> {
    let rule_engine_url = std::env::var("RULE_ENGINE_URL")
        .unwrap_or_else(|_| "http://rule-engine:8094/api/v1".to_string());

    let value: serde_json::Value = serde_json::from_str(text)?;
    let cmd_type = value.get("type").and_then(|t| t.as_str()).unwrap_or("");
    match cmd_type {
        "block_command" => {
            let ip = value.get("ip").and_then(|v| v.as_str()).unwrap_or("");
            let reason = value
                .get("reason")
                .and_then(|v| v.as_str())
                .unwrap_or("VPS command");
            let duration_secs = value
                .get("duration_secs")
                .and_then(|v| v.as_u64())
                .unwrap_or(3600);
            let severity = value.get("severity").and_then(|v| v.as_u64()).unwrap_or(5);
            info!(
                "Received block_command for {} from VPS, forwarding to network-filter",
                ip
            );
            let body = serde_json::json!({
                "ip": ip,
                "reason": reason,
                "duration_hours": (duration_secs / 3600).max(1),
                "threat_level": severity,
                "source": "vps_command"
            });
            let url = format!("{}/block", network_filter_url);
            let resp = client.post(&url).json(&body).send().await?;
            let ok = resp.status().is_success();
            if !ok {
                let status = resp.status();
                let body_text = resp.text().await.unwrap_or_default();
                error!(
                    "network-filter rejected block for {}: HTTP {} — {}",
                    ip, status, body_text
                );
            }
            ws_debug
                .write()
                .await
                .record_command("block_command", ip, reason, ok);
        }
        "unblock_command" => {
            let ip = value.get("ip").and_then(|v| v.as_str()).unwrap_or("");
            let reason = value
                .get("reason")
                .and_then(|v| v.as_str())
                .unwrap_or("VPS command");
            info!(
                "Received unblock_command for {} from VPS, forwarding to network-filter",
                ip
            );
            let body = serde_json::json!({ "ip": ip, "reason": reason });
            let url = format!("{}/unblock", network_filter_url);
            let resp = client.post(&url).json(&body).send().await?;
            let ok = resp.status().is_success();
            if !ok {
                error!(
                    "network-filter rejected unblock for {}: HTTP {}",
                    ip,
                    resp.status()
                );
            }
            ws_debug
                .write()
                .await
                .record_command("unblock_command", ip, reason, ok);
        }
        "rule_update" => {
            // Forward Suricata and/or iptables rules to the local rule-engine.
            let rule_id = value
                .get("rule_id")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            let suricata_rule = value.get("suricata_rule").and_then(|v| v.as_str());
            let iptables_rule = value.get("iptables_rule").and_then(|v| v.as_str());
            info!(
                "Received rule_update {} from VPS, forwarding to rule-engine",
                rule_id
            );
            let body = serde_json::json!({
                "suricata_rule": suricata_rule,
                "iptables_rule": iptables_rule,
            });
            let url = format!("{}/rules/apply", rule_engine_url);
            match client.post(&url).json(&body).send().await {
                Ok(resp) if resp.status().is_success() => {
                    info!("rule-engine applied rule {}", rule_id);
                }
                Ok(resp) => {
                    error!(
                        "rule-engine rejected rule {}: HTTP {}",
                        rule_id,
                        resp.status()
                    );
                }
                Err(e) => {
                    warn!("Could not reach rule-engine for rule {}: {}", rule_id, e);
                }
            }
        }
        other if !other.is_empty() => {
            // Ignore unknown message types (heartbeats, pings, etc.)
        }
        _ => {}
    }
    Ok(())
}

async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "healthy",
        "timestamp": Utc::now(),
        "service": "raspi-collector"
    }))
}

async fn get_debug_state(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
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

async fn get_status(State(state): State<Arc<AppState>>) -> Json<StatusResponse> {
    let metrics = state.metrics.read().await.clone();
    let connection_status = state.connection_monitor.read().await.get_status();

    Json(StatusResponse {
        status: "running".to_string(),
        timestamp: Utc::now(),
        service: "raspi-collector".to_string(),
        metrics,
        vps_connection: connection_status.status.clone(),
    })
}

async fn get_connection_status(State(state): State<Arc<AppState>>) -> Json<ConnectionStatus> {
    let connection_status = state.connection_monitor.read().await.get_status();
    Json(connection_status)
}

async fn get_metrics(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
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

async fn collect_log(
    State(state): State<Arc<AppState>>,
    Json(log_event): Json<RawLogEvent>,
) -> Result<Json<CollectorResponse>, StatusCode> {
    info!(
        "Collecting log event: {} from {} to {}",
        log_event.id, log_event.source_ip, log_event.dest_ip
    );

    // Update metrics
    {
        let mut metrics = state.metrics.write().await;
        metrics.events_collected += 1;
        metrics.last_collection = Some(Utc::now());
        metrics.collection_rate = calculate_collection_rate(&metrics).await;
    }

    // Convert to TrafficEvent
    let traffic_event = convert_to_traffic_event(log_event).await;
    let event_id_fallback = traffic_event.id.clone();

    // Send to VPS
    match send_to_vps(&state, traffic_event).await {
        Ok(event_id) => {
            // Update sent metrics
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
            error!("Failed to forward log to VPS: {}", e);
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

async fn collect_batch_logs(
    State(state): State<Arc<AppState>>,
    Json(log_events): Json<Vec<RawLogEvent>>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let batch_size = log_events.len();
    info!("Collecting batch of {} log events", batch_size);

    // Update metrics
    {
        let mut metrics = state.metrics.write().await;
        metrics.events_collected += batch_size as u64;
        metrics.last_collection = Some(Utc::now());
        metrics.collection_rate = calculate_collection_rate(&metrics).await;
    }

    // Convert to TrafficEvents
    let mut traffic_events = Vec::new();
    for log_event in log_events {
        traffic_events.push(convert_to_traffic_event(log_event).await);
    }

    // Send batch to VPS
    match send_batch_to_vps(&state, traffic_events).await {
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
            error!("Failed to forward batch to VPS: {}", e);
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

async fn simulate_logs(
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    info!("Generating simulated log events");

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

    // Process the simulated events
    let batch_size = simulated_events.len();

    // Update metrics
    {
        let mut metrics = state.metrics.write().await;
        metrics.events_collected += batch_size as u64;
        metrics.last_collection = Some(Utc::now());
        metrics.collection_rate = calculate_collection_rate(&metrics).await;
    }

    // Convert to TrafficEvents
    let mut traffic_events = Vec::new();
    for log_event in simulated_events {
        traffic_events.push(convert_to_traffic_event(log_event).await);
    }

    // Send batch to VPS
    match send_batch_to_vps(&state, traffic_events).await {
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
            error!("Failed to forward simulated events to VPS: {}", e);
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

async fn convert_to_traffic_event(log_event: RawLogEvent) -> TrafficEvent {
    let payload_value: serde_json::Value = match serde_json::from_str(&log_event.payload) {
        Ok(value) => value,
        Err(_) => serde_json::json!({"raw": log_event.payload}),
    };

    TrafficEvent {
        id: log_event.id,
        timestamp: log_event.timestamp,
        source_ip: log_event.source_ip,
        dest_ip: log_event.dest_ip,
        source_port: log_event.source_port,
        dest_port: log_event.dest_port,
        protocol: log_event.protocol,
        payload: payload_value,
        threat_level: log_event.severity,
        event_type: log_event.event_type,
    }
}

async fn send_to_vps(
    state: &AppState,
    traffic_event: TrafficEvent,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let url = format!("{}/traffic", state.vps_endpoint);

    let mut req = state.vps_client.post(&url).json(&traffic_event);
    if !state.api_key.is_empty() {
        req = req.header("x-api-key", &state.api_key);
    }
    let response = req.send().await?;

    if response.status().is_success() {
        let result: serde_json::Value = response.json().await?;
        Ok(result["event_id"].as_str().unwrap_or("unknown").to_string())
    } else {
        Err(format!("VPS returned status: {}", response.status()).into())
    }
}

async fn send_batch_to_vps(
    state: &AppState,
    traffic_events: Vec<TrafficEvent>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let url = format!("{}/traffic/batch", state.vps_endpoint);

    let mut req = state.vps_client.post(&url).json(&traffic_events);
    if !state.api_key.is_empty() {
        req = req.header("x-api-key", &state.api_key);
    }
    let response = req.send().await?;

    if response.status().is_success() {
        Ok(())
    } else {
        Err(format!("VPS batch returned status: {}", response.status()).into())
    }
}

async fn start_connection_monitoring(
    connection_monitor: Arc<RwLock<ConnectionMonitor>>,
    vps_client: Client,
    vps_endpoint: String,
) {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(10));

    loop {
        interval.tick().await;

        let start_time = std::time::Instant::now();
        let url = format!("{}/health", vps_endpoint);

        match vps_client.get(&url).send().await {
            Ok(response) => {
                let response_time = start_time.elapsed().as_millis() as f64;
                let success = response.status().is_success();

                {
                    let mut monitor = connection_monitor.write().await;
                    monitor.update_check(success, response_time);
                }

                if success {
                    debug!("VPS health check successful ({}ms)", response_time);
                } else {
                    warn!("VPS health check failed: HTTP {}", response.status());
                }
            }
            Err(e) => {
                let response_time = start_time.elapsed().as_millis() as f64;
                warn!("VPS health check error: {} ({}ms)", e, response_time);

                let mut monitor = connection_monitor.write().await;
                monitor.update_check(false, response_time);
            }
        }
    }
}

async fn calculate_collection_rate(metrics: &CollectorMetrics) -> f64 {
    if let Some(last_collection) = metrics.last_collection {
        let duration_since_last = Utc::now() - last_collection;
        let seconds = duration_since_last.num_seconds();
        if seconds > 0 {
            metrics.events_collected as f64 / seconds as f64
        } else {
            0.0
        }
    } else {
        0.0
    }
}

/// Tail Suricata's eve.json and forward new events to the VPS in batches.
///
/// Seeks to the end of the file on startup (skips historical events), then
/// reads new lines as they are appended.  Each line is a JSON object in the
/// Suricata EVE format.  Lines are batched and sent every 5 seconds (or when
/// the batch reaches 50 events) to avoid spamming the VPS on high-traffic
/// networks.
async fn tail_eve_json(state: Arc<AppState>, eve_path: String) {
    // Wait up to 60 s for the file to appear (Suricata may start after us)
    let file = loop {
        match tokio::fs::File::open(&eve_path).await {
            Ok(f) => break f,
            Err(_) => {
                info!("eve.json not found at {}, retrying in 10 s…", eve_path);
                tokio::time::sleep(std::time::Duration::from_secs(10)).await;
            }
        }
    };

    // Seek to end so we only forward events that arrive after startup
    use tokio::io::AsyncSeekExt;
    let mut file = file;
    let end = match file.seek(std::io::SeekFrom::End(0)).await {
        Ok(pos) => pos,
        Err(e) => {
            error!("Failed to seek eve.json: {}", e);
            return;
        }
    };
    info!("Tailing {} from byte offset {}", eve_path, end);

    let mut reader = BufReader::new(file);
    let mut batch: Vec<TrafficEvent> = Vec::new();
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));

    loop {
        tokio::select! {
            // Try to read a new line
            line_result = async {
                let mut line = String::new();
                reader.read_line(&mut line).await.map(|n| (n, line))
            } => {
                match line_result {
                    Ok((0, _)) => {
                        // EOF — file has not grown yet; yield and wait for the tick
                        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                    }
                    Ok((_, line)) => {
                        let line = line.trim();
                        if line.is_empty() { continue; }
                        if let Some(event) = parse_eve_line(line) {
                            batch.push(event);
                            // Flush early if batch is large enough
                            if batch.len() >= 50 {
                                flush_batch(&state, &mut batch).await;
                            }
                        }
                    }
                    Err(e) => {
                        warn!("Error reading eve.json: {}", e);
                        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    }
                }
            }

            // Periodic flush
            _ = interval.tick() => {
                if !batch.is_empty() {
                    flush_batch(&state, &mut batch).await;
                }
            }
        }
    }
}

/// Parse one Suricata EVE JSON line into a TrafficEvent.
/// Only alerts are forwarded; internal engine noise is dropped.
fn parse_eve_line(line: &str) -> Option<TrafficEvent> {
    let v: serde_json::Value = serde_json::from_str(line).ok()?;

    // Only forward real alerts, drop flows/dns/http/stats/etc.
    if v["event_type"].as_str() != Some("alert") {
        return None;
    }

    // Drop internal Suricata engine events (checksum errors, stream anomalies, etc.)
    let signature = v["alert"]["signature"].as_str().unwrap_or("");
    if signature.starts_with("SURICATA ") || signature.starts_with("ET INFO ") {
        return None;
    }

    let src_ip = v["src_ip"].as_str().unwrap_or("").to_string();
    if src_ip.is_empty() {
        return None;
    }

    let threat_level: u8 = v["alert"]["severity"]
        .as_u64()
        .map(|s| match s {
            1 => 9,
            2 => 6,
            3 => 3,
            _ => 1,
        })
        .unwrap_or(1) as u8;

    Some(TrafficEvent {
        id: Uuid::new_v4().to_string(),
        timestamp: v["timestamp"]
            .as_str()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|dt| dt.with_timezone(&Utc))
            .unwrap_or_else(Utc::now),
        source_ip: src_ip,
        dest_ip: v["dest_ip"].as_str().unwrap_or("").to_string(),
        source_port: v["src_port"].as_u64().unwrap_or(0) as u16,
        dest_port: v["dest_port"].as_u64().unwrap_or(0) as u16,
        protocol: v["proto"].as_str().unwrap_or("unknown").to_string(),
        payload: v.clone(),
        threat_level,
        event_type: v["event_type"].as_str().unwrap_or("unknown").to_string(),
    })
}

async fn flush_batch(state: &Arc<AppState>, batch: &mut Vec<TrafficEvent>) {
    let events = std::mem::take(batch);
    let count = events.len();
    {
        let mut metrics = state.metrics.write().await;
        metrics.events_collected += count as u64;
        metrics.last_collection = Some(Utc::now());
    }
    match send_batch_to_vps(state, events).await {
        Ok(()) => {
            let mut metrics = state.metrics.write().await;
            metrics.events_sent += count as u64;
            debug!("Forwarded {} eve.json events to VPS", count);
        }
        Err(e) => {
            let mut metrics = state.metrics.write().await;
            metrics.failed_sends += count as u64;
            warn!("Failed to forward {} eve.json events: {}", count, e);
        }
    }
}
