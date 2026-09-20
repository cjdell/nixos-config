"use strict";

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
const $ = (id) => document.getElementById(id);
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const n1 = (v) => (v == null || !isFinite(v) ? "–" : v.toFixed(1));
const n0 = (v) => (v == null || !isFinite(v) ? "–" : Math.round(v).toString());

async function api(path, body) {
  const opts = { cache: "no-store" };
  if (body !== undefined) {
    opts.method = "POST";
    opts.headers = { "Content-Type": "application/json" };
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(path, opts);
  const j = await r.json().catch(() => ({ ok: false, error: "bad response" }));
  if (!r.ok || j.ok === false) throw new Error(j.error || ("HTTP " + r.status));
  return j;
}

function say(text, isErr) {
  const el = $("msg");
  el.textContent = text || "";
  el.className = "msg " + (isErr ? "err" : "ok");
  if (text) setTimeout(() => { if (el.textContent === text) el.textContent = ""; }, 8000);
}

// ---------------------------------------------------------------------------
// charts
// ---------------------------------------------------------------------------
const CHART_DEFS = [
  { key: "power",   name: "Power",        unit: "W",   color: "#38bdf8", get: (s) => s.power,   fmt: n1, max: 400 },
  { key: "edge",    name: "Edge temp",    unit: "°C",  color: "#f87171", get: (s) => s.edge,    fmt: n1, max: 110 },
  { key: "hotspot", name: "Hotspot",      unit: "°C",  color: "#fb923c", get: (s) => s.hotspot, fmt: n1, max: 110 },
  { key: "memtemp", name: "Memory temp",  unit: "°C",  color: "#f472b6", get: (s) => s.mem_temp, fmt: n1, max: 110 },
  { key: "fanrpm",  name: "Fan",          unit: "RPM", color: "#4ade80", get: (s) => s.fan_rpm, fmt: n0 },
  { key: "fanpwm",  name: "Fan pwm",      unit: "%",   color: "#22d3ee", get: (s) => (s.fan_pwm / 255) * 100, fmt: n0, max: 100 },
  { key: "sclk",    name: "GPU clock",    unit: "MHz", color: "#a78bfa", get: (s) => s.sclk,    fmt: n0, max: 3000 },
  { key: "mclk",    name: "VRAM clock",   unit: "MHz", color: "#c084fc", get: (s) => s.mclk,    fmt: n0, max: 1600 },
  { key: "volt",    name: "VDDGFX",       unit: "mV",  color: "#facc15", get: (s) => s.volt,    fmt: n0, max: 1200 },
  { key: "gpu",     name: "GPU busy",     unit: "%",   color: "#4ade80", get: (s) => s.gpu_busy, fmt: n0, max: 100 },
  { key: "membusy", name: "Memory busy",  unit: "%",   color: "#34d399", get: (s) => s.mem_busy, fmt: n0, max: 100 },
  { key: "vram",    name: "VRAM used",    unit: "%",   color: "#60a5fa", get: (s) => s.vram_total ? (s.vram_used / s.vram_total) * 100 : 0, fmt: n1, max: 100 },
  { key: "gtt",     name: "GTT used",     unit: "%",   color: "#818cf8", get: (s) => s.gtt_total ? (s.gtt_used / s.gtt_total) * 100 : 0, fmt: n1, max: 100 },
  { key: "pidout",  name: "PID fan duty", unit: "%",   color: "#f59e0b", get: (s) => (s.fan_cmd >= 0 ? s.fan_cmd : null), fmt: n0, max: 100 },
  { key: "piderr",  name: "Thermal error", unit: "°C", color: "#ef4444", get: (s) => (s.target > 0 ? s.ctrl_temp - s.target : null), fmt: n1 },
];

class Chart {
  constructor(def, maxPoints) {
    this.def = def;
    this.maxPoints = maxPoints;
    this.data = [];
    this.vmin = Infinity;
    this.vmax = -Infinity;

    const card = document.createElement("div");
    card.className = "chart";
    card.innerHTML = `
      <div class="head"><span class="name">${def.name}</span>
        <span class="val">–<small style="color:#7f8899;font-size:11px;font-weight:400"> ${def.unit}</small></span></div>
      <canvas></canvas>
      <div class="foot"><span class="lo">–</span><span class="cur">–</span><span class="hi">–</span></div>`;
    this.el = card;
    this.valEl = card.querySelector(".val");
    this.loEl = card.querySelector(".lo");
    this.hiEl = card.querySelector(".hi");
    this.curEl = card.querySelector(".cur");
    this.canvas = card.querySelector("canvas");
    this.ctx = this.canvas.getContext("2d");
    this.resize = this.resize.bind(this);
  }

  push(sample) {
    const v = this.def.get(sample);
    if (v == null || !isFinite(v)) return;
    this.data.push(v);
    if (this.data.length > this.maxPoints) this.data.splice(0, this.data.length - this.maxPoints);
    this.vmin = Math.min(this.vmin, v);
    this.vmax = Math.max(this.vmax, v);
  }

  resize() {
    const dpr = window.devicePixelRatio || 1;
    const w = this.canvas.clientWidth || 300;
    const h = this.canvas.clientHeight || 78;
    this.canvas.width = Math.round(w * dpr);
    this.canvas.height = Math.round(h * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.w = w;
    this.h = h;
  }

  draw() {
    const ctx = this.ctx;
    const w = this.w || this.canvas.clientWidth;
    const h = this.h || this.canvas.clientHeight;
    ctx.clearRect(0, 0, w, h);

    const d = this.data;
    const last = d.length ? d[d.length - 1] : null;
    this.valEl.innerHTML =
      (last == null ? "–" : this.def.fmt(last)) +
      `<small style="color:#7f8899;font-size:11px;font-weight:400"> ${this.def.unit}</small>`;

    // grid
    ctx.strokeStyle = "rgba(255,255,255,0.05)";
    ctx.lineWidth = 1;
    for (let i = 1; i < 4; i++) {
      const y = Math.round((h * i) / 4) + 0.5;
      ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
    }
    if (d.length < 2) return;

    let lo = Infinity, hi = -Infinity;
    for (const v of d) { if (v < lo) lo = v; if (v > hi) hi = v; }
    if (hi - lo < 1e-9) { hi = lo + 1; }
    const pad = (hi - lo) * 0.12;
    const top = this.def.max != null ? Math.max(hi + pad, Math.min(this.def.max, hi * 1.05)) : hi + pad;
    const bot = Math.max(0, lo - pad);
    const span = top - bot || 1;

    const x = (i) => (i / (d.length - 1)) * w;
    const y = (v) => h - ((v - bot) / span) * h;

    // area
    const grad = ctx.createLinearGradient(0, 0, 0, h);
    grad.addColorStop(0, this.def.color + "55");
    grad.addColorStop(1, this.def.color + "05");
    ctx.beginPath();
    ctx.moveTo(0, h);
    for (let i = 0; i < d.length; i++) ctx.lineTo(x(i), y(d[i]));
    ctx.lineTo(w, h);
    ctx.closePath();
    ctx.fillStyle = grad;
    ctx.fill();

    // line
    ctx.beginPath();
    for (let i = 0; i < d.length; i++) {
      const px = x(i), py = y(d[i]);
      if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
    }
    ctx.strokeStyle = this.def.color;
    ctx.lineWidth = 1.6;
    ctx.lineJoin = "round";
    ctx.stroke();

    // last point marker
    ctx.beginPath();
    ctx.arc(x(d.length - 1), y(d[d.length - 1]), 2.2, 0, Math.PI * 2);
    ctx.fillStyle = this.def.color;
    ctx.fill();

    this.loEl.textContent = this.def.fmt(lo);
    this.hiEl.textContent = this.def.fmt(hi);
    this.curEl.textContent = this.maxPoints ? "" : "";
  }
}

const charts = CHART_DEFS.map((d) => new Chart(d, 1200));
const chartRoot = $("charts");
for (const c of charts) chartRoot.appendChild(c.el);

let rafPending = false;
function render() {
  if (rafPending) return;
  rafPending = true;
  requestAnimationFrame(() => {
    rafPending = false;
    for (const c of charts) c.draw();
  });
}
function resizeAll() { for (const c of charts) c.resize(); render(); }
window.addEventListener("resize", resizeAll);

// ---------------------------------------------------------------------------
// tiles
// ---------------------------------------------------------------------------
const TILES = [
  { k: "power", label: "power", get: (s) => n1(s.power) + " W" },
  { k: "edge", label: "edge", get: (s) => n1(s.edge) + " °C" },
  { k: "hotspot", label: "hotspot", get: (s) => n1(s.hotspot) + " °C" },
  { k: "fan", label: "fan", get: (s) => n0(s.fan_rpm) + " rpm" },
  { k: "sclk", label: "gpu clock", get: (s) => n0(s.sclk) + " MHz" },
  { k: "vram", label: "vram", get: (s) => (s.vram_used / 1073741824).toFixed(1) + " GiB" },
  { k: "perf", label: "perf", get: (s) => s.perf },
  { k: "target", label: "target", get: (s) => (s.target > 0 ? n0(s.target) + " °C" : "–") },
  { k: "pidout", label: "pid out", get: (s) => (s.fan_cmd >= 0 ? s.fan_cmd + " %" : "–") },
];
for (const t of TILES) {
  const el = document.createElement("div");
  el.className = "tile";
  el.innerHTML = `<div class="k">${t.label}</div><div class="v" id="tile-${t.k}">–</div>`;
  $("tiles").appendChild(el);
}

let lastT = 0;
function pushSample(s) {
  for (const c of charts) c.push(s);
  for (const t of TILES) $("tile-" + t.k).textContent = t.get(s);
  if (s.t !== lastT) {
    lastT = s.t;
    $("updated").textContent = new Date(s.t).toLocaleTimeString();
  }
  render();
}

// ---------------------------------------------------------------------------
// SSE
// ---------------------------------------------------------------------------
function openStream() {
  const es = new EventSource("api/stream");
  es.onopen = () => { $("stream").textContent = "stream: live"; $("stream").className = "badge ok"; };
  es.onmessage = (ev) => { try { pushSample(JSON.parse(ev.data)); } catch (_) {} };
  es.onerror = () => { $("stream").textContent = "stream: reconnecting"; $("stream").className = "badge err"; };
}

// ---------------------------------------------------------------------------
// controls
// ---------------------------------------------------------------------------
let ctl = null;
const curve = []; // [{t, s}]
let sliderMin = {}, sliderMax = {};

function sliderToVal(el, key) {
  const lo = sliderMin[key], hi = sliderMax[key];
  return lo + ((hi - lo) * Number(el.value)) / 100;
}
function valToSlider(v, key) {
  const lo = sliderMin[key], hi = sliderMax[key];
  if (hi === lo) return 0;
  return clamp(((v - lo) / (hi - lo)) * 100, 0, 100);
}

function buildCurve() {
  const root = $("curve");
  root.innerHTML = "";
  curve.forEach((pt, i) => {
    const row = document.createElement("div");
    row.className = "pt";
    row.innerHTML = `<input type="number" min="25" max="105" value="${pt.t}" data-i="${i}" data-f="t">
      <input type="range" min="0" max="100" value="${Math.round(pt.s * 100)}" data-i="${i}" data-f="s">
      <span style="text-align:right;font-variant-numeric:tabular-nums">${Math.round(pt.s * 100)}%</span>`;
    root.appendChild(row);
  });
  root.querySelectorAll("input").forEach((el) => {
    el.addEventListener("input", () => {
      const i = Number(el.dataset.i);
      if (el.dataset.f === "t") curve[i].t = clamp(Number(el.value) || 25, 25, 105);
      else {
        curve[i].s = clamp(Number(el.value) / 100, 0, 1);
        el.parentElement.querySelector("span").textContent = el.value + "%";
      }
    });
  });
}

function applyControl(c) {
  ctl = c;
  $("lact").textContent = c.ok ? "daemon: connected" : "daemon: unreachable";
  $("lact").className = "badge " + (c.ok ? "ok" : "err");
  $("lact").title = c.error || "";
  if (!c.ok) return;

  // fan
  $("fanEnabled").checked = c.fan.enabled;
  document.querySelectorAll("#fanMode button").forEach((b) => b.classList.toggle("on", b.dataset.mode === c.fan.mode));
  $("staticSpeed").value = Math.round(c.fan.static * 100);
  $("staticVal").textContent = Math.round(c.fan.static * 100) + "%";
  curve.length = 0;
  for (const [t, s] of c.fan.curve) curve.push({ t, s });
  buildCurve();
  $("targetTemperature").value = c.fan.target_temperature.cur;
  $("minimumPwm").value = c.fan.minimum_pwm.cur;
  $("acousticTarget").value = c.fan.acoustic_target.cur;
  $("acousticLimit").value = c.fan.acoustic_limit.cur;
  $("fanState").textContent =
    `${c.fan.mode}${c.fan.enabled ? "" : " (off)"} · temp ${c.fan.minimum_pwm.cur}-${c.fan.acoustic_limit.cur}`;
  toggleFanMode();

  // power
  sliderMin.cap = c.power.min; sliderMax.cap = c.power.max;
  $("powerCap").value = valToSlider(c.power.cur, "cap");
  $("capVal").textContent = n0(c.power.cur) + " W";
  $("resetCap").checked = false;
  $("capRange").textContent = `${n0(c.power.min)} – ${n0(c.power.max)} W (default ${n0(c.power_default)})`;

  // perf
  $("perfLevel").value = c.perf_level;

  // clocks
  sliderMin.sclk = c.sclk_offset.min; sliderMax.sclk = c.sclk_offset.max;
  $("sclkOffset").value = valToSlider(c.sclk_offset.cur, "sclk");
  $("sclkVal").textContent = (c.sclk_offset.cur > 0 ? "+" : "") + n0(c.sclk_offset.cur) + " MHz";
  sliderMin.volt = c.volt_offset.min; sliderMax.volt = c.volt_offset.max;
  $("voltOffset").value = valToSlider(c.volt_offset.cur, "volt");
  $("voltVal").textContent = n0(c.volt_offset.cur) + " mV";
  $("mclkMin").value = c.mclk_min.cur;
  $("mclkMax").value = c.mclk_max.cur;
  $("mclkMin").min = c.mclk_min.min; $("mclkMin").max = c.mclk_min.max;
  $("mclkMax").min = c.mclk_max.min; $("mclkMax").max = c.mclk_max.max;
  $("clkHint").textContent =
    `gpu offset ${n0(c.sclk_offset.min)}…${n0(c.sclk_offset.max)} MHz · vram ${n0(c.mclk_min.min)}…${n0(c.mclk_max.max)} MHz · voltage ${n0(c.volt_offset.min)}…${n0(c.volt_offset.max)} mV`;
}

function toggleFanMode() {
  const mode = document.querySelector("#fanMode button.on")?.dataset.mode || "curve";
  $("staticWrap").classList.toggle("hidden", mode !== "static");
  $("curveWrap").classList.toggle("hidden", mode !== "curve");
}
document.querySelectorAll("#fanMode button").forEach((b) => b.addEventListener("click", () => {
  document.querySelectorAll("#fanMode button").forEach((x) => x.classList.remove("on"));
  b.classList.add("on");
  toggleFanMode();
}));
$("staticSpeed").addEventListener("input", (e) => { $("staticVal").textContent = e.target.value + "%"; });
$("powerCap").addEventListener("input", () => { $("capVal").textContent = n0(sliderToVal($("powerCap"), "cap")) + " W"; });
$("sclkOffset").addEventListener("input", () => {
  const v = sliderToVal($("sclkOffset"), "sclk");
  $("sclkVal").textContent = (v > 0 ? "+" : "") + n0(v) + " MHz";
});
$("voltOffset").addEventListener("input", () => { $("voltVal").textContent = n0(sliderToVal($("voltOffset"), "volt")) + " mV"; });

async function apply(path, body, label) {
  try {
    const j = await api(path, body);
    if (j.control) applyControl(j.control);
    else applyControl(await api("api/control"));
    say(label + ": " + (j.message || "ok"), false);
  } catch (e) {
    say(label + " failed: " + e.message, true);
  }
}

$("applyFan").addEventListener("click", () => {
  const mode = document.querySelector("#fanMode button.on")?.dataset.mode || "curve";
  const body = {
    enabled: $("fanEnabled").checked,
    mode,
    static_speed: Number($("staticSpeed").value) / 100,
    temperature_key: "edge",
    curve: curve.map((p) => [p.t, p.s]),
    minimum_pwm: Number($("minimumPwm").value),
    target_temperature: Number($("targetTemperature").value),
    acoustic_target: Number($("acousticTarget").value),
    acoustic_limit: Number($("acousticLimit").value),
  };
  apply("api/fan", body, "fan");
});

$("applyPower").addEventListener("click", () => {
  const cap = $("resetCap").checked ? null : sliderToVal($("powerCap"), "cap");
  apply("api/power", { cap }, "power cap");
});

$("applyPerf").addEventListener("click", () => {
  apply("api/perf", { level: $("perfLevel").value }, "performance level");
});

$("applyClocks").addEventListener("click", () => {
  const body = {
    gpu_clock_offset: Math.round(sliderToVal($("sclkOffset"), "sclk")),
    voltage_offset: Math.round(sliderToVal($("voltOffset"), "volt")),
    min_memory_clock: Number($("mclkMin").value),
    max_memory_clock: Number($("mclkMax").value),
  };
  apply("api/clocks", body, "clocks");
});

$("resetClocks").addEventListener("click", () => apply("api/clocks", { reset: true }, "clocks reset"));
$("revert").addEventListener("click", () => apply("api/revert", {}, "revert"));

// ---------------------------------------------------------------------------
// PID thermal controller
// ---------------------------------------------------------------------------
let thermal = null;

function setFanCardDisabled(on) {
  $("fanCard").classList.toggle("disabled", on);
}

function fillThermalForm(t) {
  $("pidTarget").value = Math.round(t.target);
  $("pidTargetVal").textContent = Math.round(t.target) + " °C";
  $("pidSource").value = t.source;
  $("pidKp").value = t.kp;
  $("pidKi").value = t.ki;
  $("pidKd").value = t.kd;
  $("pidMinDuty").value = Math.round(t.duty_min);
  $("pidInterval").value = t.interval_ms;
}

function updateThermalLive(t) {
  thermal = t;
  const on = t.enabled && t.active;
  $("pidState").textContent = on ? "armed" : (t.enabled ? "starting…" : "off");
  $("pidMeasured").textContent = n1(t.measured) + " °C";
  $("pidError").textContent = (t.error > 0 ? "+" : "") + n1(t.error) + " °C";
  $("pidError").style.color = t.error > 2 ? "var(--err)" : (t.error < -2 ? "var(--ok)" : "");
  $("pidDuty").textContent = n0(t.duty) + " %";
  $("pidCenter").textContent = n0(t.center) + " °C";
  $("pidWrites").textContent = t.writes;
  setFanCardDisabled(on);
  if (t.last_error) say("PID: " + t.last_error, true);
}

async function refreshThermal(fillForm) {
  try {
    const t = await api("api/thermal");
    if (fillForm) fillThermalForm(t);
    updateThermalLive(t);
  } catch (_) {}
}

$("pidTarget").addEventListener("input", (e) => { $("pidTargetVal").textContent = e.target.value + " °C"; });

$("pidArm").addEventListener("click", async () => {
  const body = {
    action: "apply",
    target: Number($("pidTarget").value),
    source: $("pidSource").value,
    kp: Number($("pidKp").value),
    ki: Number($("pidKi").value),
    kd: Number($("pidKd").value),
    duty_min: Number($("pidMinDuty").value),
    interval_ms: Number($("pidInterval").value),
  };
  try {
    const j = await api("api/thermal", body);
    say(j.message || "PID armed", false);
    await refreshThermal(true);
  } catch (e) {
    say("PID arm failed: " + e.message, true);
  }
});

$("pidStop").addEventListener("click", async () => {
  try {
    const j = await api("api/thermal", { action: "stop" });
    say(j.message || "PID stopped", false);
    await refreshThermal(true);
  } catch (e) {
    say("PID stop failed: " + e.message, true);
  }
});

// ---------------------------------------------------------------------------
// boot
// ---------------------------------------------------------------------------
async function boot() {
  resizeAll();
  try {
    const snap = await api("api/snapshot");
    for (const s of snap.history) pushSample(s);
    pushSample(snap.current);
    applyControl(snap.control);
    if (snap.thermal) { fillThermalForm(snap.thermal); updateThermalLive(snap.thermal); }
  } catch (e) {
    say("initial load failed: " + e.message, true);
  }
  try { applyControl(await api("api/control")); } catch (_) {}
  refreshThermal(false);
  openStream();
  setInterval(async () => {
    try { applyControl(await api("api/control")); } catch (_) {}
  }, 30000);
  setInterval(() => refreshThermal(false), 5000);
}
boot();
