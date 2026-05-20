use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsMessage {
    pub id: String,
    pub timestamp: DateTime<Utc>,
    #[serde(flatten)]
    pub payload: WsPayload,
}

impl WsMessage {
    pub fn new(payload: WsPayload) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            timestamp: Utc::now(),
            payload,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WsPayload {
    BlockCommand(BlockCommand),
    UnblockCommand(UnblockCommand),
    RuleUpdate(RuleUpdate),
    CommandAck(CommandAck),
    Alert(AlertNotification),
    Metrics(MetricsSnapshot),
    Ping(Heartbeat),
    Pong(Heartbeat),
}

/// VPS → Raspi: block a single IP (iptables DROP + optional Suricata rule).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockCommand {
    pub ip: String,
    pub reason: String,
    /// 0 = permanent until explicit unblock.
    pub duration_secs: u64,
    pub apply_suricata_rule: bool,
    pub severity: u8,
    pub detection_event_id: Option<String>,
}

/// VPS → Raspi: remove an existing IP block.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnblockCommand {
    pub ip: String,
    pub reason: String,
    pub unblocked_by: Option<String>,
}

/// VPS → Raspi: install or update a rule.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleUpdate {
    pub rule_id: String,
    pub action: RuleAction,
    pub suricata_rule: Option<String>,
    pub iptables_rule: Option<String>,
    pub description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum RuleAction {
    Add,
    Update,
    Remove,
}

/// Raspi → VPS: acknowledgement that a command was applied (or failed).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandAck {
    pub command_id: String,
    pub success: bool,
    pub error: Option<String>,
    pub raspi_id: String,
}

/// VPS → Dashboard: real-time security alert.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlertNotification {
    pub event_id: String,
    pub severity: AlertSeverity,
    pub category: String,
    pub message: String,
    pub src_ip: String,
    pub dest_ip: Option<String>,
    pub src_port: Option<u16>,
    pub dest_port: Option<u16>,
    pub protocol: Option<String>,
    pub auto_blocked: bool,
    pub timestamp: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum AlertSeverity {
    Critical,
    High,
    Medium,
    Low,
    Info,
}

impl AlertSeverity {
    pub fn from_threat_level(level: u8) -> Self {
        match level {
            9..=10 => AlertSeverity::Critical,
            7..=8  => AlertSeverity::High,
            5..=6  => AlertSeverity::Medium,
            3..=4  => AlertSeverity::Low,
            _      => AlertSeverity::Info,
        }
    }
}

/// VPS → Dashboard: periodic system metrics snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetricsSnapshot {
    pub events_per_second: f64,
    pub alerts_per_minute: f64,
    pub blocked_ips_count: u64,
    pub cpu_usage_percent: f64,
    pub memory_usage_mb: f64,
    pub raspi_connected: bool,
    pub vps_processing_rate: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Heartbeat {
    pub sender_id: String,
}
