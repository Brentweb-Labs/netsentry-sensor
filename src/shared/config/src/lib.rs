use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

pub use loader::*;
pub use parser::*;
pub use validator::*;

/// Configuration for edge services (Raspberry Pi).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EdgeConfig {
    pub pcap_interface: String,
    pub vps_ws_url: String,
    pub network_filter_url: String,
    pub rule_engine_url: String,
    pub mongodb_uri: String,
    pub redis_url: String,
    pub vps_packets_ws_url: String,
    pub default_block_duration_hours: u32,
    pub log_level: String,
    pub service_port: u16,
}

impl Default for EdgeConfig {
    fn default() -> Self {
        Self {
            pcap_interface: "eth0".to_string(),
            vps_ws_url: "ws://localhost:8080/ws/raspi".to_string(),
            network_filter_url: "http://localhost:8092/api/v1".to_string(),
            rule_engine_url: "http://localhost:8094/api/v1".to_string(),
            mongodb_uri: "mongodb://localhost:27017".to_string(),
            redis_url: "redis://localhost:6379".to_string(),
            vps_packets_ws_url: "ws://localhost:8080/ws/packets".to_string(),
            default_block_duration_hours: 24,
            log_level: "info".to_string(),
            service_port: 8091,
        }
    }
}

impl EdgeConfig {
    pub fn from_env() -> Result<Self> {
        let config = Self {
            pcap_interface: std::env::var("PCAP_INTERFACE").unwrap_or_else(|_| "eth0".to_string()),
            vps_ws_url: std::env::var("VPS_WS_URL")
                .unwrap_or_else(|_| "ws://localhost:8080/ws/raspi".to_string()),
            network_filter_url: std::env::var("NETWORK_FILTER_URL")
                .unwrap_or_else(|_| "http://localhost:8092/api/v1".to_string()),
            rule_engine_url: std::env::var("RULE_ENGINE_URL")
                .unwrap_or_else(|_| "http://localhost:8094/api/v1".to_string()),
            mongodb_uri: std::env::var("MONGODB_URI")
                .unwrap_or_else(|_| "mongodb://localhost:27017".to_string()),
            redis_url: std::env::var("REDIS_URL")
                .unwrap_or_else(|_| "redis://localhost:6379".to_string()),
            vps_packets_ws_url: std::env::var("VPS_PACKETS_WS_URL")
                .unwrap_or_else(|_| "ws://localhost:8080/ws/packets".to_string()),
            default_block_duration_hours: std::env::var("DEFAULT_BLOCK_DURATION_HOURS")
                .ok().and_then(|s| s.parse().ok()).unwrap_or(24),
            log_level: std::env::var("LOG_LEVEL").unwrap_or_else(|_| "info".to_string()),
            service_port: std::env::var("SERVICE_PORT")
                .ok().and_then(|s| s.parse().ok()).unwrap_or(8091),
        };
        config.validate()?;
        Ok(config)
    }

    pub fn from_yaml_file<P: AsRef<Path>>(path: P) -> Result<Self> {
        let content = fs::read_to_string(path).context("Failed to read configuration file")?;
        let config: Self = serde_yaml::from_str(&content).context("Failed to parse YAML configuration")?;
        config.validate()?;
        Ok(config)
    }

    pub fn load_with_fallback<P: AsRef<Path>>(yaml_path: P) -> Result<Self> {
        match Self::from_yaml_file(&yaml_path) {
            Ok(config) => {
                log::info!("Loaded configuration from YAML file: {}", yaml_path.as_ref().display());
                Ok(config)
            }
            Err(e) => {
                log::warn!("Failed to load YAML config ({}), falling back to environment variables", e);
                Self::from_env()
            }
        }
    }

    pub fn validate(&self) -> Result<()> {
        if self.pcap_interface.is_empty() {
            return Err(anyhow::anyhow!("PCAP interface cannot be empty"));
        }
        if !self.vps_ws_url.starts_with("ws://") && !self.vps_ws_url.starts_with("wss://") {
            return Err(anyhow::anyhow!("VPS WebSocket URL must start with ws:// or wss://"));
        }
        if !self.vps_packets_ws_url.starts_with("ws://") && !self.vps_packets_ws_url.starts_with("wss://") {
            return Err(anyhow::anyhow!("VPS packets WebSocket URL must start with ws:// or wss://"));
        }
        if !self.network_filter_url.starts_with("http://") && !self.network_filter_url.starts_with("https://") {
            return Err(anyhow::anyhow!("Network filter URL must start with http:// or https://"));
        }
        if !self.rule_engine_url.starts_with("http://") && !self.rule_engine_url.starts_with("https://") {
            return Err(anyhow::anyhow!("Rule engine URL must start with http:// or https://"));
        }
        if self.mongodb_uri.is_empty() {
            return Err(anyhow::anyhow!("MongoDB URI cannot be empty"));
        }
        if self.redis_url.is_empty() {
            return Err(anyhow::anyhow!("Redis URL cannot be empty"));
        }
        if self.default_block_duration_hours == 0 {
            return Err(anyhow::anyhow!("Default block duration must be greater than 0"));
        }
        if self.service_port == 0 {
            return Err(anyhow::anyhow!("Service port must be greater than 0"));
        }
        Ok(())
    }
}

/// Configuration for cloud services (VPS).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudConfig {
    pub mongodb_uri: String,
    pub redis_url: String,
    pub auto_block_enabled: bool,
    pub threat_intel_url: Option<String>,
    pub api_key: Option<String>,
    pub log_level: String,
    pub service_port: u16,
    pub websocket_port: u16,
    pub max_packets_per_second: u32,
    pub rate_limiting_enabled: bool,
    pub tls_cert_path: Option<String>,
    pub tls_key_path: Option<String>,
}

impl Default for CloudConfig {
    fn default() -> Self {
        Self {
            mongodb_uri: "mongodb://localhost:27017".to_string(),
            redis_url: "redis://localhost:6379".to_string(),
            auto_block_enabled: false,
            threat_intel_url: None,
            api_key: None,
            log_level: "info".to_string(),
            service_port: 8080,
            websocket_port: 8080,
            max_packets_per_second: 10000,
            rate_limiting_enabled: true,
            tls_cert_path: None,
            tls_key_path: None,
        }
    }
}

impl CloudConfig {
    pub fn from_env() -> Result<Self> {
        let config = Self {
            mongodb_uri: std::env::var("MONGODB_URI")
                .unwrap_or_else(|_| "mongodb://localhost:27017".to_string()),
            redis_url: std::env::var("REDIS_URL")
                .unwrap_or_else(|_| "redis://localhost:6379".to_string()),
            auto_block_enabled: std::env::var("AUTO_BLOCK_ENABLED")
                .ok().and_then(|s| s.parse().ok()).unwrap_or(false),
            threat_intel_url: std::env::var("THREAT_INTEL_URL").ok(),
            api_key: std::env::var("API_KEY").ok(),
            log_level: std::env::var("LOG_LEVEL").unwrap_or_else(|_| "info".to_string()),
            service_port: std::env::var("SERVICE_PORT")
                .ok().and_then(|s| s.parse().ok()).unwrap_or(8080),
            websocket_port: std::env::var("WEBSOCKET_PORT")
                .ok().and_then(|s| s.parse().ok()).unwrap_or(8080),
            max_packets_per_second: std::env::var("MAX_PACKETS_PER_SECOND")
                .ok().and_then(|s| s.parse().ok()).unwrap_or(10000),
            rate_limiting_enabled: std::env::var("RATE_LIMITING_ENABLED")
                .ok().and_then(|s| s.parse().ok()).unwrap_or(true),
            tls_cert_path: std::env::var("TLS_CERT_PATH").ok(),
            tls_key_path: std::env::var("TLS_KEY_PATH").ok(),
        };
        config.validate()?;
        Ok(config)
    }

    pub fn from_yaml_file<P: AsRef<Path>>(path: P) -> Result<Self> {
        let content = fs::read_to_string(path).context("Failed to read configuration file")?;
        let config: Self = serde_yaml::from_str(&content).context("Failed to parse YAML configuration")?;
        config.validate()?;
        Ok(config)
    }

    pub fn load_with_fallback<P: AsRef<Path>>(yaml_path: P) -> Result<Self> {
        match Self::from_yaml_file(&yaml_path) {
            Ok(config) => {
                log::info!("Loaded configuration from YAML file: {}", yaml_path.as_ref().display());
                Ok(config)
            }
            Err(e) => {
                log::warn!("Failed to load YAML config ({}), falling back to environment variables", e);
                Self::from_env()
            }
        }
    }

    pub fn validate(&self) -> Result<()> {
        if self.mongodb_uri.is_empty() {
            return Err(anyhow::anyhow!("MongoDB URI cannot be empty"));
        }
        if self.redis_url.is_empty() {
            return Err(anyhow::anyhow!("Redis URL cannot be empty"));
        }
        if self.service_port == 0 {
            return Err(anyhow::anyhow!("Service port must be greater than 0"));
        }
        if self.websocket_port == 0 {
            return Err(anyhow::anyhow!("WebSocket port must be greater than 0"));
        }
        if self.max_packets_per_second == 0 {
            return Err(anyhow::anyhow!("Max packets per second must be greater than 0"));
        }
        // Both TLS cert and key must be provided together or not at all.
        if self.tls_cert_path.is_some() != self.tls_key_path.is_some() {
            return Err(anyhow::anyhow!("Both TLS certificate and key must be provided, or neither"));
        }
        Ok(())
    }

    pub fn tls_enabled(&self) -> bool {
        self.tls_cert_path.is_some() && self.tls_key_path.is_some()
    }
}

pub mod parser {
    use super::*;

    pub fn parse_log_level(level: &str) -> Result<log::LevelFilter> {
        match level.to_lowercase().as_str() {
            "error" => Ok(log::LevelFilter::Error),
            "warn"  => Ok(log::LevelFilter::Warn),
            "info"  => Ok(log::LevelFilter::Info),
            "debug" => Ok(log::LevelFilter::Debug),
            "trace" => Ok(log::LevelFilter::Trace),
            _ => Err(anyhow::anyhow!("Invalid log level: {}", level)),
        }
    }

    /// Accepts "24h", "30m", "60s", or a bare integer (seconds).
    pub fn parse_duration_seconds(duration: &str) -> Result<u64> {
        let duration = duration.trim().to_lowercase();
        if let Some(n) = duration.strip_suffix('h') {
            Ok(n.parse::<u64>().context("Invalid hour format")? * 3600)
        } else if let Some(n) = duration.strip_suffix('m') {
            Ok(n.parse::<u64>().context("Invalid minute format")? * 60)
        } else if let Some(n) = duration.strip_suffix('s') {
            n.parse::<u64>().context("Invalid second format")
        } else {
            duration.parse::<u64>().context("Invalid duration format")
        }
    }
}

pub mod validator {
    use super::*;

    pub fn validate_url(url: &str, schemes: &[&str]) -> Result<()> {
        if url.is_empty() {
            return Err(anyhow::anyhow!("URL cannot be empty"));
        }
        if !schemes.iter().any(|&s| url.starts_with(s)) {
            return Err(anyhow::anyhow!("URL must start with one of: {}", schemes.join(", ")));
        }
        Ok(())
    }

    pub fn validate_port(port: u16) -> Result<()> {
        if port == 0 {
            return Err(anyhow::anyhow!("Port cannot be 0"));
        }
        if port < 1024 {
            log::warn!("Using privileged port: {}", port);
        }
        Ok(())
    }

    pub fn validate_mongodb_uri(uri: &str) -> Result<()> {
        if uri.is_empty() {
            return Err(anyhow::anyhow!("MongoDB URI cannot be empty"));
        }
        if !uri.starts_with("mongodb://") && !uri.starts_with("mongodb+srv://") {
            return Err(anyhow::anyhow!("MongoDB URI must start with mongodb:// or mongodb+srv://"));
        }
        Ok(())
    }
}

pub mod loader {
    use super::*;

    pub fn load_config<T: for<'de> Deserialize<'de> + Validate>(
        yaml_path: Option<&str>,
        env_fallback: bool,
    ) -> Result<T>
    where
        T: Default,
    {
        if let Some(path) = yaml_path {
            match std::fs::read_to_string(path) {
                Ok(content) => {
                    let config: T = serde_yaml::from_str(&content)
                        .context("Failed to parse YAML configuration")?;
                    config.validate()?;
                    return Ok(config);
                }
                Err(e) => log::warn!("Failed to load YAML config from {}: {}", path, e),
            }
        }
        if env_fallback {
            log::info!("Using environment variables for configuration");
        }
        log::info!("Using default configuration");
        let config = T::default();
        config.validate()?;
        Ok(config)
    }
}

pub trait Validate {
    fn validate(&self) -> Result<()>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_edge_config_default() {
        let config = EdgeConfig::default();
        assert_eq!(config.pcap_interface, "eth0");
        assert_eq!(config.default_block_duration_hours, 24);
        assert!(config.validate().is_ok());
    }

    #[test]
    fn test_cloud_config_default() {
        let config = CloudConfig::default();
        assert!(!config.auto_block_enabled);
        assert_eq!(config.service_port, 8080);
        assert!(config.validate().is_ok());
    }

    #[test]
    fn test_edge_config_validation() {
        let mut config = EdgeConfig::default();
        config.vps_ws_url = "invalid-url".to_string();
        assert!(config.validate().is_err());
        config.vps_ws_url = "ws://localhost:8080/ws/raspi".to_string();
        config.mongodb_uri = "".to_string();
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_cloud_config_validation() {
        let mut config = CloudConfig::default();
        config.mongodb_uri = "invalid-uri".to_string();
        assert!(config.validate().is_err());
        config.mongodb_uri = "mongodb://localhost:27017".to_string();
        config.tls_cert_path = Some("/path/to/cert.pem".to_string());
        config.tls_key_path = None;
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_parser_utilities() {
        assert_eq!(parser::parse_log_level("info").unwrap(), log::LevelFilter::Info);
        assert_eq!(parser::parse_log_level("DEBUG").unwrap(), log::LevelFilter::Debug);
        assert!(parser::parse_log_level("invalid").is_err());
        assert_eq!(parser::parse_duration_seconds("24h").unwrap(), 86400);
        assert_eq!(parser::parse_duration_seconds("30m").unwrap(), 1800);
        assert_eq!(parser::parse_duration_seconds("60s").unwrap(), 60);
        assert_eq!(parser::parse_duration_seconds("120").unwrap(), 120);
    }

    #[test]
    fn test_validator_utilities() {
        assert!(validator::validate_url("http://localhost:8080", &["http://", "https://"]).is_ok());
        assert!(validator::validate_url("ftp://localhost", &["http://", "https://"]).is_err());
        assert!(validator::validate_port(8080).is_ok());
        assert!(validator::validate_port(0).is_err());
        assert!(validator::validate_mongodb_uri("mongodb://localhost:27017").is_ok());
        assert!(validator::validate_mongodb_uri("http://localhost:27017").is_err());
    }
}
