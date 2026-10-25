// fah-panel frontend: bootstrap from /api/snapshot, then follow /api/stream.

const $ = (id) => document.getElementById(id);
const fmt = (v, unit, digits = 0) =>
  v == null ? "–" : `${Number(v).toFixed(digits)}${unit}`;

const hist = { util: [], power: [], temp: [], total: [] };
let capRange = null; // [min, max] or null
let budget = 0; // W; 0 = off (from --budget via /api/snapshot control)
let cpuMaxGhz = null; // boost ceiling from static cpu info
let ramSpeed = ""; // SMBIOS RAM bus speed from control

function setPill(text, cls) {
  const p = $("status");
  p.textContent = text;
  p.className = `pill ${cls || ""}`;
}

function drawSpark(canvas, xs, opts) {
  const dpr = window.devicePixelRatio || 1;
  const w = (canvas.clientWidth || 200) * dpr;
  const h = (canvas.clientHeight || 46) * dpr;
  if (canvas.width !== w) { canvas.width = w; canvas.height = h; }
  const g = canvas.getContext("2d");
  g.clearRect(0, 0, w, h);
  if (xs.length < 2) return;
  let lo = Math.min(...xs, opts.min ?? Infinity);
  let hi = Math.max(...xs, opts.max ?? -Infinity, opts.mark ?? -Infinity);
  if (!(hi > lo)) hi = lo + 1;
  const pad = 2 * dpr;
  const px = (i) => (i / (xs.length - 1)) * w;
  const py = (v) => h - pad - ((v - lo) / (hi - lo)) * (h - 2 * pad);
  g.beginPath();
  xs.forEach((v, i) => (i ? g.lineTo(px(i), py(v)) : g.moveTo(px(i), py(v))));
  g.strokeStyle = opts.color; g.lineWidth = 1.6 * dpr; g.stroke();
  g.lineTo(w, h); g.lineTo(0, h); g.closePath();
  g.fillStyle = opts.fill; g.fill();
  if (opts.mark > lo && opts.mark < hi) {
    g.beginPath();
    g.setLineDash([4 * dpr, 4 * dpr]);
    g.moveTo(0, py(opts.mark)); g.lineTo(w, py(opts.mark));
    g.strokeStyle = "#f87171aa"; g.lineWidth = 1 * dpr; g.stroke();
    g.setLineDash([]);
  }
}

function tempClass(t) {
  if (t == null) return "";
  if (t >= 85) return "hot";
  if (t >= 70) return "warm";
  return "";
}

function renderSample(s) {
  $("util").textContent = fmt(s.util, " %");
  $("power").textContent = fmt(s.power, " W", 1);
  const t = $("temp");
  t.textContent = fmt(s.temp, " °C");
  t.className = `value ${tempClass(s.temp)}`;
  $("vram").textContent = s.mem_total ? `${fmt(s.mem_used, "")} MiB` : "–";
  $("vram-foot").textContent = s.mem_total ? `of ${fmt(s.mem_total / 1024, " GiB", 1)}` : "";
  $("clk-gpu").textContent = fmt(s.clock_gpu, " MHz");
  $("clk-gpu-foot").textContent = s.clock_gpu_max ? `max ${fmt(s.clock_gpu_max, " MHz")}` : "";
  $("clk-vram").textContent = fmt(s.clock_mem, " MHz");
  $("clk-vram-foot").textContent = s.clock_mem_max ? `max ${fmt(s.clock_mem_max, " MHz")}` : "";
  $("clk-cpu").textContent = fmt(s.cpu_clk_max, " GHz", 2);
  $("clk-cpu-foot").textContent =
    `avg ${fmt(s.cpu_clk_avg, " GHz", 2)}` +
    (cpuMaxGhz ? ` · boost ≤ ${fmt(cpuMaxGhz, " GHz", 2)}` : "");
  $("clk-ram").textContent = ramSpeed || "–";
  $("fan").textContent = s.fan == null ? "auto" : fmt(s.fan, " %");
  // nvidia reports P-states + throttle reasons, amdgpu a DPM performance level.
  const bits = [];
  if (s.pstate) bits.push(`P-state ${s.pstate}`);
  if (s.perf) bits.push(`profile ${s.perf}`);
  bits.push(...(s.throttle || []).filter((n) => n !== "gpu-idle"));
  $("pstate-foot").textContent = bits.join(" · ");
  const ct = $("cpu-temp");
  ct.textContent = fmt(s.cpu_temp, " °C");
  ct.className = `value ${tempClass(s.cpu_temp)}`;
  $("cpu-foot").textContent = s.cpu_hot != null ? `hottest core ${fmt(s.cpu_hot, " °C")}` : "";
  $("cpu-power").textContent = fmt(s.cpu_power, " W", 1);
  $("cpu-clk-foot").textContent =
    `avg ${fmt(s.cpu_clk_avg, " GHz", 2)} · max ${fmt(s.cpu_clk_max, " GHz", 2)}` +
    (s.cpu_cap ? ` · ceiling ${fmt(s.cpu_cap, " GHz", 2)}` : "");
  const tot = $("total");
  tot.textContent = fmt(s.total, " W", 1);
  const over = budget > 0 && s.total >= budget;
  const near = budget > 0 && s.total >= budget * 0.85;
  tot.className = "value " + (over ? "hot" : near ? "warm" : "");
  if (budget > 0) {
    $("total-foot").textContent =
      (over ? "over budget — brownout risk on load steps. " : `budget ${budget} W. `) +
      "no rail sensors exist on this board; this estimate is the monitor";
  }

  const push = (arr, v, max) => { arr.push(v ?? 0); if (arr.length > max) arr.shift(); };
  push(hist.util, s.util, 300);
  push(hist.power, s.power, 300);
  push(hist.temp, s.temp, 300);
  push(hist.total, s.total, 300);
  drawSpark($("spark-util"), hist.util, { color: "#38bdf8", fill: "#38bdf822", min: 0, max: 100 });
  drawSpark($("spark-power"), hist.power, { color: "#fbbf24", fill: "#fbbf2422", min: 0 });
  drawSpark($("spark-temp"), hist.temp, { color: "#f87171", fill: "#f8717122", min: 20 });
  drawSpark($("spark-total"), hist.total, { color: "#a78bfa", fill: "#a78bfa22", min: 0, mark: budget || null });
}

function setCapControls(ctl) {
  const slider = $("cap-slider"), btn = $("cap-apply");
  if (ctl.cap_min > 0 && ctl.cap_max > ctl.cap_min) {
    capRange = [ctl.cap_min, ctl.cap_max];
    slider.min = ctl.cap_min; slider.max = ctl.cap_max;
    if (ctl.cap > 0) slider.value = Math.round(ctl.cap);
    $("cap-value").textContent = `${Math.round(ctl.cap)} W`;
    slider.disabled = false; btn.disabled = false;
    $("cap-foot").textContent =
      `min ${ctl.cap_min.toFixed(0)} W · max ${ctl.cap_max.toFixed(0)} W` +
      (ctl.cap_default ? ` · hardware default ${ctl.cap_default.toFixed(0)} W` : "");
  } else {
    slider.disabled = btn.disabled = true;
    $("cap-foot").textContent = "this card/driver does not expose a power cap";
  }
}

function renderCtl(ctl) {
  $("gpu-name").textContent =
    `${ctl.gpu} · driver ${ctl.driver}` + (ctl.host ? ` · ${ctl.host}` : "");
  budget = ctl.budget || 0;
  if (ctl.ram) ramSpeed = ctl.ram;
  setPill(ctl.ok ? "live" : "no data", ctl.ok ? "ok" : "bad");
  if (!sliderDragging) setCapControls(ctl);
  if (!cpuDragging) setCpuControls(ctl);
}

function setCpuControls(ctl) {
  const slider = $("cpu-slider"), btn = $("cpu-apply");
  if (!ctl.cpu_throttle) {
    slider.disabled = btn.disabled = true;
    $("cpu-value").textContent = "–";
    $("cpu-ctl-foot").textContent = "no writable cpufreq interface on this host";
    return;
  }
  slider.disabled = btn.disabled = false;
  slider.value = Math.round(ctl.cpu_target || 0);
  $("cpu-value").textContent = ctl.cpu_target > 0 ? `${Math.round(ctl.cpu_target)} °C` : "off";
  $("cpu-ctl-foot").textContent =
    `ceiling ${ctl.cpu_min_ghz.toFixed(2)}–${ctl.cpu_max_ghz.toFixed(2)} GHz · ` +
    (ctl.cpu_cap ? `currently throttled to ≤ ${ctl.cpu_cap.toFixed(2)} GHz` : "currently no limit");
}

let sliderDragging = false;
$("cap-slider").addEventListener("input", () => {
  $("cap-value").textContent = `${$("cap-slider").value} W`;
  sliderDragging = true;
});
$("cap-slider").addEventListener("change", () => { sliderDragging = false; });
$("cap-apply").addEventListener("click", async () => {
  const cap = Number($("cap-slider").value);
  const r = await fetch("/api/power", {
    method: "POST",
    body: JSON.stringify({ cap }),
  });
  const j = await r.json();
  $("cap-foot").textContent = j.ok ? j.message : `error: ${j.error}`;
  if (j.ok) { setCapControls(j.control); }
});

let cpuDragging = false;
$("cpu-slider").addEventListener("input", () => {
  const v = Number($("cpu-slider").value);
  $("cpu-value").textContent = v === 0 ? "off" : `${v} °C`;
  cpuDragging = true;
});
$("cpu-slider").addEventListener("change", () => { cpuDragging = false; });
$("cpu-apply").addEventListener("click", async () => {
  let v = Number($("cpu-slider").value);
  if (v > 0 && v < 40) { v = 40; $("cpu-slider").value = 40; } // 0 or >= 40 °C
  const r = await fetch("/api/cpu-target", {
    method: "POST",
    body: JSON.stringify({ target: v }),
  });
  const j = await r.json();
  $("cpu-ctl-foot").textContent = j.ok ? j.message : `error: ${j.error}`;
  if (j.ok) { setCpuControls(j.control); }
});

$("fah-link").href = `${location.protocol}//${location.hostname}:7396/`;

// bootstrap + stream
(async () => {
  try {
    const j = await (await fetch("/api/snapshot")).json();
    renderCtl(j.control);
    cpuMaxGhz = j.cpu && j.cpu.max_ghz ? j.cpu.max_ghz : null;
    (j.history || []).forEach((s) => {
      hist.util.push(s.util ?? 0); hist.power.push(s.power ?? 0);
      hist.temp.push(s.temp ?? 0); hist.total.push(s.total ?? 0);
      if (hist.util.length > 300) { hist.util.shift(); hist.power.shift(); hist.temp.shift(); hist.total.shift(); }
    });
    renderSample(j.current);
  } catch (e) { setPill("offline", "bad"); }

  const es = new EventSource("/api/stream");
  es.onmessage = (m) => {
    try { renderSample(JSON.parse(m.data)); } catch (_) {}
    setPill("live", "ok");
  };
  es.onerror = () => setPill("reconnecting…", "");
})();
