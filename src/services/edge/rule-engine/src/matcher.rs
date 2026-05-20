//! In-memory rule matcher.
//!
//! Loads the local dynamic rules file and provides fast lookups so the
//! packet-processor can skip VPS analysis for packets that already match a
//! local rule (e.g. a known-bad IP that was blocked earlier).

use std::collections::HashSet;
use std::path::Path;
use std::sync::{Arc, RwLock};

use log::{info, warn};

use super::executor::DEFAULT_RULES_PATH;
use super::parser::parse_suricata_rule;

/// Result of a local rule match.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MatchResult {
    /// Packet matches a DROP rule — block it immediately.
    Block { reason: String },
    /// No local rule matched — forward to VPS for analysis.
    NoMatch,
}

/// Thread-safe, in-memory cache of blocked source IPs derived from the local
/// Suricata rules file.
#[derive(Clone)]
pub struct RuleMatcher {
    /// Set of source IPs targeted by `drop` rules.
    blocked_ips: Arc<RwLock<HashSet<String>>>,
}

impl RuleMatcher {
    /// Create a new matcher and load rules from the default path.
    pub fn new() -> Self {
        let matcher = Self {
            blocked_ips: Arc::new(RwLock::new(HashSet::new())),
        };
        matcher.reload();
        matcher
    }

    /// Reload rules from `DEFAULT_RULES_PATH`.
    pub fn reload(&self) {
        self.reload_from(DEFAULT_RULES_PATH);
    }

    pub fn reload_from(&self, path: &str) {
        if !Path::new(path).exists() {
            return;
        }
        let content = match std::fs::read_to_string(path) {
            Ok(c) => c,
            Err(e) => {
                warn!("RuleMatcher: could not read {}: {}", path, e);
                return;
            }
        };

        let mut ips = HashSet::new();
        for line in content.lines() {
            if let Some(rule) = parse_suricata_rule(line) {
                if rule.action == "drop" && !rule.src_ip.is_empty() && rule.src_ip != "any" {
                    ips.insert(rule.src_ip);
                }
            }
        }

        match self.blocked_ips.write() {
            Ok(mut guard) => {
                *guard = ips;
                info!(
                    "RuleMatcher: loaded {} blocked IPs from {}",
                    guard.len(),
                    path
                );
            }
            Err(e) => warn!("RuleMatcher: lock poisoned: {}", e),
        }
    }

    /// Check if the given source IP is matched by a local DROP rule.
    pub fn check(&self, src_ip: &str) -> MatchResult {
        match self.blocked_ips.read() {
            Ok(guard) => {
                if guard.contains(src_ip) {
                    MatchResult::Block {
                        reason: format!("Matched local DROP rule for {}", src_ip),
                    }
                } else {
                    MatchResult::NoMatch
                }
            }
            Err(_) => MatchResult::NoMatch, // Fail-open on lock error
        }
    }

    /// Add an IP to the in-memory blocked set (called when a new block rule is applied).
    pub fn add_blocked_ip(&self, ip: &str) {
        if let Ok(mut guard) = self.blocked_ips.write() {
            guard.insert(ip.to_string());
        }
    }

    /// Remove an IP from the in-memory blocked set.
    pub fn remove_blocked_ip(&self, ip: &str) {
        if let Ok(mut guard) = self.blocked_ips.write() {
            guard.remove(ip);
        }
    }
}

impl Default for RuleMatcher {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_no_match_for_unknown_ip() {
        let matcher = RuleMatcher {
            blocked_ips: Arc::new(RwLock::new(HashSet::new())),
        };
        assert_eq!(matcher.check("1.2.3.4"), MatchResult::NoMatch);
    }

    #[test]
    fn test_match_for_blocked_ip() {
        let matcher = RuleMatcher {
            blocked_ips: Arc::new(RwLock::new(HashSet::new())),
        };
        matcher.add_blocked_ip("5.6.7.8");
        assert!(matches!(
            matcher.check("5.6.7.8"),
            MatchResult::Block { .. }
        ));
    }
}
