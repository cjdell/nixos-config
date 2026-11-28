use std::convert::Infallible;
use std::path::PathBuf;
use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Json, Response};
use axum::routing::{get, get_service};
use axum::Router;
use futures::stream::{self, Stream, StreamExt};
use serde_json::json;
use tokio::net::TcpListener;
use tower_http::cors::CorsLayer;
use tower_http::services::{ServeDir, ServeFile};
use tower_http::set_header::SetResponseHeaderLayer;

use crate::diagnostics::{ConnectionsResponse, Diagnostics};
use crate::inverter_controller::InverterController;
use crate::rawmodbus::{ModbusCall, ModbusQuery, RawModbus};
use crate::telemetry::{StatusSnapshot, Telemetry};

/// `index.html` and any path the SPA resolves itself. Revalidate on every
/// load: these files are small, and the alternative is what bit us — Nix store
/// paths carry a normalised mtime, so every deploy answers with the same
/// `last-modified: 1970`, a browser may treat that as fresh indefinitely, and a
/// dashboard whose whole job is "what is the plant doing right now" keeps
/// showing the previous build. Seen 2026-11-28: a corrected panel was live and
/// the page still showed the old one until a hard refresh.
const ENTRY_CACHE: &str = "no-cache";

/// Content-hashed bundles under `/assets` (`index-<hash>.js`): changing a byte
/// changes the filename, so a cached copy can never be the wrong copy. Unlike
/// the entry document, this one is safe to keep for a year.
const ASSET_CACHE: &str = "public, max-age=31536000, immutable";

/// Everything the HTTP layer reads. Both halves are `Arc`s so a handler clone
/// is two pointer copies.
#[derive(Clone)]
pub struct AppState {
    pub telemetry: Arc<Telemetry>,
    pub diagnostics: Arc<Diagnostics>,
    /// `None` in tests: the raw lane needs a live stats connection.
    pub raw: Option<Arc<RawModbus>>,
    /// `(id, controller)` of every inverter, for the bounded target override.
    pub inverters: Vec<(String, Arc<InverterController>)>,
}

pub fn router(
    telemetry: Arc<Telemetry>,
    diagnostics: Arc<Diagnostics>,
    web_dir: PathBuf,
    raw: Option<Arc<RawModbus>>,
    inverters: Vec<(String, Arc<InverterController>)>,
) -> Router {
    let index = web_dir.join("index.html");

    let api = Router::new()
        .route("/stats", get(stats))
        .route("/api/status", get(status))
        .route("/api/history", get(history))
        .route("/api/events", get(events))
        .route("/api/connections", get(connections))
        .route("/api/modbus", get(modbus_read).post(modbus_write))
        .route("/api/inverter/:id/target", get(target_state).post(force_target))
        .with_state(AppState {
            telemetry,
            diagnostics,
            raw,
            inverters,
        })
        // Live plant state is only worth its response time: the dashboard's
        // whole purpose is "now", and a browser-rewound JSON reply is the same
        // class of lie as a stale bundle.
        .layer(SetResponseHeaderLayer::overriding(
            header::CACHE_CONTROL,
            HeaderValue::from_static("no-store"),
        ));

    // Content-hashed bundles get their own route so they can be cached for a
    // year; everything else must revalidate. A hashed name that no longer
    // exists is unreachable by construction (the entry document, which is the
    // only thing naming it, is never served from cache), so answering a miss
    // with the same header is not a trap.
    let hashed = Router::new()
        .route("/assets/*file", get_service(ServeDir::new(&web_dir)))
        .layer(SetResponseHeaderLayer::overriding(
            header::CACHE_CONTROL,
            HeaderValue::from_static(ASSET_CACHE),
        ));

    let pages = Router::new()
        .fallback_service(ServeDir::new(&web_dir).fallback(ServeFile::new(&index)))
        .layer(SetResponseHeaderLayer::overriding(
            header::CACHE_CONTROL,
            HeaderValue::from_static(ENTRY_CACHE),
        ));

    api.merge(hashed)
        .merge(pages)
        .layer(CorsLayer::permissive())
}

pub async fn serve(
    telemetry: Arc<Telemetry>,
    diagnostics: Arc<Diagnostics>,
    port: u16,
    web_dir: PathBuf,
    raw: Option<Arc<RawModbus>>,
    inverters: Vec<(String, Arc<InverterController>)>,
) -> anyhow::Result<()> {
    let app = router(telemetry, diagnostics, web_dir.clone(), raw, inverters);

    let listener = TcpListener::bind(("0.0.0.0", port)).await?;
    tracing::info!(port, web_dir = %web_dir.display(), "web dashboard listening");
    axum::serve(listener, app).await?;
    Ok(())
}

/// `POST /api/inverter/:id/target {"watts": 1500, "seconds": 90}` — pin one
/// line's target for a bounded window, replacing the allocator's. This is the
/// end-to-end command-path test: the relay biases the meter by
/// `kp * (target - measured)`, the inverter nulls the bias by dispatching, so
/// a working line converges on `measured == target` and a dead one does not
/// move at all.
#[derive(serde::Deserialize)]
struct TargetCall {
    watts: f64,
    #[serde(default = "sixty")]
    seconds: u64,
}

fn sixty() -> u64 {
    60
}

/// `GET /api/inverter/:id/target` — is an override pinned, and what is the
/// line actually commanded to right now?
async fn target_state(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let Some((id, controller)) = state
        .inverters
        .iter()
        .find(|(name, _)| name == &id)
        .map(|(name, controller)| (name.clone(), controller))
    else {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({ "ok": false, "error": format!("no inverter {id:?}") })),
        )
            .into_response();
    };
    match controller.forced_target() {
        Some((watts, seconds_left)) => (StatusCode::OK, Json(json!({
            "ok": true,
            "id": id,
            "pinned": true,
            "watts": watts,
            "seconds_left": seconds_left,
        })))
        .into_response(),
        None => (StatusCode::OK, Json(json!({
            "ok": true,
            "id": id,
            "pinned": false,
            "watts": controller.target(),
        })))
        .into_response(),
    }
}

async fn force_target(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(call): Json<TargetCall>,
) -> Response {
    if !call.watts.is_finite() || call.watts.abs() > 10_000.0 {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": "watts must be finite and within +/-10000" })),
        )
            .into_response();
    }
    let Some((id, controller)) = state
        .inverters
        .iter()
        .find(|(name, _)| name == &id)
        .map(|(name, controller)| (name.clone(), controller))
    else {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({ "ok": false, "error": format!("no inverter {id:?}") })),
        )
            .into_response();
    };

    let seconds = call.seconds.clamp(1, crate::inverter_controller::MAX_FORCED_TARGET_S);
    controller.force_target(call.watts, seconds);
    (StatusCode::OK, Json(json!({
        "ok": true,
        "id": id,
        "watts": call.watts,
        "seconds": seconds,
    })))
        .into_response()
}

/// `GET /api/modbus?slave=3&address=43110&count=1` — the read half of the raw
/// passthrough, shaped so a plain `curl` is enough to look at a register.
async fn modbus_read(
    State(state): State<AppState>,
    Query(query): Query<ModbusQuery>,
) -> Response {
    dispatch(state, query.validate()).await
}

/// `POST /api/modbus` with `{"op":"read"|"write", ...}`.
async fn modbus_write(
    State(state): State<AppState>,
    Json(call): Json<ModbusCall>,
) -> Response {
    dispatch(state, call.validate()).await
}

async fn dispatch(state: AppState, call: Result<crate::rawmodbus::Call, String>) -> Response {
    let call = match call {
        Ok(call) => call,
        Err(error) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "ok": false, "error": error })),
            )
                .into_response()
        }
    };
    let Some(raw) = state.raw.as_ref() else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "ok": false, "error": "no stats bus on this instance" })),
        )
            .into_response();
    };
    match raw.run(call).await {
        Ok(reply) => (StatusCode::OK, Json(reply)).into_response(),
        // The device's answer (timeout, exception, refused register) is the
        // interesting part, so it is passed through rather than swallowed.
        Err(error) => (
            StatusCode::BAD_GATEWAY,
            Json(json!({ "ok": false, "error": error })),
        )
            .into_response(),
    }
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
                    control_power: -100.0,
                    power_source: "battery",
                    solar_power: Some(200.0),
                    battery_voltage: Some(51.2),
                    solar_voltage: Some(300.0),
                    ac_voltage: Some(240.0),
                    load_power: Some(300.0),
                    inverting_power: Some(-100.0),
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
                    control_power: -25.0,
                    power_source: "battery",
                    // This make/model reports nothing but power and SOC.
                    solar_power: None,
                    battery_voltage: None,
                    solar_voltage: None,
                    ac_voltage: None,
                    load_power: None,
                    inverting_power: None,
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
            meter_stale: false,
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
        let app = router(
            telemetry,
            diagnostics,
            PathBuf::from("/nonexistent-web-dir"),
            None,
            Vec::new(),
        );
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
