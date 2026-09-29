use std::convert::Infallible;
use std::path::PathBuf;
use std::sync::Arc;

use axum::extract::State;
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::Json;
use axum::routing::get;
use axum::Router;
use futures::stream::{self, Stream, StreamExt};
use serde_json::json;
use tokio::net::TcpListener;
use tower_http::cors::CorsLayer;
use tower_http::services::{ServeDir, ServeFile};

use crate::diagnostics::{ConnectionsResponse, Diagnostics};
use crate::telemetry::{StatusSnapshot, Telemetry};

/// Everything the HTTP layer reads. Both halves are `Arc`s so a handler clone
/// is two pointer copies.
#[derive(Clone)]
pub struct AppState {
    pub telemetry: Arc<Telemetry>,
    pub diagnostics: Arc<Diagnostics>,
}

pub fn router(
    telemetry: Arc<Telemetry>,
    diagnostics: Arc<Diagnostics>,
    web_dir: PathBuf,
) -> Router {
    let index = web_dir.join("index.html");

    let api = Router::new()
        .route("/stats", get(stats))
        .route("/api/status", get(status))
        .route("/api/history", get(history))
        .route("/api/events", get(events))
        .route("/api/connections", get(connections))
        .with_state(AppState {
            telemetry,
            diagnostics,
        });

    api.fallback_service(ServeDir::new(&web_dir).fallback(ServeFile::new(&index)))
        .layer(CorsLayer::permissive())
}

pub async fn serve(
    telemetry: Arc<Telemetry>,
    diagnostics: Arc<Diagnostics>,
    port: u16,
    web_dir: PathBuf,
) -> anyhow::Result<()> {
    let app = router(telemetry, diagnostics, web_dir.clone());

    let listener = TcpListener::bind(("0.0.0.0", port)).await?;
    tracing::info!(port, web_dir = %web_dir.display(), "web dashboard listening");
    axum::serve(listener, app).await?;
    Ok(())
}

/// Legacy JSON endpoint, kept compatible with the TypeScript service: the field
/// names are the two-inverter ones it has always published, looked up by id so
/// that a plant of any size keeps serving them.
async fn stats(State(state): State<AppState>) -> Json<serde_json::Value> {
    let s = state.telemetry.snapshot();

    let battery_power =
        |id: &str| -> i64 { s.inverter(id).map(|inv| inv.battery_power as i64).unwrap_or(0) };
    let solar_power = |id: &str| -> i64 {
        s.inverter(id)
            .and_then(|inv| inv.solar_power)
            .unwrap_or(0.0) as i64
    };
    let target = |id: &str| -> f64 { s.inverter(id).map(|inv| inv.target).unwrap_or(0.0) };
    let authority =
        |id: &str| -> f64 { s.inverter(id).map(|inv| inv.discharge_limit).unwrap_or(0.0) };

    Json(json!({
        "grid_power": s.central.grid_power as i64,
        "solis_battery_power": battery_power("solis"),
        "solis_solar_power": solar_power("solis"),
        "solax_battery_power": battery_power("solax"),
        "lab_solar_power": s.lab_solar_power,
        "solis_target_power": target("solis"),
        "solax_target_power": target("solax"),
        "grid_voltage": s.central.grid_voltage,
        "meter_target_power": s.central.meter_target,
        "charging": s.charging,
        "solax_reserve_state": s.reserve.state.as_str(),
        "solax_reserve_power": s.reserve.share,
        "solis_authority": authority("solis"),
        "solax_authority": authority("solax"),
    }))
}

async fn status(State(state): State<AppState>) -> Json<StatusSnapshot> {
    Json(state.telemetry.snapshot())
}

async fn history(State(state): State<AppState>) -> Json<Vec<StatusSnapshot>> {
    Json(state.telemetry.history())
}

/// Which endpoint turned out to be which, and how each connection is doing.
/// Polled by the diagnostics page; see `discovery.rs` for how the roles are
/// worked out and `diagnostics.rs` for what the counters mean.
async fn connections(State(state): State<AppState>) -> Json<ConnectionsResponse> {
    Json(state.diagnostics.report())
}

async fn events(
    State(state): State<AppState>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let receiver = state.telemetry.subscribe();
    let initial = state.telemetry.snapshot();

    let initial_stream = stream::once(async move {
        let data = serde_json::to_string(&initial).unwrap_or_default();
        Ok(Event::default().data(data))
    });

    let live_stream = stream::unfold(receiver, |mut receiver| async move {
        loop {
            match receiver.recv().await {
                Ok(snapshot) => {
                    let data = serde_json::to_string(&snapshot).unwrap_or_default();
                    return Some((Ok(Event::default().data(data)), receiver));
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return None,
            }
        }
    });

    Sse::new(initial_stream.chain(live_stream)).keep_alive(KeepAlive::default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::allocation::ReserveState;
    use crate::diagnostics::{ConnectionStats, Role};
    use crate::endpoint::Endpoint;
    use crate::pid::PidController;
    use crate::telemetry::{CentralTelemetry, InverterTelemetry, ReserveTelemetry, StatusSnapshot};
    use crate::util::now_ms;

    fn sample_snapshot() -> StatusSnapshot {
        let pid = PidController::new(1.0, 0.0, 0.0, 10.0).snapshot();
        StatusSnapshot {
            ts: now_ms(),
            central: CentralTelemetry {
                grid_power: 123.0,
                grid_voltage: 240.0,
                meter_target: 50.0,
                pid: pid.clone(),
            },
            inverters: vec![
                InverterTelemetry {
                    id: "solis".into(),
                    name: "Solis".into(),
                    primary: true,
                    present: true,
                    stale: false,
                    battery_power: -100.0,
                    solar_power: Some(200.0),
                    battery_voltage: Some(51.2),
                    solar_voltage: Some(300.0),
                    ac_voltage: Some(240.0),
                    load_power: Some(300.0),
                    percentage: None,
                    status: Some("Normal Running".into()),
                    target: -50.0,
                    last_nudge: 1.0,
                    discharge_limit: 3_600.0,
                    charge_limit: 3_600.0,
                    absorbing: true,
                    request_interval_ms: 250.0,
                    pid: pid.clone(),
                },
                InverterTelemetry {
                    id: "solax".into(),
                    name: "Solax".into(),
                    primary: false,
                    present: true,
                    stale: false,
                    battery_power: -25.0,
                    // This make/model reports nothing but power and SOC.
                    solar_power: None,
                    battery_voltage: None,
                    solar_voltage: None,
                    ac_voltage: None,
                    load_power: None,
                    percentage: Some(55.0),
                    status: None,
                    target: -25.0,
                    last_nudge: 0.5,
                    discharge_limit: 1_500.0,
                    charge_limit: 1_000.0,
                    absorbing: true,
                    request_interval_ms: 400.0,
                    pid,
                },
            ],
            reserve: ReserveTelemetry {
                engaged: true,
                state: ReserveState::Reserve,
                share: 480.0,
                absorbed: 25.0,
                unmet: 0.0,
                soc: 55.0,
                total_discharge_limit: 5_100.0,
                total_charge_limit: 4_600.0,
            },
            lab_solar_power: 42.0,
            use_octopus_go: true,
            charging: false,
        }
    }

    /// A diagnostics registry holding one live meter-emulator connection.
    fn sample_diagnostics() -> Arc<Diagnostics> {
        let diagnostics = Diagnostics::new();
        let solis = ConnectionStats::new(
            "solis",
            Role::MeterEmulator,
            Some(Endpoint::tcp("192.168.49.30", 2001)),
            Some("solax".into()),
            2,
        );
        solis.mark_connected();
        solis.identify(
            Some("solis".into()),
            crate::diagnostics::Identification::listen_fingerprint(1.0, "two bulk meter polls"),
        );
        solis.count_requests_in(12);
        solis.count_responses_out(12);
        solis.observe_rx(96, 12);
        diagnostics.register(solis);
        diagnostics
    }

    async fn serve_test_app(
        telemetry: Arc<Telemetry>,
        diagnostics: Arc<Diagnostics>,
    ) -> std::net::SocketAddr {
        let app = router(telemetry, diagnostics, PathBuf::from("/nonexistent-web-dir"));
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        addr
    }

    #[tokio::test]
    async fn status_endpoint_serves_snapshot() {
        let telemetry = Telemetry::new(sample_snapshot(), 10);
        let addr = serve_test_app(telemetry, Diagnostics::new()).await;

        let body = reqwest::get(format!("http://{addr}/api/status"))
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(body.contains("\"grid_power\":123.0"), "unexpected body: {body}");
        assert!(body.contains("\"Solis\""));

        let stats = reqwest::get(format!("http://{addr}/stats"))
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(stats.contains("\"grid_power\":123"));
        assert!(stats.contains("\"solis_battery_power\":-100"));
    }

    #[tokio::test]
    async fn the_connections_endpoint_reports_discovered_identity_and_health() {
        let telemetry = Telemetry::new(sample_snapshot(), 10);
        let addr = serve_test_app(telemetry, sample_diagnostics()).await;

        let body = reqwest::get(format!("http://{addr}/api/connections"))
            .await
            .unwrap()
            .text()
            .await
            .unwrap();

        assert!(body.contains("\"endpoint\":\"tcp://192.168.49.30:2001\""), "{body}");
        assert!(body.contains("\"identity\":\"solis\""), "{body}");
        assert!(body.contains("\"expected_identity\":\"solax\""), "{body}");
        assert!(body.contains("\"mismatch\":true"), "{body}");
        assert!(body.contains("\"state\":\"online\""), "{body}");
        assert!(body.contains("\"healthy\":true"), "{body}");
        assert!(body.contains("\"requests_in\":12"), "{body}");
        assert!(body.contains("\"last_rx\":"), "{body}");
    }
}
