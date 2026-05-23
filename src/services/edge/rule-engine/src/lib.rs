//! IDPS Rule Engine
//!
//! Local rule application and enforcement engine for edge services.
//! Accepts Suricata rule strings from the VPS, writes them to the local
//! rules file, and signals Suricata to reload.  Also exposes an HTTP API
//! so other edge services (raspi-collector, packet-processor) can submit
//! rules without needing direct filesystem access.

pub mod executor;
pub mod matcher;
pub mod parser;

pub use executor::{apply_rule, reload_suricata, remove_rule_by_ip};
pub use matcher::{MatchResult, RuleMatcher};
pub use parser::{parse_suricata_rule, ParsedRule};
