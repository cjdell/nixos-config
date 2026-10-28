// fah-panel frontend: bootstrap from /api/snapshot, then follow /api/stream.
// One live card + one power-cap slider PER GPU (control.gpus / sample.gpus);
// the CPU block and the DC total stay machine-wide.

const $ = (id) => document.getElementById(id);
const fmt = (v, unit, digits = 0) =>
  v == null ? "–" : `${Number(v).toFixed(digits)}${unit}`;

// Per-GPU accent colours, index-picked; cards and sliders share one colour
// so a GPU is recognisable across the page.
const COLORS = ["#38bdf8", "#fbbf24", "#34d399", "#f87171", "#a78bfa", "#f472b6"];

let budget = 0; // W; 0 = off (from --budget via /api/snapshot control)
let cpuMaxGhz = null; // boost ceiling from static cpu info
let ramSpeed = ""; // SMBIOS RAM bus speed from control
let cpuDragging = false;

// One block per GPU: its stat card (values + power sparkline) and its cap
// slider row, both built lazily once the GPU count is known.
const gpuBlocks = [];

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

// ---------------------------------------------------------------------------
// Per-GPU blocks
// ---------------------------------------------------------------------------

function buildGpuBlock(index) {
  const color = COLORS[index % COLORS.length];
  const card = document.createElement("div");
  card.className = "card gpu-card";
  card.innerHTML = `
    <div class="label"><span class="dot" style="background:${color}"></span><span class="gname"></span></div>
    <div class="value"><span class="power">–</span><span class="unit">W</span></div>
    <canvas></canvas>
    <div class="gkv">
      <div><span class="label">load</span><span class="gv util">–</span></div>
      <div><span class="label">temp</span><span class="gv temp">–</span></div>
      <div><span class="label">fan</span><span class="gv fan">–</span></div>
      <div><span class="label">vram</span><span class="gv vram">–</span></div>
      <div><span class="label">core clk</span><span class="gv clk">–</span></div>
    </div>
    <div class="foot state">–</div>`;
  $("gpu-strip").appendChild(card);

  const row = document.createElement("div");
  row.className = "cap-row";
  row.innerHTML = `
    <div class="label"><span class="dot" style="background:${color}"></span><span class="gname">GPU ${index}</span> power cap</div>
    <div class="cap-inner">
      <input type="range" min="0" max="200" step="1">
      <span class="value small cap-value">–</span>
      <button>apply</button>
    </div>
    <div class="foot cap-foot"></div>`;
  $("cap-rows").appendChild(row);

  const q = (sel, root) => (root || card).querySelector(sel);
  const rq = (sel) => row.querySelector(sel);
  const block = {
    index,
    color,
    canvas: q("canvas"),
    power: [], // power history, minutes at the sample interval
    nameEl: q(".gname"),
    powerEl: q(".power"),
    utilEl: q(".util"),
    tempEl: q(".temp"),
    fanEl: q(".fan"),
    vramEl: q(".vram"),
    clkEl: q(".clk"),
    stateEl: q(".state"),
    slider: rq("input"),
    capValue: rq(".cap-value"),
    apply: rq("button"),
    capFoot: rq(".cap-foot"),
    nameRowEl: rq(".gname"),
    dragging: false,
  };
  block.slider.addEventListener("input", () => {
    block.capValue.textContent = `${block.slider.value} W`;
    block.dragging = true;
  });
  block.slider.addEventListener("change", () => { block.dragging = false; });
  block.apply.addEventListener("click", async () => {
    const cap = Number(block.slider.value);
    const r = await fetch("/api/power", {
      method: "POST",
      body: JSON.stringify({ gpu: block.index, cap }),
    });
    const j = await r.json();
    block.capFoot.textContent = j.ok ? j.message : `error: ${j.error}`;
    if (j.ok) renderCtl(j.control);
  });
  return block;
}

function ensureGpus(n) {
  while (gpuBlocks.length < n) gpuBlocks.push(buildGpuBlock(gpuBlocks.length));
}

function setCapRow(block, g) {
  if (g.name) {
    block.nameRowEl.textContent = g.name;
    block.nameEl.textContent = g.name;
  }
  if (g.cap_min > 0 && g.cap_max > g.cap_min) {
    block.slider.min = g.cap_min;
    block.slider.max = g.cap_max;
    if (!block.dragging) {
      block.slider.value = Math.round(g.cap ?? g.cap_min);
      block.capValue.textContent = g.cap != null ? `${Math.round(g.cap)} W` : "–";
    }
    block.slider.disabled = false;
    block.apply.disabled = false;
    block.capFoot.textContent =
      `min ${g.cap_min.toFixed(0)} W · max ${g.cap_max.toFixed(0)} W` +
      (g.cap_default ? ` · hardware default ${g.cap_default.toFixed(0)} W` : "");
  } else {
    block.slider.disabled = block.apply.disabled = true;
    block.capFoot.textContent = "this card/driver does not expose a power cap";
  }
}

function renderCtl(ctl) {
  const gpus = ctl.gpus || [];
  ensureGpus(gpus.length);
  const names = gpus.map((g) => g.name).filter(Boolean);
  $("gpu-name").textContent =
    (names.join(" + ") || "GPU") +
    (gpus[0] && gpus[0].driver ? ` · driver ${gpus[0].driver}` : "") +
    (ctl.host ? ` · ${ctl.host}` : "");
  budget = ctl.budget || 0;
  if (ctl.ram) ramSpeed = ctl.ram;
  setPill(ctl.ok ? "live" : "no data", ctl.ok ? "ok" : "bad");
  gpus.forEach((g, i) => setCapRow(gpuBlocks[i], g));
  if (!cpuDragging) setCpuControls(ctl);
}

function renderGpu(block, g) {
  if (!g) return;
  block.powerEl.textContent = fmt(g.power, "", 1);
  block.utilEl.textContent = fmt(g.util, " %");
  block.tempEl.textContent = fmt(g.temp, " °C");
  block.tempEl.className = `gv temp ${tempClass(g.temp)}`;
  block.fanEl.textContent = g.fan == null ? "auto" : fmt(g.fan, " %");
  block.vramEl.textContent = g.mem_total ? fmt(g.mem_used / 1024, " GiB", 1) : "–";
  block.clkEl.textContent = fmt(g.clock_gpu, " MHz");
  // nvidia reports P-states + throttle reasons, amdgpu a DPM performance level.
  const bits = [];
  if (g.pstate) bits.push(`P-state ${g.pstate}`);
  if (g.perf) bits.push(`profile ${g.perf}`);
  bits.push(...(g.throttle || []).filter((n) => n !== "gpu-idle"));
  block.stateEl.textContent = bits.join(" · ");

  block.power.push(g.power ?? 0);
  if (block.power.length > 300) block.power.shift();
  drawSpark(block.canvas, block.power, {
    color: block.color,
    fill: block.color + "22",
    min: 0,
  });
}

function renderSample(s) {
  const gpus = s.gpus || [];
  ensureGpus(gpus.length);
  gpus.forEach((g, i) => renderGpu(gpuBlocks[i], g));

  $("clk-cpu").textContent = fmt(s.cpu_clk_max, " GHz", 2);
  $("clk-cpu-foot").textContent =
    `avg ${fmt(s.cpu_clk_avg, " GHz", 2)}` +
    (cpuMaxGhz ? ` · boost ≤ ${fmt(cpuMaxGhz, " GHz", 2)}` : "");
  $("clk-ram").textContent = ramSpeed || "–";
  const ct = $("cpu-temp");
  ct.textContent = fmt(s.cpu_temp, " °C");
  ct.className = `value ${tempClass(s.cpu_temp)}`;
  $("cpu-foot").textContent =
    s.cpu_hot != null ? `hottest core ${fmt(s.cpu_hot, " °C")}` : "";
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
  totalHist.push(s.total ?? 0);
  if (totalHist.length > 300) totalHist.shift();
  drawSpark($("spark-total"), totalHist, {
    color: "#a78bfa",
    fill: "#a78bfa22",
    min: 0,
    mark: budget || null,
  });
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
      (s.gpus || []).forEach((g, i) => {
        ensureGpus(i + 1);
        gpuBlocks[i].power.push(g.power ?? 0);
        if (gpuBlocks[i].power.length > 300) gpuBlocks[i].power.shift();
      });
      totalHist.push(s.total ?? 0);
      if (totalHist.length > 300) totalHist.shift();
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
