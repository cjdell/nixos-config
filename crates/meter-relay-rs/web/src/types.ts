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
