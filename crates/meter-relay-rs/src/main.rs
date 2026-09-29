mod allocation;
mod config;
mod control;
mod controller;
mod diagnostics;
mod discovery;
mod endpoint;
mod home_assistant;
mod influx;
mod inverter_controller;
mod inverters;
mod meter;
mod parser;
mod pid;
mod registers;
mod stream;
mod telemetry;
mod transport;
mod util;
mod web;

use std::sync::Arc;

use anyhow::Context;
use tracing_subscriber::EnvFilter;

use crate::config::Config;
use crate::controller::Controller;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("meter_relay=info,tower_http=warn")),
        )
        .init();

    let config = Arc::new(Config::from_env().context("loading configuration")?);

    if config.discovery.only {
        return report_endpoints(&config).await;
    }

    tracing::info!(
        inverters = ?config.inverters.iter().map(|inv| inv.id()).collect::<Vec<_>>(),
        discovery = config.discovery.mode.as_str(),
        strict = config.discovery.strict,
        "starting meter-relay (Rust)"
    );

    let controller = Controller::new(config).context("building the controller")?;
    controller.run().await
}

/// `MR_DISCOVERY_ONLY=1`: say what each endpoint is and exit.
///
/// A one-shot version of the phase the service runs at startup, for the times
/// the physical wiring has changed and the question is "which cable went
/// where?". It reads and probes but never serves or controls anything, needs no
/// publishing credentials, and exits non-zero when a required connection could
/// not be identified — so it can gate a deploy script.
async fn report_endpoints(config: &Config) -> anyhow::Result<()> {
    let outcome = discovery::discover(config, None).await;

    for line in &outcome.report.log {
        println!("  {line}");
    }
    println!();
    println!(
        "{:<34} {:<15} {:<8} {:<11} {:>6}  METHOD",
        "ENDPOINT", "ROLE", "IDENTITY", "STATUS", "CONF"
    );
    for assignment in &outcome.assignments {
        let endpoint = assignment
            .endpoint
            .as_ref()
            .map(|endpoint| endpoint.to_string())
            .unwrap_or_else(|| "—".to_string());
        println!(
            "{:<34} {:<15} {:<8} {:<11} {:>6.2}  {}",
            endpoint,
            assignment.role.as_str(),
            assignment.identity.clone().unwrap_or_else(|| "—".to_string()),
            if assignment.identified {
                "identified"
            } else {
                "unverified"
            },
            assignment.identification.confidence,
            assignment.identification.method,
        );
    }
    println!();

    let missing = outcome.unidentified_required();
    if missing.is_empty() {
        println!(
            "all {} required connection(s) identified in {} ms",
            outcome.report.assigned, outcome.report.duration_ms
        );
        Ok(())
    } else {
        anyhow::bail!("unidentified required connections: {}", missing.join(", "))
    }
}
