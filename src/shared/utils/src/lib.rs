use std::net::IpAddr;
use std::time::Duration;
use std::io::Write;

use anyhow::{Result, Context};
use ipnetwork::IpNetwork;
use log::LevelFilter;
use env_logger::Builder;
use std::pin::Pin;
use std::future::Future;
use tokio::time::sleep;
use rand::Rng;

pub mod network_utils {
    use super::*;

    pub fn is_in_cidr(ip: &str, cidr: &str) -> Result<bool> {
        let ip_addr: IpAddr = ip.parse()
            .with_context(|| format!("Invalid IP address: {}", ip))?;
        let network: IpNetwork = cidr.parse()
            .with_context(|| format!("Invalid CIDR notation: {}", cidr))?;
        Ok(network.contains(ip_addr))
    }

    pub fn is_private_ip(ip: &str) -> Result<bool> {
        let private_ranges = [
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "127.0.0.0/8",
        ];
        for range in &private_ranges {
            if is_in_cidr(ip, range)? {
                return Ok(true);
            }
        }
        Ok(false)
    }

    pub fn is_valid_ip(ip: &str) -> bool {
        ip.parse::<IpAddr>().is_ok()
    }
}

pub mod retry_utils {
    use super::*;

    pub async fn retry_with_backoff<F, T, E>(
        mut operation: F,
        max_attempts: u8,
        base_delay: Duration,
        max_delay: Duration,
    ) -> Result<T, E>
    where
        F: FnMut() -> Pin<Box<dyn Future<Output = Result<T, E>> + Send>>,
        E: std::fmt::Display,
    {
        let mut attempt = 0;
        let mut delay = base_delay;

        loop {
            attempt += 1;
            match operation().await {
                Ok(result) => return Ok(result),
                Err(e) => {
                    if attempt >= max_attempts {
                        log::error!("Operation failed after {} attempts: {}", attempt, e);
                        return Err(e);
                    }
                    // Jitter prevents thundering herd on reconnect storms.
                    let jitter = rand::thread_rng().gen_range(0..=delay.as_millis() as u64);
                    let actual_delay = Duration::from_millis(jitter);
                    log::warn!("Attempt {} failed: {}, retrying in {:?}", attempt, e, actual_delay);
                    sleep(actual_delay).await;
                    delay = std::cmp::min(delay * 2, max_delay);
                }
            }
        }
    }

    pub fn retry_operation<F, T, E>(f: F) -> impl FnMut() -> Pin<Box<dyn Future<Output = Result<T, E>> + Send>>
    where
        F: Fn() -> Pin<Box<dyn Future<Output = Result<T, E>> + Send>> + 'static,
        E: 'static,
    {
        Box::new(move || f())
    }
}

pub mod logging_utils {
    use super::*;

    pub fn init_logging(service_name: &str, level: LevelFilter) -> Result<()> {
        let service_name_clone = service_name.to_string();
        let service_name = service_name_clone.clone();
        Builder::new()
            .filter_level(level)
            .format(move |buf, record| {
                writeln!(buf,
                    "{} [{}] [{}] {}:{}: {}",
                    chrono::Utc::now().format("%Y-%m-%d %H:%M:%S%.3f"),
                    record.level(),
                    service_name,
                    record.file().unwrap_or("unknown"),
                    record.line().unwrap_or(0),
                    record.args()
                )
            })
            .init();
        log::info!("Logging initialized for service: {}", service_name_clone);
        Ok(())
    }

    pub fn init_json_logging(service_name: &str, level: LevelFilter) -> Result<()> {
        let service_name_clone = service_name.to_string();
        let service_name = service_name_clone.clone();
        Builder::new()
            .filter_level(level)
            .format(move |buf, record| {
                writeln!(buf,
                    r#"{{"timestamp":"{}","level":"{}","service":"{}","file":"{}","line":{},"message":"{}"}}"#,
                    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                    record.level(),
                    service_name,
                    record.file().unwrap_or("unknown"),
                    record.line().unwrap_or(0),
                    record.args()
                )
            })
            .init();
        log::info!("JSON logging initialized for service: {}", service_name_clone);
        Ok(())
    }
}

pub mod time_utils {
    use std::time::{SystemTime, UNIX_EPOCH};
    use super::Duration;

    pub fn unix_timestamp() -> u64 {
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
    }

    pub fn unix_timestamp_ms() -> u128 {
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis()
    }

    pub fn format_duration(duration: Duration) -> String {
        let total_seconds = duration.as_secs();
        let hours = total_seconds / 3600;
        let minutes = (total_seconds % 3600) / 60;
        let seconds = total_seconds % 60;
        if hours > 0 {
            format!("{}h {}m {}s", hours, minutes, seconds)
        } else if minutes > 0 {
            format!("{}m {}s", minutes, seconds)
        } else {
            format!("{}s", seconds)
        }
    }
}

pub use network_utils::{is_in_cidr, is_private_ip, is_valid_ip};
pub use retry_utils::{retry_with_backoff, retry_operation};
pub use logging_utils::{init_logging, init_json_logging};
pub use time_utils::{unix_timestamp, unix_timestamp_ms, format_duration};

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[tokio::test]
    async fn test_cidr_validation() {
        assert!(is_in_cidr("192.168.1.50", "192.168.1.0/24").unwrap());
        assert!(!is_in_cidr("10.0.0.1", "192.168.1.0/24").unwrap());
        assert!(is_in_cidr("10.1.2.3", "10.0.0.0/8").unwrap());
    }

    #[test]
    fn test_private_ip_detection() {
        assert!(is_private_ip("192.168.1.1").unwrap());
        assert!(is_private_ip("10.0.0.1").unwrap());
        assert!(is_private_ip("172.16.0.1").unwrap());
        assert!(is_private_ip("127.0.0.1").unwrap());
        assert!(!is_private_ip("8.8.8.8").unwrap());
        assert!(!is_private_ip("1.1.1.1").unwrap());
    }

    #[test]
    fn test_ip_validation() {
        assert!(is_valid_ip("192.168.1.1"));
        assert!(is_valid_ip("8.8.8.8"));
        assert!(!is_valid_ip("invalid.ip"));
        assert!(!is_valid_ip("256.256.256.256"));
    }

    #[tokio::test]
    async fn test_retry_with_backoff() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let attempts_for_assert = attempts.clone();

        let mut operation = {
            let attempts = attempts.clone();
            move || -> Pin<Box<dyn Future<Output = Result<&'static str, &'static str>> + Send>> {
                let attempts = attempts.clone();
                Box::pin(async move {
                    let attempt_num = attempts.fetch_add(1, Ordering::SeqCst) + 1;
                    if attempt_num < 3 { Err("Simulated failure") } else { Ok("success") }
                })
            }
        };

        let result = retry_with_backoff(&mut operation, 5, Duration::from_millis(10), Duration::from_millis(100)).await;
        assert_eq!(result.unwrap(), "success");
        assert_eq!(attempts_for_assert.load(Ordering::SeqCst), 3);
    }

    #[test]
    fn test_time_utils() {
        let ts = unix_timestamp();
        assert!(ts > 1600000000);
        let ts_ms = unix_timestamp_ms();
        assert!(ts_ms > 1600000000000);
        let duration = Duration::from_secs(3661);
        assert_eq!(format_duration(duration), "1h 1m 1s");
    }
}
