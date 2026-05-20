//! Suricata rule executor.
//!
//! Writes / removes rules from the dynamic rules file on disk and signals
//! Suricata to reload without a full restart.

use log::{info, warn};
use std::path::Path;

use super::parser::parse_suricata_rule;

/// Default path for IDPS-managed dynamic Suricata rules.
pub const DEFAULT_RULES_PATH: &str = "/etc/suricata/rules/idps-dynamic.rules";

/// Write `rule` to the dynamic rules file and reload Suricata.
///
/// The function is idempotent: if a rule with the same SID already exists it
/// is replaced rather than appended.
pub fn apply_rule(rule: &str) -> Result<(), String> {
    apply_rule_to(rule, DEFAULT_RULES_PATH)
}

pub fn apply_rule_to(rule: &str, path: &str) -> Result<(), String> {
    let parsed = parse_suricata_rule(rule);

    // Load existing rules (create file if it doesn't exist yet).
    let existing = if Path::new(path).exists() {
        std::fs::read_to_string(path)
            .map_err(|e| format!("Failed to read rules file {}: {}", path, e))?
    } else {
        // Ensure parent directory exists.
        if let Some(parent) = Path::new(path).parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("Failed to create rules directory: {}", e))?;
        }
        String::new()
    };

    let mut lines: Vec<String> = existing.lines().map(|l| l.to_string()).collect();

    // Replace existing rule with same SID, or append.
    if let Some(ref p) = parsed {
        if let Some(sid) = p.sid {
            let replaced = lines.iter_mut().any(|l| {
                if let Some(existing_parsed) = parse_suricata_rule(l) {
                    if existing_parsed.sid == Some(sid) {
                        *l = rule.trim().to_string();
                        return true;
                    }
                }
                false
            });
            if !replaced {
                lines.push(rule.trim().to_string());
            }
        } else {
            lines.push(rule.trim().to_string());
        }
    } else {
        lines.push(rule.trim().to_string());
    }

    let content = lines.join("\n") + "\n";
    std::fs::write(path, &content)
        .map_err(|e| format!("Failed to write rules file {}: {}", path, e))?;

    info!(
        "Rule applied to {}: {}",
        path,
        rule.chars().take(80).collect::<String>()
    );
    reload_suricata();
    Ok(())
}

/// Remove all rules matching `ip` as the source IP from the dynamic rules file.
pub fn remove_rule_by_ip(ip: &str) -> Result<(), String> {
    remove_rule_by_ip_from(ip, DEFAULT_RULES_PATH)
}

pub fn remove_rule_by_ip_from(ip: &str, path: &str) -> Result<(), String> {
    if !Path::new(path).exists() {
        return Ok(());
    }

    let existing =
        std::fs::read_to_string(path).map_err(|e| format!("Failed to read rules file: {}", e))?;

    let filtered: String = existing
        .lines()
        .filter(|l| {
            parse_suricata_rule(l)
                .map(|p| p.src_ip != ip)
                .unwrap_or(true) // Keep comments and unparseable lines
        })
        .map(|l| format!("{}\n", l))
        .collect();

    std::fs::write(path, &filtered).map_err(|e| format!("Failed to write rules file: {}", e))?;

    info!("Removed rules for IP {} from {}", ip, path);
    reload_suricata();
    Ok(())
}

/// Signal Suricata to reload its rules without a full restart.
///
/// Tries three methods in order:
/// 1. `suricatasc -c reload-rules` (preferred, requires suricatasc socket)
/// 2. `kill -USR2 $(cat /var/run/suricata.pid)` (classic signal)
/// 3. Log a warning — reload can be triggered manually
pub fn reload_suricata() {
    // Method 1: suricatasc
    let sc = std::process::Command::new("suricatasc")
        .args(["-c", "reload-rules"])
        .output();
    if let Ok(out) = sc {
        if out.status.success() {
            info!("Suricata rules reloaded via suricatasc");
            return;
        }
    }

    // Method 2: SIGUSR2 via pid file
    let pid_result = std::process::Command::new("sh")
        .args([
            "-c",
            "kill -USR2 $(cat /var/run/suricata.pid 2>/dev/null) 2>/dev/null",
        ])
        .status();
    match pid_result {
        Ok(s) if s.success() => {
            info!("Suricata rules reload signal (SIGUSR2) sent");
        }
        _ => {
            warn!("Could not reload Suricata rules automatically — reload manually or restart Suricata");
        }
    }
}
