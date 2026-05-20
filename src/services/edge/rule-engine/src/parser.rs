//! Suricata rule parser.
//!
//! Parses Suricata rule strings into structured `ParsedRule` values so they
//! can be reasoned about (e.g. deduplication, IP extraction) before being
//! written to disk.

use serde::{Deserialize, Serialize};

/// A parsed representation of a single Suricata rule line.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedRule {
    /// Full raw rule text (single line, no trailing newline).
    pub raw: String,
    /// Rule action: `drop`, `alert`, `pass`, …
    pub action: String,
    /// Source IP / network from the rule header.
    pub src_ip: String,
    /// Destination IP / network from the rule header.
    pub dst_ip: String,
    /// `msg` option value, or empty string if absent.
    pub msg: String,
    /// Numeric SID extracted from the `sid:…;` option.
    pub sid: Option<u64>,
}

/// Parse a single Suricata rule line.
///
/// Returns `None` if `line` is empty, a comment, or cannot be parsed.
/// This is a best-effort parser — it does not validate the full Suricata
/// grammar; it extracts the fields we care about for local management.
pub fn parse_suricata_rule(line: &str) -> Option<ParsedRule> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }

    // Basic structure: <action> <proto> <src_ip> <src_port> -> <dst_ip> <dst_port> (<options>)
    let mut parts = line.splitn(7, ' ');
    let action = parts.next()?.to_string();
    let _proto = parts.next()?; // ip / tcp / udp / …
    let src_ip = parts.next()?.to_string();
    let _src_port = parts.next()?;
    let _arrow = parts.next()?; // "->"
    let dst_ip = parts.next()?.to_string();
    // rest is "<dst_port> (options)"
    let rest = parts.next().unwrap_or("");

    let msg = extract_option(rest, "msg")
        .unwrap_or_default()
        .trim_matches('"')
        .to_string();

    let sid = extract_option(rest, "sid").and_then(|s| s.parse::<u64>().ok());

    Some(ParsedRule {
        raw: line.to_string(),
        action,
        src_ip,
        dst_ip,
        msg,
        sid,
    })
}

/// Extract the value of a `key:value;` option from the Suricata options block.
fn extract_option<'a>(options: &'a str, key: &str) -> Option<String> {
    let search = format!("{}:", key);
    let start = options.find(&search)? + search.len();
    let slice = &options[start..];
    // Value ends at `;` or end of string
    let end = slice.find(';').unwrap_or(slice.len());
    Some(slice[..end].trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_basic_rule() {
        let rule = r#"drop ip 1.2.3.4 any -> any any (msg:"IDPS Block"; sid:9000001; rev:1;)"#;
        let parsed = parse_suricata_rule(rule).unwrap();
        assert_eq!(parsed.action, "drop");
        assert_eq!(parsed.src_ip, "1.2.3.4");
        assert_eq!(parsed.msg, "IDPS Block");
        assert_eq!(parsed.sid, Some(9000001));
    }

    #[test]
    fn test_skip_comment() {
        assert!(parse_suricata_rule("# this is a comment").is_none());
    }
}
