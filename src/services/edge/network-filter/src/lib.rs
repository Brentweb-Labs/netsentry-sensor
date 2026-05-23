use chrono::Utc;
use dashmap::DashMap;
use idps_types::{Packet, PacketAction, PacketDecision};
use log::{debug, info, warn};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;
use tokio::sync::RwLock;

/// Network filter for adaptive packet blocking with minimal latency
pub struct NetworkFilter {
    /// Fast lookup for blocked IPs (O(1) access)
    blocked_ips: Arc<DashMap<String, BlockedIp>>,
    /// Trusted IPs that bypass VPS analysis
    trusted_ips: Arc<RwLock<HashMap<String, TrustedIp>>>,
    /// Pending packets awaiting VPS decision
    pending_packets: Arc<DashMap<String, PendingPacket>>,
    /// Statistics for adaptive learning
    stats: Arc<RwLock<FilterStats>>,
    /// Configuration
    config: FilterConfig,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
struct BlockedIp {
    ip: String,
    blocked_at: Instant,
    expires_at: Instant,
    blocked_at_utc: chrono::DateTime<Utc>,
    expires_at_utc: chrono::DateTime<Utc>,
    reason: String,
    threat_level: u8,
    source: String,
    interface: String,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
struct TrustedIp {
    ip: String,
    trusted_at: Instant,
    expires_at: Instant,
    packet_count: usize,
    last_seen: Instant,
}

#[derive(Debug, Clone)]
struct PendingPacket {
    packet: Packet,
    buffer: Vec<u8>,
    socket: Arc<UdpSocket>,
    dest_addr: String,
    created_at: Instant,
    timeout: Duration,
}

#[derive(Debug, Clone)]
pub struct FilterStats {
    pub total_packets: usize,
    pub blocked_packets: usize,
    pub allowed_packets: usize,
    pub fast_tracked_packets: usize,
    pub avg_processing_time_ms: f64,
    pub vps_timeouts: usize,
}

#[derive(Debug, Clone)]
pub struct FilterConfig {
    /// Maximum time to wait for VPS decision
    pub vps_timeout_ms: u64,
    /// Block duration for high-threat IPs
    pub block_duration_hours: u64,
    /// Trust duration for verified safe IPs
    pub trust_duration_minutes: u64,
    /// Minimum packets before considering an IP trusted
    pub trust_threshold_packets: usize,
    /// Maximum allowed processing time before fast-tracking
    pub max_processing_time_ms: u64,
    /// Enable adaptive learning
    pub enable_adaptive_learning: bool,
}

impl Default for FilterConfig {
    fn default() -> Self {
        Self {
            vps_timeout_ms: 50,           // 50ms timeout for ultra-low latency
            block_duration_hours: 24,     // Block for 24 hours
            trust_duration_minutes: 60,   // Trust for 1 hour
            trust_threshold_packets: 100, // Need 100 safe packets
            max_processing_time_ms: 30,   // Fast-track if VPS is slow
            enable_adaptive_learning: true,
        }
    }
}

impl NetworkFilter {
    pub fn new(config: FilterConfig) -> Self {
        Self {
            blocked_ips: Arc::new(DashMap::new()),
            trusted_ips: Arc::new(RwLock::new(HashMap::new())),
            pending_packets: Arc::new(DashMap::new()),
            stats: Arc::new(RwLock::new(FilterStats {
                total_packets: 0,
                blocked_packets: 0,
                allowed_packets: 0,
                fast_tracked_packets: 0,
                avg_processing_time_ms: 0.0,
                vps_timeouts: 0,
            })),
            config,
        }
    }

    /// Fast packet filtering decision (sub-microsecond for cached results)
    pub async fn should_block_packet(&self, packet: &Packet) -> FilterDecision {
        let start_time = Instant::now();

        // Update statistics
        {
            let mut stats = self.stats.write().await;
            stats.total_packets += 1;
        }

        // Check blocked IPs first (fastest path)
        if let Some(blocked) = self.blocked_ips.get(&packet.src_ip) {
            if blocked.expires_at > Instant::now() {
                debug!("Fast block: {} (cached)", packet.src_ip);
                return FilterDecision::Block {
                    reason: format!("Cached block: {}", blocked.reason),
                    threat_level: blocked.threat_level,
                    processing_time_ns: start_time.elapsed().as_nanos(),
                };
            } else {
                // Expired entry, remove it
                self.blocked_ips.remove(&packet.src_ip);
            }
        }

        // Check trusted IPs (second fastest path)
        {
            let trusted = self.trusted_ips.read().await;
            if let Some(trusted_ip) = trusted.get(&packet.src_ip) {
                if trusted_ip.expires_at > Instant::now() {
                    debug!("Fast allow: {} (trusted)", packet.src_ip);

                    // Update trust statistics
                    drop(trusted);
                    self.update_trust_stats(&packet.src_ip).await;

                    return FilterDecision::Allow {
                        reason: "Trusted IP (fast-path)".to_string(),
                        processing_time_ns: start_time.elapsed().as_nanos(),
                    };
                }
            }
        }

        // Need VPS analysis - return pending decision
        FilterDecision::Pending {
            timeout: Duration::from_millis(self.config.vps_timeout_ms),
            processing_time_ns: start_time.elapsed().as_nanos(),
        }
    }

    /// Apply VPS decision to packet
    pub async fn apply_vps_decision(
        &self,
        decision: &PacketDecision,
    ) -> Result<(), Box<dyn std::error::Error>> {
        match decision.action {
            PacketAction::Block => {
                self.block_ip(&decision.packet_id, &decision.reason, decision.threat_level)
                    .await?;
                self.forward_or_drop_pending_packet(&decision.packet_id, false)
                    .await?;
            }
            PacketAction::Allow => {
                self.trust_ip(&decision.packet_id).await;
                self.forward_or_drop_pending_packet(&decision.packet_id, true)
                    .await?;
            }
            PacketAction::Monitor => {
                self.forward_or_drop_pending_packet(&decision.packet_id, true)
                    .await?;
            }
            PacketAction::Quarantine => {
                self.forward_or_drop_pending_packet(&decision.packet_id, false)
                    .await?;
            }
        }

        // Update statistics
        {
            let mut stats = self.stats.write().await;
            stats.avg_processing_time_ms =
                (stats.avg_processing_time_ms + decision.processing_time_ms as f64) / 2.0;

            // Adaptive learning: if VPS is consistently slow, increase fast-tracking
            if self.config.enable_adaptive_learning
                && decision.processing_time_ms > self.config.max_processing_time_ms
            {
                stats.vps_timeouts += 1;
                if stats.vps_timeouts > 10 {
                    info!("VPS consistently slow, enabling more aggressive fast-tracking");
                    self.enable_aggressive_fast_tracking().await;
                }
            }
        }

        Ok(())
    }

    /// Block an IP address directly (for manual prevention)
    pub async fn block_ip_direct(
        &self,
        ip: &str,
        reason: &str,
        threat_level: u8,
        duration_hours: u64,
        source: &str,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let blocked_at_utc = Utc::now();
        let expires_at_utc =
            blocked_at_utc + chrono::Duration::seconds((duration_hours * 3600) as i64);

        self.apply_iptables_block(ip).await?;

        let blocked = BlockedIp {
            ip: ip.to_string(),
            blocked_at: Instant::now(),
            expires_at: Instant::now() + Duration::from_secs(duration_hours * 3600),
            blocked_at_utc,
            expires_at_utc,
            reason: reason.to_string(),
            threat_level,
            source: source.to_string(),
            interface: self.firewall_interface(),
        };

        self.blocked_ips.insert(ip.to_string(), blocked);

        // Update statistics
        {
            let mut stats = self.stats.write().await;
            stats.blocked_packets += 1;
        }

        info!(
            "Blocked IP: {} - Reason: {} - Threat Level: {}",
            ip, reason, threat_level
        );
        Ok(())
    }

    /// Restore an already-persisted block into kernel firewall + in-memory cache.
    pub async fn restore_blocked_ip(
        &self,
        ip: &str,
        reason: &str,
        threat_level: u8,
        source: &str,
        blocked_at_utc: chrono::DateTime<Utc>,
        expires_at_utc: chrono::DateTime<Utc>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        if expires_at_utc <= Utc::now() {
            return Ok(());
        }

        self.apply_iptables_block(ip).await?;

        let remaining_secs = (expires_at_utc - Utc::now()).num_seconds().max(1) as u64;
        let blocked = BlockedIp {
            ip: ip.to_string(),
            blocked_at: Instant::now(),
            expires_at: Instant::now() + Duration::from_secs(remaining_secs),
            blocked_at_utc,
            expires_at_utc,
            reason: reason.to_string(),
            threat_level,
            source: source.to_string(),
            interface: self.firewall_interface(),
        };
        self.blocked_ips.insert(ip.to_string(), blocked);
        Ok(())
    }

    /// Block an IP address
    pub async fn block_ip(
        &self,
        packet_id: &str,
        reason: &str,
        threat_level: u8,
    ) -> Result<(), Box<dyn std::error::Error>> {
        if let Some(pending) = self.pending_packets.get(packet_id) {
            let src_ip = pending.packet.src_ip.clone();
            let blocked_at_utc = Utc::now();
            let expires_at_utc = blocked_at_utc
                + chrono::Duration::seconds((self.config.block_duration_hours * 3600) as i64);

            self.apply_iptables_block(&src_ip).await?;

            let blocked = BlockedIp {
                ip: src_ip.clone(),
                blocked_at: Instant::now(),
                expires_at: Instant::now()
                    + Duration::from_secs(self.config.block_duration_hours * 3600),
                blocked_at_utc,
                expires_at_utc,
                reason: reason.to_string(),
                threat_level,
                source: "auto_detection".to_string(),
                interface: self.firewall_interface(),
            };

            self.blocked_ips.insert(src_ip.clone(), blocked);

            info!(
                "Blocked IP {} for {} hours: {}",
                src_ip, self.config.block_duration_hours, reason
            );

            // Update statistics
            {
                let mut stats = self.stats.write().await;
                stats.blocked_packets += 1;
            }
        }
        Ok(())
    }

    /// Trust an IP address for future fast-tracking
    async fn trust_ip(&self, packet_id: &str) {
        if let Some(pending) = self.pending_packets.get(packet_id) {
            let src_ip = pending.packet.src_ip.clone();

            let trusted = TrustedIp {
                ip: src_ip.clone(),
                trusted_at: Instant::now(),
                expires_at: Instant::now()
                    + Duration::from_secs(self.config.trust_duration_minutes * 60),
                packet_count: 1,
                last_seen: Instant::now(),
            };

            {
                let mut trusted_ips = self.trusted_ips.write().await;
                trusted_ips.insert(src_ip.clone(), trusted);
            }

            info!(
                "Trusted IP {} for {} minutes",
                src_ip, self.config.trust_duration_minutes
            );

            // Update statistics
            {
                let mut stats = self.stats.write().await;
                stats.fast_tracked_packets += 1;
            }
        }
    }

    /// Update trust statistics for an IP
    async fn update_trust_stats(&self, ip: &str) {
        let mut trusted_ips = self.trusted_ips.write().await;
        if let Some(trusted_ip) = trusted_ips.get_mut(ip) {
            trusted_ip.packet_count += 1;
            trusted_ip.last_seen = Instant::now();

            // If IP has enough safe packets, extend trust duration
            if trusted_ip.packet_count > self.config.trust_threshold_packets {
                trusted_ip.expires_at = Instant::now()
                    + Duration::from_secs(self.config.trust_duration_minutes * 60 * 2);
                // Double trust duration
            }
        }
    }

    /// Forward or drop pending packet based on decision
    async fn forward_or_drop_pending_packet(
        &self,
        packet_id: &str,
        should_forward: bool,
    ) -> Result<(), Box<dyn std::error::Error>> {
        if let Some((_, pending)) = self.pending_packets.remove(packet_id) {
            if should_forward {
                // Forward packet to original destination
                pending
                    .socket
                    .send_to(&pending.buffer, &pending.dest_addr)
                    .await?;
                debug!("Forwarded packet to {}", pending.dest_addr);

                // Update statistics
                {
                    let mut stats = self.stats.write().await;
                    stats.allowed_packets += 1;
                }
            } else {
                debug!("Dropped packet from {}", pending.packet.src_ip);
            }
        }
        Ok(())
    }

    /// Apply iptables rule for IP blocking
    async fn apply_iptables_block(&self, ip: &str) -> Result<(), Box<dyn std::error::Error>> {
        let rule_specs = self.rule_specs(ip);
        for (chain, args_suffix, insert_action) in rule_specs {
            let mut check_args = vec!["-C".to_string(), chain.to_string()];
            check_args.extend(args_suffix.iter().cloned());
            let check_output = self.run_iptables_command(&check_args).await?;

            if !check_output.status.success() {
                let mut add_args = vec![insert_action.to_string(), chain.to_string()];
                add_args.extend(args_suffix.iter().cloned());
                let output = self.run_iptables_command(&add_args).await?;

                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    if chain == "DOCKER-USER" && stderr.contains("No chain/target/match") {
                        warn!("DOCKER-USER chain unavailable; fallback chains still active");
                        continue;
                    }

                    return Err(format!(
                        "Failed to add firewall rule on {} for {}: {}",
                        chain, ip, stderr
                    )
                    .into());
                }
            }
        }

        Ok(())
    }

    /// Enable aggressive fast-tracking when VPS is slow
    async fn enable_aggressive_fast_tracking(&self) {
        info!("Enabling aggressive fast-tracking due to VPS latency");

        // Trust more IPs based on historical data
        let _trusted_ips = self.trusted_ips.write().await;

        // This would implement more aggressive trust criteria
        // For example: trust IPs from certain subnets, trust low-volume traffic, etc.
    }

    /// Start cleanup task for expired entries
    pub async fn start_cleanup_task(&self) {
        let blocked_ips = self.blocked_ips.clone();
        let trusted_ips = self.trusted_ips.clone();
        let pending_packets = self.pending_packets.clone();
        let host_netns_path = self.host_netns_path();

        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(30));

            loop {
                interval.tick().await;

                let now = Instant::now();

                // Clean up expired blocked IPs and remove firewall rules
                let mut expired_ips = Vec::new();
                for entry in blocked_ips.iter() {
                    if entry.value().expires_at <= now {
                        expired_ips.push(entry.key().clone());
                    }
                }
                for ip in expired_ips {
                    let interface =
                        std::env::var("NETWORK_INTERFACE").unwrap_or_else(|_| "eth0".to_string());
                    let rule_specs = vec![
                        (
                            "DOCKER-USER",
                            vec![
                                "-s".to_string(),
                                ip.clone(),
                                "-j".to_string(),
                                "DROP".to_string(),
                            ],
                        ),
                        (
                            "DOCKER-USER",
                            vec![
                                "-d".to_string(),
                                ip.clone(),
                                "-j".to_string(),
                                "DROP".to_string(),
                            ],
                        ),
                        (
                            "INPUT",
                            vec![
                                "-i".to_string(),
                                interface.clone(),
                                "-s".to_string(),
                                ip.clone(),
                                "-j".to_string(),
                                "DROP".to_string(),
                            ],
                        ),
                        (
                            "OUTPUT",
                            vec![
                                "-o".to_string(),
                                interface.clone(),
                                "-d".to_string(),
                                ip.clone(),
                                "-j".to_string(),
                                "DROP".to_string(),
                            ],
                        ),
                        (
                            "FORWARD",
                            vec![
                                "-i".to_string(),
                                interface.clone(),
                                "-s".to_string(),
                                ip.clone(),
                                "-j".to_string(),
                                "DROP".to_string(),
                            ],
                        ),
                        (
                            "FORWARD",
                            vec![
                                "-o".to_string(),
                                interface.clone(),
                                "-d".to_string(),
                                ip.clone(),
                                "-j".to_string(),
                                "DROP".to_string(),
                            ],
                        ),
                    ];

                    for (chain, args_suffix) in rule_specs {
                        let mut del_args = vec!["-D".to_string(), chain.to_string()];
                        del_args.extend(args_suffix.iter().map(|s| s.to_string()));

                        let cmd = if Path::new(&host_netns_path).exists() {
                            let mut base = vec![
                                "--net".to_string(),
                                host_netns_path.clone(),
                                "iptables".to_string(),
                            ];
                            base.extend(del_args.clone());
                            tokio::process::Command::new("nsenter")
                                .args(base)
                                .output()
                                .await
                        } else {
                            tokio::process::Command::new("iptables")
                                .args(del_args.clone())
                                .output()
                                .await
                        };

                        if let Err(e) = cmd {
                            warn!(
                                "Failed to cleanup firewall rule for {} on {}: {}",
                                ip, chain, e
                            );
                        }
                    }
                    blocked_ips.remove(&ip);
                }

                // Clean up expired trusted IPs
                {
                    let mut trusted = trusted_ips.write().await;
                    trusted.retain(|_, trusted| trusted.expires_at > now);
                }

                // Clean up timed out pending packets
                pending_packets.retain(|_, pending| pending.created_at + pending.timeout > now);
            }
        });
    }

    /// Get current filter statistics
    pub async fn get_stats(&self) -> FilterStats {
        self.stats.read().await.clone()
    }

    /// Get list of currently blocked IPs
    pub async fn get_blocked_ips(&self) -> Vec<(String, String, u8, String, String, String)> {
        let mut blocked_ips = Vec::new();
        let now = Instant::now();

        // Iterate through blocked IPs and collect non-expired ones
        for entry in self.blocked_ips.iter() {
            let (ip, blocked_info) = entry.pair();
            if blocked_info.expires_at > now {
                blocked_ips.push((
                    ip.clone(),
                    blocked_info.reason.clone(),
                    blocked_info.threat_level,
                    blocked_info.blocked_at_utc.to_rfc3339(),
                    blocked_info.expires_at_utc.to_rfc3339(),
                    blocked_info.source.clone(),
                ));
            }
        }

        blocked_ips
    }

    /// Unblock an IP address
    pub async fn unblock_ip(&self, ip: &str) -> Result<(), Box<dyn std::error::Error>> {
        info!("Unblocking IP: {}", ip);

        // Remove iptables rule first; keep internal state unchanged on failure
        self.remove_iptables_block(ip).await?;

        // Remove from blocked list
        self.blocked_ips.remove(ip);

        // Update statistics
        {
            let mut stats = self.stats.write().await;
            if stats.blocked_packets > 0 {
                stats.blocked_packets -= 1;
            }
        }

        Ok(())
    }

    /// Remove iptables rule for IP unblocking
    async fn remove_iptables_block(&self, ip: &str) -> Result<(), Box<dyn std::error::Error>> {
        let rule_specs = self.rule_specs(ip);
        for (chain, args_suffix, _) in rule_specs {
            let mut del_args = vec!["-D".to_string(), chain.to_string()];
            del_args.extend(args_suffix.iter().cloned());
            let output = self.run_iptables_command(&del_args).await?;

            if !output.status.success()
                && !String::from_utf8_lossy(&output.stderr).contains("No chain/target/match")
                && !String::from_utf8_lossy(&output.stderr).contains("Bad rule")
            {
                return Err(format!(
                    "Failed to remove firewall rule on {} for {}: {}",
                    chain,
                    ip,
                    String::from_utf8_lossy(&output.stderr)
                )
                .into());
            }
        }

        Ok(())
    }

    /// Check if IP is currently blocked
    pub async fn is_ip_blocked(&self, ip: &str) -> bool {
        if let Some(blocked) = self.blocked_ips.get(ip) {
            blocked.expires_at > Instant::now()
        } else {
            false
        }
    }

    /// Get block reason for an IP
    pub async fn get_block_reason(&self, ip: &str) -> Option<String> {
        if let Some(blocked) = self.blocked_ips.get(ip) {
            if blocked.expires_at > Instant::now() {
                Some(blocked.reason.clone())
            } else {
                None
            }
        } else {
            None
        }
    }

    pub fn firewall_interface(&self) -> String {
        std::env::var("NETWORK_INTERFACE").unwrap_or_else(|_| "eth0".to_string())
    }

    fn host_netns_path(&self) -> String {
        std::env::var("HOST_NETNS_PATH").unwrap_or_else(|_| "/host_proc/1/ns/net".to_string())
    }

    fn rule_specs(&self, ip: &str) -> Vec<(&'static str, Vec<String>, &'static str)> {
        let interface = self.firewall_interface();
        vec![
            (
                "DOCKER-USER",
                vec![
                    "-s".to_string(),
                    ip.to_string(),
                    "-j".to_string(),
                    "DROP".to_string(),
                ],
                "-I",
            ),
            (
                "DOCKER-USER",
                vec![
                    "-d".to_string(),
                    ip.to_string(),
                    "-j".to_string(),
                    "DROP".to_string(),
                ],
                "-I",
            ),
            (
                "INPUT",
                vec![
                    "-i".to_string(),
                    interface.clone(),
                    "-s".to_string(),
                    ip.to_string(),
                    "-j".to_string(),
                    "DROP".to_string(),
                ],
                "-A",
            ),
            (
                "OUTPUT",
                vec![
                    "-o".to_string(),
                    interface.clone(),
                    "-d".to_string(),
                    ip.to_string(),
                    "-j".to_string(),
                    "DROP".to_string(),
                ],
                "-A",
            ),
            (
                "FORWARD",
                vec![
                    "-i".to_string(),
                    interface.clone(),
                    "-s".to_string(),
                    ip.to_string(),
                    "-j".to_string(),
                    "DROP".to_string(),
                ],
                "-A",
            ),
            (
                "FORWARD",
                vec![
                    "-o".to_string(),
                    interface,
                    "-d".to_string(),
                    ip.to_string(),
                    "-j".to_string(),
                    "DROP".to_string(),
                ],
                "-A",
            ),
        ]
    }

    async fn run_iptables_command(
        &self,
        args: &[String],
    ) -> Result<std::process::Output, Box<dyn std::error::Error>> {
        use tokio::process::Command;

        let host_netns_path = self.host_netns_path();
        let output = if Path::new(&host_netns_path).exists() {
            let mut nsenter_args =
                vec![format!("--net={}", host_netns_path), "iptables".to_string()];
            nsenter_args.extend(args.iter().cloned());
            let nsenter_output = Command::new("nsenter").args(nsenter_args).output().await?;
            let nsenter_stderr = String::from_utf8_lossy(&nsenter_output.stderr);
            if nsenter_stderr.contains("Permission denied")
                || nsenter_stderr.contains("Operation not permitted")
                || nsenter_stderr.contains("failed to execute")
            {
                warn!(
                    "Host namespace iptables failed, using container namespace fallback: {}",
                    nsenter_stderr
                );
                Command::new("iptables").args(args).output().await?
            } else {
                nsenter_output
            }
        } else {
            Command::new("iptables").args(args).output().await?
        };

        Ok(output)
    }
}

#[derive(Debug)]
pub enum FilterDecision {
    Block {
        reason: String,
        threat_level: u8,
        processing_time_ns: u128,
    },
    Allow {
        reason: String,
        processing_time_ns: u128,
    },
    Pending {
        timeout: Duration,
        processing_time_ns: u128,
    },
}
