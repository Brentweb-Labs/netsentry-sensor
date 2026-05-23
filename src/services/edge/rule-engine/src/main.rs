//! IDPS Rule Engine — HTTP API server
//!
//! Exposes a small REST API that raspi-collector and packet-processor can call
//! to apply / remove Suricata rules received from the VPS.
//!
//! Endpoints:
//!   POST /api/v1/rules/apply   { "suricata_rule": "…", "iptables_rule": "…" }
//!   POST /api/v1/rules/remove  { "ip": "1.2.3.4" }
//!   GET  /health

use std::net::SocketAddr;

use axum::{
    extract::Json,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use log::info;
use serde::{Deserialize, Serialize};

use idps_rule_engine::{apply_rule, remove_rule_by_ip};

#[derive(Debug, Deserialize)]
struct ApplyRuleRequest {
    suricata_rule: Option<String>,
    iptables_rule: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RemoveRuleRequest {
    ip: String,
}

#[derive(Debug, Serialize)]
struct RuleResponse {
    success: bool,
    message: String,
}

#[tokio::main]
async fn main() {
    env_logger::init();

    let port: u16 = std::env::var("RULE_ENGINE_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8094);

    let app = Router::new()
        .route("/health", get(health))
        .route("/api/v1/rules/apply", post(handle_apply))
        .route("/api/v1/rules/remove", post(handle_remove));

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    info!("Rule Engine API listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    axum::serve(listener, app).await.expect("serve");
}

async fn health() -> impl IntoResponse {
    axum::response::Json(serde_json::json!({
        "status": "healthy",
        "service": "rule-engine",
        "timestamp": chrono::Utc::now(),
    }))
}

async fn handle_apply(Json(req): Json<ApplyRuleRequest>) -> Result<Json<RuleResponse>, StatusCode> {
    let mut applied = false;
    let mut errors: Vec<String> = Vec::new();

    if let Some(rule) = req.suricata_rule {
        if !rule.trim().is_empty() {
            match apply_rule(&rule) {
                Ok(()) => applied = true,
                Err(e) => errors.push(format!("Suricata: {}", e)),
            }
        }
    }

    if let Some(rule) = req.iptables_rule {
        if !rule.trim().is_empty() {
            let status = std::process::Command::new("iptables")
                .args(rule.split_whitespace())
                .status();
            match status {
                Ok(s) if s.success() => applied = true,
                Ok(s) => errors.push(format!("iptables exited with {}", s)),
                Err(e) => errors.push(format!("iptables exec error: {}", e)),
            }
        }
    }

    if errors.is_empty() {
        Ok(Json(RuleResponse {
            success: applied,
            message: if applied {
                "Rule(s) applied".to_string()
            } else {
                "Nothing to apply".to_string()
            },
        }))
    } else {
        Ok(Json(RuleResponse {
            success: false,
            message: errors.join("; "),
        }))
    }
}

async fn handle_remove(
    Json(req): Json<RemoveRuleRequest>,
) -> Result<Json<RuleResponse>, StatusCode> {
    match remove_rule_by_ip(&req.ip) {
        Ok(()) => Ok(Json(RuleResponse {
            success: true,
            message: format!("Rules for {} removed", req.ip),
        })),
        Err(e) => Ok(Json(RuleResponse {
            success: false,
            message: e,
        })),
    }
}
