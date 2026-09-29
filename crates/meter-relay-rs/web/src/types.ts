/**
 * Snake-case code for the reserve state, as serialised by the relay. The
 * spellings are stable (they are InfluxDB tags); "solis_only" now means "the
 * primary alone", which is the same thing on a two-inverter plant.
 */
export type ReserveStateCode =
  | "solis_only"
  | "waking"
  | "reserve"
  | "soc_floor"
  | "charging";

export interface PidMetrics {
  mean_absolute_error: number;
  root_mean_square_error: number;
  peak_error: number;
  in_band_percent: number;
  oscillation_count: number;
  actuator_energy_kwh: number;
  output_roughness: number;
  current_error: number;
  slow_error: number;
}

export interface PidSnapshot {
  set_point: number;
  error: number;
  output: number;
  integral: number;
  kp: number;
  ki: number;
  kd: number;
  /** Live authority limits (W) — for the central loop these are learned. */
  min_output: number;
  max_output: number;
  /** Error band inside which the loop deliberately does nothing (W). */
  deadband: number;
  saturated: boolean;
  metrics: PidMetrics;
}

/**
 * One inverter. Readings are nullable because the plant is general: a
 * make/model publishes the registers it actually has, and `null` means "this
 * device does not report that" rather than a misleading zero.
 */
export interface InverterTelemetry {
  /** Stable key, matching the policy id ("solis"). */
  id: string;
  name: string;
  /** True for priority 0, the always-on-line actuator. */
  primary: boolean;
  present: boolean;
  /** True when this inverter's registers have stopped refreshing. */
  stale: boolean;
  battery_power: number;
  solar_power: number | null;
  battery_voltage: number | null;
  solar_voltage: number | null;
  ac_voltage: number | null;
  load_power: number | null;
  percentage: number | null;
  status: string | null;
  target: number;
  last_nudge: number;
  /** Power this inverter has been observed to deliver / accept (W). */
  discharge_limit: number;
  charge_limit: number;
  /** True while this inverter is being asked to absorb surplus (charge). */
  absorbing: boolean;
  /** Mean interval between this inverter's meter requests (ms). */
  request_interval_ms: number;
  pid: PidSnapshot;
}

export interface CentralTelemetry {
  grid_power: number;
  grid_voltage: number;
  meter_target: number;
  pid: PidSnapshot;
}

export interface ReserveTelemetry {
  engaged: boolean;
  state: ReserveStateCode;
  /** Demand the reserve is covering right now (W, discharge). */
  share: number;
  /** Surplus the reserve is absorbing right now (W, charge). */
  absorbed: number;
  /** Demand the engaged set could not cover (W). */
  unmet: number;
  soc: number;
  total_discharge_limit: number;
  total_charge_limit: number;
}

export interface StatusSnapshot {
  ts: number;
  central: CentralTelemetry;
  /** One entry per inverter, in the plant's priority order. */
  inverters: InverterTelemetry[];
  reserve: ReserveTelemetry;
  lab_solar_power: number;
  use_octopus_go: boolean;
  charging: boolean;
}

/* ------------------------------------------------------------------ */
/* Connections / diagnostics                                           */
/*                                                                     */
/* Everything below is served by GET /api/connections. The relay may   */
/* add fields to that payload; nothing here depends on anything that   */
/* is not documented, and every timestamp is milliseconds since the    */
/* Unix epoch. `null` or an absent key means "never".                  */
/* ------------------------------------------------------------------ */

/** What part of the relay a connection plays. */
export type ConnectionRole =
  | "grid_meter"
  | "stats_bus"
  | "meter_emulator"
  | "unknown";

/** Transport under the connection. */
export type ConnectionKind = "tcp" | "serial";

/** Lifecycle state as reported by the relay; `null`/absent becomes "unknown". */
export type ConnectionState =
  | "online"
  | "connecting"
  | "listening"
  | "down"
  | "unidentified"
  | "unknown";

/**
 * How the relay decided which endpoint is which. Present once discovery has
 * run; `mismatch` is the interesting one — it means auto-detection kept a
 * different identity than the one the configuration expected, typically
 * because the configured port had gone stale.
 */
export interface ConnectionIdentification {
  /** e.g. "listen_fingerprint", "probe", "configured". */
  method: string;
  /** 0..1. */
  confidence: number;
  /** Human-readable justification, e.g. "100% match the solis fingerprint". */
  evidence: string;
  mismatch: boolean;
}

/** One connection-level error, newest first in `recent_errors`. */
export interface RecentError {
  /** Milliseconds since the Unix epoch. */
  at: number;
  /** e.g. "timeout", "crc", "exception", "io". */
  kind: string;
  detail: string;
}

/**
 * One serial/Modbus connection. Counters are cumulative for the life of the
 * process; `error_rate` is per the `window_secs` window.
 *
 * `requests_in`/`responses_out` are the meter-emulator direction (inverters
 * poll us); `polls_out`/`responses_in` are the master direction (we poll the
 * grid meter and the stats bus). The unused pair reads zero.
 */
export interface ConnectionReport {
  id: string;
  role: ConnectionRole;
  label: string;
  /** e.g. "tcp://192.168.49.30:2002" or "serial:/dev/serial/by-id/...". */
  endpoint: string;
  kind: ConnectionKind;
  state: ConnectionState;
  healthy: boolean;
  /** What discovery found at the other end, if anything. */
  identity: string | null;
  /** What the configuration says should be there. */
  expected_identity: string | null;
  identification: ConnectionIdentification;
  /** Epoch ms this connection last came up; `null` if it never has. */
  connected_since: number | null;
  last_rx: number | null;
  last_tx: number | null;
  rx_bytes: number;
  tx_bytes: number;
  rx_frames: number;
  tx_frames: number;
  requests_in: number;
  responses_out: number;
  polls_out: number;
  responses_in: number;
  timeouts: number;
  crc_errors: number;
  exceptions: number;
  io_errors: number;
  reconnects: number;
  /** Fraction, 0..1, over the last `window_secs`. */
  error_rate: number;
  window_secs: number;
  recent_errors: RecentError[];
}

/** The startup discovery pass, summarised. `null` if it has not completed. */
export interface DiscoveryReport {
  /** e.g. "auto". */
  mode: string;
  /** Epoch ms the pass started. */
  ran_at: number;
  duration_ms: number;
  listen_ms: number;
  /** Endpoints considered / matched to a known device / left unknown. */
  candidates: number;
  assigned: number;
  unidentified: number;
  /** The human-readable decision log, one line per step. */
  log: string[];
}

export interface ConnectionsResponse {
  /** Epoch ms this payload was produced. */
  ts: number;
  discovery: DiscoveryReport | null;
  connections: ConnectionReport[];
}

/** A field the relay might serialise with a different case than we expect. */
export type WireValue = string | null | undefined;

/** Runtime helpers for the frozen /api/connections shape. */

export function asFiniteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

export function parseConnectionState(value: WireValue): ConnectionState {
  switch ((value ?? "").toLowerCase()) {
    case "online":
      return "online";
    case "connecting":
      return "connecting";
    case "listening":
      return "listening";
    case "down":
      return "down";
    case "unidentified":
      return "unidentified";
    default:
      return "unknown";
  }
}

export function parseConnectionKind(value: WireValue): ConnectionKind {
  return (value ?? "").toLowerCase() === "tcp" ? "tcp" : "serial";
}

export function parseConnectionRole(value: WireValue): ConnectionRole {
  switch ((value ?? "").toLowerCase()) {
    case "grid_meter":
    case "stats_bus":
    case "meter_emulator":
      return (value ?? "").toLowerCase() as ConnectionRole;
    default:
      return "unknown";
  }
}

export function parseStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((entry): entry is string => typeof entry === "string");
}
