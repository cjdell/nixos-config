#!/usr/bin/env python3
"""Audit the meter-relay control loop from an InfluxDB CSV export.

Input: a CSV exported from the `Meter` bucket, `relay` measurement, pivoted so
each field is a column (`meter_power`, `needed_power`, `solis_target_power`,
`solis_actual_power`, `solax_target_power`, `solax_actual_power`).

    flux: from(bucket:"Meter") |> range(start:-7d)
          |> filter(fn:(r)=>r._measurement=="relay")
          |> aggregateWindow(every:1m, fn:mean, createEmpty:false)
          |> pivot(rowKey:["_time"], columnKey:["_field"], valueColumn:"_value")

Reports:
  * grid tracking against the export target (-MR_METER_TARGET_POWER),
  * the P/I/D decomposition of the controller output (needs --gains),
  * per-inverter authority: delivered vs commanded battery power, by command bin.

Usage:
    control_audit.py relay_1m_7d.csv
    control_audit.py relay_raw_5m.csv --gains 0.9 0.3 0.15 --target 50
"""

from __future__ import annotations

import argparse
import csv
import math
import statistics as st
import sys
from datetime import datetime

TERM_SLOTS = ("p", "i", "d")


def load(path: str) -> list[dict]:
    rows = []
    with open(path, newline="") as fh:
        for raw in csv.DictReader(fh):
            if not raw.get("_time"):
                continue
            try:
                row = {
                    "t": datetime.fromisoformat(raw["_time"].replace("Z", "+00:00")),
                    "m": float(raw["meter_power"]),
                    "n": float(raw["needed_power"]),
                }
            except (TypeError, ValueError, KeyError):
                continue
            for key, col in (
                ("st", "solis_target_power"),
                ("sa", "solis_actual_power"),
                ("xt", "solax_target_power"),
                ("xa", "solax_actual_power"),
            ):
                try:
                    row[key] = float(raw[col])
                except (TypeError, ValueError, KeyError):
                    row[key] = float("nan")
            rows.append(row)
    rows.sort(key=lambda r: r["t"])
    return rows


def pct(values: list[float], q: float) -> float:
    if not values:
        return float("nan")
    s = sorted(values)
    return s[min(len(s) - 1, max(0, int(round(q / 100.0 * (len(s) - 1)))))]


def tracking(rows: list[dict], target_export: float) -> None:
    grid = [r["m"] for r in rows]
    # Target export means the meter should read -target_export.
    err = [g + target_export for g in grid]
    aerr = [abs(e) for e in err]
    span = (rows[-1]["t"] - rows[0]["t"]).total_seconds()
    print(f"rows={len(rows)}  span={span/60:.1f} min  rate={len(rows)/span if span else 0:.2f} Hz")
    print(f"grid mean={st.mean(grid):8.1f} W  sd={st.pstdev(grid):7.1f} W  bias={st.mean(err):+7.1f} W")
    print(f"|error|   mean={st.mean(aerr):8.1f} W  median={pct(aerr,50):7.1f}  p90={pct(aerr,90):7.1f}  p99={pct(aerr,99):7.1f}")
    for band in (10, 25, 50, 100, 250):
        share = 100.0 * sum(1 for e in aerr if e <= band) / len(aerr)
        print(f"  within +/-{band:>4} W: {share:5.1f}%")
    print(f"importing: {100.0*sum(1 for g in grid if g>0)/len(grid):.1f}% of samples")


def decomposing(rows: list[dict], gains: tuple[float, float, float], target_export: float,
                dt: float) -> None:
    """Attribute the logged controller output to its P, I and D terms.

    The relay logs the process variable (`meter_power`) and the output
    (`needed_power`) but not the terms. Two of them are computable exactly:

        error = target_export + meter_power      (setpoint minus (-meter))
        P     = kp * error
        D     = kd * (error - previous_error) / dt
        I     = logged_output - P - D            (residual, exact by construction)

    so the decomposition needs no simulation and no guess at the unlogged
    integral state. The one assumption is the control interval `dt` used by the
    derivative; a wrong `dt` shows up as structure in the residual.
    """
    kp, ki, kd = gains
    logged = [r["n"] for r in rows]
    errors = [target_export + r["m"] for r in rows]

    terms: dict[str, list[float]] = {k: [] for k in TERM_SLOTS}
    prev_error: float | None = None
    for error, out in zip(errors, logged):
        derivative = 0.0 if prev_error is None else (error - prev_error) / dt
        p, d = kp * error, kd * derivative
        terms["p"].append(p)
        terms["d"].append(d)
        terms["i"].append(out - p - d)  # residual: the integral term (ki * I)
        prev_error = error

    var = st.pvariance(logged)
    mean_out = st.mean(logged)
    print(f"\nterm attribution (kp={kp} ki={ki} kd={kd}, dt={dt:g}s) - I is the exact residual")
    for name in TERM_SLOTS:
        v = terms[name]
        mean_v = st.mean(v)
        cov = sum((a - mean_v) * (b - mean_out) for a, b in zip(v, logged)) / len(logged)
        deltas = [abs(b - a) for a, b in zip(v, v[1:])]
        print(f"  term {name.upper()}: mean={mean_v:8.1f} W  sd={st.pstdev(v):7.1f} W"
              f"  |delta| mean={st.mean(deltas):7.1f} W  p99={pct(deltas,99):8.1f} W"
              f"  var share={cov/var*100 if var else float('nan'):5.1f}%")

    # Consistency check: the residual divided by ki is the controller's integral
    # state. Its drift must match the integral of the error, i.e. the code's
    # `integral += error * dt`. A mismatch means the real loop's dt is not `dt`.
    if ki != 0.0:
        drift = (terms["i"][-1] - terms["i"][0]) / ki
        expected = sum(e * dt for e in errors[:-1])
        print(f"  integral drift: measured {drift:9.0f} W.s vs sum(error*dt) {expected:9.0f} W.s"
              f"  (ratio {drift/expected if expected else float('nan'):.3f})")
    print("  (var shares sum to 100% by construction; a term with a large |delta| and ~0 mean"
          " is injecting noise rather than control)")


def authority(rows: list[dict]) -> None:
    if all(math.isnan(r.get("st", float("nan"))) for r in rows):
        print("\nno target/actual columns - skipping authority table")
        return
    edges = [-4000, -1500, -800, -300, -100, 100, 300, 800, 1500, 4000]
    print("\nauthority: delivered / commanded battery power, by command bin")
    print(f"{'commanded bin (W)':>20} | {'n':>6} {'cmd':>8} {'act':>8} {'ratio':>7}"
          f" | {'n':>6} {'cmd':>8} {'act':>8} {'ratio':>7}")
    print(f"{'':>20} | {'--- Solis ---':^33} | {'--- Solax ---':^33}")
    for lo, hi in zip(edges, edges[1:]):
        s = [r for r in rows if lo <= r["st"] < hi]
        x = [r for r in rows if lo <= r["xt"] < hi]

        def cell(b: list[dict], tk: str, ak: str) -> str:
            if not b:
                return f"{'-':>6} {'-':>8} {'-':>8} {'-':>7}"
            cmd = st.mean(r[tk] for r in b)
            act = st.mean(r[ak] for r in b)
            ratio = act / cmd if abs(cmd) > 50 else float("nan")
            return f"{len(b):6d} {cmd:8.0f} {act:8.0f} {ratio:+7.2f}"

        print(f"  [{lo:>5},{hi:>5})       | {cell(s,'st','sa')} | {cell(x,'xt','xa')}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("--target", type=float, default=50.0, help="export target in W (default 50)")
    ap.add_argument("--gains", nargs=3, type=float, metavar=("KP", "KI", "KD"),
                    help="central PID gains; enables the term decomposition")
    ap.add_argument("--dt", type=float, default=0.010, help="control interval in s (default 0.010)")
    ap.add_argument("--no-authority", action="store_true")
    ap.add_argument("--hours", metavar="A-B",
                    help="only use samples whose LOCAL hour is in A..B inclusive, e.g. 6-23 to "
                         "exclude the Octopus Go charge window")
    ap.add_argument("--tz-offset", type=float, default=0.0,
                    help="hours to add to the UTC timestamp before taking the hour (BST = 1)")
    args = ap.parse_args()

    rows = load(args.csv)
    if args.hours:
        lo_s, _, hi_s = args.hours.partition("-")
        lo, hi = int(lo_s), int(hi_s)
        rows = [r for r in rows if lo <= (r["t"].hour + args.tz_offset) % 24 <= hi]
        print(f"### {args.csv}  (local hours {lo}-{hi}, tz+{args.tz_offset:g})")
    else:
        print(f"### {args.csv}")
    if len(rows) < 4:
        print(f"not enough rows in {args.csv}", file=sys.stderr)
        return 1

    tracking(rows, args.target)
    if args.gains:
        decomposing(rows, tuple(args.gains), args.target, args.dt)
    if not args.no_authority:
        authority(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
