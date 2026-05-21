use dashmap::DashMap;
use futures_util::{SinkExt, StreamExt};
use log::{error, info, warn};
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::mpsc;
use tokio::time::{interval, Duration};
use tokio_tungstenite::{connect_async, tungstenite::Message as WsMsg};

/// A raw packet captured from the network interface, ready to be streamed to the VPS.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct StreamedPacket {
    pub id: String,
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub src_ip: String,
    pub dst_ip: String,
    pub src_port: u16,
    pub dst_port: u16,
    pub protocol: String,
    /// First 256 bytes of the IP payload as hex.
    pub payload_hex: String,
    pub packet_size: usize,
    pub interface: String,
}

#[derive(Debug, Clone)]
struct BlockedIpInfo {
    blocked_at: Instant,
    expires_at: Option<Instant>,
}

/// Shared set of IPs currently blocked. Populated by periodically syncing with
/// the local network-filter service; used by the pcap loop to skip already-dropped
/// sources without sending them to the VPS unnecessarily.
type BlockedIps = Arc<DashMap<String, BlockedIpInfo>>;

/// Capture raw packets from `interface` using libpcap and forward them to the
/// `packet_tx` channel. Fail-open: if pcap fails or the channel is full, packets
/// are silently skipped — traffic is never held up waiting for analysis.
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

                        if !src_ip.is_empty() && is_ip_blocked(&src_ip, &blocked) {
                            continue;
                        }

                        let (src_port, dst_port, protocol) = extract_transport(&headers);

                        if is_junk_packet(&src_ip, &dst_ip, &protocol, dst_port) {
                            continue;
                        }

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

                        // Fire-and-forget: never block the capture thread.
                        if tx.try_send(pkt).is_err() {
                            // Channel full — VPS analysis is lagging; skip this packet.
                        }
                    }
                    Err(_) => {}
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

/// Periodically evict expired entries from the local blocked-IPs cache.
/// Actual iptables/Suricata enforcement is owned by the network-filter service.
async fn run_ttl_cleanup(blocked_ips: BlockedIps, cleanup_interval_secs: u64) {
    let mut ticker = interval(Duration::from_secs(cleanup_interval_secs));
    loop {
        ticker.tick().await;
        let now = Instant::now();
        let expired: Vec<String> = blocked_ips
            .iter()
            .filter_map(|e| {
                e.value()
                    .expires_at
                    .filter(|&exp| now >= exp)
                    .map(|_| e.key().clone())
            })
            .collect();
        for ip in &expired {
            blocked_ips.remove(ip);
            info!("TTL cache: evicted {}", ip);
        }
    }
}

/// Periodically sync the blocked-IPs cache from the local network-filter service.
/// This keeps run_pcap_capture up to date without a second VPS WebSocket connection.
async fn sync_blocked_ips(network_filter_url: String, blocked_ips: BlockedIps) {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .expect("failed to build HTTP client");

    let mut ticker = interval(Duration::from_secs(30));
    loop {
        ticker.tick().await;
        let url = format!("{}/blocked", network_filter_url.trim_end_matches('/'));
        match client.get(&url).send().await {
            Ok(resp) if resp.status().is_success() => {
                if let Ok(body) = resp.json::<serde_json::Value>().await {
                    if let Some(arr) = body.get("data").and_then(|d| d.as_array()) {
                        blocked_ips.clear();
                        for entry in arr {
                            let ip = match entry.get("ip").and_then(|v| v.as_str()) {
                                Some(s) => s.to_string(),
                                None => continue,
                            };
                            let expires_at = entry
                                .get("expires_at")
                                .and_then(|v| v.as_str())
                                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                                .map(|dt| {
                                    let secs = (dt.with_timezone(&chrono::Utc)
                                        - chrono::Utc::now())
                                    .num_seconds()
                                    .max(0) as u64;
                                    Instant::now() + Duration::from_secs(secs)
                                });
                            blocked_ips.insert(
                                ip,
                                BlockedIpInfo {
                                    blocked_at: Instant::now(),
                                    expires_at,
                                },
                            );
                        }
                        log::debug!(
                            "Synced {} blocked IPs from network-filter",
                            blocked_ips.len()
                        );
                    }
                }
            }
            Ok(resp) => warn!("network-filter /blocked returned HTTP {}", resp.status()),
            Err(e) => warn!("Could not reach network-filter for blocked-IP sync: {}", e),
        }
    }
}

fn is_private_or_local(ip: &str) -> bool {
    let octets: Vec<u8> = ip.split('.').filter_map(|p| p.parse().ok()).collect();
    if octets.len() != 4 {
        return false;
    }
    match (octets[0], octets[1]) {
        (10, _) => true,
        (172, 16..=31) => true,
        (192, 168) => true,
        (127, _) => true,
        (169, 254) => true,
        (255, _) => true,
        _ => ip.ends_with(".255") || ip == "255.255.255.255",
    }
}

fn is_junk_packet(src_ip: &str, dst_ip: &str, protocol: &str, dst_port: u16) -> bool {
    if dst_ip.starts_with("224.") || dst_ip.starts_with("239.") || dst_ip.starts_with("255.") {
        return true;
    }
    if is_private_or_local(src_ip) && is_private_or_local(dst_ip) {
        return true;
    }
    if protocol == "UDP" && matches!(dst_port, 53 | 123 | 5353 | 1900) {
        return true;
    }
    false
}

fn is_ip_blocked(ip: &str, blocked_ips: &BlockedIps) -> bool {
    if let Some(info) = blocked_ips.get(ip) {
        if let Some(expires_at) = info.expires_at {
            Instant::now() < expires_at
        } else {
            true
        }
    } else {
        false
    }
}

/// Long-lived WebSocket connection to the VPS /ws/packets endpoint.
/// Packets are sent as JSON text frames; no response is expected on this channel.
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

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::init();

    let capture_interface =
        std::env::var("CAPTURE_INTERFACE").unwrap_or_else(|_| "eth0".to_string());

    // Accept either VPS_API_KEY or API_KEY so both compose files work.
    let api_key = std::env::var("API_KEY")
        .or_else(|_| std::env::var("VPS_API_KEY"))
        .unwrap_or_default();

    let collector_port = std::env::var("COLLECTOR_PORT").unwrap_or_else(|_| "8091".to_string());
    let network_filter_url = std::env::var("NETWORK_FILTER_URL")
        .unwrap_or_else(|_| "http://localhost:8092/api/v1".to_string());

    let ttl_cleanup_interval_secs: u64 = std::env::var("TTL_CLEANUP_INTERVAL_SECS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(300);

    // Derive packet-stream WS URL from VPS_ENDPOINT (strips /api/vps suffix if present).
    let vps_endpoint = std::env::var("VPS_ENDPOINT")
        .unwrap_or_else(|_| "https://idps.brentweb.eu".to_string());
    let packet_stream_ws_url = std::env::var("PACKET_STREAM_WS_URL").unwrap_or_else(|_| {
        let base = vps_endpoint
            .replace("https://", "wss://")
            .replace("http://", "ws://");
        let base = base.trim_end_matches("/api/vps").to_string();
        format!("{}/ws/packets", base)
    });

    info!("Starting NetSentry Packet Processor");
    info!("Capture interface : {}", capture_interface);
    info!("Packet stream WS  : {}", packet_stream_ws_url);
    info!("Network filter URL: {}", network_filter_url);

    let blocked_ips: BlockedIps = Arc::new(DashMap::new());

    // Buffer up to 50 000 packets before dropping.
    let (packet_tx, packet_rx) = mpsc::channel::<StreamedPacket>(50_000);

    let pcap_handle = tokio::spawn(run_pcap_capture(
        capture_interface,
        blocked_ips.clone(),
        packet_tx,
    ));

    let streamer_handle = tokio::spawn(run_packet_ws_streamer(
        packet_stream_ws_url,
        packet_rx,
        api_key,
    ));

    let ttl_handle =
        tokio::spawn(run_ttl_cleanup(blocked_ips.clone(), ttl_cleanup_interval_secs));

    let sync_handle = tokio::spawn(sync_blocked_ips(network_filter_url, blocked_ips));

    let health_handle = tokio::spawn(async move {
        use warp::Filter;
        let health = warp::path("health").and(warp::get()).map(|| {
            warp::reply::json(&serde_json::json!({
                "status": "healthy",
                "timestamp": chrono::Utc::now(),
                "service": "packet-processor"
            }))
        });
        let addr: std::net::SocketAddr =
            ([0, 0, 0, 0], collector_port.parse::<u16>().unwrap_or(8091)).into();
        info!("Packet processor health check on {}", addr);
        warp::serve(health.with(warp::log("packet_processor")))
            .run(addr)
            .await;
    });

    tokio::try_join!(
        pcap_handle,
        streamer_handle,
        ttl_handle,
        sync_handle,
        health_handle,
    )?;

    Ok(())
}
