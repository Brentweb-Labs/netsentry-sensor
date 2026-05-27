//! Business logic services for raspi-collector.

use std::sync::Arc;

use chrono::Utc;
use futures_util::{SinkExt, StreamExt};
use log::{debug, error, info, warn};
use reqwest::Client;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::RwLock;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use uuid::Uuid;

use crate::models::{AppState, CollectorMetrics, ConnectionMonitor, TrafficEvent, WsDebugState};

/// Convert raw log event to traffic event.
pub async fn convert_to_traffic_event(log_event: super::controllers::RawLogEvent) -> TrafficEvent {
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

/// Send a single traffic event to VPS.
pub async fn send_to_vps(
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

/// Send batch of traffic events to VPS.
pub async fn send_batch_to_vps(
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

/// Start connection monitoring for VPS health checks.
pub async fn start_connection_monitoring(
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

/// Calculate collection rate from metrics.
pub async fn calculate_collection_rate(metrics: &CollectorMetrics) -> f64 {
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

/// Sync active blocks from VPS on connect.
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

/// Handle VPS command and forward to network-filter/rule-engine.
pub async fn handle_vps_command(
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
            // Ignore unknown message types
        }
        _ => {}
    }
    Ok(())
}

/// Run the VPS WebSocket command listener.
pub async fn run_vps_command_listener(
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
            Ok((mut ws_stream, _)) => {
                info!("Connected to VPS WebSocket");
                {
                    let mut dbg = ws_debug.write().await;
                    dbg.connected = true;
                    dbg.last_connected_at = Some(Utc::now());
                }

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

                if let Err(e) = ws_stream.send(Message::Text(registration.to_string().into())).await {
                    warn!("Failed to send sensor registration: {}", e);
                }

                sync_active_blocks(&vps_api_url, &network_filter_url, &api_key, &client).await;

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
                            let text_str = text.to_string();
                            let success =
                                handle_vps_command(&text_str, &network_filter_url, &client, &ws_debug)
                                    .await
                                    .is_ok();
                            if !success {
                                warn!(
                                    "Failed to handle VPS command: {}",
                                    text_str.chars().take(120).collect::<String>()
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

/// Parse Suricata EVE JSON line into TrafficEvent.
pub fn parse_eve_line(line: &str) -> Option<TrafficEvent> {
    let v: serde_json::Value = serde_json::from_str(line).ok()?;

    if v["event_type"].as_str() != Some("alert") {
        return None;
    }

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

/// Flush batch of events to VPS.
pub async fn flush_batch(state: &Arc<AppState>, batch: &mut Vec<TrafficEvent>) {
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

/// Tail Suricata's eve.json and forward events to VPS.
pub async fn tail_eve_json(state: Arc<AppState>, eve_path: String) {
    let file = loop {
        match tokio::fs::File::open(&eve_path).await {
            Ok(f) => break f,
            Err(_) => {
                info!("eve.json not found at {}, retrying in 10 s…", eve_path);
                tokio::time::sleep(std::time::Duration::from_secs(10)).await;
            }
        }
    };

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
            line_result = async {
                let mut line = String::new();
                reader.read_line(&mut line).await.map(|n| (n, line))
            } => {
                match line_result {
                    Ok((0, _)) => {
                        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                    }
                    Ok((_, line)) => {
                        let line = line.trim();
                        if line.is_empty() {
                            continue;
                        }
                        if let Some(event) = parse_eve_line(line) {
                            batch.push(event);
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

            _ = interval.tick() => {
                if !batch.is_empty() {
                    flush_batch(&state, &mut batch).await;
                }
            }
        }
    }
}
