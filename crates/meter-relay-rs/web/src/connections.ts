/**
 * Polling and defensive parsing for GET /api/connections.
 *
 * The relay owns that payload and may add fields to it; this module only ever
 * reads what the frozen shape promises, and it never throws on a malformed
 * entry — a connection with unusable fields renders as a placeholder rather
 * than taking the whole page down. A failed *fetch*, by contrast, is a real
 * error and is surfaced as such.
 */
import type {
  ConnectionIdentification,
  ConnectionRole,
  ConnectionState,
  RecentError,
} from "./types";
import {
  asFiniteNumber,
  parseConnectionKind,
  parseConnectionRole,
  parseConnectionState,
  parseStringArray,
} from "./types";

/** How often the diagnostics page asks for the connection list. */
export const POLL_MS = 1000;

/**
 * A fetch older than this is treated as stale rather than current. 1000 ms
 * polling plus a little slack: past it, the feed — not the relay — has a
 * problem, and saying so beats reprinting the last payload as if it were live.
 */
export const STALE_MS = 2500;

export interface NormalizedConnection {
  id: string;
  role: ConnectionRole;
  label: string;
  endpoint: string;
  kind: "tcp" | "serial";
  state: ConnectionState;
  /** The state string exactly as the relay sent it. */
  stateLabel: string;
  healthy: boolean;
  identity: string | null;
  expectedIdentity: string | null;
  identification: ConnectionIdentification;
  connectedSince: number | null;
  lastRx: number | null;
  lastTx: number | null;
  rxBytes: number;
  txBytes: number;
  rxFrames: number;
  txFrames: number;
  requestsIn: number;
  responsesOut: number;
  pollsOut: number;
  responsesIn: number;
  timeouts: number;
  crcErrors: number;
  exceptions: number;
  ioErrors: number;
  reconnects: number;
  /** Fraction, 0..1. */
  errorRate: number;
  windowSecs: number;
  recentErrors: RecentError[];
}

export interface NormalizedDiscovery {
  mode: string;
  ranAt: number | null;
  durationMs: number | null;
  listenMs: number | null;
  candidates: number | null;
  assigned: number | null;
  unidentified: number | null;
  log: string[];
}

export interface NormalizedConnections {
  /** Epoch ms this payload was produced, if the relay said. */
  ts: number | null;
  discovery: NormalizedDiscovery | null;
  connections: NormalizedConnection[];
}

function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
}

function asString(value: unknown): string | null {
  return typeof value === "string" && value !== "" ? value : null;
}

function asStringOr(value: unknown, fallback: string): string {
  return asString(value) ?? fallback;
}

function asCount(value: unknown): number {
  return asFiniteNumber(value) ?? 0;
}

function normalizeError(value: unknown): RecentError | null {
  const entry = asRecord(value);
  const at = asFiniteNumber(entry.at);
  if (at === null) {
    return null;
  }
  return {
    at,
    kind: asStringOr(entry.kind, "error"),
    detail: asStringOr(entry.detail, ""),
  };
}

function normalizeIdentification(value: unknown): ConnectionIdentification {
  const entry = asRecord(value);
  return {
    method: asStringOr(entry.method, "unknown"),
    confidence: asFiniteNumber(entry.confidence) ?? 0,
    evidence: asStringOr(entry.evidence, "no evidence recorded"),
    mismatch: entry.mismatch === true,
  };
}

function normalizeConnection(value: unknown, index: number): NormalizedConnection {
  const entry = asRecord(value);
  const stateRaw = asString(entry.state);
  return {
    id: asStringOr(entry.id, `connection-${index + 1}`),
    role: parseConnectionRole(asString(entry.role)),
    label: asStringOr(entry.label, asString(entry.id) ?? `Connection ${index + 1}`),
    endpoint: asStringOr(entry.endpoint, "no endpoint reported"),
    kind: parseConnectionKind(asString(entry.kind)),
    state: parseConnectionState(stateRaw),
    stateLabel: stateRaw ?? "unknown",
    healthy: entry.healthy === true,
    identity: asString(entry.identity),
    expectedIdentity: asString(entry.expected_identity),
    identification: normalizeIdentification(entry.identification),
    connectedSince: asFiniteNumber(entry.connected_since),
    lastRx: asFiniteNumber(entry.last_rx),
    lastTx: asFiniteNumber(entry.last_tx),
    rxBytes: asCount(entry.rx_bytes),
    txBytes: asCount(entry.tx_bytes),
    rxFrames: asCount(entry.rx_frames),
    txFrames: asCount(entry.tx_frames),
    requestsIn: asCount(entry.requests_in),
    responsesOut: asCount(entry.responses_out),
    pollsOut: asCount(entry.polls_out),
    responsesIn: asCount(entry.responses_in),
    timeouts: asCount(entry.timeouts),
    crcErrors: asCount(entry.crc_errors),
    exceptions: asCount(entry.exceptions),
    ioErrors: asCount(entry.io_errors),
    reconnects: asCount(entry.reconnects),
    errorRate: asFiniteNumber(entry.error_rate) ?? 0,
    windowSecs: asFiniteNumber(entry.window_secs) ?? 0,
    recentErrors: (Array.isArray(entry.recent_errors) ? entry.recent_errors : [])
      .map(normalizeError)
      .filter((error): error is RecentError => error !== null),
  };
}

function normalizeDiscovery(value: unknown): NormalizedDiscovery | null {
  if (typeof value !== "object" || value === null) {
    return null;
  }
  const entry = asRecord(value);
  return {
    mode: asStringOr(entry.mode, "unknown"),
    ranAt: asFiniteNumber(entry.ran_at),
    durationMs: asFiniteNumber(entry.duration_ms),
    listenMs: asFiniteNumber(entry.listen_ms),
    candidates: asFiniteNumber(entry.candidates),
    assigned: asFiniteNumber(entry.assigned),
    unidentified: asFiniteNumber(entry.unidentified),
    log: parseStringArray(entry.log),
  };
}

/** Turns an unknown JSON body into something the page can render safely. */
export function normalizeConnections(payload: unknown): NormalizedConnections {
  const body = asRecord(payload);
  const connections = Array.isArray(body.connections) ? body.connections : [];
  return {
    ts: asFiniteNumber(body.ts),
    discovery: normalizeDiscovery(body.discovery),
    connections: connections.map(normalizeConnection),
  };
}

/** `fetch` plus parse, typed. Only network/HTTP failures reject. */
export async function fetchConnections(
  signal: AbortSignal,
): Promise<{ fetchedAt: number; data: NormalizedConnections }> {
  const response = await fetch("/api/connections", { signal, cache: "no-store" });
  if (!response.ok) {
    throw new Error(`/api/connections responded ${response.status}`);
  }
  return { fetchedAt: Date.now(), data: normalizeConnections(await response.json()) };
}

/* ------------------------------------------------------------------ */
/* Formatting                                                          */
/* ------------------------------------------------------------------ */

/** "0.4 s ago", "3 m ago", "2 h ago", "never". */
export function formatAge(
  at: number | null,
  now: number,
  options: { never?: string } = {},
): string {
  if (at === null) {
    return options.never ?? "never";
  }
  const seconds = Math.max(0, (now - at) / 1000);
  if (seconds < 1) {
    return `${seconds.toFixed(1)} s ago`;
  }
  if (seconds < 90) {
    return `${Math.round(seconds)} s ago`;
  }
  if (seconds < 5400) {
    return `${Math.round(seconds / 60)} m ago`;
  }
  if (seconds < 172800) {
    return `${Math.round(seconds / 3600)} h ago`;
  }
  return `${Math.round(seconds / 86400)} d ago`;
}

/** An elapsed span as "4 m 12 s" / "3 h 07 m" / "2 d 04 h". */
export function formatDuration(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 60) {
    return `${seconds} s`;
  }
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) {
    return `${minutes} m ${String(seconds % 60).padStart(2, "0")} s`;
  }
  const hours = Math.floor(minutes / 60);
  if (hours < 48) {
    return `${hours} h ${String(minutes % 60).padStart(2, "0")} m`;
  }
  return `${Math.floor(hours / 24)} d ${String(hours % 24).padStart(2, "0")} h`;
}

/** A short absolute wall-clock time for the same day, e.g. "14:31:07". */
export function formatClock(at: number | null): string {
  if (at === null) {
    return "never";
  }
  return new Date(at).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

/** A full absolute date-time for a fixed point in the past. */
export function formatDateTime(at: number | null): string {
  if (at === null) {
    return "never";
  }
  return new Date(at).toLocaleString([], {
    year: "numeric",
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

/** A 0..1 fraction as a percentage, e.g. "0.7%". */
export function formatPercent(fraction: number, digits = 1): string {
  if (!Number.isFinite(fraction)) {
    return "—";
  }
  return `${(fraction * 100).toFixed(digits)}%`;
}

/** Thousands separators for the cumulative byte counters. */
export function formatCount(value: number): string {
  return Number.isFinite(value) ? value.toLocaleString("en-GB") : "—";
}
