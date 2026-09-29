/**
 * The Diagnostics page: what the relay's serial/Modbus connections are doing.
 *
 * It polls GET /api/connections once a second. Two rules shape the rendering:
 *
 *   1. A connection's freshness is judged from *our* clock (when the fetch
 *      landed), not from anything the page would have to trust on the wire.
 *      If the feed stops answering, the last payload is marked unavailable
 *      rather than reprinted as if it were current.
 *   2. Ages tick locally between polls. The 1 s poll is the data refresh; the
 *      200 ms local tick is only so "0.4 s ago" does not sit frozen.
 */
import { createMemo, createSignal, For, onCleanup, onMount, Show } from "solid-js";
import Tip from "./Tip";
import type { ConnectionRole, ConnectionState } from "./types";
import {
  fetchConnections,
  formatAge,
  formatClock,
  formatCount,
  formatDateTime,
  formatDuration,
  formatPercent,
  POLL_MS,
  STALE_MS,
  type NormalizedConnection,
  type NormalizedConnections,
  type NormalizedDiscovery,
} from "./connections";

const ROLE_LABEL: Record<ConnectionRole, string> = {
  grid_meter: "grid meter",
  stats_bus: "stats bus",
  meter_emulator: "meter emulator",
  unknown: "unclassified",
};

const ROLE_TIP: Record<ConnectionRole, string> = {
  grid_meter:
    "The relay is the Modbus master here: it polls the actual grid meter over this link and reads the house's import/export. The directional counters are therefore outgoing polls and incoming responses.",
  stats_bus:
    "A secondary polled link, used for statistics rather than control. The relay is the master, so the directional counters are outgoing polls and incoming responses.",
  meter_emulator:
    "The relay pretends to *be* a meter on this link: the inverters poll it for a grid reading that the relay rewrites to steer them. The directional counters are therefore incoming requests and the outgoing responses we serve.",
  unknown:
    "The relay did not classify this connection's role, so the directional counters are labelled generically.",
};

/** What a role's two directional counters are, in the relay's own terms. */
function directions(role: ConnectionRole): {
  first: { label: string; tip: string };
  second: { label: string; tip: string };
} {
  if (role === "meter_emulator") {
    return {
      first: {
        label: "Requests in",
        tip: "Modbus requests received on this link — the inverters polling the emulated meter. The same number as rx_frames for this connection.",
      },
      second: {
        label: "Responses out",
        tip: "Modbus responses the relay served back on this link. The same number as tx_frames for this connection.",
      },
    };
  }
  return {
    first: {
      label: "Polls out",
      tip: "Modbus requests the relay sent down this link — it is the master here. The same number as tx_frames for this connection.",
    },
    second: {
      label: "Responses in",
      tip: "Modbus responses the far end returned on this link. The same number as rx_frames for this connection.",
    },
  };
}

function stateClass(state: ConnectionState, healthy: boolean): string {
  switch (state) {
    case "online":
    case "listening":
      return "ok";
    case "connecting":
    case "unidentified":
      return "warn";
    case "unknown":
      return healthy ? "ok" : "off";
    default:
      return "off";
  }
}

function describeState(connection: NormalizedConnection): string {
  switch (connection.state) {
    case "online":
      return "connected and exchanging frames";
    case "listening":
      return "listening for the far end to connect — normal for an emulated meter, which waits to be polled";
    case "connecting":
      return "opening the link right now";
    case "down":
      return connection.healthy
        ? "down, but the relay still counts it healthy — usually a reconnect under way"
        : "down — nothing exchanged recently; check the cable, adapter or far-end address";
    case "unidentified":
      return "up, but discovery could not work out what is at the other end — nothing is polled or served over it";
    default:
      return "a state this page does not recognise, so it is treated as unknown";
  }
}

function Stat(props: { label: string; value: string; unit?: string; sub?: string; tip?: string }) {
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
      <Show when={props.sub}>
        <div class="diag-stat-sub">{props.sub}</div>
      </Show>
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

/** Milliseconds as a bare number of seconds, for use with unit "s". */
function secs(value: number | null): string {
  if (value === null || !Number.isFinite(value)) {
    return "—";
  }
  return (value / 1000).toFixed(value < 10000 ? 1 : 0);
}

function fmtNum(value: number | null): string {
  return value === null || !Number.isFinite(value) ? "—" : String(value);
}

export function DiscoveryPanel(props: { discovery: NormalizedDiscovery; now: () => number }) {
  const ranAt = () => props.discovery.ranAt;
  return (
    <section class="panel">
      <div class="panel-head">
        <h2>
          Discovery
          <Tip
            down
            text="Runs once at startup. The relay opens every configured endpoint, listens for inverter meter polls and probes the bus, then matches what it hears against the known meter fingerprints to work out which endpoint is which device. That is how a stale configured port gets corrected instead of the relay polling the wrong thing forever."
          />
        </h2>
        <span class="panel-head-right">
          <span class="panel-sub">mode {props.discovery.mode}</span>
        </span>
      </div>

      <div class="stat-grid">
        <Stat
          label="Ran"
          value={ranAt() === null ? "unknown" : formatClock(ranAt())}
          sub={ranAt() === null ? "not recorded" : formatAge(ranAt(), props.now())}
          tip="Wall-clock time the discovery pass started, and how long ago that was."
        />
        <Stat
          label="Duration"
          value={secs(props.discovery.durationMs)}
          unit="s"
          tip="Wall-clock length of the whole pass."
        />
        <Stat
          label="Listen window"
          value={fmtNum(props.discovery.listenMs)}
          unit="ms"
          tip="How long the relay passively listened on the bus before deciding. Listening to real traffic is more reliable than trusting a configured address."
        />
        <Stat
          label="Candidates"
          value={fmtNum(props.discovery.candidates)}
          tip="Endpoints the pass considered — configured ports plus anything it heard on the bus."
        />
        <Stat
          label="Assigned"
          value={fmtNum(props.discovery.assigned)}
          tip="Endpoints matched to a known device and put to work."
        />
        <Stat
          label="Unidentified"
          value={fmtNum(props.discovery.unidentified)}
          tip="Endpoints left unresolved. Anything still silent at the end of the listen window lands here and is not polled."
        />
      </div>

      <div class="diag-log-label">Decision log</div>
      <Show
        when={props.discovery.log.length > 0}
        fallback={<div class="diag-none">Discovery produced no decision log lines.</div>}
      >
        <ol class="diag-log">
          <For each={props.discovery.log}>{(line) => <li>{line}</li>}</For>
        </ol>
      </Show>
    </section>
  );
}

export function ConnectionCard(props: { connection: NormalizedConnection; now: () => number }) {
  const conn = () => props.connection;
  const dirs = () => directions(conn().role);
  const age = (at: number | null) => formatAge(at, props.now(), { never: "never" });

  const firstDirection = () => conn().requestsIn + conn().pollsOut;
  const secondDirection = () => conn().responsesOut + conn().responsesIn;

  const identityLine = () => {
    const id = conn().identity;
    const expected = conn().expectedIdentity;
    if (id === null) {
      return "identity not determined";
    }
    if (expected === null) {
      return "no identity expected from configuration";
    }
    return id === expected ? "matches configuration" : `configuration expected ${expected}`;
  };

  const uptime = () => {
    const since = conn().connectedSince;
    if (since === null) {
      return "not connected since the relay started";
    }
    return `connected since ${formatDateTime(since)} · up ${formatDuration(props.now() - since)}`;
  };

  const errorWindow = () =>
    conn().windowSecs > 0 ? `Error rate · ${Math.round(conn().windowSecs)} s` : "Error rate";

  return (
    <div class="panel diag-card" classList={{ mismatch: conn().identification.mismatch }}>
      <div class="panel-head">
        <h2>
          <span class="badge role">{ROLE_LABEL[conn().role]}</span>
          <span class="diag-label">{conn().label}</span>
          <Tip down text={ROLE_TIP[conn().role]} />
        </h2>
        <span class="panel-head-right">
          <span class="badge" classList={{ ok: conn().healthy, off: !conn().healthy }}>
            {conn().healthy ? "healthy" : "not healthy"}
          </span>
          <Show when={conn().identification.mismatch}>
            <span class="badge warn">mismatch</span>
          </Show>
        </span>
      </div>

      <div class="diag-endpoint">
        <span class="diag-endpoint-value">{conn().endpoint}</span>
        <span class="badge">{conn().kind}</span>
      </div>

      <div class="diag-conn-line">
        <span class={`badge ${stateClass(conn().state, conn().healthy)}`}>{conn().stateLabel}</span>
        <span class="diag-conn-note">{describeState(conn())}</span>
      </div>

      <Show when={conn().identification.mismatch}>
        <div class="diag-mismatch">
          <strong>Identity mismatch.</strong>{" "}
          <Show
            when={conn().identity}
            fallback={
              <>
                The configuration expects{" "}
                <strong>{conn().expectedIdentity ?? "something else"}</strong> here, but discovery
                could not identify anything at this endpoint.
              </>
            }
          >
            {(identity) => (
              <>
                Discovery found <strong>{identity()}</strong> here, but the configuration expected{" "}
                <strong>{conn().expectedIdentity ?? "something else"}</strong>.
              </>
            )}
          </Show>{" "}
          Auto-detection kept the discovered identity, so the configured port is stale.
        </div>
      </Show>

      <div class="diag-block">
        <div class="diag-block-title">Identity</div>
        {/*
          Only a meter-emulation line has an inverter identity: it is the one
          endpoint whose *behaviour* (the register map the inverter polls) says
          which inverter is behind it. The grid meter is a device and the stats
          bus is shared by every inverter, so showing those two as
          "unidentified" would read as a problem where there is none.
        */}
        <Show
          when={conn().role === "meter_emulator"}
          fallback={
            <div class="diag-note">
              {conn().role === "grid_meter"
                ? "A device rather than an inverter: the grid meter has no inverter identity to match."
                : conn().role === "stats_bus"
                  ? "A shared bus: every inverter answers on it, so it has no single identity."
                  : "No inverter identity applies to this endpoint."}
            </div>
          }
        >
          <div class="diag-identity">
            <div>
              <div class="diag-field-label">Discovered</div>
              <div class="diag-field-value">{conn().identity ?? "unidentified"}</div>
            </div>
            <div>
              <div class="diag-field-label">Expected</div>
              <div class="diag-field-value">{conn().expectedIdentity ?? "—"}</div>
            </div>
            <div class="diag-field-note">{identityLine()}</div>
          </div>
        </Show>
        <div class="metrics">
          <Metric
            label="Method"
            value={conn().identification.method}
            tip="How discovery reached its conclusion. Listening to real polls and fingerprinting them is the strongest signal; a configured hint is the weakest."
          />
          <Metric
            label="Confidence"
            value={formatPercent(conn().identification.confidence, 0)}
            tip="How sure the match is, 0–100%. A fingerprint matching every observed request reads 100%."
          />
        </div>
        <div class="diag-evidence">{conn().identification.evidence}</div>
      </div>

      <div class="diag-block">
        <div class="diag-block-title">Last activity</div>
        <div class="metrics">
          <Metric
            label="Last rx"
            value={age(conn().lastRx)}
            tip="How long since a frame arrived on this link."
          />
          <Metric
            label="Last tx"
            value={age(conn().lastTx)}
            tip="How long since a frame was sent on this link."
          />
        </div>
        <div class="diag-note">{uptime()}</div>
      </div>

      <div class="diag-block">
        <div class="diag-block-title">Health</div>
        <div class="metrics">
          <Metric
            label={errorWindow()}
            value={formatPercent(conn().errorRate, 2)}
            tip="Share of exchanges in the last window that ended in a timeout, CRC failure, Modbus exception or I/O error."
          />
          <Metric
            label="Timeouts"
            value={formatCount(conn().timeouts)}
            tip="Cumulative requests that got no answer in time."
          />
          <Metric
            label="CRC errors"
            value={formatCount(conn().crcErrors)}
            tip="Cumulative frames whose checksum did not match — usually bus noise or a baud/parity mismatch."
          />
          <Metric
            label="Exceptions"
            value={formatCount(conn().exceptions)}
            tip="Cumulative Modbus exception responses: the far end understood the request and refused it."
          />
          <Metric
            label="I/O errors"
            value={formatCount(conn().ioErrors)}
            tip="Cumulative socket or serial read/write failures."
          />
          <Metric
            label="Reconnects"
            value={formatCount(conn().reconnects)}
            tip="How many times this link has had to be re-established."
          />
        </div>
      </div>

      <div class="diag-block">
        <div class="diag-block-title">Traffic</div>
        <div class="metrics">
          <Metric
            label="Rx frames"
            value={formatCount(conn().rxFrames)}
            tip="Frames received on this link since the relay started."
          />
          <Metric
            label="Tx frames"
            value={formatCount(conn().txFrames)}
            tip="Frames sent on this link since the relay started."
          />
          <Metric
            label="Rx bytes"
            value={formatCount(conn().rxBytes)}
            tip="Bytes received on this link since the relay started."
          />
          <Metric
            label="Tx bytes"
            value={formatCount(conn().txBytes)}
            tip="Bytes sent on this link since the relay started."
          />
        </div>
        <div class="metrics diag-directional">
          <Metric
            label={dirs().first.label}
            value={formatCount(firstDirection())}
            tip={dirs().first.tip}
          />
          <Metric
            label={dirs().second.label}
            value={formatCount(secondDirection())}
            tip={dirs().second.tip}
          />
        </div>
      </div>

      <div class="diag-block">
        <div class="diag-block-title">Recent errors</div>
        <Show
          when={conn().recentErrors.length > 0}
          fallback={<div class="diag-none">no recent errors</div>}
        >
          <ul class="diag-errors">
            <For each={conn().recentErrors}>
              {(entry) => (
                <li>
                  <span class="diag-error-time">{formatClock(entry.at)}</span>
                  <span class="badge off diag-error-kind">{entry.kind}</span>
                  <span class="diag-error-detail">{entry.detail}</span>
                </li>
              )}
            </For>
          </ul>
        </Show>
      </div>
    </div>
  );
}

export default function Diagnostics() {
  const [data, setData] = createSignal<NormalizedConnections | null>(null);
  const [fetchedAt, setFetchedAt] = createSignal<number | null>(null);
  const [error, setError] = createSignal<string | null>(null);
  const [tick, setTick] = createSignal(Date.now());

  // The local clock every "x ago" is measured against. It advances even while
  // the feed is broken, so a frozen timestamp keeps aging and cannot be
  // mistaken for a fresh one.
  const now = () => tick();

  // A payload we have never managed to fetch is unavailable; one that has gone
  // quiet since is shown but marked unavailable. Either way old numbers are
  // never presented as current.
  const feedDown = createMemo(() => error() !== null);
  const feedFresh = createMemo(() => {
    const at = fetchedAt();
    return at !== null && error() === null && tick() - at < STALE_MS;
  });
  const sinceSuccess = createMemo(() => {
    const at = fetchedAt();
    return at === null ? null : formatAge(at, tick());
  });

  onMount(() => {
    // Ages tick locally; this never triggers a fetch.
    const ticker = window.setInterval(() => setTick(Date.now()), 200);
    onCleanup(() => window.clearInterval(ticker));
  });

  onMount(() => {
    const controller = new AbortController();
    let timer = 0;

    const load = async () => {
      try {
        const result = await fetchConnections(controller.signal);
        setData(result.data);
        setFetchedAt(result.fetchedAt);
        setError(null);
      } catch (cause) {
        if (controller.signal.aborted) {
          return;
        }
        setError(cause instanceof Error ? cause.message : String(cause));
      }
    };

    // A self-rescheduling timeout rather than setInterval, so a slow response
    // cannot pile up overlapping requests.
    const schedule = () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        void load().then(schedule);
      }, POLL_MS);
    };

    void load().then(schedule);

    // Coming back to a backgrounded tab must not leave a minute-old reading
    // sitting under a "live" label.
    const onWake = () => {
      if (document.visibilityState === "visible") {
        void load();
      }
    };
    document.addEventListener("visibilitychange", onWake);
    window.addEventListener("focus", onWake);

    onCleanup(() => {
      controller.abort();
      window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", onWake);
      window.removeEventListener("focus", onWake);
    });
  });

  return (
    <Show
      when={data()}
      fallback={
        <Show
          when={error()}
          fallback={<div class="loading">Fetching connection diagnostics…</div>}
        >
          <section class="panel diag-unavailable">
            <div class="diag-unavailable-title">
              Diagnostics feed unavailable
              <Tip
                down
                text="GET /api/connections has never answered in this session, so there is nothing trustworthy to show. This is a relay or network problem, not an absence of connections."
              />
            </div>
            <div class="diag-unavailable-detail">{error()}</div>
            <div class="diag-note">
              Retrying every {POLL_MS / 1000} s. The relay's legacy status page is at{" "}
              <a href="/stats">/stats</a>; the raw connection payload is at{" "}
              <a href="/api/connections">/api/connections</a>.
            </div>
          </section>
        </Show>
      }
    >
      {(current) => (
        <>
          <section class="diag-feed" classList={{ stale: !feedFresh() }}>
            <span class={`badge ${feedFresh() ? "ok" : "off"}`}>
              {feedFresh() ? "feed live" : "feed stale"}
            </span>
            <span class="diag-feed-text">
              last successful fetch {sinceSuccess() ?? "never"}
              <Show when={current().ts !== null}>
                {" · "}payload stamped {formatClock(current().ts)}
              </Show>
              <Show when={!feedFresh() && !feedDown()}>{" · "}waiting for the next poll</Show>
            </span>
          </section>

          <Show when={feedDown()}>
            <section class="panel diag-unavailable">
              <div class="diag-unavailable-title">Diagnostics feed is not answering</div>
              <div class="diag-unavailable-detail">
                Last successful fetch {sinceSuccess() ?? "never"} ago — {error()}. Everything below
                is frozen at that moment and may no longer describe the relay.
              </div>
            </section>
          </Show>

          <Show
            when={current().discovery}
            fallback={
              <section class="panel">
                <div class="panel-head">
                  <h2>
                    Discovery
                    <Tip
                      down
                      text="Runs once at startup. The relay opens every configured endpoint, listens for inverter meter polls and probes the bus, then matches what it hears against the known meter fingerprints to work out which endpoint is which device."
                    />
                  </h2>
                </div>
                <div class="diag-none">
                  Discovery has not completed yet, so there is no report to show. The connections
                  below still report their own state.
                </div>
              </section>
            }
          >
            {(discovery) => <DiscoveryPanel discovery={discovery()} now={now} />}
          </Show>

          <section class="panels diag-cards">
            <Show
              when={current().connections.length > 0}
              fallback={
                <div class="panel">
                  <div class="diag-none">The relay reports no connections at all.</div>
                </div>
              }
            >
              <For each={current().connections}>
                {(connection) => <ConnectionCard connection={connection} now={now} />}
              </For>
            </Show>
          </section>
        </>
      )}
    </Show>
  );
}
