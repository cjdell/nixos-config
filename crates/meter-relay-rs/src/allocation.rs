//! Priority allocation of the central demand across the plant's inverters.
//!
//! The plant is a **priority-ordered list** of inverters: index 0 is the
//! primary actuator, everything after it is the *reserve group*. Nothing here
//! knows how many inverters there are or what they are called — the policy for
//! each one lives in [`InverterPolicy`], and the order of that list *is* the
//! priority order. Adding a third inverter is a config change, not a rewrite.
//!
//! `CONTROL-REVIEW.md` measured the old fixed 2:1 split as the structural
//! defect: the small battery was asked for a third of *every* demand, so it was
//! either saturated or empty for most of the day. The rule here is a priority
//! (water-filling) split instead, and it runs in **both directions** with the
//! same shape:
//!
//! * **Discharge.** Walk the list in order; each inverter is asked for what is
//!   left of the demand, up to the authority it has been *observed* to deliver.
//!   The primary is always on line. The reserve only joins in after the loop has
//!   demonstrated the primary cannot cope: the central PID must be sitting at
//!   the primary-only limit with the grid still off target, sustained past a
//!   short confirmation delay. It stays in until the demand has fallen back
//!   comfortably inside the primary's own authority (hysteresis), or it reaches
//!   its state-of-charge floor.
//!
//! * **Charge.** Walk the same list; each inverter absorbs what is left of the
//!   surplus, up to the authority it has been observed to *accept* and its own
//!   state-of-charge ceiling. Inverters with `absorb_surplus = false` are
//!   skipped. This is what keeps the reserve usable as a *discharge* reserve:
//!   the main bank takes the surplus first, and only what it cannot absorb (a
//!   near-full pack tapering to a few hundred watts) spills down the list into
//!   the reserve, so the reserve is full when a load spike needs it. It is also
//!   self-limiting: a full reserve's acceptance collapses and it stops being
//!   asked, which is the same learned-authority mechanism the discharge side
//!   uses.
//!
//!   Note the deliberate trade-off: surplus absorbed by the reserve is surplus
//!   not exported at 12p/kWh. `absorb_surplus = false` restores pure export for
//!   an inverter (see §4.6 of the review, which argues for export on tariff
//!   grounds alone); the reserve exists to cover demand the main bank cannot, so
//!   the default here is to keep it charged.
//!
//! Authority is learned, not assumed. Each inverter carries one estimate per
//! direction, revised down when it is asked for its limit and delivers less
//! (a tapering battery near full, a pack that is empty) and allowed to relax
//! back up slowly once it delivers what it is asked for. The central loop's
//! output clamp is set from those estimates every tick: that is what removes
//! the windup the review measured at midday, where the loop asked for a mean
//! -1861 W of charge against 179 W of actual acceptance and stayed pinned.

use serde::Serialize;

/// Tolerated gap between requested and delivered power before an authority
/// estimate is revised downwards (W).
const AUTHORITY_MARGIN_W: f64 = 150.0;
/// How fast a collapsed authority estimate may probe back up (W/s).
const AUTHORITY_RELAX_W_PER_S: f64 = 60.0;
/// Delivery must rise by at least this much inside a deficit run for the gap to
/// count as the plant *catching up* rather than refusing (W).
///
/// This is the fix for the field failure of 2026-09-23. The estimate's own
/// upward probe (60 W/s) trails the real Solis by ~200 W, which a flat 150 W
/// margin read as refusal: every probe collapsed the estimate to what had
/// already been delivered, the central loop was clamped to that fraction of the
/// configured rating, and the grid imported ~1 kW for minutes while a 3.6 kW
/// bank sat at ~1 kW. A refusal is a gap that stops closing; a gap that is
/// closing is the plant following a moving command. Requiring delivery to be
/// stationary separates the two without tolerating a genuine refusal.
///
/// It must be small enough that *any* real ramp counts as progress. The first
/// value, 50 W, demanded ~17 W/s inside the 3 s confirm window and so read a
/// slow-but-live charge as a refusal: on 2026-10-01 the Solis's learned charge
/// limit crawled from ~1.4 kW to its 3.6 kW rating at ~6 W/s (seven minutes) in
/// both the Go window and midday PV. Because the command is the estimate, the
/// collapse pinned the command ~150 W above the plant, and the plant could then
/// only ramp as fast as that small gap drove it — a self-limiting ratchet, not
/// the inverter's own soft-start. See `a_slow_charging_plant_...` and
/// `a_load_step_does_not_collapse_the_estimate`: 10 W is above the smoothed
/// battery-power noise floor and below a 6 W/s ramp's progress in the window.
const DELIVERY_PROGRESS_W: f64 = 10.0;
/// After a downward revision, wait this long before probing upwards again (ms).
const AUTHORITY_HOLD_MS: u64 = 20_000;
/// A command within this distance of an estimate counts as leaning on it (W).
const PROBE_BAND_W: f64 = 50.0;
/// A deficit must persist this long before the estimate is revised down (ms).
/// Long enough to ride out the plant's own step response (the inverters' loops
/// take a fraction of a second; the measured authority table shows ~0.98
/// tracking once settled) and slow enough that a genuine refusal - a full
/// battery taking 100 W of a 3.6 kW request - still collapses the estimate
/// within a few seconds.
const AUTHORITY_CONFIRM_MS: u64 = 3_000;
/// A plant asked for power that delivers *none at all* has not refused — it has
/// not acted. A command below a device's minimum start power produces exactly
/// this, and since growth needs the plant to answer, an estimate collapsed onto
/// such a device can never grow: the device is asked for a command too small to
/// stir it, for as long as the process runs. This is the reserve on 2026-09-26,
/// found with both its limits pinned at `AUTHORITY_MARGIN_W` and delivering
/// zero for five hours (W).
const AUTHORITY_SILENT_W: f64 = 1.0;
/// How often a silent plant is offered a larger command (ms).
const AUTHORITY_REPROBE_MS: u64 = 30_000;
/// The least each silent re-probe adds to the ladder (W). The ladder also
/// doubles, so a handful of probes covers the range from the margin floor to
/// any rating without a long tail once the plant starts answering.
const AUTHORITY_REPROBE_STEP_W: f64 = 500.0;
/// How far the loop's demand must be from the primary-only limit to count as
/// "asking for everything the primary has" (W).
const NEAR_LIMIT_W: f64 = 50.0;
/// Smoothing applied to *both* the command and the measurement before they are
/// compared. Smoothing them together matters: comparing a smoothed measurement
/// against a raw command would read every command step as a deficit and
/// collapse the estimate on every load change.
const SMOOTHING_TAU_S: f64 = 0.5;
/// A commanded charge smaller than this is reported as idle rather than as
/// "absorbing surplus" (W).
const ABSORBING_DEADBAND_W: f64 = 1.0;
/// A learned state of charge is not allowed to fall outside this range (%).
const SOC_MIN_PERCENT: f64 = 0.0;
const SOC_MAX_PERCENT: f64 = 100.0;
/// State of charge assumed for an inverter that reports one but has not been
/// read yet. Neutral rather than zero: the floor is a safety net for the
/// battery, not a data-availability check.
const SOC_UNKNOWN_SEED: f64 = 50.0;

/// What one inverter is doing this tick, as the allocator sees it.
#[derive(Clone, Copy, Debug)]
pub struct InverterState {
    /// Power the allocator last asked this inverter for (W, positive = discharge).
    pub commanded: f64,
    /// Measured battery power (W, positive = discharge).
    pub delivered: f64,
    /// Whether that measurement is fresh enough to learn from.
    pub fresh: bool,
    /// Measured state of charge (%), or NaN when this device has no SOC
    /// register, or its register has gone stale. NaN keeps the last known
    /// value rather than treating 0% as real.
    pub soc: f64,
}

impl Default for InverterState {
    fn default() -> Self {
        Self::new(0.0, 0.0, false)
    }
}

impl InverterState {
    pub fn new(commanded: f64, delivered: f64, fresh: bool) -> Self {
        Self {
            commanded,
            delivered,
            fresh,
            soc: f64::NAN,
        }
    }

    /// Attaches a state-of-charge reading (%). Pass NaN for "not reported".
    pub fn with_soc(mut self, soc: f64) -> Self {
        self.soc = soc;
        self
    }
}

/// Static policy for one inverter.
///
/// The order of these in [`AllocatorConfig::inverters`] *is* the plant's
/// priority order, so this struct carries no priority field: index 0 is the
/// primary, the rest are the reserve group.
#[derive(Clone, Debug)]
pub struct InverterPolicy {
    /// Stable key used by the JSON API, InfluxDB field names and Home
    /// Assistant entity ids (e.g. "solis"). Must be unique in the plant.
    pub id: String,
    /// Human-readable name for the dashboard (e.g. "Solis").
    pub name: String,
    /// Largest discharge this inverter may be asked for (W).
    pub max_discharge: f64,
    /// Largest charge this inverter may be asked for (W).
    pub max_charge: f64,
    /// Maximum rate of change of this inverter's target (W/s).
    pub slew_w_per_s: f64,
    /// Grid-charging target during the Go window (W, positive magnitude).
    pub charge_power: f64,
    /// Not discharged at or below this state of charge (%); `None` = no SOC
    /// sensing, so no floor.
    pub min_soc: Option<f64>,
    /// Not charged at or above this state of charge (%); `None` = no SOC
    /// sensing, so no ceiling.
    pub max_soc: Option<f64>,
    /// May this inverter absorb surplus PV that higher-priority inverters
    /// cannot take? `false` means it is discharge-only outside the Go window.
    pub absorb_surplus: bool,
}

impl InverterPolicy {
    /// A policy with the mechanism defaults and no SOC sensing.
    pub fn new(id: &str, name: &str) -> Self {
        Self {
            id: id.to_string(),
            name: name.to_string(),
            max_discharge: 1_500.0,
            max_charge: 1_000.0,
            slew_w_per_s: 1_200.0,
            charge_power: 1_000.0,
            min_soc: None,
            max_soc: None,
            absorb_surplus: true,
        }
    }

    fn senses_soc(&self) -> bool {
        self.min_soc.is_some() || self.max_soc.is_some()
    }
}

/// Policy inputs for the allocator. Everything here is a decision someone might
/// reasonably want to change; the mechanism constants above are not.
#[derive(Clone, Debug)]
pub struct AllocatorConfig {
    /// Grid error beyond the deadband that shows the primary has run out of
    /// authority and the reserve is needed (W).
    pub wake_error_w: f64,
    /// How long that error must persist before the reserve is engaged (ms).
    pub wake_delay_ms: u64,
    /// The reserve is released once the demand has been this far inside the
    /// primary's own authority (W).
    pub release_margin_w: f64,
    /// How long the demand must stay there before releasing (ms).
    pub release_delay_ms: u64,
    /// The plant, in priority order: index 0 is the primary actuator.
    pub inverters: Vec<InverterPolicy>,
}

impl Default for AllocatorConfig {
    fn default() -> Self {
        Self {
            wake_error_w: 120.0,
            wake_delay_ms: 1_500,
            release_margin_w: 250.0,
            release_delay_ms: 30_000,
            inverters: vec![
                // The large main bank: primary actuator in both directions.
                InverterPolicy {
                    max_discharge: 3_600.0,
                    max_charge: 3_600.0,
                    slew_w_per_s: 4_000.0,
                    charge_power: 4_000.0,
                    min_soc: None,
                    max_soc: None,
                    absorb_surplus: true,
                    ..InverterPolicy::new("solis", "Solis")
                },
                // The small reserve: discharge-only outside the Go window, but
                // it does absorb the surplus the main bank cannot take, so it
                // has charge to give when a load spike needs it.
                InverterPolicy {
                    max_discharge: 1_500.0,
                    max_charge: 1_000.0,
                    slew_w_per_s: 1_200.0,
                    charge_power: 1_000.0,
                    min_soc: Some(15.0),
                    max_soc: Some(95.0),
                    absorb_surplus: true,
                    ..InverterPolicy::new("solax", "Solax")
                },
            ],
        }
    }
}

impl AllocatorConfig {
    /// The policy for `id`, mutably — the concise way for callers and tests to
    /// retune one inverter without restating the whole plant.
    ///
    /// # Panics
    /// If no inverter in the plant has that id.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn policy_mut(&mut self, id: &str) -> &mut InverterPolicy {
        self.inverters
            .iter_mut()
            .find(|policy| policy.id == id)
            .unwrap_or_else(|| panic!("no inverter {id:?} in the plant"))
    }
}

/// Why the reserve is (not) contributing. Serialised for the dashboard and the
/// Influx tag, so the codes are part of the API. The four original spellings
/// are kept verbatim (even though "solis_only" now means "the primary alone")
/// so existing InfluxDB/Grafana queries keep matching historical data.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ReserveState {
    /// The primary alone can meet the demand; the reserve is standing by.
    #[serde(rename = "solis_only")]
    PrimaryOnly,
    /// The primary is at its limit and the grid is still off target; the wake
    /// confirmation timer is running.
    Waking,
    /// The reserve is supplying the part of the demand the primary cannot.
    Reserve,
    /// The reserve is unusable: at or below its floor, or not reporting.
    SocFloor,
    /// Grid charging (Octopus Go window).
    Charging,
}

impl ReserveState {
    /// Snake-case code, as used in the JSON API and as an InfluxDB tag.
    pub fn as_str(&self) -> &'static str {
        match self {
            ReserveState::PrimaryOnly => "solis_only",
            ReserveState::Waking => "waking",
            ReserveState::Reserve => "reserve",
            ReserveState::SocFloor => "soc_floor",
            ReserveState::Charging => "charging",
        }
    }
}

/// Authority the engaged actuator set can deliver right now (W, magnitudes).
#[derive(Clone, Copy, Debug, Serialize)]
pub struct ActuatorLimits {
    pub discharge: f64,
    pub charge: f64,
}

/// One inverter's share of one tick's allocation, as published to telemetry.
#[derive(Clone, Debug, Serialize)]
pub struct InverterAllocation {
    /// Matches [`InverterPolicy::id`].
    pub id: String,
    pub name: String,
    /// Power the allocator asked this inverter for (W, positive = discharge).
    pub target: f64,
    pub discharge_limit: f64,
    pub charge_limit: f64,
    /// State of charge this inverter last reported (%), 0.0 when it has none.
    pub soc: f64,
    /// True for index 0, the always-on-line actuator.
    pub primary: bool,
    /// True while this inverter is being asked to absorb (charge).
    pub absorbing: bool,
}

/// One tick's allocation, as published to telemetry.
#[derive(Clone, Debug, Serialize)]
pub struct Allocation {
    /// Per-inverter shares, in the plant's priority order.
    pub inverters: Vec<InverterAllocation>,
    pub state: ReserveState,
    pub total_discharge_limit: f64,
    pub total_charge_limit: f64,
    /// The demand the reserve group is covering (W, discharge only).
    pub reserve_share: f64,
    /// The surplus the reserve group is absorbing (W, charge only).
    pub absorbed: f64,
    /// The demand the engaged set could not cover (W): grid error left over.
    pub unmet: f64,
}

impl Allocation {
    /// This inverter's share, or `None` if it is not in the plant.
    pub fn by_id(&self, id: &str) -> Option<&InverterAllocation> {
        self.inverters.iter().find(|inv| inv.id == id)
    }

    /// This inverter's target (W), or 0.0 if it is not in the plant.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn target(&self, id: &str) -> f64 {
        self.by_id(id).map(|inv| inv.target).unwrap_or(0.0)
    }

    /// Targets in priority order.
    pub fn targets(&self) -> Vec<f64> {
        self.inverters.iter().map(|inv| inv.target).collect()
    }
}

/// A learned limit for one direction of one inverter.
#[derive(Clone, Copy, Debug)]
struct AuthorityLimit {
    /// Never exceed the configured rating.
    ceiling: f64,
    /// Best estimate of what this inverter can actually deliver (W).
    value: f64,
    /// When the current run of "asked for this, did not deliver it" started.
    deficit_since: Option<u64>,
    /// Do not probe upwards before this time.
    hold_until: u64,
    /// What the plant had delivered when the current deficit run began. While
    /// delivery keeps rising past this the gap is the plant following a moving
    /// command, not a refusal.
    deficit_baseline: f64,
    /// Highest command the re-probe ladder has reached since the plant last
    /// answered. Independent of `value`, which the collapse logic may pull back
    /// to the floor between probes — that is what lets a stranded estimate
    /// climb out instead of re-trying the same too-small command forever.
    reprobe_high: f64,
    /// Do not re-probe a silent plant before this time. Pushed forward while
    /// the plant is answering, so a probe only follows sustained silence.
    reprobe_at: u64,
}

impl AuthorityLimit {
    fn new(ceiling: f64) -> Self {
        Self {
            ceiling,
            value: ceiling,
            deficit_since: None,
            hold_until: 0,
            deficit_baseline: 0.0,
            reprobe_high: 0.0,
            reprobe_at: 0,
        }
    }

    fn limit(&self) -> f64 {
        self.value
    }

    /// Offers a silent plant a command one rung further up the ladder. The
    /// normal collapse logic takes the estimate straight back down if the plant
    /// still does not answer, so the cost of a wrong guess is a brief
    /// over-command rather than a standing one.
    fn escalate(&mut self, now: u64) {
        let from = self.reprobe_high.max(self.value);
        self.reprobe_high = (from * 2.0)
            .max(from + AUTHORITY_REPROBE_STEP_W)
            .min(self.ceiling);
        self.value = self.reprobe_high;
        self.deficit_since = Some(now);
        self.hold_until = 0;
        self.reprobe_at = now + AUTHORITY_REPROBE_MS;
    }

    /// One tick of "asked for `commanded`, delivered `delivered`", both as
    /// magnitudes in this direction and both smoothed the same way.
    ///
    /// A gap that stops closing means the plant cannot do what it is being
    /// asked, and the estimate is revised down to what it actually delivered.
    /// A gap that is still closing is the plant following a moving command -
    /// or a plant that is merely slower than the probe - so the probe
    /// continues. Either way a plant that keeps up is assumed to have headroom,
    /// so the estimate relaxes back towards the configured rating, slowly and
    /// only while the loop is actually leaning on it, so an idle direction does
    /// not drift upwards unattended.
    fn observe(&mut self, commanded: f64, delivered: f64, now: u64, dt: f64) {
        // Delivery making progress towards the command means the plant is
        // catching up, not refusing: restart the stall clock. A plant trailing
        // a moving command will keep doing this, so the probe continues; only a
        // delivery that stops moving is evidence of a refusal.
        if delivered > self.deficit_baseline + DELIVERY_PROGRESS_W {
            self.deficit_baseline = delivered;
            self.deficit_since = Some(now);
        }

        let leaning_on_it = commanded >= self.value - PROBE_BAND_W;

        // A silent plant needs a way out. Everything else here can only revise
        // the estimate *down* to what was delivered, and the loop then asks for
        // no more than that, so a device that will not act on what it is asked
        // is never asked for anything it *would* act on. Walk the estimate up a
        // rung at a time until either the plant answers (and the ordinary probe
        // takes over from a real measurement) or the ceiling is reached.
        //
        // Escalating is only ever a *permission* in balance mode - the split
        // still caps each inverter at what the demand needs - so the only place
        // it raises an actual command is the open-loop Go-window charge, which
        // is the case that must not be left asking for a command too small to
        // act on.
        let silent = commanded > AUTHORITY_SILENT_W && delivered <= AUTHORITY_SILENT_W;
        if silent {
            if leaning_on_it && now >= self.reprobe_at {
                self.escalate(now);
            }
        } else {
            // The plant is answering, so the ladder may start again from here.
            self.reprobe_high = self.value;
            self.reprobe_at = now + AUTHORITY_REPROBE_MS;
        }

        if delivered + AUTHORITY_MARGIN_W < commanded {
            let since = *self.deficit_since.get_or_insert(now);
            if now.saturating_sub(since) >= AUTHORITY_CONFIRM_MS {
                self.value = (delivered + AUTHORITY_MARGIN_W).clamp(0.0, self.ceiling);
                self.hold_until = now + AUTHORITY_HOLD_MS;
                // Keep confirming: a further collapse may follow.
                self.deficit_since = Some(now);
                self.deficit_baseline = delivered;
                // A stalled delivery is no evidence for more authority.
                return;
            }
        } else {
            self.deficit_since = None;
            self.deficit_baseline = delivered;
        }

        // `value` may have moved on the escalation above, so re-read it.
        let leaning_on_it = commanded >= self.value - PROBE_BAND_W;
        if leaning_on_it && now >= self.hold_until {
            self.value = (self.value + AUTHORITY_RELAX_W_PER_S * dt).min(self.ceiling);
        }
    }
}

/// Per-inverter authority estimates in both directions.
#[derive(Clone, Copy, Debug)]
pub struct InverterAuthority {
    discharge: AuthorityLimit,
    charge: AuthorityLimit,
    commanded: f64,
    delivered: f64,
    seen: bool,
}

impl InverterAuthority {
    pub fn new(discharge_ceiling: f64, charge_ceiling: f64) -> Self {
        Self {
            discharge: AuthorityLimit::new(discharge_ceiling),
            charge: AuthorityLimit::new(charge_ceiling),
            commanded: 0.0,
            delivered: 0.0,
            seen: false,
        }
    }

    /// True while this inverter is reporting fresh measurements. A device that
    /// has stopped answering must not be handed demand, however healthy its
    /// last reading looked.
    pub fn available(&self) -> bool {
        self.seen
    }

    pub fn discharge_limit(&self) -> f64 {
        self.discharge.limit()
    }

    pub fn charge_limit(&self) -> f64 {
        self.charge.limit()
    }

    fn observe(&mut self, state: InverterState, now: u64, dt: f64) {
        if !state.fresh {
            // No usable measurement: change nothing rather than collapsing to
            // whatever a stale or absent register happens to read.
            self.seen = false;
            return;
        }

        let alpha = (dt / SMOOTHING_TAU_S).min(1.0);
        if !self.seen {
            self.commanded = state.commanded;
            self.delivered = state.delivered;
            self.seen = true;
        } else {
            self.commanded += alpha * (state.commanded - self.commanded);
            self.delivered += alpha * (state.delivered - self.delivered);
        }

        self.discharge
            .observe(self.commanded.max(0.0), self.delivered.max(0.0), now, dt);
        self.charge
            .observe((-self.commanded).max(0.0), (-self.delivered).max(0.0), now, dt);
    }
}

/// One inverter's live state: its policy, its learned authority, and the target
/// being slewed towards.
struct InverterSlot {
    policy: InverterPolicy,
    authority: InverterAuthority,
    target: f64,
    soc: f64,
    last_soc: f64,
    absorbing: bool,
}

impl InverterSlot {
    fn new(policy: InverterPolicy) -> Self {
        let authority = InverterAuthority::new(policy.max_discharge, policy.max_charge);
        // A device that senses SOC starts from a neutral guess rather than
        // "unknown": the floor is a battery safety net, not an availability
        // check, and an unread floor must not block the reserve for the first
        // poll interval.
        let soc = if policy.senses_soc() {
            SOC_UNKNOWN_SEED
        } else {
            f64::NAN
        };

        Self {
            policy,
            authority,
            target: 0.0,
            soc,
            last_soc: soc,
            absorbing: false,
        }
    }

    /// Fresh measurements *and* enough charge to be discharged.
    fn discharge_available(&self) -> bool {
        if !self.authority.available() {
            return false;
        }
        match self.policy.min_soc {
            Some(floor) => self.soc > floor,
            None => true,
        }
    }

    /// Willing and able to absorb surplus right now.
    fn can_absorb_charge(&self) -> bool {
        if !self.policy.absorb_surplus || !self.authority.available() {
            return false;
        }
        match self.policy.max_soc {
            Some(ceiling) => self.soc < ceiling,
            None => true,
        }
    }

    fn set_soc(&mut self, soc: f64) {
        if soc.is_finite() {
            self.soc = soc.clamp(SOC_MIN_PERCENT, SOC_MAX_PERCENT);
        }
    }
}

/// The allocator: decides who supplies or absorbs what, and learns what each
/// inverter can actually deliver.
pub struct Allocator {
    cfg: AllocatorConfig,
    inverters: Vec<InverterSlot>,
    engaged: bool,
    wake_since: Option<u64>,
    release_since: Option<u64>,
    /// Demand the last `split_*` call could not cover.
    unmet: f64,
}

impl Allocator {
    pub fn new(cfg: AllocatorConfig) -> Self {
        assert!(
            !cfg.inverters.is_empty(),
            "the plant must have at least one inverter"
        );

        Self {
            inverters: cfg.inverters.iter().cloned().map(InverterSlot::new).collect(),
            cfg,
            engaged: false,
            wake_since: None,
            release_since: None,
            unmet: 0.0,
        }
    }

    /// The plant's policies, in priority order.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn policies(&self) -> &[InverterPolicy] {
        &self.cfg.inverters
    }

    pub fn engaged(&self) -> bool {
        self.engaged
    }

    /// State of charge (%) of the first reserve inverter, for telemetry.
    pub fn reserve_soc(&self) -> f64 {
        self.inverters
            .iter()
            .skip(1)
            .map(|slot| slot.soc)
            .find(|soc| soc.is_finite())
            .unwrap_or(0.0)
    }

    /// True while the reserve may be used at all: at least one inverter in it
    /// is reporting fresh measurements and is above its own floor.
    pub fn reserve_available(&self) -> bool {
        self.inverters
            .iter()
            .skip(1)
            .any(InverterSlot::discharge_available)
    }

    /// Whether this plant has a reserve group at all.
    fn has_reserve(&self) -> bool {
        self.inverters.len() > 1
    }

    /// What the primary alone can be asked for (W).
    fn primary_discharge_limit(&self) -> f64 {
        self.inverters
            .first()
            .map(|slot| slot.authority.discharge_limit())
            .unwrap_or(0.0)
    }

    /// Learn from the last tick's commands and measurements. `states` is in
    /// priority order; a missing entry is treated as "not reporting".
    pub fn observe(&mut self, states: &[InverterState], now: u64, dt: f64) {
        for (index, slot) in self.inverters.iter_mut().enumerate() {
            let state = states.get(index).copied().unwrap_or_default();
            slot.set_soc(state.soc);
            slot.authority.observe(state, now, dt);
            if slot.soc.is_finite() {
                slot.last_soc = slot.soc;
            }
        }
    }

    /// Authority of the actuator set the allocator would actually use: the
    /// primary always, the reserve only where it is genuinely usable. The
    /// central PID's output clamp is set from this, so it can never ask for
    /// more than the actuators on line can deliver.
    ///
    /// Charge authority is the sum of every inverter that will absorb surplus,
    /// which is what lets the loop keep asking after the main bank has filled
    /// up: the remainder is picked up further down the priority list.
    pub fn limits(&self) -> ActuatorLimits {
        let discharge = self
            .inverters
            .iter()
            .enumerate()
            .filter(|(index, slot)| *index == 0 || (self.engaged && slot.discharge_available()))
            .map(|(_, slot)| slot.authority.discharge_limit())
            .sum();

        let charge = self
            .inverters
            .iter()
            .filter(|slot| slot.can_absorb_charge())
            .map(|slot| slot.authority.charge_limit())
            .sum();

        ActuatorLimits { discharge, charge }
    }

    /// Decide whether the reserve is needed, from the previous tick's outcome.
    ///
    /// The test is physical rather than structural: the loop is asking for
    /// everything the primary has to give (`needed` sits at the primary-only
    /// limit) and the grid is still off target by more than the deadband plus
    /// the wake threshold, sustained. Both halves are needed: the error alone
    /// would fire on any plant transient, and the demand alone would fire on
    /// every load the primary is about to cover anyway.
    pub fn update_reserve(&mut self, error: f64, needed: f64, now: u64) {
        if !self.has_reserve() || !self.reserve_available() {
            self.engaged = false;
            self.wake_since = None;
            self.release_since = None;
            return;
        }

        let primary_only = self.primary_discharge_limit();

        if self.engaged {
            if needed < primary_only - self.cfg.release_margin_w {
                let since = *self.release_since.get_or_insert(now);
                if now.saturating_sub(since) >= self.cfg.release_delay_ms {
                    self.engaged = false;
                    self.release_since = None;
                }
            } else {
                self.release_since = None;
            }
            return;
        }

        let at_primary_limit = needed >= primary_only - NEAR_LIMIT_W;
        let wants_reserve = at_primary_limit && error > self.cfg.wake_error_w;
        if wants_reserve {
            let since = *self.wake_since.get_or_insert(now);
            if now.saturating_sub(since) >= self.cfg.wake_delay_ms {
                self.engaged = true;
                self.wake_since = None;
            }
        } else {
            self.wake_since = None;
        }
    }

    fn state(&self, charging: bool) -> ReserveState {
        if charging {
            return ReserveState::Charging;
        }
        // A plant with no reserve has nothing to report but "the primary has
        // it"; a reserve that is at its floor or not answering is a different
        // situation and is worth flagging.
        if !self.has_reserve() {
            return ReserveState::PrimaryOnly;
        }
        if !self.reserve_available() {
            return ReserveState::SocFloor;
        }
        if self.engaged {
            return ReserveState::Reserve;
        }
        if self.wake_since.is_some() {
            return ReserveState::Waking;
        }
        ReserveState::PrimaryOnly
    }

    /// Allocate a demand that the central loop has already bounded by
    /// [`Allocator::limits`].
    pub fn split(&mut self, needed: f64, dt: f64) -> Allocation {
        let wants = if needed >= 0.0 {
            self.plan_discharge(needed)
        } else {
            self.plan_charge(-needed)
        };

        for (slot, want) in self.inverters.iter_mut().zip(wants) {
            slot.target = slew(slot.target, want, slot.policy.slew_w_per_s, dt);
            // A slew-limited target decaying through zero is not "absorbing".
            slot.absorbing = slot.target < -ABSORBING_DEADBAND_W;
        }

        // What the engaged set could not cover: the part of the demand that
        // has to come from the grid.
        let covered: f64 = self.inverters.iter().map(|slot| slot.target.max(0.0)).sum();
        self.unmet = (needed - covered).max(0.0);

        self.allocation(false)
    }

    /// Water-fill a discharge demand down the priority list (W, positive).
    fn plan_discharge(&self, needed: f64) -> Vec<f64> {
        let mut remaining = needed;
        self.inverters
            .iter()
            .enumerate()
            .map(|(index, slot)| {
                // The primary is always on line; the reserve only once the loop
                // has shown the primary cannot cope.
                let on_line = index == 0 || (self.engaged && slot.discharge_available());
                if !on_line {
                    return 0.0;
                }
                let take = remaining.min(slot.authority.discharge_limit()).max(0.0);
                remaining -= take;
                take
            })
            .collect()
    }

    /// Water-fill a charging demand down the priority list (W, positive
    /// magnitude; the returned targets are negative).
    ///
    /// The reserve is *not* gated on `engaged` here: it is charged precisely so
    /// that it has something to give when a spike does need it.
    fn plan_charge(&self, demand: f64) -> Vec<f64> {
        let mut remaining = demand;
        self.inverters
            .iter()
            .map(|slot| {
                if !slot.can_absorb_charge() {
                    return 0.0;
                }
                let take = remaining.min(slot.authority.charge_limit()).max(0.0);
                remaining -= take;
                -take
            })
            .collect()
    }

    fn allocation(&self, charging: bool) -> Allocation {
        let limits = self.limits();
        let inverters: Vec<InverterAllocation> = self
            .inverters
            .iter()
            .enumerate()
            .map(|(index, slot)| InverterAllocation {
                id: slot.policy.id.clone(),
                name: slot.policy.name.clone(),
                target: slot.target,
                discharge_limit: slot.authority.discharge_limit(),
                charge_limit: slot.authority.charge_limit(),
                soc: if slot.soc.is_finite() { slot.soc } else { 0.0 },
                primary: index == 0,
                absorbing: slot.absorbing,
            })
            .collect();

        let reserve_share = inverters
            .iter()
            .skip(1)
            .map(|inv| inv.target.max(0.0))
            .sum();
        let absorbed = inverters
            .iter()
            .skip(1)
            .map(|inv| (-inv.target).max(0.0))
            .sum();

        Allocation {
            inverters,
            state: self.state(charging),
            total_discharge_limit: limits.discharge,
            total_charge_limit: limits.charge,
            reserve_share,
            absorbed,
            unmet: self.unmet,
        }
    }

    /// Neutral allocation for start-up, before the first tick has run.
    pub fn idle_allocation(&self) -> Allocation {
        let mut allocation = self.allocation(false);
        allocation.state = ReserveState::PrimaryOnly;
        allocation
    }

    /// Targets for the open-loop Octopus Go charging window, where the central
    /// PID does not run.
    pub fn split_charge(&mut self, dt: f64) -> Allocation {
        for slot in self.inverters.iter_mut() {
            let want = match slot.policy.max_soc {
                Some(ceiling) if slot.soc >= ceiling => 0.0,
                _ => -(slot.policy.charge_power.min(slot.authority.charge_limit())),
            };
            slot.target = slew(slot.target, want, slot.policy.slew_w_per_s, dt);
            // A slew-limited target decaying through zero is not "absorbing".
            slot.absorbing = slot.target < -ABSORBING_DEADBAND_W;
        }
        self.unmet = 0.0;

        self.allocation(true)
    }

    /// The plant's regime changed (charge <-> balance): the reserve decision
    /// does not carry across it, and neither do the timers.
    pub fn reset_regime(&mut self) {
        self.engaged = false;
        self.wake_since = None;
        self.release_since = None;
        self.unmet = 0.0;
    }
}

/// Limits how fast a commanded power may change (W/s).
fn slew(previous: f64, wanted: f64, rate_w_per_s: f64, dt: f64) -> f64 {
    let max_step = (rate_w_per_s * dt).max(0.0);
    wanted.clamp(previous - max_step, previous + max_step)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TICK_MS: u64 = 10;
    const DT: f64 = 0.01;

    fn fresh(commanded: f64, delivered: f64) -> InverterState {
        InverterState::new(commanded, delivered, true)
    }

    fn stale(commanded: f64, delivered: f64) -> InverterState {
        InverterState::new(commanded, delivered, false)
    }

    fn plant() -> AllocatorConfig {
        AllocatorConfig::default()
    }

    /// Marks every inverter as reporting fresh measurements, as the controller
    /// does on its first poll. Until then the reserve is unavailable by design.
    fn mark_available(alloc: &mut Allocator) {
        let states = vec![fresh(0.0, 0.0); alloc.policies().len()];
        alloc.observe(&states, 0, DT);
    }

    /// A one-line plant: the inverter follows what it is asked for with a small
    /// lag, limited by what its battery can actually give or accept.
    struct Stub {
        delivered: f64,
        discharge_cap: f64,
        charge_cap: f64,
    }

    impl Stub {
        fn new(discharge_cap: f64, charge_cap: f64) -> Self {
            Self {
                delivered: 0.0,
                discharge_cap,
                charge_cap,
            }
        }

        fn step(&mut self, commanded: f64, dt: f64) -> f64 {
            let goal = commanded.clamp(-self.charge_cap, self.discharge_cap);
            let alpha = (dt / 0.3).min(1.0);
            self.delivered += alpha * (goal - self.delivered);
            self.delivered
        }
    }

    /// Runs the allocator's split repeatedly so the slew-limited targets reach
    /// their settled values, as they do under the 100 Hz loop.
    fn settle(alloc: &mut Allocator, needed: f64, ticks: u32) -> Allocation {
        let mut out = alloc.idle_allocation();
        for _ in 0..ticks {
            out = alloc.split(needed, DT);
        }
        out
    }

    /// Ticks the allocator against a stub plant, feeding the plant's own
    /// response back as the measurement — the same order the controller uses:
    /// step the plant with the last command, learn from it, then allocate.
    fn drive(alloc: &mut Allocator, stub: &mut Stub, needed: f64, ticks: u32, now: &mut u64) -> Allocation {
        let mut commanded = 0.0;
        let mut out = alloc.idle_allocation();
        for _ in 0..ticks {
            *now += TICK_MS;
            let measured = stub.step(commanded, DT);
            alloc.observe(&[fresh(commanded, measured), stale(0.0, 0.0)], *now, DT);
            out = alloc.split(needed, DT);
            commanded = out.target("solis");
        }
        out
    }

    /// A plant that follows the command with a lag must not have that lag read
    /// as refusal. While the estimate probes upwards the command is moving, and
    /// a plant that cannot teleport to a new setpoint trails it. Before the fix
    /// that trail pinned the estimate at `delivered + AUTHORITY_MARGIN_W`, so
    /// the probe could only advance as fast as the plant itself followed it
    /// instead of at `AUTHORITY_RELAX_W_PER_S` (the 2026-09-23 field failure).
    #[test]
    fn a_lagging_plant_is_not_mistaken_for_a_refusing_one() {
        // Start where a genuine refusal would have left it: the estimate at
        // the plant's floor, with the plant sitting exactly on it. Everything
        // from here is the estimate's own upward probe.
        let mut limit = AuthorityLimit::new(3_000.0);
        limit.value = 150.0;
        let mut delivered = 150.0;
        // The loop is saturated on the estimate, so the command *is* the
        // estimate. A real inverter sees that command over a Modbus link it
        // polls on its own cadence (~2 s for the Solis) and then follows it
        // with its own lag, so the plant is a transport delay plus a first-order
        // response - which is what makes a 60 W/s probe trail by ~200 W.
        let delay_ticks = 250;
        let tau = 2.0;
        let dt = TICK_MS as f64 / 1000.0;
        let mut now = 0u64;
        let mut in_flight: std::collections::VecDeque<f64> = std::collections::VecDeque::new();
        let mut max_gap = 0.0f64;
        let mut collapses = 0u32;
        let mut reached_at: Option<u64> = None;

        for _ in 0..12_000 {
            let commanded = limit.limit();
            in_flight.push_back(commanded);
            let seen = if in_flight.len() > delay_ticks {
                in_flight.pop_front().unwrap()
            } else {
                150.0
            };
            delivered += (seen.clamp(0.0, 3_000.0) - delivered) * (dt / tau);
            let before = limit.limit();
            max_gap = max_gap.max(commanded - delivered);
            limit.observe(commanded, delivered, now, dt);
            now += TICK_MS;
            if limit.limit() + 1.0 < before {
                collapses += 1;
            }
            if reached_at.is_none() && limit.limit() > 3_000.0 - 1.0 {
                reached_at = Some(now);
            }
        }

        assert_eq!(
            collapses, 0,
            "the estimate must never be knocked back while the plant follows it"
        );
        let reached =
            reached_at.expect("the estimate should recover to the ceiling through its own probe");
        assert!(
            reached <= 60_000,
            "recovery took {reached} ms; the probe must not be limited by the plant's own lag (max_gap {max_gap})"
        );
        assert!(
            limit.limit() > 3_000.0 - 1.0,
            "the estimate should recover to the ceiling through its own probe, got {}",
            limit.limit()
        );
    }

    #[test]
    fn primary_takes_the_whole_demand_while_the_reserve_stands_by() {
        let mut alloc = Allocator::new(plant());
        let mut stub = Stub::new(3_000.0, 3_000.0);
        let mut now = 0;

        let mut commanded = 0.0;
        for _ in 0..3_000 {
            now += TICK_MS;
            alloc.observe(
                &[
                    fresh(commanded, stub.step(commanded, DT)),
                    // The reserve is idle but healthy: it reports fresh zeroes.
                    fresh(0.0, 0.0),
                ],
                now,
                DT,
            );
            alloc.update_reserve(0.0, 1_000.0, now);
            let out = alloc.split(1_000.0, DT);
            commanded = out.target("solis");
            assert_eq!(out.target("solax"), 0.0);
            assert_eq!(out.state, ReserveState::PrimaryOnly);
        }
        // No authority is spent on the reserve, so the loop keeps its full
        // primary-only range.
        assert_eq!(alloc.limits().discharge, 3_600.0);
    }

    #[test]
    fn reserve_engages_only_after_sustained_unmet_demand() {
        let mut cfg = plant();
        cfg.policy_mut("solis").max_discharge = 2_000.0;
        let mut alloc = Allocator::new(cfg.clone());
        let mut now = 0;
        mark_available(&mut alloc);

        // The loop is asking for everything the primary has and the grid is
        // 500 W off target: the demand needs the reserve, but not before the
        // confirmation delay.
        alloc.update_reserve(500.0, 2_000.0, now);
        assert!(!alloc.engaged());
        now += cfg.wake_delay_ms - TICK_MS;
        alloc.update_reserve(500.0, 2_000.0, now);
        assert!(!alloc.engaged(), "must not engage before the delay elapses");

        now += TICK_MS;
        alloc.update_reserve(500.0, 2_000.0, now);
        assert!(alloc.engaged());

        let out = settle(&mut alloc, 2_500.0, 1_000);
        assert_eq!(alloc.limits().discharge, 3_500.0, "reserve authority is now on line");
        // The primary is capped at its learned authority, the reserve takes the rest.
        assert_eq!(out.target("solis"), 2_000.0);
        assert_eq!(out.target("solax"), 500.0);
        assert_eq!(out.state, ReserveState::Reserve);
        assert_eq!(out.reserve_share, 500.0);
    }

    #[test]
    fn a_transient_that_clears_never_wakes_the_reserve() {
        // A kettle: a couple of seconds of shortfall from a cold start.
        let mut alloc = Allocator::new(plant());
        let mut now = 0;
        mark_available(&mut alloc);
        alloc.update_reserve(900.0, 3_600.0, now);
        assert_eq!(alloc.state(false), ReserveState::Waking);

        // ... the transient ends before the confirmation delay is up.
        now += 1_000;
        alloc.update_reserve(10.0, 1_000.0, now);
        alloc.update_reserve(10.0, 1_000.0, now + 10);
        assert!(!alloc.engaged());
        assert_eq!(alloc.state(false), ReserveState::PrimaryOnly);
    }

    #[test]
    fn demand_inside_primary_authority_never_wakes_the_reserve() {
        // The loop is not asking for everything the primary has, whatever the
        // grid error: this is the case that a plain error threshold would get
        // wrong.
        let mut alloc = Allocator::new(plant());
        let mut now = 0;
        mark_available(&mut alloc);
        for _ in 0..1_000 {
            now += TICK_MS;
            alloc.update_reserve(2_000.0, 1_000.0, now);
        }
        assert!(!alloc.engaged());
        assert_eq!(alloc.state(false), ReserveState::PrimaryOnly);
    }

    #[test]
    fn reserve_releases_when_demand_falls_back_inside_primary_authority() {
        let mut alloc = Allocator::new(plant());
        alloc.engaged = true;
        mark_available(&mut alloc);
        let mut now = 1_000_000;

        // Demand still needs the reserve: no release.
        alloc.update_reserve(-20.0, 3_700.0, now);
        assert!(alloc.engaged());

        // Demand drops well inside the primary's own authority: released after
        // the release delay, not before.
        now += 5_000;
        alloc.update_reserve(-20.0, 2_000.0, now);
        assert!(alloc.engaged());
        now += 30_000;
        alloc.update_reserve(-20.0, 2_000.0, now);
        assert!(!alloc.engaged());

        let out = settle(&mut alloc, 2_000.0, 1_000);
        assert_eq!(out.target("solax"), 0.0);
        assert_eq!(out.state, ReserveState::PrimaryOnly);
    }

    #[test]
    fn reserve_is_never_discharged_below_its_floor() {
        let mut alloc = Allocator::new(plant());
        alloc.engaged = true;
        mark_available(&mut alloc);
        let mut now = 0;
        for _ in 0..100 {
            now += TICK_MS;
            alloc.observe(
                &[
                    fresh(2_000.0, 2_000.0),
                    fresh(500.0, 500.0).with_soc(10.0),
                ],
                now,
                DT,
            );
            // A measured deficit right at the floor must not reopen it.
            alloc.update_reserve(900.0, 4_000.0, now);
            let out = settle(&mut alloc, 4_000.0, 50);
            assert_eq!(out.target("solax"), 0.0);
        }
        assert!(!alloc.engaged());
        assert_eq!(alloc.state(false), ReserveState::SocFloor);
        assert_eq!(alloc.limits().discharge, 3_600.0);
    }

    // --- Charging: surplus water-fills down the priority list ----------------

    /// The main bank takes the surplus while it has headroom; nothing spills.
    #[test]
    fn surplus_goes_to_the_primary_while_it_can_absorb_it() {
        let mut alloc = Allocator::new(plant());
        let mut now = 0;
        for _ in 0..1_000 {
            now += TICK_MS;
            alloc.observe(
                &[
                    fresh(-500.0, -500.0),
                    fresh(0.0, 0.0).with_soc(60.0),
                ],
                now,
                DT,
            );
            let out = settle(&mut alloc, -500.0, 50);
            assert_eq!(out.target("solis"), -500.0);
            assert_eq!(out.target("solax"), 0.0, "nothing should spill while the bank fills");
        }
        assert_eq!(alloc.limits().charge, 3_600.0 + 1_000.0);
    }

    /// The headline behaviour: once the main bank's acceptance collapses, the
    /// reserve absorbs the surplus instead of it going to the grid.
    #[test]
    fn surplus_spills_into_the_reserve_when_the_main_bank_is_full() {
        let mut alloc = Allocator::new(plant());
        let mut now = 0;

        // The main bank accepts only 200 W of whatever it is asked for.
        let mut main = Stub::new(0.0, 200.0);
        let mut reserve = Stub::new(0.0, 1_000.0);

        let mut out = alloc.idle_allocation();
        for _ in 0..3_000 {
            now += TICK_MS;
            let main_measured = main.step(out.target("solis"), DT);
            let reserve_measured = reserve.step(out.target("solax"), DT);
            alloc.observe(
                &[
                    fresh(out.target("solis"), main_measured),
                    fresh(out.target("solax"), reserve_measured).with_soc(40.0),
                ],
                now,
                DT,
            );
            out = alloc.split(-2_000.0, DT);
        }

        // The primary's charge authority follows its real acceptance...
        let main_limit = out.by_id("solis").unwrap().charge_limit;
        assert!(main_limit < 500.0, "primary charge authority {main_limit}");
        // ... and everything it could not take landed in the reserve, right up
        // to the reserve's own configured rating.
        assert!(
            (out.target("solax") + 1_000.0).abs() < 100.0,
            "the reserve should be saturated at its rating, got {}",
            out.target("solax")
        );
        assert_eq!(out.absorbed, -out.target("solax"));
        assert!(out.absorbed > 800.0, "absorbed {}", out.absorbed);
        assert!(out.by_id("solax").unwrap().absorbing);
        // The demand beyond what both banks can accept is what still exports.
        let covered = -(out.target("solis") + out.target("solax"));
        assert!(covered < 1_500.0, "combined absorption should be capped, got {covered} W");
    }

    /// The spill is self-limiting: a reserve at its ceiling is left alone.
    #[test]
    fn the_reserve_stops_absorbing_at_its_ceiling() {
        // The main bank takes almost nothing, so the whole surplus is looking
        // for somewhere to go.
        let mut cfg = plant();
        cfg.policy_mut("solis").max_charge = 100.0;
        let mut alloc = Allocator::new(cfg);
        let mut now = 0;

        for soc in [40.0, 94.0, 96.0] {
            now += TICK_MS;
            alloc.observe(
                &[fresh(0.0, 0.0), fresh(0.0, 0.0).with_soc(soc)],
                now,
                DT,
            );
            let out = settle(&mut alloc, -1_500.0, 500);
            if soc < 95.0 {
                assert!(
                    out.target("solax") < -100.0,
                    "at {soc}% the reserve should absorb, got {}",
                    out.target("solax")
                );
            } else {
                assert_eq!(out.target("solax"), 0.0, "at {soc}% the reserve must be left alone");
            }
        }
    }

    /// `absorb_surplus = false` is the one-line revert to pure export.
    #[test]
    fn a_discharge_only_inverter_never_absorbs_surplus() {
        let mut cfg = plant();
        cfg.policy_mut("solax").absorb_surplus = false;
        let mut alloc = Allocator::new(cfg);
        let mut now = 0;

        for _ in 0..500 {
            now += TICK_MS;
            alloc.observe(
                &[fresh(0.0, 0.0), fresh(0.0, 0.0).with_soc(40.0)],
                now,
                DT,
            );
            let out = settle(&mut alloc, -1_500.0, 50);
            assert_eq!(out.target("solax"), 0.0);
            assert_eq!(out.absorbed, 0.0);
        }
        // ... and it contributes no charge authority to the central loop.
        assert_eq!(alloc.limits().charge, 3_600.0);
    }

    #[test]
    fn go_window_charges_every_bank_up_to_its_own_ceiling() {
        let mut cfg = plant();
        cfg.policy_mut("solis").max_charge = 4_000.0;
        let mut alloc = Allocator::new(cfg);
        let mut now = 0;

        // Reserve at 40%: charged at the configured rate.
        alloc.observe(
            &[
                fresh(-1_000.0, -1_000.0),
                fresh(-500.0, -500.0).with_soc(40.0),
            ],
            now,
            DT,
        );
        let out = alloc.split_charge(DT);
        assert_eq!(out.state, ReserveState::Charging);

        // Drive the targets to their configured values.
        for _ in 0..2_000 {
            alloc.split_charge(DT);
        }
        let out = alloc.split_charge(DT);
        assert!((out.target("solis") + 4_000.0).abs() < 1.0);
        assert!((out.target("solax") + 1_000.0).abs() < 1.0);

        // At 96% the reserve is left alone; the primary keeps charging.
        now += TICK_MS;
        alloc.observe(
            &[
                fresh(-4_000.0, -4_000.0),
                fresh(0.0, 0.0).with_soc(96.0),
            ],
            now,
            DT,
        );
        let mut out = alloc.split_charge(DT);
        for _ in 0..200 {
            out = alloc.split_charge(DT);
        }
        assert_eq!(out.target("solax"), 0.0);
        assert!((out.target("solis") + 4_000.0).abs() < 1.0);
    }

    /// A plant whose own response is slow must not have that slowness read as
    /// refusal, or the estimate's downward revision caps the command at
    /// `delivered + AUTHORITY_MARGIN_W` and the plant can then only ramp as fast
    /// as that small gap drives it. On 2026-10-01 the Solis's charge limit
    /// crawled from ~1.4 kW to its 3.6 kW rating at ~6 W/s — seven minutes — in
    /// both the Go window and midday PV, because the probe was collapsing on
    /// the plant's own lag. The command here *is* the estimate (the central
    /// loop is saturated on it), which is exactly the field case.
    #[test]
    fn a_slow_charging_plant_is_not_throttled_to_its_own_lag() {
        let mut limit = AuthorityLimit::new(3_600.0);
        limit.value = AUTHORITY_MARGIN_W; // start from the collapsed floor
        let mut delivered = 0.0f64;
        let dt = TICK_MS as f64 / 1000.0;
        let tau = 20.0; // a genuinely slow charge response
        let mut now = 0u64;
        let mut collapses = 0u32;
        let mut reached_at: Option<u64> = None;

        for _ in 0..12_000 {
            let commanded = limit.limit();
            delivered += (commanded - delivered) * (dt / tau).min(1.0);
            let before = limit.limit();
            limit.observe(commanded, delivered, now, dt);
            now += TICK_MS;
            if limit.limit() + 1.0 < before {
                collapses += 1;
            }
            if reached_at.is_none() && limit.limit() > 3_599.0 {
                reached_at = Some(now);
            }
        }

        assert_eq!(
            collapses, 0,
            "a plant that is still moving towards the command must not be collapsed"
        );
        let reached = reached_at.expect("the estimate should reach the ceiling");
        assert!(
            reached <= 60_000,
            "recovery took {reached} ms: the probe must run at its own rate, not the plant's"
        );
    }

    #[test]
    fn authority_collapses_when_the_battery_refuses_charge() {
        let mut alloc = Allocator::new(plant());
        let mut stub = Stub::new(0.0, 100.0);
        let mut now = 0;

        // Full battery: asked for 3.6 kW, accepts 100 W.
        let mut out = alloc.idle_allocation();
        for _ in 0..3_000 {
            now += TICK_MS;
            let measured = stub.step(-3_600.0, DT);
            alloc.observe(&[fresh(-3_600.0, measured), stale(0.0, 0.0)], now, DT);
            out = alloc.split(-3_600.0, DT);
        }

        let learned = out.by_id("solis").unwrap().charge_limit;
        assert!(
            learned < 400.0,
            "charge authority should collapse to the observed acceptance, got {learned}"
        );
        assert!(out.target("solis") > -400.0, "target {}", out.target("solis"));
    }

    #[test]
    fn a_load_step_does_not_collapse_the_estimate() {
        // A 2 kW step: the command and the measurement are smoothed the same
        // way, so the estimate must not read the plant's own response time as
        // a shortfall.
        let mut alloc = Allocator::new(plant());
        let mut stub = Stub::new(3_000.0, 3_000.0);
        let mut now = 0;

        // Settle at 1 kW.
        drive(&mut alloc, &mut stub, 1_000.0, 2_000, &mut now);
        let before = alloc.limits().discharge;

        // Step to 2.5 kW and run for 6 s.
        drive(&mut alloc, &mut stub, 2_500.0, 600, &mut now);

        let after = alloc.limits().discharge;
        assert_eq!(before, 3_600.0);
        assert_eq!(after, 3_600.0, "a step must not revise the estimate down");
    }

    #[test]
    fn authority_recovers_slowly_once_the_deficit_clears() {
        let mut cfg = plant();
        cfg.policy_mut("solis").max_charge = 1_000.0;
        let mut alloc = Allocator::new(cfg);
        let mut stub = Stub::new(0.0, 100.0);
        let mut now = 0;

        for _ in 0..3_000 {
            now += TICK_MS;
            let measured = stub.step(-1_000.0, DT);
            alloc.observe(&[fresh(-1_000.0, measured), stale(0.0, 0.0)], now, DT);
        }
        let collapsed = alloc.limits().charge;
        assert!(collapsed < 300.0, "collapsed to {collapsed}");

        // The battery now accepts what it is asked for. The estimate is held
        // for AUTHORITY_HOLD_MS, then relaxes at AUTHORITY_RELAX_W_PER_S.
        stub.charge_cap = 1_000.0;
        let mut commanded = collapsed;
        for _ in 0..6_000 {
            now += TICK_MS;
            let measured = stub.step(-commanded, DT);
            alloc.observe(&[fresh(-commanded, measured), stale(0.0, 0.0)], now, DT);
            // The command follows the estimate, as it does through the central
            // PID, whose authority is the learned limit.
            commanded = alloc.limits().charge;
        }
        let recovered = alloc.limits().charge;
        assert!(recovered > 500.0, "estimate should relax upwards, got {recovered}");
        assert!(recovered <= 1_000.0, "estimate must respect the ceiling");
    }

    /// A device that ignores commands below its start power cannot answer the
    /// command a collapsed estimate permits, and growth needs an answer: the
    /// estimate is stranded at the margin floor and the device is asked for a
    /// command too small to stir it, for as long as the process runs.
    #[test]
    fn a_silent_plant_is_offered_a_command_it_can_act_on() {
        let mut cfg = plant();
        cfg.policy_mut("solis").max_charge = 0.0;
        cfg.policy_mut("solax").max_charge = 1_000.0;
        let mut alloc = Allocator::new(cfg);
        let mut now = 0u64;

        // 1. Drive it into the state the reserve was found in: asked for 1 kW,
        //    delivering nothing, so the estimate collapses to the margin floor.
        let mut out = alloc.idle_allocation();
        for _ in 0..10_000 {
            now += TICK_MS;
            alloc.observe(&[fresh(0.0, 0.0), fresh(-1_000.0, 0.0)], now, DT);
            out = alloc.split_charge(DT);
        }
        let collapsed = out.by_id("solax").unwrap().charge_limit;
        assert!(collapsed < 300.0, "estimate should have collapsed, got {collapsed}");

        // 2. The device is healthy again, but it will not act on a command
        //    below its 600 W start power.
        let mut commanded = out.target("solax");
        let mut ever = 0.0f64;
        for _ in 0..30_000 {
            now += TICK_MS;
            let delivered = if commanded.abs() < 600.0 { 0.0 } else { commanded };
            alloc.observe(&[fresh(0.0, 0.0), fresh(commanded, delivered)], now, DT);
            let out = alloc.split_charge(DT);
            commanded = out.target("solax");
            ever = ever.max(delivered.abs());
        }

        assert!(
            ever >= 600.0,
            "the plant must eventually be offered a command it can act on, best was {ever} W"
        );
        assert!(
            commanded.abs() > 300.0,
            "and the estimate must hold the plant's real authority, ended at {commanded} W"
        );
    }

    #[test]
    fn authority_ignores_stale_measurements() {
        let mut alloc = Allocator::new(plant());
        let mut now = 0;
        for _ in 0..2_000 {
            now += TICK_MS;
            // Present but not fresh: no learning either way.
            alloc.observe(&[stale(-3_600.0, 0.0), stale(0.0, 0.0)], now, DT);
        }
        // Neither inverter is reporting, so nothing may be asked of either.
        assert_eq!(alloc.limits().charge, 0.0);
    }

    #[test]
    fn targets_are_slew_limited() {
        let mut alloc = Allocator::new(plant());
        mark_available(&mut alloc);
        // A 4 kW step commanded at a 1 ms tick may only move 4 W.
        let out = alloc.split(4_000.0, 0.001);
        assert!((out.target("solis") - 4.0).abs() < 1e-9);

        // ... and the reserve, which dislikes sudden changes, moves slower.
        alloc.engaged = true;
        let out = alloc.split(4_000.0, 0.001);
        assert!((out.target("solax") - 1.2).abs() < 1e-9);
    }

    #[test]
    fn unmet_demand_is_reported() {
        let mut cfg = plant();
        cfg.policy_mut("solis").max_discharge = 2_000.0;
        cfg.policy_mut("solax").max_discharge = 500.0;
        let mut alloc = Allocator::new(cfg);
        alloc.engaged = true;
        mark_available(&mut alloc);

        let out = settle(&mut alloc, 3_000.0, 1_000);
        assert_eq!(out.target("solis"), 2_000.0);
        assert_eq!(out.target("solax"), 500.0);
        assert!((out.unmet - 500.0).abs() < 1e-9);
    }

    // --- Generality: a third inverter is just another policy -----------------

    /// Three inverters, two of them reserves. Nothing about the allocation
    /// names an inverter, so the same rules extend: the second and third are
    /// water-filled in order in discharge, and in charge.
    fn three_inverter_plant() -> AllocatorConfig {
        let mut cfg = plant();
        cfg.inverters.push(InverterPolicy {
            max_discharge: 800.0,
            max_charge: 600.0,
            slew_w_per_s: 1_200.0,
            charge_power: 600.0,
            min_soc: Some(20.0),
            max_soc: Some(90.0),
            absorb_surplus: true,
            ..InverterPolicy::new("solax2", "Solax 2")
        });
        cfg
    }

    #[test]
    fn a_third_inverter_is_filled_by_priority_in_discharge() {
        let mut cfg = three_inverter_plant();
        cfg.policy_mut("solis").max_discharge = 1_000.0;
        cfg.policy_mut("solax").max_discharge = 500.0;
        let mut alloc = Allocator::new(cfg);
        alloc.engaged = true;
        mark_available(&mut alloc);

        // 1.8 kW of demand: the primary takes 1 kW, then the reserves in order.
        let out = settle(&mut alloc, 1_800.0, 2_000);
        assert_eq!(out.target("solis"), 1_000.0);
        assert_eq!(out.target("solax"), 500.0);
        assert_eq!(out.target("solax2"), 300.0);
        assert_eq!(out.targets().len(), 3, "every policy gets a share");
        // The reserve group's combined share is reported as one figure.
        assert_eq!(out.reserve_share, 800.0);
        assert_eq!(alloc.limits().discharge, 1_000.0 + 500.0 + 800.0);
    }

    #[test]
    fn a_third_inverter_absorbs_surplus_after_the_others_fill() {
        let mut cfg = three_inverter_plant();
        cfg.policy_mut("solis").max_charge = 400.0;
        cfg.policy_mut("solax").max_charge = 500.0;
        let mut alloc = Allocator::new(cfg);
        let mut now = 0;

        // Both reserves are well inside their ceilings and the primary is full.
        alloc.observe(
            &[
                fresh(0.0, 0.0),
                fresh(0.0, 0.0).with_soc(40.0),
                fresh(0.0, 0.0).with_soc(60.0),
            ],
            now,
            DT,
        );
        // Collapse the primary's acceptance to 0 so the whole surplus spills.
        for _ in 0..2_000 {
            now += TICK_MS;
            alloc.observe(
                &[
                    fresh(-400.0, 0.0),
                    fresh(0.0, 0.0).with_soc(40.0),
                    fresh(0.0, 0.0).with_soc(60.0),
                ],
                now,
                DT,
            );
        }
        let out = settle(&mut alloc, -1_400.0, 500);
        // The full bank is still asked for the ~150 W margin the authority
        // estimate leaves it, but nothing beyond that.
        assert!(
            out.target("solis") > -300.0,
            "the full bank must not be asked for real power, got {}",
            out.target("solis")
        );
        assert!(
            (out.target("solax") + 500.0).abs() < 50.0,
            "second inverter should be filled first, got {}",
            out.target("solax")
        );
        assert!(
            (out.target("solax2") + 600.0).abs() < 250.0,
            "third inverter takes what is left, got {}",
            out.target("solax2")
        );
    }

    /// With one inverter the reserve logic must simply never fire: the plant
    /// still regulates on the primary alone.
    #[test]
    fn a_single_inverter_plant_still_allocates() {
        let mut cfg = plant();
        cfg.inverters.truncate(1);
        let mut alloc = Allocator::new(cfg);
        mark_available(&mut alloc);

        alloc.update_reserve(5_000.0, 3_600.0, 10_000);
        assert!(!alloc.engaged());
        let out = settle(&mut alloc, 1_200.0, 1_000);
        assert_eq!(out.target("solis"), 1_200.0);
        assert_eq!(out.inverters.len(), 1);
        assert!(out.inverters[0].primary);
        assert_eq!(out.state, ReserveState::PrimaryOnly);
        assert_eq!(out.reserve_share, 0.0);
    }
}
