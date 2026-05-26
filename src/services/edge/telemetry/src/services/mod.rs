//! Business logic services for telemetry.

use chrono::Utc;
use serde::{Deserialize, Serialize};
use sysinfo::{Components, Disks, Networks, System};
use std::sync::Arc;
use std::time::Duration;
use tokio::time::interval;

use crate::models::AppState;

/// System metrics collected from the edge device.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemMetrics {
    pub device_id: String,
    pub cpu_usage_percent: f64,
    pub memory_usage_percent: f64,
    pub memory_used_mb: f64,
    pub memory_total_mb: f64,
    pub disk_usage_percent: f64,
    pub disk_used_gb: f64,
    pub disk_total_gb: f64,
    pub network_rx_bytes: u64,
    pub network_tx_bytes: u64,
    pub temperature_celsius: Option<f64>,
    pub uptime_seconds: u64,
    pub load_average_1m: f64,
    pub timestamp: chrono::DateTime<Utc>,
}

/// Threshold alert generated when a metric exceeds limits.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThresholdAlert {
    pub device_id: String,
    pub metric: String,
    pub value: f64,
    pub threshold: f64,
    pub severity: String,
    pub message: String,
    pub timestamp: chrono::DateTime<Utc>,
}

/// Metrics collector service.
pub struct Collector;

impl Collector {
    /// Collect system metrics from the edge device.
    pub fn collect(sys: &mut System, networks: &mut Networks, device_id: &str) -> SystemMetrics {
        sys.refresh_all();
        networks.refresh(true);

        let cpu = sys.global_cpu_usage() as f64;

        let memory_total = sys.total_memory();
        let memory_used = sys.used_memory();
        let memory_total_mb = memory_total as f64 / 1024.0 / 1024.0;
        let memory_used_mb = memory_used as f64 / 1024.0 / 1024.0;
        let memory_pct = if memory_total > 0 {
            (memory_used as f64 / memory_total as f64) * 100.0
        } else {
            0.0
        };

        // Aggregate disk usage across all mounts
        let disks = Disks::new_with_refreshed_list();
        let (disk_used_bytes, disk_total_bytes) = disks.iter().fold((0u64, 0u64), |(u, t), d| {
            (
                u + (d.total_space() - d.available_space()),
                t + d.total_space(),
            )
        });
        let disk_total_gb = disk_total_bytes as f64 / 1024.0 / 1024.0 / 1024.0;
        let disk_used_gb = disk_used_bytes as f64 / 1024.0 / 1024.0 / 1024.0;
        let disk_pct = if disk_total_bytes > 0 {
            (disk_used_bytes as f64 / disk_total_bytes as f64) * 100.0
        } else {
            0.0
        };

        // Network I/O — sum across all interfaces (skip loopback)
        let (rx_bytes, tx_bytes) = networks.iter().fold((0u64, 0u64), |(r, t), (name, data)| {
            if name == "lo" {
                (r, t)
            } else {
                (r + data.total_received(), t + data.total_transmitted())
            }
        });

        // CPU temperature via sysinfo Components
        let components = Components::new_with_refreshed_list();
        let temperature_celsius = components
            .iter()
            .find(|c| {
                let label = c.label().to_lowercase();
                label.contains("cpu") || label.contains("core") || label.contains("thermal")
            })
            .and_then(|c| c.temperature().map(|t| t as f64));

        // Uptime
        let uptime_seconds = System::uptime();

        // Load average (Linux only; returns 0.0 on other platforms)
        let load = System::load_average();
        let load_average_1m = load.one;

        SystemMetrics {
            device_id: device_id.to_string(),
            cpu_usage_percent: cpu,
            memory_usage_percent: memory_pct,
            memory_used_mb,
            memory_total_mb,
            disk_usage_percent: disk_pct,
            disk_used_gb,
            disk_total_gb,
            network_rx_bytes: rx_bytes,
            network_tx_bytes: tx_bytes,
            temperature_celsius,
            uptime_seconds,
            load_average_1m,
            timestamp: Utc::now(),
        }
    }
}

/// Threshold checking service.
pub struct ThresholdChecker;

impl ThresholdChecker {
    /// Check metrics against thresholds and generate alerts.
    pub fn check(metrics: &SystemMetrics) -> Vec<ThresholdAlert> {
        let mut alerts = Vec::new();

        if metrics.cpu_usage_percent > 90.0 {
            alerts.push(ThresholdAlert {
                device_id: metrics.device_id.clone(),
                metric: "cpu_usage_percent".to_string(),
                value: metrics.cpu_usage_percent,
                threshold: 90.0,
                severity: "critical".to_string(),
                message: format!(
                    "CPU usage {:.1}% exceeds critical threshold 90%",
                    metrics.cpu_usage_percent
                ),
                timestamp: Utc::now(),
            });
        } else if metrics.cpu_usage_percent > 75.0 {
            alerts.push(ThresholdAlert {
                device_id: metrics.device_id.clone(),
                metric: "cpu_usage_percent".to_string(),
                value: metrics.cpu_usage_percent,
                threshold: 75.0,
                severity: "warning".to_string(),
                message: format!(
                    "CPU usage {:.1}% exceeds warning threshold 75%",
                    metrics.cpu_usage_percent
                ),
                timestamp: Utc::now(),
            });
        }

        if metrics.memory_usage_percent > 85.0 {
            alerts.push(ThresholdAlert {
                device_id: metrics.device_id.clone(),
                metric: "memory_usage_percent".to_string(),
                value: metrics.memory_usage_percent,
                threshold: 85.0,
                severity: "critical".to_string(),
                message: format!(
                    "Memory usage {:.1}% exceeds critical threshold 85%",
                    metrics.memory_usage_percent
                ),
                timestamp: Utc::now(),
            });
        }

        if metrics.disk_usage_percent > 90.0 {
            alerts.push(ThresholdAlert {
                device_id: metrics.device_id.clone(),
                metric: "disk_usage_percent".to_string(),
                value: metrics.disk_usage_percent,
                threshold: 90.0,
                severity: "critical".to_string(),
                message: format!(
                    "Disk usage {:.1}% exceeds critical threshold 90%",
                    metrics.disk_usage_percent
                ),
                timestamp: Utc::now(),
            });
        }

        if let Some(temp) = metrics.temperature_celsius {
            if temp > 80.0 {
                alerts.push(ThresholdAlert {
                    device_id: metrics.device_id.clone(),
                    metric: "temperature_celsius".to_string(),
                    value: temp,
                    threshold: 80.0,
                    severity: "critical".to_string(),
                    message: format!(
                        "CPU temperature {:.1}°C exceeds critical threshold 80°C",
                        temp
                    ),
                    timestamp: Utc::now(),
                });
            } else if temp > 70.0 {
                alerts.push(ThresholdAlert {
                    device_id: metrics.device_id.clone(),
                    metric: "temperature_celsius".to_string(),
                    value: temp,
                    threshold: 70.0,
                    severity: "warning".to_string(),
                    message: format!(
                        "CPU temperature {:.1}°C exceeds warning threshold 70°C",
                        temp
                    ),
                    timestamp: Utc::now(),
                });
            }
        }

        alerts
    }
}

/// VPS push service for sending telemetry data.
pub struct VpsPusher;

impl VpsPusher {
    /// Push metrics and alerts to the VPS.
    pub async fn push(
        client: &reqwest::Client,
        vps_url: &str,
        api_key: &str,
        sensor_id: &str,
        tenant_id: &str,
        device_id: &str,
        metrics: &SystemMetrics,
        alerts: &[ThresholdAlert],
    ) {
        let payload = serde_json::json!({
            "sensor_id": sensor_id,
            "tenant_id": tenant_id,
            "device_id": device_id,
            "metrics": metrics,
            "alerts": alerts,
        });

        let mut req = client
            .post(&format!("{}/api/telemetry", vps_url))
            .json(&payload);

        if !api_key.is_empty() {
            req = req.header("X-API-Key", api_key);
        }

        match req.timeout(Duration::from_secs(5)).send().await {
            Ok(resp) if resp.status().is_success() => {
                tracing::debug!("Telemetry pushed successfully");
            }
            Ok(resp) => {
                tracing::warn!("VPS returned {} for telemetry push", resp.status());
            }
            Err(e) => {
                tracing::warn!("Failed to push telemetry to VPS: {}", e);
            }
        }
    }

    /// Push a threshold alert to the VPS.
    pub async fn push_alert(
        client: &reqwest::Client,
        vps_url: &str,
        api_key: &str,
        alert: &ThresholdAlert,
    ) {
        let mut req = client
            .post(&format!("{}/api/telemetry/alert", vps_url))
            .json(alert);

        if !api_key.is_empty() {
            req = req.header("X-API-Key", api_key);
        }

        match req.timeout(Duration::from_secs(5)).send().await {
            Ok(resp) if resp.status().is_success() => {
                tracing::info!("Threshold alert sent: {}", alert.message);
            }
            Ok(resp) => {
                tracing::warn!("VPS returned {} for threshold alert", resp.status());
            }
            Err(e) => {
                tracing::warn!("Failed to push threshold alert: {}", e);
            }
        }
    }
}

/// Background collection loop.
pub async fn run_collection_loop(
    state: Arc<AppState>,
    vps_url: String,
    api_key: String,
    collection_interval_secs: u64,
) {
    let client = reqwest::Client::new();
    let mut sys = System::new_all();
    let mut networks = Networks::new_with_refreshed_list();
    let mut ticker = interval(Duration::from_secs(collection_interval_secs));

    tracing::info!(
        "Telemetry collection started (interval: {}s, VPS: {})",
        collection_interval_secs,
        vps_url
    );

    loop {
        ticker.tick().await;

        let metrics = Collector::collect(&mut sys, &mut networks, &state.device_id);
        let alerts = ThresholdChecker::check(&metrics);

        if !alerts.is_empty() {
            for alert in &alerts {
                tracing::warn!("Threshold breach: {}", alert.message);
                VpsPusher::push_alert(&client, &vps_url, &api_key, alert).await;
            }
        }

        VpsPusher::push(
            &client,
            &vps_url,
            &api_key,
            &state.sensor_id,
            &state.tenant_id,
            &state.device_id,
            &metrics,
            &alerts,
        )
        .await;

        {
            let mut lock = state.latest_metrics.write().await;
            *lock = Some(metrics);
        }
    }
}
