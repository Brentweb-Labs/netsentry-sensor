//! Application models for raspi-collector.

use std::collections::VecDeque;
use std::sync::Arc;

use chrono::{DateTime, Utc};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

/// Application state shared across handlers.
#[derive(Clone)]
pub struct AppState {
    pub vps_client: Client,
    pub metrics: Arc<RwLock<CollectorMetrics>>,
    pub vps_endpoint: String,
    pub api_key: String,
    pub connection_monitor: Arc<RwLock<ConnectionMonitor>>,
    pub ws_debug: Arc<RwLock<WsDebugState>>,
}

impl AppState {
    pub fn new(
        vps_client: Client,
        metrics: CollectorMetrics,
        vps_endpoint: String,
        api_key: String,
        connection_monitor: ConnectionMonitor,
        ws_debug: WsDebugState,
    ) -> Self {
        Self {
            vps_client,
            metrics: Arc::new(RwLock::new(metrics)),
            vps_endpoint,
            api_key,
            connection_monitor: Arc::new(RwLock::new(connection_monitor)),
            ws_debug: Arc::new(RwLock::new(ws_debug)),
        }
    }
}

/// Metrics collected by the collector.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct CollectorMetrics {
    pub events_collected: u64,
    pub events_sent: u64,
    pub last_collection: Option<DateTime<Utc>>,
    pub collection_rate: f64,
    pub failed_sends: u64,
}

/// WebSocket debug state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsDebugState {
    pub ws_url: String,
    pub connected: bool,
    pub last_connected_at: Option<DateTime<Utc>>,
    pub last_disconnected_at: Option<DateTime<Utc>>,
    pub reconnect_count: u32,
    pub last_command_at: Option<DateTime<Utc>>,
    pub commands_received: u64,
    pub blocks_applied: u64,
    pub unblocks_applied: u64,
    pub network_filter_url: String,
    pub network_filter_reachable: Option<bool>,
    pub recent_commands: VecDeque<DebugCommand>,
}

impl WsDebugState {
    pub fn new(ws_url: &str, network_filter_url: &str) -> Self {
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

    pub fn record_command(&mut self, cmd_type: &str, ip: &str, reason: &str, success: bool) {
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

/// Debug command entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DebugCommand {
    pub received_at: DateTime<Utc>,
    pub cmd_type: String,
    pub ip: String,
    pub reason: String,
    pub success: bool,
}

/// Connection status response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionStatus {
    pub status: String,
    pub uptime_duration: u64,
    pub uptime_percentage: f64,
    pub last_connected: Option<DateTime<Utc>>,
    pub last_disconnected: Option<DateTime<Utc>>,
    pub total_checks: u64,
    pub successful_checks: u64,
    pub failed_checks: u64,
    pub average_response_time: f64,
    pub response_time_last_check: f64,
    pub consecutive_failures: u64,
    pub longest_uptime: u64,
    pub shortest_downtime: u64,
}

/// Connection monitor for tracking VPS connectivity.
#[derive(Debug, Clone)]
pub struct ConnectionMonitor {
    pub current_status: String,
    pub start_time: DateTime<Utc>,
    pub last_connected: Option<DateTime<Utc>>,
    pub last_disconnected: Option<DateTime<Utc>>,
    pub total_uptime: u64,
    pub total_downtime: u64,
    pub total_checks: u64,
    pub successful_checks: u64,
    pub failed_checks: u64,
    pub response_times: VecDeque<f64>,
    pub consecutive_failures: u64,
    pub longest_uptime: u64,
    pub shortest_downtime: u64,
    pub current_uptime_start: Option<DateTime<Utc>>,
    pub current_downtime_start: Option<DateTime<Utc>>,
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
    pub fn update_check(&mut self, success: bool, response_time: f64) {
        let now = Utc::now();
        self.total_checks += 1;

        if self.response_times.len() >= 100 {
            self.response_times.pop_front();
        }
        self.response_times.push_back(response_time);

        if success {
            self.successful_checks += 1;
            self.consecutive_failures = 0;

            if self.current_status != "connected" {
                self.current_status = "connected".to_string();
                self.last_connected = Some(now);

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

            if self.current_status != "disconnected" {
                self.current_status = "disconnected".to_string();
                self.last_disconnected = Some(now);

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

    pub fn get_status(&self) -> ConnectionStatus {
        let now = Utc::now();
        let total_time = (now - self.start_time).num_seconds() as u64;

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

/// Traffic event sent to VPS.
#[derive(Debug, Serialize, Deserialize)]
pub struct TrafficEvent {
    pub id: String,
    pub timestamp: DateTime<Utc>,
    pub source_ip: String,
    pub dest_ip: String,
    pub source_port: u16,
    pub dest_port: u16,
    pub protocol: String,
    pub payload: serde_json::Value,
    pub threat_level: u8,
    pub event_type: String,
}
