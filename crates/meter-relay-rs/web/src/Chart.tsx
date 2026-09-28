import { For, Show } from "solid-js";
import Tip from "./Tip";
import type { StatusSnapshot } from "./types";

interface Series {
  label: string;
  color: string;
  values: number[];
  tip?: string;
}

/// One colour per inverter, in priority order. A third (or fourth) inverter
/// gets its own line without any change here.
const PALETTE = ["#34d399", "#fbbf24", "#f472b6", "#60a5fa", "#c084fc"];

export default function PowerChart(props: { history: StatusSnapshot[] }) {
  const latest = (): StatusSnapshot | undefined => props.history[props.history.length - 1];

  const series = (): Series[] => {
    const inverters = latest()?.inverters ?? [];

    return [
      {
        label: "Grid (meter)",
        color: "#38bdf8",
        values: props.history.map((h) => h.central.grid_power),
        tip: "Actual power at the grid meter: above the zero line = importing, below = exporting.",
      },
      {
        label: "Demand",
        color: "#a78bfa",
        values: props.history.map((h) => h.central.pid.output),
        tip: "Total inverter power the relay is requesting: the inverters are filled in priority order, each up to the authority it has been observed to have.",
      },
      ...inverters.map((inverter, index) => ({
        label: `${inverter.name} battery`,
        color: PALETTE[index % PALETTE.length],
        values: props.history.map(
          (h) => h.inverters.find((inv) => inv.id === inverter.id)?.battery_power ?? 0,
        ),
        tip: inverter.primary
          ? "The primary bank. Above the zero line = discharging, below = charging."
          : "A reserve: asked to discharge only for what the higher-priority inverters cannot cover, and to absorb the surplus they cannot take.",
      })),
    ];
  };

  const bounds = () => {
    const all = series().flatMap((s) => s.values);
    if (all.length === 0) {
      return { min: -100, max: 100 };
    }
    let min = Math.min(...all);
    let max = Math.max(...all);
    const span = Math.max(max - min, 1);
    min -= span * 0.1;
    max += span * 0.1;
    return { min, max };
  };

  const path = (values: number[]) => {
    if (values.length < 2) {
      return "";
    }
    const { min, max } = bounds();
    const range = max - min || 1;
    return values
      .map((value, index) => {
        const x = (index / (values.length - 1)) * 100;
        const y = 100 - ((value - min) / range) * 100;
        return `${index === 0 ? "M" : "L"}${x.toFixed(2)},${y.toFixed(2)}`;
      })
      .join(" ");
  };

  const zeroY = () => {
    const { min, max } = bounds();
    const range = max - min || 1;
    return 100 - ((0 - min) / range) * 100;
  };

  return (
    <div class="chart-wrap">
      <div class="chart-legend">
        <For each={series()}>
          {(s) => (
            <span class="legend-item">
              <i style={{ background: s.color }} />
              {s.label}
              <Show when={s.tip}>
                <Tip down text={s.tip!} />
              </Show>
            </span>
          )}
        </For>
      </div>
      <svg class="chart" viewBox="0 0 100 100" preserveAspectRatio="none">
        <line
          x1="0"
          y1={zeroY()}
          x2="100"
          y2={zeroY()}
          class="zero-line"
          vector-effect="non-scaling-stroke"
        />
        <For each={series()}>
          {(s) => (
            <path
              d={path(s.values)}
              fill="none"
              stroke={s.color}
              stroke-width="1.5"
              vector-effect="non-scaling-stroke"
            />
          )}
        </For>
      </svg>
      <div class="chart-axis">
        <span>{Math.round(bounds().max)} W</span>
        <span>0 W</span>
        <span>{Math.round(bounds().min)} W</span>
      </div>
    </div>
  );
}
