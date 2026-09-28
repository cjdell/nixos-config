mod allocation;
mod config;
mod control;
mod controller;
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
    tracing::info!(
        inverters = ?config.inverters.iter().map(|inv| inv.id()).collect::<Vec<_>>(),
        "starting meter-relay (Rust)"
    );

    let controller = Controller::new(config).context("building the controller")?;
    controller.run().await
}
