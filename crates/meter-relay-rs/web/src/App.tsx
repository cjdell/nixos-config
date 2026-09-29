/**
 * The application shell.
 *
 * It owns two things the pages do not:
 *
 *   - the single live-telemetry subscription. The SSE stream is opened once,
 *     here, so the header can show the same reserve/mode/connection state on
 *     both pages and so switching tabs never re-subscribes (or reloads).
 *   - the page routing: hash-based, with Live on `#/` (or no hash) and
 *     Diagnostics on `#/diagnostics`.
 *
 * The Live page body stays mounted while Diagnostics is shown, hidden with
 * CSS, so its chart history is not thrown away by a tab switch. The Diagnostics
 * page is mounted only while it is visible, so its 1 s poll runs only then.
 */
import { createSignal, onCleanup, onMount, Show } from "solid-js";
import Diagnostics from "./Diagnostics";
import LivePage from "./Live";
import Tip from "./Tip";
import type { ReserveStateCode, StatusSnapshot } from "./types";

const MAX_HISTORY = 300;

type Page = "live" | "diagnostics";

/** `#/diagnostics` -> diagnostics; `#/`, `#`, `` -> live; junk -> live. */
function pageFromHash(hash: string): Page {
  const path = hash.replace(/^#\/?/, "").replace(/\/+$/, "").toLowerCase();
  return path === "diagnostics" ? "diagnostics" : "live";
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

function NavTab(props: { page: Page; current: Page; label: string; tip: string }) {
  return (
    <a
      class="nav-tab"
      classList={{ active: props.current === props.page }}
      href={props.page === "live" ? "#/" : "#/diagnostics"}
      aria-current={props.current === props.page ? "page" : undefined}
    >
      {props.label}
      <Tip down text={props.tip} />
    </a>
  );
}

export default function App() {
  const [snapshot, setSnapshot] = createSignal<StatusSnapshot | null>(null);
  const [history, setHistory] = createSignal<StatusSnapshot[]>([]);
  const [connected, setConnected] = createSignal(false);
  const [page, setPage] = createSignal<Page>(pageFromHash(window.location.hash));

  const push = (next: StatusSnapshot) => {
    setSnapshot(next);
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

    const onHashChange = () => setPage(pageFromHash(window.location.hash));
    window.addEventListener("hashchange", onHashChange);

    onCleanup(() => {
      events.close();
      window.removeEventListener("hashchange", onHashChange);
    });
  });

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
          <nav class="nav" aria-label="Pages">
            <NavTab
              page="live"
              current={page()}
              label="Live"
              tip="The control loop at work: grid power, the reserve's share of the demand, the power history and every PID's own numbers."
            />
            <NavTab
              page="diagnostics"
              current={page()}
              label="Diagnostics"
              tip="The relay's serial and Modbus connections: what discovery decided each endpoint is, how fresh each link is, and the errors each has seen. Polled live from /api/connections."
            />
          </nav>
        </div>
      </header>

      <div class="page" classList={{ "page-hidden": page() !== "live" }} aria-hidden={page() !== "live"}>
        <LivePage snapshot={snapshot} history={history} />
      </div>

      <Show when={page() === "diagnostics"}>
        <Diagnostics />
      </Show>

      <footer>
        <span>meter-relay-rs</span>
        <a href="/stats">/stats</a>
        <a href="/api/status">/api/status</a>
        <a href="/api/connections">/api/connections</a>
      </footer>
    </div>
  );
}
