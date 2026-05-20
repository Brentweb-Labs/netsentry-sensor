use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Core packet data structure shared across services
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Packet {
    pub id: String,
    pub timestamp: DateTime<Utc>,
    pub src_ip: String,
    pub dst_ip: String,
    pub src_port: u16,
    pub dst_port: u16,
    pub protocol: String,
    pub payload: Vec<u8>,
    pub packet_size: usize,
    pub interface: String,
}

/// Packet analysis decision from VPS
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PacketDecision {
    pub packet_id: String,
    pub action: PacketAction,
    pub threat_level: u8,
    pub reason: String,
    pub rule_matches: Vec<String>,
    pub processing_time_ms: u64,
    pub metadata: serde_json::Value,
}

/// Packet action types
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PacketAction {
    Allow,
    Block,
    Monitor,
    Quarantine,
}

/// Security rule structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityRule {
    pub id: String,
    pub name: String,
    pub rule_type: RuleType,
    pub target: String,
    pub action: PacketAction,
    pub duration_seconds: u64,
    pub created_at: DateTime<Utc>,
    pub active: bool,
    pub rule_content: String,
    pub metadata: RuleMetadata,
}

/// Rule types
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuleType {
    IpBlock,
    PortBlock,
    MacBlock,
    Pattern,
    Threshold,
}

/// Rule metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleMetadata {
    pub source: String,
    pub confidence: f64,
    pub severity: u8,
    pub tags: Vec<String>,
    pub last_triggered: Option<DateTime<Utc>>,
    pub trigger_count: u64,
}

/// Threat intelligence data
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThreatIntel {
    pub id: String,
    pub indicator: String,
    pub indicator_type: IndicatorType,
    pub threat_type: ThreatType,
    pub confidence: f64,
    pub severity: u8,
    pub source: String,
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub metadata: serde_json::Value,
}

/// Indicator types for threat intelligence
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IndicatorType {
    Ip,
    Domain,
    Url,
    Hash,
    Email,
    Pattern,
}

/// Threat types
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThreatType {
    Malware,
    Phishing,
    Botnet,
    Ddos,
    Scanning,
    Exploit,
    DataLeak,
    Unknown,
}

/// Service health and status information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceStatus {
    pub service_name: String,
    pub status: ServiceHealth,
    pub version: String,
    pub uptime_seconds: u64,
    pub last_check: DateTime<Utc>,
    pub metrics: ServiceMetrics,
    pub dependencies: Vec<ServiceDependency>,
}

/// Service health status
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ServiceHealth {
    Healthy,
    Degraded,
    Unhealthy,
    Unknown,
}

/// Service metrics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceMetrics {
    pub packets_processed: u64,
    pub packets_blocked: u64,
    pub packets_allowed: u64,
    pub avg_processing_time_ms: f64,
    pub memory_usage_mb: f64,
    pub cpu_usage_percent: f64,
    pub error_rate: f64,
}

/// Service dependency status
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceDependency {
    pub name: String,
    pub required: bool,
    pub status: ServiceHealth,
    pub last_check: DateTime<Utc>,
    pub response_time_ms: Option<u64>,
}

/// Detection settings for anomaly and brute force detection
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DetectionSettings {
    /// Number of requests within the window before blocking
    pub brute_force_threshold: u32,
    /// Sliding window duration in seconds
    pub brute_force_window_seconds: u32,
    /// How long to block an IP after detection (hours)
    pub block_duration_hours: u64,
    /// URL paths to monitor for brute force (e.g. ["/login", "/api/auth"])
    pub monitored_paths: Vec<String>,
    /// Automatically block the IP when threshold is exceeded
    pub auto_block_enabled: bool,
    /// Enrich blocked IPs with reverse DNS names
    pub dns_enrichment_enabled: bool,
    pub updated_at: DateTime<Utc>,
}

impl Default for DetectionSettings {
    fn default() -> Self {
        Self {
            brute_force_threshold: 10,
            brute_force_window_seconds: 60,
            block_duration_hours: 1,
            monitored_paths: vec![
                "/login".to_string(),
                "/api/auth".to_string(),
                "/api/login".to_string(),
                "/admin".to_string(),
                "/wp-admin".to_string(),
                "/signin".to_string(),
            ],
            auto_block_enabled: true,
            dns_enrichment_enabled: true,
            updated_at: Utc::now(),
        }
    }
}

/// A recorded anomaly/brute-force detection event
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DetectionEvent {
    pub id: String,
    /// Source IP that triggered the detection
    pub src_ip: String,
    /// Detection pattern name (e.g. "BruteForce", "PortScan")
    pub detected_pattern: String,
    /// The path or context that was targeted
    pub path: String,
    /// Number of requests seen in the window
    pub request_count: u32,
    /// The window used for detection (seconds)
    pub window_seconds: u32,
    /// Whether this event caused an automatic IP block
    pub triggered_block: bool,
    pub timestamp: DateTime<Utc>,
    /// DNS names associated with the src_ip (may be empty)
    pub dns_names: Vec<String>,
}

impl DetectionEvent {
    pub fn new(
        src_ip: String,
        detected_pattern: String,
        path: String,
        request_count: u32,
        window_seconds: u32,
        triggered_block: bool,
    ) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            src_ip,
            detected_pattern,
            path,
            request_count,
            window_seconds,
            triggered_block,
            timestamp: Utc::now(),
            dns_names: vec![],
        }
    }
}

/// Configuration for packet processing
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessingConfig {
    pub max_packet_size: usize,
    pub processing_timeout_ms: u64,
    pub batch_size: usize,
    pub buffer_size: usize,
    pub worker_threads: usize,
    pub enable_caching: bool,
    pub cache_ttl_seconds: u64,
}

/// Network interface information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkInterface {
    pub name: String,
    pub ip_address: String,
    pub netmask: String,
    pub gateway: Option<String>,
    pub mac_address: String,
    pub mtu: u32,
    pub is_up: bool,
}

/// API response wrapper
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResponse<T> {
    pub success: bool,
    pub data: Option<T>,
    pub error: Option<ApiError>,
    pub timestamp: DateTime<Utc>,
    pub request_id: String,
}

/// API error information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiError {
    pub code: String,
    pub message: String,
    pub details: Option<serde_json::Value>,
}

impl Packet {
    pub fn new(
        src_ip: String,
        dst_ip: String,
        src_port: u16,
        dst_port: u16,
        protocol: String,
        payload: Vec<u8>,
        interface: String,
    ) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            timestamp: Utc::now(),
            src_ip,
            dst_ip,
            src_port,
            dst_port,
            protocol,
            packet_size: payload.len(),
            payload,
            interface,
        }
    }
}

impl PacketDecision {
    pub fn allow(packet_id: String, reason: String) -> Self {
        Self {
            packet_id,
            action: PacketAction::Allow,
            threat_level: 0,
            reason,
            rule_matches: vec![],
            processing_time_ms: 0,
            metadata: serde_json::json!({}),
        }
    }

    pub fn block(packet_id: String, reason: String, threat_level: u8) -> Self {
        Self {
            packet_id,
            action: PacketAction::Block,
            threat_level,
            reason,
            rule_matches: vec![],
            processing_time_ms: 0,
            metadata: serde_json::json!({}),
        }
    }
}

impl<T> ApiResponse<T> {
    pub fn success(data: T) -> Self {
        Self {
            success: true,
            data: Some(data),
            error: None,
            timestamp: Utc::now(),
            request_id: Uuid::new_v4().to_string(),
        }
    }

    pub fn error(code: String, message: String) -> Self {
        Self {
            success: false,
            data: None,
            error: Some(ApiError {
                code,
                message,
                details: None,
            }),
            timestamp: Utc::now(),
            request_id: Uuid::new_v4().to_string(),
        }
    }
}
