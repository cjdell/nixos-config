//! Shout when the plant should not be trusted.
//!
//! Three layers, and this is the loud one. On the wire the relay fails safe
//! (a stale measurement reads zero and the central loop holds — `meter.rs`,
//! `control.rs`), and a meter adapter that leaves the bus exits the process
//! for a supervised re-discovery (`transport.rs`). Neither of those tells a
//! human, and "fail safe" is no excuse for "fail silently": this module
//! assembles the current problems (a grid measurement that has gone stale,
//! links that are not online and healthy), debounces them through a grace so
//! reconnect backoff cannot page anyone, and then
//!
//! * publishes the list on a Home Assistant *sensor* (`sensor.meter_relay_alerts`,
//!   the stable hook for automations), always;
//! * fires each configured `notify.*` service — the push to a phone;
//! * posts the same text to an optional generic webhook (ntfy, an HA
//!   webhook, whatever else listens).
//!
//! New problems are pushed, resolved problems are pushed, and while problems
//! persist the whole list re-shouts every `MR_ALERT_REPEAT_MS` — a
//! once-only message is a message that gets missed. The *process* failing is
//! beyond anything running inside it: the systemd `OnFailure=` unit in
//! `hosts/grafton-router/services/meter-relay.nix` covers that, and drops an
//! outage marker here so the first clean run after an outage says "recovered"
//! rather than silence.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use serde_json::json;

use crate::config::AlertSettings;
use crate::diagnostics::Diagnostics;
use crate::home_assistant::HomeAssistant;
use crate::meter::Meter;
use crate::util::now_ms;

const POLL_INTERVAL_MS: u64 = 5_000;
/// The Home Assistant entity the state is mirrored onto (`sensor.` prefix
/// added by the publisher): the stable hook for user automations.
const HEALTH_SENSOR_ID: &str = "meter_relay_alerts";
/// Written by the systemd `OnFailure` alert unit when the process itself
/// died; deleted here once things are demonstrably healthy again.
const OUTAGE_MARKER: &str = "/var/lib/meter-relay-alert/outage";

pub fn spawn(
    settings: AlertSettings,
    ha: HomeAssistant,
    meter: Arc<Meter>,
    diagnostics: Arc<Diagnostics>,
) {
    tokio::spawn(run(settings, ha, meter, diagnostics));
}

async fn run(
    settings: AlertSettings,
    ha: HomeAssistant,
    meter: Arc<Meter>,
    diagnostics: Arc<Diagnostics>,
) {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .expect("a reqwest client for alerts");
    let started = now_ms();
    let mut latch = Latch::new(settings.grace_ms);
    let mut last_sent = 0_u64;
    let mut last_published: Option<String> = None;
    let marker = PathBuf::from(OUTAGE_MARKER);

    loop {
        tokio::time::sleep(Duration::from_millis(POLL_INTERVAL_MS)).await;
        let now = now_ms();
        let raw = problems(
            &meter,
            &diagnostics,
            now.saturating_sub(started),
            settings.grace_ms,
        );
        let (added, resolved) = latch.update(raw, now);

        if !latch.active.is_empty() {
            let overdue = now.saturating_sub(last_sent) >= settings.repeat_ms;
            if !added.is_empty() || overdue {
                send_all(
                    &settings,
                    &ha,
                    &client,
                    "meter-relay PROBLEM (grafton-router)",
                    &summary(&latch.active),
                )
                .await;
                last_sent = now;
            }
        } else if !resolved.is_empty() {
            send_all(
                &settings,
                &ha,
                &client,
                "meter-relay RESOLVED (grafton-router)",
                &format!(
                    "Cleared: {}.",
                    resolved
                        .iter()
                        .map(String::as_str)
                        .collect::<Vec<_>>()
                        .join("; ")
                ),
            )
            .await;
            last_sent = now;
        }

        // An outage the systemd unit shouted about is only over when the
        // problems are gone *and* the meter is answering again — say so.
        if latch.active.is_empty() && marker.exists() {
            send_all(
                &settings,
                &ha,
                &client,
                "meter-relay RECOVERED (grafton-router)",
                "The relay came back after its outage and reports no problems.",
            )
            .await;
            if let Err(error) = std::fs::remove_file(&marker) {
                tracing::warn!(%error, "could not remove the outage marker");
            }
        }

        let published = if latch.active.is_empty() {
            "ok".to_string()
        } else {
            latch
                .active
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>()
                .join("; ")
        };
        if last_published.as_deref() != Some(published.as_str()) {
            ha.send_str(HEALTH_SENSOR_ID, "Meter Relay Alerts", &published, "")
                .await;
            last_published = Some(published);
        }
    }
}

/// The candidate problems, before debouncing. Every one is phrased so the
/// same wording across ticks identifies the same problem (the Latch keys on
/// the string).
fn problems(
    meter: &Meter,
    diagnostics: &Diagnostics,
    uptime_ms: u64,
    grace_ms: u64,
) -> BTreeSet<String> {
    let mut out = BTreeSet::new();

    match meter.feed_age_ms() {
        Some(age) if age > grace_ms => {
            out.insert(format!(
                "the grid meter feed is stale ({:?}) — meter readings are 0 W and the central loop is holding",
                Duration::from_millis(age)
            ));
        }
        None if uptime_ms > grace_ms => {
            out.insert(
                "the grid meter has not answered a single read since this process started — meter \
                 readings are 0 W and the central loop is holding"
                    .to_string(),
            );
        }
        _ => {}
    }

    for report in diagnostics.report().connections {
        // An unassigned spare port is not a problem, and neither is a link
        // that is up and within its error budget.
        if report.role == "unknown" {
            continue;
        }
        if report.state != "online" || !report.healthy {
            out.insert(format!(
                "the {} link {} is {}{}",
                report.label,
                report.endpoint,
                report.state,
                if report.state == "online" {
                    " with a high error rate"
                } else {
                    ""
                }
            ));
        }
    }

    out
}

fn summary(active: &BTreeSet<String>) -> String {
    let mut text =
        String::from("meter-relay on grafton-router reports a problem with the solar plant:\n");
    for problem in active {
        text.push_str("- ");
        text.push_str(problem);
        text.push('\n');
    }
    text.trim_end().to_string()
}

async fn send_all(
    settings: &AlertSettings,
    ha: &HomeAssistant,
    client: &reqwest::Client,
    title: &str,
    message: &str,
) {
    // The journal gets every shout even when no push channel is configured.
    tracing::warn!(title, "{message}");
    for service in &settings.ha_services {
        ha.notify(service, title, message).await;
    }
    if !settings.webhook_url.is_empty() {
        match client
            .post(&settings.webhook_url)
            .json(&json!({"title": title, "message": message}))
            .send()
            .await
        {
            Ok(res) if !res.status().is_success() => {
                tracing::warn!(status = %res.status(), "alert webhook rejected the post")
            }
            Err(error) => tracing::warn!(%error, "alert webhook failed"),
            _ => {}
        }
    }
}

/// Turns raw candidate problems into stable `active` ones: a problem must be
/// seen continuously for `grace_ms` before it counts (reconnect backoff
/// flapping must never page), and clearing requires a raw absence.
struct Latch {
    grace_ms: u64,
    pending: BTreeMap<String, u64>,
    active: BTreeSet<String>,
}

impl Latch {
    fn new(grace_ms: u64) -> Self {
        Self {
            grace_ms,
            pending: BTreeMap::new(),
            active: BTreeSet::new(),
        }
    }

    fn update(&mut self, raw: BTreeSet<String>, now: u64) -> (BTreeSet<String>, BTreeSet<String>) {
        self.pending.retain(|problem, _| raw.contains(problem));
        for problem in &raw {
            self.pending.entry(problem.clone()).or_insert(now);
        }

        let mut added = BTreeSet::new();
        for (problem, since) in self.pending.iter() {
            if !self.active.contains(problem)
                && now.saturating_sub(*since) >= self.grace_ms
                && self.active.insert(problem.clone())
            {
                added.insert(problem.clone());
            }
        }

        let resolved: BTreeSet<String> = self
            .active
            .iter()
            .filter(|problem| !raw.contains(*problem))
            .cloned()
            .collect();
        self.active.retain(|problem| !resolved.contains(problem));
        (added, resolved)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{ModbusRequest, ModbusResponse};
    use crate::registers::RegisterCache;

    #[test]
    fn a_problem_pages_only_once_it_has_survived_the_grace() {
        let grace = 60_000;
        let mut latch = Latch::new(grace);
        let problem = "the Grid meter link serial:/dev/ttyUSB1 is offline".to_string();
        let raw = || std::iter::once(problem.clone()).collect::<BTreeSet<_>>();

        // Flapping in and out inside the grace never activates…
        let (added, _) = latch.update(raw(), 1_000);
        assert!(added.is_empty());
        let (added, _) = latch.update(BTreeSet::new(), 2_000);
        assert!(added.is_empty(), "the pending clock restarts with the wire");
        let (added, _) = latch.update(raw(), 3_000);
        assert!(added.is_empty());

        // …and one seen continuously past the grace activates once.
        let (added, _) = latch.update(raw(), 3_000 + grace);
        assert_eq!(added.len(), 1);
        let (added, _) = latch.update(raw(), 4_000 + grace);
        assert!(added.is_empty(), "an ongoing problem is not a new one");

        // Clearing resolves it, and resolving a second time says nothing.
        let (_, resolved) = latch.update(BTreeSet::new(), 5_000 + grace);
        assert_eq!(resolved.len(), 1);
        let (_, resolved) = latch.update(BTreeSet::new(), 6_000 + grace);
        assert!(resolved.is_empty());
    }

    #[test]
    fn the_meter_feed_goes_stale_once_its_age_exceeds_the_grace() {
        let cache = Arc::new(RegisterCache::new());
        let meter = Meter::new(Arc::clone(&cache));
        let diagnostics = Diagnostics::new();
        let grace = 60_000;

        cache.store_response(&ModbusResponse::from_regs(
            ModbusRequest::new(1, 4, crate::meter::R_ACTIVE_POWER, 2),
            (230.0f32).to_bits().to_be_bytes().to_vec(),
        ));
        assert!(problems(&meter, &diagnostics, 10_000, grace).is_empty());

        // Fresh enough for control (its own 5 s window) but old enough to
        // be worth telling a human: the alert grace is the longer clock.
        cache.mark_age(4, crate::meter::R_ACTIVE_POWER, grace + 1);
        let list = problems(&meter, &diagnostics, 10_000, grace);
        assert_eq!(list.len(), 1, "{list:?}");
        assert!(list
            .iter()
            .next()
            .unwrap()
            .contains("grid meter feed is stale"));

        // A process that has never heard from the meter at all is its own
        // problem statement — and only once it is old enough to mean it.
        let mute = Meter::new(Arc::new(RegisterCache::new()));
        assert!(problems(&mute, &diagnostics, 10_000, grace).is_empty());
        let list = problems(&mute, &diagnostics, grace + 1, grace);
        assert!(list
            .iter()
            .any(|problem| problem.contains("not answered a single read")));
    }

    #[test]
    fn the_summary_names_the_host_and_lists_everything_active() {
        let mut active = BTreeSet::new();
        active.insert("problem one".to_string());
        active.insert("problem two".to_string());
        let text = summary(&active);
        assert!(text.contains("grafton-router"), "{text}");
        assert!(text.contains("- problem one\n- problem two"), "{text}");
    }

    #[test]
    fn the_outage_marker_path_is_the_state_directory() {
        // Keep the Rust side and the systemd unit (meter-relay.nix,
        // StateDirectory) pointed at the same directory.
        assert!(PathBuf::from(OUTAGE_MARKER).starts_with("/var/lib/meter-relay-alert/"));
    }
}
