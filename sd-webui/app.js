"use strict";

const $ = (id) => document.getElementById(id);
const API = "/sd-api/sdapi/v1/txt2img";
const SETTINGS_KEY = "sd-studio-settings";

const byId = (id) => $(id);

function loadSettings() {
  try {
    const s = JSON.parse(localStorage.getItem(SETTINGS_KEY) || "{}");
    for (const [k, v] of Object.entries(s)) {
      const el = byId(k);
      if (el && typeof v === "string") el.value = v;
    }
  } catch (_) { /* ignore corrupt settings */ }
}

function saveSettings() {
  const s = {};
  for (const id of ["prompt", "neg-prompt", "steps", "cfg", "sampler", "width", "height", "seed", "batch"]) {
    s[id] = byId(id).value;
  }
  localStorage.setItem(SETTINGS_KEY, JSON.stringify(s));
}

function setStatus(text, cls) {
  const el = byId("server-status");
  el.textContent = text;
  el.className = "status" + (cls ? " " + cls : "");
}

function setStatusline(text, isErr) {
  const el = byId("statusline");
  el.textContent = text;
  el.className = isErr ? "err" : "muted";
}

async function pingServer() {
  try {
    const r = await fetch("/sd-api/v1/models", { signal: AbortSignal.timeout(3000) });
    setStatus(r.ok ? "server up" : "server: HTTP " + r.status, r.ok ? "ok" : "bad");
  } catch (_) {
    setStatus("server down", "bad");
  }
}

async function generate() {
  const btn = byId("generate");
  const prompt = byId("prompt").value.trim();
  if (!prompt) {
    setStatusline("Please enter a prompt.", true);
    byId("prompt").focus();
    return;
  }

  const steps = Math.max(1, Math.min(100, parseInt(byId("steps").value, 10) || 30));
  const cfg = Math.max(1, Math.min(20, parseFloat(byId("cfg").value) || 6));
  const width = Math.max(256, Math.min(2048, parseInt(byId("width").value, 10) || 1024));
  const height = Math.max(256, Math.min(2048, parseInt(byId("height").value, 10) || 1024));
  const seed = parseInt(byId("seed").value, 10);
  const batch = Math.max(1, Math.min(4, parseInt(byId("batch").value, 10) || 1));
  const sampler = byId("sampler").value;

  saveSettings();

  const payload = {
    prompt,
    negative_prompt: byId("neg-prompt").value.trim(),
    steps,
    cfg_scale: cfg,
    width,
    height,
    seed: Number.isFinite(seed) ? seed : -1,
    sampler_name: sampler,
    batch_size: batch,
  };

  btn.disabled = true;
  btn.textContent = "Generating…";
  setStatusline("diffusing " + width + "×" + height + ", " + steps + " steps…");
  byId("result").classList.add("hidden");
  byId("empty").classList.add("hidden");

  const t0 = performance.now();
  let resp;
  try {
    resp = await fetch(API, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch (e) {
    setStatusline("Request failed: " + e.message, true);
    btn.disabled = false;
    btn.textContent = "Generate";
    return;
  }

  const dt = (performance.now() - t0) / 1000;

  if (!resp.ok) {
    let detail = "HTTP " + resp.status;
    try {
      const j = await resp.json();
      if (j.error) detail = typeof j.error === "string" ? j.error : JSON.stringify(j.error);
      else if (j.detail) detail = JSON.stringify(j.detail);
    } catch (_) { /* keep status code */ }
    setStatusline("Generation failed (" + detail + ").", true);
    btn.disabled = false;
    btn.textContent = "Generate";
    return;
  }

  let imgs;
  try {
    const j = await resp.json();
    imgs = j.images || [];
  } catch (e) {
    setStatusline("Bad response from server.", true);
    btn.disabled = false;
    btn.textContent = "Generate";
    return;
  }

  const img = byId("image");
  const meta = byId("meta");
  if (imgs.length > 0) {
    img.src = "data:image/png;base64," + imgs[0];
    byId("download").href = img.src;
    byId("download").download = "sd-" + seed + "-" + width + "x" + height + ".png";
    meta.textContent = imgs.length + " image" + (imgs.length > 1 ? "s" : "") +
      " · " + width + "×" + height + " · " + steps + " steps · cfg " + cfg +
      " · " + sampler + " · seed " + seed + " · " + dt.toFixed(1) + " s";
    byId("result").classList.remove("hidden");
  } else {
    setStatusline("Server returned no images.", true);
  }

  btn.disabled = false;
  btn.textContent = "Generate";
  if (imgs.length > 0) setStatusline("Done in " + dt.toFixed(1) + " s.");
}

byId("generate").addEventListener("click", generate);

byId("dice").addEventListener("click", () => {
  byId("seed").value = Math.floor(Math.random() * 0x7fffffff);
});

for (const b of document.querySelectorAll(".presets .mini-btn")) {
  b.addEventListener("click", () => {
    byId("width").value = b.dataset.w;
    byId("height").value = b.dataset.h;
  });
}

document.addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === "Enter") generate();
});

loadSettings();
pingServer();
setInterval(pingServer, 30000);
