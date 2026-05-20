use dashmap::DashMap;
use futures_util::{SinkExt, StreamExt};
use log::{error, info, warn};
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio::sync::mpsc;
use tokio::time::{interval, Duration};
use tokio_tungstenite::{connect_async, tungstenite::Message as WsMsg};

/// A raw packet captured from the network interface, ready to be streamed to the VPS.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct StreamedPacket {
    pub id: String,
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub src_ip: String,
    pub dst_ip: String,
    pub src_port: u16,
    pub dst_port: u16,
    pub protocol: String,
    /// First 256 bytes of the IP payload as hex — enough for pattern matching without leaking full data.
    pub payload_hex: String,
    pub packet_size: usize,
    pub interface: String,
}

/// Information about a blocked IP address
#[derive(Debug, Clone)]
struct BlockedIpInfo {
    /// When the block was applied
    blocked_at: Instant,
    /// When the block should expire (None for permanent blocks)
    expires_at: Option<Instant>,
    /// Reason for the block
    reason: String,
}

/// Shared set of IPs that are currently blocked by the Raspi.
/// Populated from VPS block/unblock commands; used by the pcap loop to skip
/// packets whose source is already being dropped by iptables.
type BlockedIps = Arc<DashMap<String, BlockedIpInfo>>;

/// Capture raw packets from `interface` using libpcap and forward them to the
/// `packet_tx` channel for streaming to the VPS.
///
/// The capture is **fail-open**: if libpcap fails to open the device, or if the
/// sender channel is full, packets are silently skipped.  Traffic is never held
/// up waiting for pcap — this is a passive mirror.
async fn run_pcap_capture(
    interface: String,
    blocked_ips: BlockedIps,
    packet_tx: mpsc::Sender<StreamedPacket>,
) {
    loop {
        let iface = interface.clone();
        let blocked = blocked_ips.clone();
        let tx = packet_tx.clone();

        let result = tokio::task::spawn_blocking(move || {
            let cap = match pcap::Capture::from_device(iface.as_str()) {
                Ok(c) => match c.promisc(true).snaplen(1500).timeout(1000).open() {
                    Ok(c) => c,
                    Err(e) => {
                        error!("Failed to open pcap device {}: {}", iface, e);
                        return;
                    }
                },
                Err(e) => {
                    error!("Failed to find pcap device '{}': {}", iface, e);
                    return;
                }
            };

            info!("pcap capture started on interface '{}'", iface);
            let mut cap = cap;

            while let Ok(packet) = cap.next_packet() {
                match etherparse::PacketHeaders::from_ethernet_slice(packet.data) {
                    Ok(headers) => {
                        let (src_ip, dst_ip) = extract_ips(&headers);

                        // Skip packets from already-blocked IPs to reduce VPS load.
                        if !src_ip.is_empty() && is_ip_blocked(&src_ip, &blocked) {
                            continue;
                        }

                        let (src_port, dst_port, protocol) = extract_transport(&headers);

                        // Drop broadcast / multicast / internal-only / housekeeping traffic.
                        if is_junk_packet(&src_ip, &dst_ip, &protocol, dst_port) {
                            continue;
                        }

                        // Capture up to 256 bytes of payload as hex.
                        let payload_bytes: &[u8] = match &headers.payload {
                            etherparse::PayloadSlice::Tcp(b) => b,
                            etherparse::PayloadSlice::Udp(b) => b,
                            etherparse::PayloadSlice::Ip(s) => s.payload,
                            etherparse::PayloadSlice::Ether(s) => s.payload,
                            etherparse::PayloadSlice::Icmpv4(b) => b,
                            etherparse::PayloadSlice::Icmpv6(b) => b,
                        };
                        let payload_hex: String = payload_bytes
                            .iter()
                            .take(256)
                            .map(|b| format!("{:02x}", b))
                            .collect();

                        let pkt = StreamedPacket {
                            id: uuid::Uuid::new_v4().to_string(),
                            timestamp: chrono::Utc::now(),
                            src_ip,
                            dst_ip,
                            src_port,
                            dst_port,
                            protocol,
                            payload_hex,
                            packet_size: packet.data.len(),
                            interface: iface.clone(),
                        };

                        // Fire-and-forget: use `try_send` so we never block the capture thread.
                        if tx.try_send(pkt).is_err() {
                            // Channel full — VPS analysis is lagging; skip this packet.
                        }
                    }
                    Err(_) => {} // Non-Ethernet or malformed frame — ignore.
                }
            }
        })
        .await;

        if let Err(e) = result {
            error!("pcap capture task panicked: {:?}", e);
        }

        warn!("pcap capture stopped on '{}', restarting in 5s…", interface);
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

fn extract_ips(headers: &etherparse::PacketHeaders<'_>) -> (String, String) {
    match &headers.net {
        Some(etherparse::NetHeaders::Ipv4(ipv4, _)) => {
            let src = std::net::Ipv4Addr::from(ipv4.source).to_string();
            let dst = std::net::Ipv4Addr::from(ipv4.destination).to_string();
            (src, dst)
        }
        Some(etherparse::NetHeaders::Ipv6(ipv6, _)) => {
            let src = std::net::Ipv6Addr::from(ipv6.source).to_string();
            let dst = std::net::Ipv6Addr::from(ipv6.destination).to_string();
            (src, dst)
        }
        None => (String::new(), String::new()),
    }
}

fn extract_transport(headers: &etherparse::PacketHeaders<'_>) -> (u16, u16, String) {
    match &headers.transport {
        Some(etherparse::TransportHeader::Tcp(tcp)) => {
            (tcp.source_port, tcp.destination_port, "TCP".to_string())
        }
        Some(etherparse::TransportHeader::Udp(udp)) => {
            (udp.source_port, udp.destination_port, "UDP".to_string())
        }
        Some(etherparse::TransportHeader::Icmpv4(_)) => (0, 0, "ICMP".to_string()),
        Some(etherparse::TransportHeader::Icmpv6(_)) => (0, 0, "ICMPv6".to_string()),
        None => (0, 0, "unknown".to_string()),
    }
}

/// Periodically cleanup expired IP blocks
async fn run_ttl_cleanup(blocked_ips: BlockedIps, cleanup_interval_secs: u64) {
    let mut interval = interval(Duration::from_secs(cleanup_interval_secs));

    loop {
        interval.tick().await;

        let now = Instant::now();
        let mut expired_ips = Vec::new();

        // Find expired IPs
        for entry in blocked_ips.iter() {
            if let Some(expires_at) = entry.value().expires_at {
                if now >= expires_at {
                    expired_ips.push(entry.key().clone());
                }
            }
        }

        // Remove expired IPs and clean up iptables rules
        for ip in &expired_ips {
            info!("TTL expired for IP {}, removing block", ip);
            blocked_ips.remove(ip);
            remove_iptables_block(ip);
            remove_suricata_rule(ip);
        }

        if !expired_ips.is_empty() {
            info!("TTL cleanup completed: {} IPs unblocked", expired_ips.len());
        }
    }
}

/// Returns true for RFC 1918 / loopback / link-local / broadcast addresses.
fn is_private_or_local(ip: &str) -> bool {
    // Fast path: parse only the first octet for most checks.
    let octets: Vec<u8> = ip.split('.').filter_map(|p| p.parse().ok()).collect();
    if octets.len() != 4 {
        return false;
    }
    match (octets[0], octets[1]) {
        (10, _) => true,        // 10.0.0.0/8
        (172, 16..=31) => true, // 172.16.0.0/12
        (192, 168) => true,     // 192.168.0.0/16
        (127, _) => true,       // loopback
        (169, 254) => true,     // link-local
        (255, _) => true,       // broadcast
        _ => ip.ends_with(".255") || ip == "255.255.255.255",
    }
}

/// Returns true if this packet is internal-only or otherwise junk and should
/// NOT be forwarded to the VPS (broadcast, multicast, RFC-1918 ↔ RFC-1918).
fn is_junk_packet(src_ip: &str, dst_ip: &str, protocol: &str, dst_port: u16) -> bool {
    // Multicast destination
    if dst_ip.starts_with("224.") || dst_ip.starts_with("239.") || dst_ip.starts_with("255.") {
        return true;
    }
    // Both endpoints are internal — no external threat to report.
    if is_private_or_local(src_ip) && is_private_or_local(dst_ip) {
        return true;
    }
    // Benign high-volume protocols that produce no actionable signal.
    // DNS (53 UDP) queries are handled by Suricata alerts; raw pcap DNS is noise.
    // NTP (123), mDNS (5353), SSDP (1900) are housekeeping traffic.
    if protocol == "UDP" && matches!(dst_port, 53 | 123 | 5353 | 1900) {
        return true;
    }
    false
}

/// Check if an IP is currently blocked (considering TTL)
fn is_ip_blocked(ip: &str, blocked_ips: &BlockedIps) -> bool {
    if let Some(info) = blocked_ips.get(ip) {
        if let Some(expires_at) = info.expires_at {
            Instant::now() < expires_at
        } else {
            true // Permanent block
        }
    } else {
        false
    }
}

/// Streams captured packets to the VPS packet analysis WebSocket endpoint.
///
/// Uses a single long-lived WebSocket connection with automatic reconnect.
/// Packets are sent as JSON text frames with no wait for a response — the
/// response channel is the `/ws/raspi` feed (block commands).
async fn run_packet_ws_streamer(
    ws_url: String,
    mut packet_rx: mpsc::Receiver<StreamedPacket>,
    api_key: String,
) {
    loop {
        info!("Connecting to VPS packet stream WebSocket at {}", ws_url);

        let url = match url::Url::parse(&ws_url) {
            Ok(u) => u,
            Err(e) => {
                error!("Invalid packet stream WS URL '{}': {}", ws_url, e);
                tokio::time::sleep(Duration::from_secs(10)).await;
                continue;
            }
        };

        let mut request = tokio_tungstenite::tungstenite::handshake::client::Request::builder()
            .uri(ws_url.as_str())
            .header("X-API-Key", &api_key);
        if let Some(host) = url.host_str() {
            request = request.header("Host", host);
        }
        let request = match request.body(()) {
            Ok(r) => r,
            Err(e) => {
                error!("Failed to build packet stream WS request: {}", e);
                tokio::time::sleep(Duration::from_secs(5)).await;
                continue;
            }
        };

        match connect_async(request).await {
            Ok((ws_stream, _)) => {
                info!("Connected to VPS packet stream WebSocket");
                let (mut write, _) = ws_stream.split();

                // Send packets until connection drops or channel closes.
                while let Some(pkt) = packet_rx.recv().await {
                    match serde_json::to_string(&pkt) {
                        Ok(json) => {
                            if write.send(WsMsg::Text(json.into())).await.is_err() {
                                warn!("Packet stream WS write failed, reconnecting…");
                                break;
                            }
                        }
                        Err(e) => error!("Failed to serialize packet: {}", e),
                    }
                }
            }
            Err(e) => {
                warn!("Could not connect to packet stream WS ({}), retry in 5s", e);
            }
        }

        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TrafficEvent {
    id: String,
    timestamp: chrono::DateTime<chrono::Utc>,
    source_ip: String,
    dest_ip: String,
    source_port: u16,
    dest_port: u16,
    protocol: String,
    payload: serde_json::Value,
    threat_level: u8,
    event_type: String,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct ProcessorResponse {
    success: bool,
    message: String,
    rule_id: Option<String>,
    processing_time_ms: u64,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct SecurityRule {
    id: String,
    name: String,
    rule_type: String,
    target: String,
    action: String,
    duration: i64,
    created_at: chrono::DateTime<chrono::Utc>,
    active: bool,
}

/// Command received from the VPS via WebSocket (`/ws/raspi`).
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
#[allow(dead_code)]
enum VpsCommand {
    BlockCommand {
        ip: String,
        reason: String,
        duration_secs: u64,
        apply_suricata_rule: bool,
        severity: u8,
        detection_event_id: Option<String>,
    },
    UnblockCommand {
        ip: String,
        reason: String,
        unblocked_by: Option<String>,
    },
    RuleUpdate {
        rule_id: String,
        action: String,
        suricata_rule: Option<String>,
        iptables_rule: Option<String>,
        description: String,
    },
    Connected {},
    Ping {},
}

#[derive(Clone)]
#[allow(dead_code)]
struct Collector {
    vps_url: String,
    raspi_ip: String,
    event_sender: mpsc::Sender<TrafficEvent>,
    /// Tracks byte offset in eve.json so we only read new lines, never re-process old ones.
    file_offset: Arc<AtomicU64>,
}

impl Collector {
    fn new(
        vps_url: String,
        raspi_ip: String,
    ) -> (
        Self,
        mpsc::Receiver<TrafficEvent>,
        mpsc::Sender<SecurityRule>,
        mpsc::Receiver<SecurityRule>,
    ) {
        let (event_tx, event_rx) = mpsc::channel(1000);
        let (rule_tx, rule_rx) = mpsc::channel(100);

        (
            Self {
                vps_url,
                raspi_ip,
                event_sender: event_tx,
                file_offset: Arc::new(AtomicU64::new(0)),
            },
            event_rx,
            rule_tx,
            rule_rx,
        )
    }

    async fn start_file_watcher(&self) -> Result<(), Box<dyn std::error::Error>> {
        let eve_path_str = std::env::var("SURICATA_EVE_PATH")
            .unwrap_or_else(|_| "/var/log/suricata/eve.json".to_string());
        let eve_path = Path::new(&eve_path_str).to_path_buf();

        // Ensure the log directory exists
        if let Some(parent) = eve_path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        let (tx, mut rx) = mpsc::channel::<()>(100);

        let mut watcher: RecommendedWatcher = Watcher::new(
            move |res: Result<Event, _>| {
                if let Ok(event) = res {
                    if matches!(event.kind, EventKind::Modify(_) | EventKind::Create(_)) {
                        let _ = tx.blocking_send(());
                    }
                }
            },
            notify::Config::default(),
        )?;

        watcher.watch(
            eve_path.parent().unwrap_or(Path::new("/")),
            RecursiveMode::NonRecursive,
        )?;

        info!("Watching Suricata EVE log at: {}", eve_path.display());

        // Seek to end on startup so we only process *new* events written after this service starts.
        // This prevents re-sending historical events on every restart.
        if eve_path.exists() {
            let metadata = tokio::fs::metadata(&eve_path).await?;
            self.file_offset.store(metadata.len(), Ordering::SeqCst);
            info!(
                "Starting from offset {} (skipping existing events)",
                metadata.len()
            );
        }

        // Process new bytes whenever the file changes
        while rx.recv().await.is_some() {
            if let Err(e) = self.read_new_lines(&eve_path).await {
                error!("Error reading new lines from eve.json: {}", e);
            }
        }

        Ok(())
    }

    /// Read only the bytes written since the last read and parse any complete JSON lines.
    async fn read_new_lines(
        &self,
        eve_path: &std::path::PathBuf,
    ) -> Result<(), Box<dyn std::error::Error>> {
        if !eve_path.exists() {
            return Ok(());
        }

        let metadata = tokio::fs::metadata(eve_path).await?;
        let file_len = metadata.len();
        let current_offset = self.file_offset.load(Ordering::SeqCst);

        // File was rotated / truncated — reset offset
        if file_len < current_offset {
            warn!("eve.json was rotated or truncated, resetting offset");
            self.file_offset.store(0, Ordering::SeqCst);
        }

        let offset = self.file_offset.load(Ordering::SeqCst);
        if file_len <= offset {
            return Ok(()); // No new data
        }

        let mut file = File::open(eve_path).await?;
        file.seek(std::io::SeekFrom::Start(offset)).await?;

        let mut buf = Vec::new();
        file.read_to_end(&mut buf).await?;

        let new_content = String::from_utf8_lossy(&buf);
        let mut bytes_consumed: u64 = 0;

        for line in new_content.lines() {
            let line_bytes = line.len() as u64 + 1; // +1 for '\n'
            if let Ok(event_value) = serde_json::from_str::<serde_json::Value>(line) {
                if let Some(event) = self.parse_suricata_event(&event_value) {
                    if let Err(e) = self.event_sender.send(event).await {
                        error!("Failed to enqueue event: {}", e);
                    }
                }
            }
            bytes_consumed += line_bytes;
        }

        self.file_offset
            .store(offset + bytes_consumed, Ordering::SeqCst);
        Ok(())
    }

    fn parse_suricata_event(&self, event_value: &serde_json::Value) -> Option<TrafficEvent> {
        // Parse Suricata EVE JSON format
        let event_type = event_value.get("event_type")?.as_str()?;

        // Only forward events that carry real threat signal.
        // dns / http / tls / flow / stats / netflow are verbose metadata — drop them.
        match event_type {
            "alert" => {} // always forward
            "fileinfo" => {
                // Only forward if Suricata flagged it as suspicious.
                let suspicious = event_value
                    .get("fileinfo")
                    .and_then(|f| f.get("suspicious"))
                    .and_then(|s| s.as_bool())
                    .unwrap_or(false);
                if !suspicious {
                    return None;
                }
            }
            _ => return None, // drop dns, http, tls, flow, stats, netflow, …
        }

        // Parse timestamp
        let timestamp_str = event_value.get("timestamp")?.as_str()?;
        let timestamp = chrono::DateTime::parse_from_rfc3339(timestamp_str)
            .ok()?
            .with_timezone(&chrono::Utc);

        // Extract basic network information
        let src_ip = event_value.get("src_ip")?.as_str()?.to_string();
        let dest_ip = event_value.get("dest_ip")?.as_str()?.to_string();
        let src_port = event_value.get("src_port")?.as_u64()? as u16;
        let dest_port = event_value.get("dest_port")?.as_u64()? as u16;
        let protocol = event_value
            .get("proto")?
            .as_str()
            .unwrap_or("unknown")
            .to_string();

        // Determine threat level based on event type and severity
        let threat_level = match event_type {
            "alert" => {
                let sev = event_value.get("alert")?.get("severity")?.as_u64()?;
                // Severity 4 = informational noise — skip entirely.
                if sev >= 4 {
                    return None;
                }
                match sev {
                    1 => 9, // Critical
                    2 => 7, // High
                    3 => 5, // Medium
                    _ => return None,
                }
            }
            "fileinfo" => 6, // suspicious fileinfo already gated above
            _ => return None,
        };

        Some(TrafficEvent {
            id: uuid::Uuid::new_v4().to_string(),
            timestamp,
            source_ip: src_ip,
            dest_ip: dest_ip,
            source_port: src_port,
            dest_port: dest_port,
            protocol,
            payload: event_value.clone(),
            threat_level,
            event_type: event_type.to_string(),
        })
    }

    async fn process_rules(
        mut rule_receiver: mpsc::Receiver<SecurityRule>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        while let Some(rule) = rule_receiver.recv().await {
            info!("Received rule from VPS: {}", rule.name);

            // Apply the rule locally (e.g., update firewall, iptables, etc.)
            Collector::apply_rule(&rule).await?;
        }
        Ok(())
    }

    async fn apply_rule(rule: &SecurityRule) -> Result<(), Box<dyn std::error::Error>> {
        match rule.rule_type.as_str() {
            "ip_block" => {
                info!("Applying IP block rule for: {}", rule.target);
                // Here you would implement actual firewall rules
                // For example: iptables -A INPUT -s <target> -j DROP
            }
            "port_block" => {
                info!("Applying port block rule for: {}", rule.target);
                // Implement port blocking
            }
            "mac_block" => {
                info!("Applying MAC block rule for: {}", rule.target);
                // Implement MAC filtering
            }
            _ => {
                warn!("Unknown rule type: {}", rule.rule_type);
            }
        }
        Ok(())
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::init();

    let vps_url = std::env::var("VPS_PROCESSOR_URL")
        .unwrap_or_else(|_| "http://vps-processor:8090".to_string());
    let raspi_ip = std::env::var("RASPI_IP").unwrap_or_else(|_| "127.0.0.1".to_string());
    let collector_port = std::env::var("COLLECTOR_PORT").unwrap_or_else(|_| "8091".to_string());
    let api_key = std::env::var("VPS_API_KEY").unwrap_or_default();

    // Raw packet capture interface (eth0 by default on Raspi).
    let capture_interface =
        std::env::var("CAPTURE_INTERFACE").unwrap_or_else(|_| "eth0".to_string());

    // Default block duration in hours (configurable via environment)
    let default_block_duration_hours = std::env::var("DEFAULT_BLOCK_DURATION_HOURS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(24); // Default to 24 hours

    // TTL cleanup interval in seconds (how often to check for expired blocks)
    let ttl_cleanup_interval_secs = std::env::var("TTL_CLEANUP_INTERVAL_SECS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(300); // Default to 5 minutes

    // VPS WebSocket endpoint for streaming raw packets to the packet analyzer.
    // Defaults to api-gateway /ws/packets.
    let packet_stream_ws_url = std::env::var("PACKET_STREAM_WS_URL").unwrap_or_else(|_| {
        let base = vps_url
            .replace("https://", "wss://")
            .replace("http://", "ws://");
        format!("{}/ws/packets", base)
    });

    info!("Starting Raspberry Pi Traffic Collector");
    info!("VPS URL: {}", vps_url);
    info!("Raspberry Pi IP: {}", raspi_ip);
    info!("Collector Port: {}", collector_port);
    info!("Capture interface: {}", capture_interface);

    // Shared blocked-IP cache — updated from VPS commands, read by pcap capture loop.
    let blocked_ips: BlockedIps = Arc::new(DashMap::new());

    let (collector, mut event_rx, _rule_tx, rule_rx) = Collector::new(vps_url.clone(), raspi_ip);

    // Channel to route VPS WS commands to the rule-engine handler
    let (cmd_tx, cmd_rx) = mpsc::channel::<VpsCommand>(100);

    // ── Raw packet capture (pcap) → VPS streaming ────────────────────────────
    // Buffer up to 50 000 packets before dropping to avoid memory bloat.
    let (packet_tx, packet_rx) = mpsc::channel::<StreamedPacket>(50_000);

    let pcap_handle = tokio::spawn(run_pcap_capture(
        capture_interface.clone(),
        blocked_ips.clone(),
        packet_tx,
    ));

    let streamer_handle = tokio::spawn(run_packet_ws_streamer(
        packet_stream_ws_url,
        packet_rx,
        api_key.clone(),
    ));

    // ── Suricata eve.json watcher (supplementary events) ─────────────────────
    let collector_clone = collector.clone();
    let watcher_handle = tokio::spawn(async move {
        if let Err(e) = collector_clone.start_file_watcher().await {
            error!("File watcher error: {}", e);
        }
    });

    // ── Suricata event batch sender ───────────────────────────────────────────
    let collector_clone = collector.clone();
    let api_key_clone = api_key.clone();
    let event_handle = tokio::spawn(async move {
        let client = reqwest::Client::new();
        let mut batch = Vec::new();
        let mut interval = interval(Duration::from_secs(3));

        loop {
            tokio::select! {
                event = event_rx.recv() => {
                    if let Some(event) = event {
                        batch.push(event);

                        if batch.len() >= 25 {
                            if let Err(e) = send_batch(&client, &collector_clone.vps_url, &batch, &api_key_clone).await {
                                error!("Failed to send batch: {}", e);
                            } else {
                                info!("Sent batch of {} events to VPS", batch.len());
                            }
                            batch.clear();
                        }
                    }
                }
                _ = interval.tick() => {
                    if !batch.is_empty() {
                        if let Err(e) = send_batch(&client, &collector_clone.vps_url, &batch, &api_key_clone).await {
                            error!("Failed to send batch: {}", e);
                        } else {
                            info!("Sent batch of {} events to VPS", batch.len());
                        }
                        batch.clear();
                    }
                }
            }
        }
    });

    // Start legacy rule processing (HTTP-based)
    let rule_handle = tokio::spawn(async move {
        if let Err(e) = Collector::process_rules(rule_rx).await {
            error!("Rule processing error: {}", e);
        }
    });

    // ── VPS WebSocket client — receives BlockCommand / UnblockCommand / RuleUpdate ──
    let ws_url = std::env::var("VPS_WS_URL").unwrap_or_else(|_| {
        let base = vps_url
            .replace("https://", "wss://")
            .replace("http://", "ws://");
        format!("{}/ws/raspi", base)
    });
    let ws_handle = tokio::spawn(async move {
        run_ws_client(ws_url, cmd_tx).await;
    });

    // ── TTL cleanup task (removes expired IP blocks) ─────────────────────────────
    let blocked_ips_for_cleanup = blocked_ips.clone();
    let ttl_cleanup_handle = tokio::spawn(async move {
        run_ttl_cleanup(blocked_ips_for_cleanup, ttl_cleanup_interval_secs).await;
    });

    // ── Rule-engine command handler (applies iptables + Suricata rules) ───────
    let rule_engine_handle = tokio::spawn(async move {
        apply_vps_commands(cmd_rx, blocked_ips, default_block_duration_hours).await;
    });

    // ── Health check server ───────────────────────────────────────────────────
    let health_handle = tokio::spawn(async move {
        use warp::Filter;

        let health = warp::path("health").and(warp::get()).map(|| {
            warp::reply::json(&serde_json::json!({
                "status": "healthy",
                "timestamp": chrono::Utc::now(),
                "service": "packet-processor"
            }))
        });

        let routes = health.with(warp::log("packet_processor"));
        let addr: std::net::SocketAddr =
            ([0, 0, 0, 0], collector_port.parse::<u16>().unwrap_or(8091)).into();

        info!("Packet processor health check on {}", addr);
        warp::serve(routes).run(addr).await;
    });

    // Wait for all tasks
    tokio::try_join!(
        pcap_handle,
        streamer_handle,
        watcher_handle,
        event_handle,
        rule_handle,
        ws_handle,
        ttl_cleanup_handle,
        rule_engine_handle,
        health_handle,
    )?;

    Ok(())
}

/// Connect to VPS `/ws/raspi` with automatic reconnect, parse command messages
/// and forward them to the rule-engine via `cmd_tx`.
async fn run_ws_client(ws_url: String, cmd_tx: mpsc::Sender<VpsCommand>) {
    let api_key = std::env::var("VPS_API_KEY").unwrap_or_default();
    let reconnect_delay = Duration::from_secs(5);

    loop {
        info!("Connecting to VPS WebSocket at {}", ws_url);

        let url = match url::Url::parse(&ws_url) {
            Ok(u) => u,
            Err(e) => {
                error!("Invalid VPS WS URL '{}': {}", ws_url, e);
                tokio::time::sleep(reconnect_delay).await;
                continue;
            }
        };

        // Build the request with API key header
        let mut request = tokio_tungstenite::tungstenite::handshake::client::Request::builder()
            .uri(ws_url.as_str())
            .header("X-API-Key", &api_key);
        // Inject Host header (required by tungstenite)
        if let Some(host) = url.host_str() {
            request = request.header("Host", host);
        }
        let request = match request.body(()) {
            Ok(r) => r,
            Err(e) => {
                error!("Failed to build WS request: {}", e);
                tokio::time::sleep(reconnect_delay).await;
                continue;
            }
        };

        match connect_async(request).await {
            Ok((ws_stream, _)) => {
                info!("Connected to VPS WebSocket");
                let (_, mut read) = ws_stream.split();

                loop {
                    match read.next().await {
                        Some(Ok(WsMsg::Text(text))) => {
                            match serde_json::from_str::<VpsCommand>(&text) {
                                Ok(cmd) => {
                                    if let Err(e) = cmd_tx.send(cmd).await {
                                        error!("Failed to forward VPS command: {}", e);
                                    }
                                }
                                Err(e) => {
                                    // Ignore unknown message types (e.g., pings)
                                    tracing::debug!(
                                        "Unknown VPS WS message ({}): {}",
                                        e,
                                        &text[..text.len().min(80)]
                                    );
                                }
                            }
                        }
                        Some(Ok(WsMsg::Close(_))) | None => {
                            warn!(
                                "VPS WebSocket closed, reconnecting in {}s…",
                                reconnect_delay.as_secs()
                            );
                            break;
                        }
                        Some(Err(e)) => {
                            error!("VPS WebSocket error: {}", e);
                            break;
                        }
                        _ => {}
                    }
                }
            }
            Err(e) => {
                warn!(
                    "Could not connect to VPS WebSocket ({}), retry in {}s",
                    e,
                    reconnect_delay.as_secs()
                );
            }
        }

        tokio::time::sleep(reconnect_delay).await;
    }
}

/// Receive VPS commands and apply them via the rule-engine.
/// Also keeps `blocked_ips` in sync so the pcap capture loop can skip
/// already-blocked sources without going through VPS again.
async fn apply_vps_commands(
    mut cmd_rx: mpsc::Receiver<VpsCommand>,
    blocked_ips: BlockedIps,
    default_block_duration_hours: u32,
) {
    while let Some(cmd) = cmd_rx.recv().await {
        match cmd {
            VpsCommand::BlockCommand {
                ip,
                reason,
                duration_secs,
                apply_suricata_rule,
                ..
            } => {
                info!(
                    "Applying block for IP {} (reason: {}, duration: {}s)",
                    ip, reason, duration_secs
                );

                let blocked_at = Instant::now();
                let expires_at = if duration_secs > 0 {
                    Some(blocked_at + Duration::from_secs(duration_secs))
                } else {
                    // Use default block duration if not specified
                    Some(
                        blocked_at
                            + Duration::from_secs(default_block_duration_hours as u64 * 3600),
                    )
                };

                let block_info = BlockedIpInfo {
                    blocked_at,
                    expires_at,
                    reason: reason.clone(),
                };

                blocked_ips.insert(ip.clone(), block_info);
                apply_iptables_block(&ip, duration_secs);
                if apply_suricata_rule {
                    apply_suricata_drop_rule(&ip, &reason);
                }
            }
            VpsCommand::UnblockCommand { ip, reason, .. } => {
                info!("Removing block for IP {} (reason: {})", ip, reason);
                blocked_ips.remove(&ip);
                remove_iptables_block(&ip);
                remove_suricata_rule(&ip);
            }
            VpsCommand::RuleUpdate {
                rule_id,
                action,
                suricata_rule,
                iptables_rule,
                ..
            } => {
                info!("Rule update {}: action={}", rule_id, action);
                if let Some(rule) = &iptables_rule {
                    if let Err(e) = std::process::Command::new("iptables")
                        .args(rule.split_whitespace())
                        .status()
                    {
                        error!("iptables rule error: {}", e);
                    }
                }
                if let Some(rule) = &suricata_rule {
                    append_suricata_rule(rule);
                }
            }
            VpsCommand::Connected {} => info!("VPS acknowledged connection"),
            VpsCommand::Ping {} => info!("VPS ping received"),
        }
    }
}

fn apply_iptables_block(ip: &str, duration_secs: u64) {
    // Add DROP rule
    let status = std::process::Command::new("iptables")
        .args([
            "-I",
            "INPUT",
            "1",
            "-s",
            ip,
            "-j",
            "DROP",
            "-m",
            "comment",
            "--comment",
            &format!("idps-block-{}", ip),
        ])
        .status();
    match status {
        Ok(s) if s.success() => info!("iptables: blocked {}", ip),
        Ok(s) => warn!("iptables block returned exit code {}", s),
        Err(e) => error!("iptables exec error: {}", e),
    }
    // Persist rules
    let _ = std::process::Command::new("sh")
        .args([
            "-c",
            "iptables-save > /etc/iptables/rules.v4 2>/dev/null || true",
        ])
        .status();
    // Schedule auto-unblock
    if duration_secs > 0 {
        let ip = ip.to_string();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(duration_secs)).await;
            remove_iptables_block(&ip);
        });
    }
}

fn remove_iptables_block(ip: &str) {
    let _ = std::process::Command::new("iptables")
        .args([
            "-D",
            "INPUT",
            "-s",
            ip,
            "-j",
            "DROP",
            "-m",
            "comment",
            "--comment",
            &format!("idps-block-{}", ip),
        ])
        .status();
    let _ = std::process::Command::new("sh")
        .args([
            "-c",
            "iptables-save > /etc/iptables/rules.v4 2>/dev/null || true",
        ])
        .status();
    info!("iptables: unblocked {}", ip);
}

fn apply_suricata_drop_rule(ip: &str, reason: &str) {
    let rule = format!(
        r#"drop ip {} any -> any any (msg:"IDPS Auto-Block: {}"; sid:{}; rev:1;)"#,
        ip,
        reason.replace('"', "'"),
        // Derive a stable SID from IP: use a hash to stay in 9_000_000+ range
        9_000_000u64 + ip.bytes().fold(0u64, |acc, b| acc.wrapping_add(b as u64))
    );
    append_suricata_rule(&rule);
}

fn append_suricata_rule(rule: &str) {
    let path = std::env::var("SURICATA_CUSTOM_RULES")
        .unwrap_or_else(|_| "/etc/suricata/rules/idps-custom.rules".to_string());
    if let Err(e) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .and_then(|mut f| {
            use std::io::Write;
            writeln!(f, "{}", rule)
        })
    {
        error!("Failed to write Suricata rule: {}", e);
        return;
    }
    reload_suricata();
}

fn remove_suricata_rule(ip: &str) {
    let path = std::env::var("SURICATA_CUSTOM_RULES")
        .unwrap_or_else(|_| "/etc/suricata/rules/idps-custom.rules".to_string());
    if let Ok(content) = std::fs::read_to_string(&path) {
        let filtered: String = content
            .lines()
            .filter(|l| !l.contains(&format!("ip {ip} ")))
            .map(|l| format!("{l}\n"))
            .collect();
        if let Err(e) = std::fs::write(&path, filtered) {
            error!("Failed to update Suricata rules: {}", e);
            return;
        }
        reload_suricata();
    }
}

fn reload_suricata() {
    // Send SIGUSR2 to Suricata to reload rules without restart
    let result = std::process::Command::new("sh")
        .args(["-c", "kill -USR2 $(cat /var/run/suricata.pid 2>/dev/null) 2>/dev/null || suricatasc -c reload-rules 2>/dev/null || true"])
        .status();
    match result {
        Ok(_) => info!("Suricata rules reload signal sent"),
        Err(e) => warn!("Could not reload Suricata rules: {}", e),
    }
}

async fn send_batch(
    client: &reqwest::Client,
    vps_url: &str,
    events: &[TrafficEvent],
    api_key: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    if events.is_empty() {
        return Ok(());
    }

    // Try batch endpoint first
    let batch_response = client
        .post(&format!("{}/traffic/batch", vps_url))
        .header("X-API-Key", api_key)
        .json(&events.to_vec())
        .send()
        .await;

    match batch_response {
        Ok(response) => {
            if response.status().is_success() {
                let result: serde_json::Value = response.json().await?;
                info!("Batch response: {}", serde_json::to_string(&result)?);
                return Ok(());
            } else {
                warn!(
                    "Batch endpoint failed with status: {}, falling back to individual sends",
                    response.status()
                );
            }
        }
        Err(e) => {
            warn!(
                "Batch endpoint error: {}, falling back to individual sends",
                e
            );
        }
    }

    // Fallback to individual sends
    for event in events {
        let response: ProcessorResponse = client
            .post(&format!("{}/traffic", vps_url))
            .header("X-API-Key", api_key)
            .json(event)
            .send()
            .await?
            .json()
            .await?;

        if !response.success {
            warn!(
                "VPS processing failed for event {}: {}",
                event.id, response.message
            );
        }
    }
    Ok(())
}
