import { createSignal, For, onCleanup, onMount, Show } from "solid-js";
import PowerChart from "./Chart";
import Tip from "./Tip";
import type {
  InverterTelemetry,
  PidSnapshot,
  ReserveStateCode,
  ReserveTelemetry,
  StatusSnapshot,
} from "./types";

const MAX_HISTORY = 300;

function fmt(value: number, digits = 0): string {
  if (!Number.isFinite(value)) {
    return "—";
  }
  return value.toFixed(digits);
}

/** Formats a reading this device may not report at all. */
function fmtOpt(value: number | null, digits = 0): string {
  if (value === null || !Number.isFinite(value)) {
    return "—";
  }
  return value.toFixed(digits);
}

function Stat(props: { label: string; value: string; unit?: string; tip?: string }) {
  return (
    <div class="stat">
      <div class="stat-label">
        {props.label}
        <Show when={props.tip}>
          <Tip text={props.tip!} />
        </Show>
      </div>
      <div class="stat-value">
        {props.value}
        <Show when={props.unit}>
          <span class="stat-unit"> {props.unit}</span>
        </Show>
      </div>
    </div>
  );
}

function Metric(props: { label: string; value: string; tip?: string }) {
  return (
    <div class="metric">
      <span class="metric-label">
        {props.label}
        <Show when={props.tip}>
          <Tip text={props.tip!} />
        </Show>
      </span>
      <span class="metric-value">{props.value}</span>
    </div>
  );
}

const RESERVE_LABEL: Record<ReserveStateCode, string> = {
  solis_only: "standing by",
  waking: "needs help",
  reserve: "engaged",
  soc_floor: "at SOC floor",
  charging: "charging",
};

const RESERVE_DETAIL: Record<ReserveStateCode, string> = {
  solis_only:
    "The primary inverter is covering the whole demand. The reserve is not asked for anything, which is the point: the small battery is no longer cycled for load the main bank can carry.",
  waking:
    "The demand has been beyond the primary's authority for the wake delay. The reserve is about to take the remainder.",
  reserve:
    "The primary is at the limit it has been observed to deliver, so the reserve is covering the rest of the demand.",
  soc_floor:
    "Every reserve inverter is at or below its state-of-charge floor (MR_<ID>_MIN_SOC) or has stopped reporting, so none of them is discharged. They are refilled in the Octopus Go window.",
  charging:
    "Octopus Go window: every bank is charged from cheap grid energy, capped by the authority each has been observed to accept.",
};

function PidPanel(props: {
  title: string;
  subtitle?: string;
  pid: PidSnapshot;
  isCentral?: boolean;
}) {
  const metrics = () => props.pid.metrics;

  const integralTip = () =>
    props.pid.ki === 0
      ? "Unused here: this PID is P-only (Ki = 0), so it holds no integral state at all."
      : `∫error·dt in W·s. It trims out persistent bias; its share of the output right now is Ki × I = ${fmt(
          props.pid.ki * props.pid.integral,
        )} W. It freezes while the output is at its limit, and its term may use at most the whole live authority.`;

  const authorityTip = () =>
    props.isCentral
      ? `The authority the central loop has right now (W). It is not a fixed clamp: the relay learns what each inverter actually delivers or accepts, and counts a reserve inverter's share only where that inverter is genuinely usable. Deadband ±${fmt(
          props.pid.deadband,
        )} W.`
      : `Output clamp on the nudge written into this inverter's view of the meter; the integral may use at most the whole range. Deadband ±${fmt(
          props.pid.deadband,
        )} W.`;

  return (
    <div class="panel">
      <div class="panel-head">
        <h2>{props.title}</h2>
        <span class="panel-head-right">
          <Show when={props.pid.saturated}>
            <span class="limit-badge">at limit</span>
          </Show>
          <Show when={props.subtitle}>
            <span class="panel-sub">{props.subtitle}</span>
          </Show>
        </span>
      </div>

      <div class="stat-grid">
        <Stat
          label={props.isCentral ? "Target" : "Assigned"}
          value={fmt(props.pid.set_point)}
          unit="W"
          tip={
            props.isCentral
              ? "The grid power the relay is aiming for (MR_METER_TARGET_POWER), in the meter's own sign convention: positive means import, so the 50 W default holds a small export."
              : "Power the allocator assigned to this inverter: the inverters are filled in priority order, each up to its learned authority."
          }
        />
        <Stat
          label="Error"
          value={fmt(props.pid.error)}
          unit="W"
          tip={
            props.isCentral
              ? "Target minus grid power, with sign. Positive while importing more than the target; the loop ignores the part inside the deadband."
              : "Assigned power minus this inverter's measured battery power."
          }
        />
        <Stat
          label={props.isCentral ? "Demand" : "Nudge"}
          value={fmt(props.pid.output)}
          unit="W"
          tip={
            props.isCentral
              ? "Total inverter power the relay is requesting, filled in priority order as far as the learned acceptance allows."
              : "The value written into the fake grid meter the inverter reads; the inverter balances its own output against it."
          }
        />
        <Stat label="Integral" value={fmt(props.pid.integral, 2)} unit="W·s" tip={integralTip()} />
      </div>

      <div class="metrics">
        <Metric
          label="Avg error"
          value={fmt(metrics().mean_absolute_error, 1)}
          tip="Mean absolute grid error over the current window (W), reset hourly."
        />
        <Metric
          label="RMS error"
          value={fmt(metrics().root_mean_square_error, 1)}
          tip="Root-mean-square error over the current window (W)."
        />
        <Metric
          label="Peak error"
          value={fmt(metrics().peak_error, 1)}
          tip="Largest absolute error seen in the window (W). This replaced an 'overshoot' figure that divided the largest export excursion by a 50 W setpoint and never decayed."
        />
        <Metric
          label="In band"
          value={`${fmt(metrics().in_band_percent, 0)}%`}
          tip="Share of samples within ±25 W of the target. A better summary of regulation quality than a peak that never decays."
        />
        <Metric
          label="Oscillations"
          value={String(metrics().oscillation_count)}
          tip="Target crossings outside the ±25 W band that stayed on the new side for at least 2 s, over the current window — meter noise no longer counts."
        />
        <Metric
          label="Slow error"
          value={fmt(metrics().slow_error, 1)}
          tip="10 s mean of the error (W) — the bias the integral is still trimming."
        />
        <Metric
          label="Roughness"
          value={fmt(metrics().output_roughness, 2)}
          tip="RMS change of the output between ticks (W). 41% of the old output variance was derivative noise on the meter's 80 ms refresh; with derivative-on-measurement off by default this is now the vendor loop's own noise."
        />
        <Metric
          label="Actuator energy"
          value={fmt(metrics().actuator_energy_kwh, 2)}
          tip="∫|output|dt over the window (kWh): the work actually commanded. The old 'total control effort' was a bare sum over 100 Hz samples, so it grew without bound."
        />
      </div>

      <div class="gains">
        Kp {props.pid.kp} · Ki {props.pid.ki} · Kd {props.pid.kd} · authority ±
        {fmt(props.pid.max_output)} W
        <Tip text={authorityTip()} />
      </div>
    </div>
  );
}

/// Power below which an inverter is neither meaningfully charging nor
/// discharging. One constant for every inverter, because the relay normalises
/// them all to the same convention.
const IDLE_BAND_W = 50;

function InverterPanel(props: { inv: InverterTelemetry }) {
  // Direction is always read from the *measurement*, never from the request.
  // The relay's sign convention is positive = discharging for every inverter
  // (the Solis driver normalises its own status/power pair, the Solax register
  // is already signed that way), so a positive reading is discharging whatever
  // the allocator happened to ask for. Labelling the request instead is how
  // this panel used to show "+153 W absorbing", which is nonsense.
  const flow = () => {
    const p = props.inv.battery_power;
    if (p > IDLE_BAND_W) {
      return "discharging";
    }
    if (p < -IDLE_BAND_W) {
      return "charging";
    }
    return "idle";
  };

  // The request, kept visibly separate from the reading. A full bank asked to
  // absorb simply does not follow, and that gap is the useful thing to show.
  const askedToAbsorb = () => props.inv.target < -IDLE_BAND_W;
  const refusing = () => askedToAbsorb() && props.inv.battery_power > -IDLE_BAND_W;

  return (
    <div class="panel">
      <div class="panel-head">
        <h2>{props.inv.name}</h2>
        <span class="panel-head-right">
          <span class="panel-sub">{props.inv.primary ? "primary" : "reserve"}</span>
          <span class={`badge ${props.inv.present ? (props.inv.stale ? "off" : "ok") : "off"}`}>
            {props.inv.present ? (props.inv.stale ? "stale" : "online") : "no data"}
          </span>
        </span>
      </div>

      <div class="battery-line">
        <span class="battery-power">{fmt(props.inv.battery_power)}</span>
        <span class="battery-unit">W</span>
        <span class={`battery-state ${flow()}`}>{flow()}</span>
        <span class="battery-target">
          assigned {fmt(props.inv.target)} W
          <Tip
            down
            text="Power the allocator has assigned to this inverter, slew-limited towards the target rather than stepped. In priority order, each inverter takes what the ones before it could not. Negative = asked to charge, positive = asked to discharge."
          />
        </span>
      </div>

      <Show when={refusing()}>
        <div class="battery-note">
          assigned {fmt(-props.inv.target)} W of absorption it is not taking — a
          full bank tapers to nothing and the surplus moves down the list.
          <Tip
            down
            text="The measured battery power and the assignment disagree. This is normal at high state of charge: the pack's acceptance collapses and the allocator's learned charge authority follows it down, so the remaining surplus is offered to the next inverter in the priority list."
          />
        </div>
      </Show>

      <div class="stat-grid">
        <Stat
          label="Meter override"
          value={fmt(props.inv.last_nudge)}
          unit="W"
          tip="Last nudge sent: the grid power this inverter was told to balance against (its view of the meter is rewritten by the relay)."
        />
        <Stat
          label="Discharge authority"
          value={fmt(props.inv.discharge_limit)}
          unit="W"
          tip="What this inverter has been observed to deliver when asked. It starts at the configured rating and is revised down when the battery cannot follow, then relaxes back up."
        />
        <Stat
          label="Charge authority"
          value={fmt(props.inv.charge_limit)}
          unit="W"
          tip="What this inverter has been observed to accept when charging. At high state of charge this collapses — and the surplus then spills down the priority list to the next inverter."
        />
        <Stat
          label="Meter requests"
          value={fmt(props.inv.request_interval_ms)}
          unit="ms"
          tip="Mean interval between this inverter's Modbus meter requests — how often a new command can reach it."
        />
        <Show when={props.inv.solar_power !== null}>
          <Stat
            label="Solar"
            value={fmtOpt(props.inv.solar_power)}
            unit="W"
            tip="PV array power at the inverter."
          />
        </Show>
        <Show when={props.inv.battery_voltage !== null}>
          <Stat
            label="Battery V"
            value={fmtOpt(props.inv.battery_voltage, 1)}
            unit="V"
            tip="Battery pack voltage."
          />
        </Show>
        <Show when={props.inv.ac_voltage !== null}>
          <Stat
            label="AC V"
            value={fmtOpt(props.inv.ac_voltage, 1)}
            unit="V"
            tip="AC phase voltage at the inverter output."
          />
        </Show>
        <Show when={props.inv.load_power !== null}>
          <Stat
            label="Load"
            value={fmtOpt(props.inv.load_power)}
            unit="W"
            tip="AC power the inverter is delivering to the house."
          />
        </Show>
        <Show when={props.inv.percentage !== null}>
          <Stat
            label="SOC"
            value={fmtOpt(props.inv.percentage)}
            unit="%"
            tip="Battery state of charge. Below MR_<ID>_MIN_SOC this inverter is not discharged; it is refilled in the Go window or from surplus."
          />
        </Show>
        <Show when={props.inv.status !== null}>
          <Stat
            label="Status"
            value={props.inv.status || "—"}
            tip="Inverter status string from its registers."
          />
        </Show>
      </div>
    </div>
  );
}

function ReservePanel(props: { reserve: ReserveTelemetry; inverters: InverterTelemetry[] }) {
  const primary = () => props.inverters[0];
  const reserves = () => props.inverters.filter((inv) => !inv.primary);

  // What the reserve is *doing*, summed from the measurements rather than from
  // what it was asked for — the two disagree exactly when a bank refuses, and a
  // "what is happening now" panel must report the former. Each inverter's own
  // panel carries its assignment.
  const measuredShare = () =>
    reserves().reduce((total, inv) => total + Math.max(0, inv.battery_power), 0);
  const measuredAbsorbed = () =>
    reserves().reduce((total, inv) => total + Math.max(0, -inv.battery_power), 0);

  return (
    <div class="panel reserve-panel">
      <div class="panel-head">
        <h2>Reserve</h2>
        <span class="panel-head-right">
          <span class={`reserve-badge ${props.reserve.state}`}>
            {RESERVE_LABEL[props.reserve.state]}
          </span>
          <span class="panel-sub">
            <Tip down text={RESERVE_DETAIL[props.reserve.state]} />
          </span>
        </span>
      </div>

      <div class="stat-grid">
        <Stat
          label="Reserve output"
          value={fmt(measuredShare())}
          unit="W"
          tip="Power the reserve inverters are delivering right now, measured (positive = discharging). Zero whenever the primary alone can meet the demand."
        />
        <Stat
          label="Surplus absorbed"
          value={fmt(measuredAbsorbed())}
          unit="W"
          tip="PV surplus the reserve is absorbing right now, measured (negative battery power). This is what keeps the reserve charged for a load spike; a reserve at its ceiling drops to zero and the surplus exports."
        />
        <Stat
          label="Grid still short"
          value={fmt(props.reserve.unmet)}
          unit="W"
          tip="Demand the engaged inverters could not cover, so it came from the grid. Non-zero only when every inverter is at its limit."
        />
        <Stat
          label="Reserve SOC"
          value={fmt(props.reserve.soc)}
          unit="%"
          tip="State of charge of the first reserve inverter. Below MR_<ID>_MIN_SOC it is not discharged; it is refilled in the Go window."
        />
        <Stat
          label="Total authority"
          value={fmt(props.reserve.total_discharge_limit)}
          unit="W"
          tip="What the central loop is allowed to ask for right now: the primary's learned authority, plus each reserve's only while that reserve is genuinely usable."
        />
        <Stat
          label="Primary alone"
          value={fmt(primary()?.discharge_limit ?? 0)}
          unit="W"
          tip="The primary's learned discharge authority — the level the demand must exceed, sustained, before the reserve is woken."
        />
        <Stat
          label="Charge authority"
          value={fmt(props.reserve.total_charge_limit)}
          unit="W"
          tip="How much charging the loop may ask for: every inverter that absorbs surplus, up to the authority each has been observed to accept. Set MR_<ID>_ABSORB_SURPLUS=false to make an inverter discharge-only and take it out of this figure."
        />
      </div>
    </div>
  );
}

export default function App() {
  const [snapshot, setSnapshot] = createSignal<StatusSnapshot | null>(null);
  const [history, setHistory] = createSignal<StatusSnapshot[]>([]);
  const [connected, setConnected] = createSignal(false);
  const [lastUpdate, setLastUpdate] = createSignal(0);

  const push = (next: StatusSnapshot) => {
    setSnapshot(next);
    setLastUpdate(Date.now());
    setHistory((current) => {
      const combined = [...current, next];
      return combined.length > MAX_HISTORY ? combined.slice(combined.length - MAX_HISTORY) : combined;
    });
  };

  onMount(() => {
    void fetch("/api/history")
      .then((res) => (res.ok ? res.json() : []))
      .then((data: StatusSnapshot[]) => setHistory(data.slice(-MAX_HISTORY)))
      .catch(() => {});

    const events = new EventSource("/api/events");
    events.onopen = () => setConnected(true);
    events.onerror = () => setConnected(false);
    events.onmessage = (event) => {
      try {
        push(JSON.parse(event.data) as StatusSnapshot);
      } catch {
        // ignore malformed frames
      }
    };

    onCleanup(() => events.close());
  });

  const inverters = () => snapshot()?.inverters ?? [];

  const mode = () => {
    const current = snapshot();
    if (!current) {
      return "connecting";
    }
    if (current.charging) {
      return "Octopus Go · charging";
    }
    if (current.use_octopus_go) {
      return "Octopus Go · armed";
    }
    return "load balancing";
  };

  const modeTip = () => {
    const current = snapshot();
    if (!current) {
      return "Waiting for telemetry.";
    }
    if (current.charging) {
      return "Inverters are charging the batteries from the grid at their configured rates, capped by the authority each has been observed to accept; the PID is off.";
    }
    if (current.use_octopus_go) {
      return "Octopus Go is enabled in Home Assistant; the cheap charging window is not active right now.";
    }
    return "The central loop nudges every inverter to hold grid power at the target: the inverters are filled in priority order, and each takes the demand the ones before it could not — in both directions, so surplus the main bank cannot absorb charges the reserve instead of being exported.";
  };

  const gridTone = () => {
    const power = snapshot()?.central.grid_power ?? 0;
    return power > 0 ? "import" : "export";
  };

  return (
    <div class="app">
      <header>
        <div class="brand">
          <h1>Meter Relay</h1>
          <span class="tag">rust · solid</span>
        </div>
        <div class="status-row">
          <Show when={snapshot()}>
            {(current) => (
              <span class={`reserve-badge ${current().reserve.state}`}>
                reserve {RESERVE_LABEL[current().reserve.state]}
                <Tip down text={RESERVE_DETAIL[current().reserve.state]} />
              </span>
            )}
          </Show>
          <span class={`mode ${snapshot()?.charging ? "charging" : ""}`}>
            {mode()}
            <Tip down text={modeTip()} />
          </span>
          <span class={`conn ${connected() ? "ok" : "off"}`}>
            {connected() ? "live" : "disconnected"}
          </span>
        </div>
      </header>

      <Show when={snapshot()} fallback={<div class="loading">Waiting for telemetry…</div>}>
        {(current) => (
          <>
            <section class="kpis">
              <div class={`kpi ${gridTone()}`}>
                <div class="kpi-label">
                  Grid power
                  <Tip down text="Power at the grid meter. Positive = importing from the grid, negative = exporting. The relay drives the inverters to hold this at the target." />
                </div>
                <div class="kpi-value">{fmt(current().central.grid_power)} W</div>
                <div class="kpi-sub">
                  {current().central.grid_power > 0 ? "importing" : "exporting"} · target{" "}
                  {fmt(current().central.meter_target)} W
                </div>
              </div>
              <div class="kpi">
                <div class="kpi-label">
                  Grid voltage
                  <Tip down text="RMS phase voltage at the meter." />
                </div>
                <div class="kpi-value">{fmt(current().central.grid_voltage, 1)} V</div>
                <div class="kpi-sub">at the meter</div>
              </div>
              <div class="kpi">
                <div class="kpi-label">
                  Lab solar
                  <Tip down text="Solar into the lab, read from the Tasmota plug (plug_01_energy_power)." />
                </div>
                <div class="kpi-value">{fmt(current().lab_solar_power)} W</div>
                <div class="kpi-sub">Tasmota plug 01</div>
              </div>
              <div class="kpi">
                <div class="kpi-label">Last update</div>
                <div class="kpi-value">
                  {lastUpdate() ? `${Math.max(0, Math.round((Date.now() - lastUpdate()) / 1000))} s` : "—"}
                </div>
                <div class="kpi-sub">ago</div>
              </div>
            </section>

            <section class="panels two">
              <ReservePanel reserve={current().reserve} inverters={inverters()} />
            </section>

            <section class="panel chart-panel">
              <div class="panel-head">
                <h2>Power history</h2>
                <span class="panel-sub">last {history().length} samples</span>
              </div>
              <PowerChart history={history()} />
            </section>

            <section class="panels">
              <PidPanel
                title="Central control loop"
                subtitle="keeps grid power at the target"
                pid={current().central.pid}
                isCentral
              />
              <For each={inverters()}>
                {(inv) => (
                  <PidPanel
                    title={`${inv.name} PID`}
                    subtitle={`drives ${inv.name} toward its assignment`}
                    pid={inv.pid}
                  />
                )}
              </For>
            </section>

            <section class="panels">
              <For each={inverters()}>{(inv) => <InverterPanel inv={inv} />}</For>
            </section>
          </>
        )}
      </Show>

      <footer>
        <span>meter-relay-rs</span>
        <a href="/stats">/stats</a>
        <a href="/api/status">/api/status</a>
      </footer>
    </div>
  );
}
