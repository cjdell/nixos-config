/* Llama Log Viewer — vanilla JS frontend. No dependencies. */

const ROLE_COLORS = {
  system: "#8b5cf6",
  user: "#0ea5e9",
  assistant: "#22c55e",
  tool: "#f59e0b",
};

const state = {
  expanded: new Set(), // node ids currently expanded in the tree
  selected: null,      // selected node id
  searchMode: false,
  refreshTimer: null,
};

const $ = (sel) => document.querySelector(sel);

async function api(path) {
  const res = await fetch(path);
  if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
  return res.json();
}

function esc(s) {
  const div = document.createElement("div");
  div.textContent = s;
  return div.innerHTML;
}

function roleBadge(role) {
  const color = ROLE_COLORS[role] || "#64748b";
  return `<span class="badge" style="background:${color}22;color:${color};border-color:${color}55">${esc(role)}</span>`;
}

function fmtSize(n) {
  if (n >= 1 << 20) return (n / (1 << 20)).toFixed(1) + " MB";
  if (n >= 1 << 10) return (n / (1 << 10)).toFixed(1) + " KB";
  return n + " B";
}

function fmtTime(ts) {
  const d = new Date(ts * 1000);
  return d.toLocaleString();
}

// ---------------------------------------------------------------------------
// Header / stats
// ---------------------------------------------------------------------------

async function refreshStats() {
  try {
    const s = await api("api/stats");
    $("#stats").innerHTML =
      `<span title="API call log files">${s.files} files</span>` +
      `<span title="Unique messages (shared context deduplicated)">${s.unique_messages} messages</span>` +
      `<span title="Distinct first messages (system prompts etc.)">${s.roots} roots</span>` +
      `<span class="muted">${fmtTime(s.updated)}</span>`;
    $("#tree-count").textContent = s.roots
      ? `${s.roots} root${s.roots === 1 ? "" : "s"}`
      : "";
    return s;
  } catch (e) {
    $("#stats").innerHTML = `<span class="err">Failed to load: ${esc(e.message)}</span>`;
    return null;
  }
}

// ---------------------------------------------------------------------------
// Tree
// ---------------------------------------------------------------------------

async function renderTree() {
  const tree = $("#tree");
  tree.innerHTML = "";
  const data = await api("api/roots");
  if (!data.roots.length) {
    tree.innerHTML = `<div class="muted">No log files found.</div>`;
    return;
  }
  const rootEl = document.createElement("div");
  for (const n of data.roots) {
    const row = nodeRow(n, 0);
    rootEl.appendChild(row);
    // Restore expansion state after a re-render (30s poll / refresh button)
    if (state.expanded.has(n.id)) {
      await expandRow(row, n);
    }
  }
  tree.appendChild(rootEl);
  await refreshStats();
}

function nodeRow(node, depth) {
  const row = document.createElement("div");
  row.className = "tree-row";
  row.dataset.id = node.id;
  row.style.paddingLeft = `${depth * 18 + 8}px`;

  const hasChildren = node.children > 0;
  const chevron = document.createElement("span");
  chevron.className = "chevron" + (hasChildren ? "" : " dim");
  chevron.textContent = state.expanded.has(node.id) ? "▾" : "▸";
  if (!hasChildren) chevron.textContent = "·";

  const label = document.createElement("span");
  label.className = "tree-label";
  label.innerHTML = roleBadge(node.role);
  const preview = document.createElement("span");
  preview.className = "tree-preview";
  preview.textContent = node.preview;
  label.appendChild(preview);

  const counts = document.createElement("span");
  counts.className = "tree-counts";
  counts.innerHTML =
    `<span class="chip" title="API calls passing through this context">${node.count}</span>` +
    (node.ends > 0
      ? `<span class="chip leaf" title="Files ending here (complete API calls)">⚑ ${node.ends}</span>`
      : "") +
    (node.children > 0
      ? `<span class="chip br" title="Divergent branches">${node.children}↳</span>`
      : "");

  row.append(chevron, label, counts);

  if (hasChildren) {
    const drill = document.createElement("button");
    drill.className = "drill-btn";
    drill.title = "Expand to the deepest thread in this branch";
    drill.textContent = "⇣";
    drill.addEventListener("click", async (ev) => {
      ev.stopPropagation();
      await drillDeep(row, node);
    });
    row.appendChild(drill);
  }

  chevron.addEventListener("click", async (ev) => {
    ev.stopPropagation();
    await toggleExpand(row, node);
  });

  row.addEventListener("click", async () => {
    await selectNode(node);
    // also expand when selecting
    if (hasChildren && !state.expanded.has(node.id)) {
      await toggleExpand(row, node);
    }
  });

  return row;
}

async function expandRow(row, node) {
  const id = node.id;
  state.expanded.add(id);
  row.querySelector(".chevron").textContent = "▾";
  // Reuse a previously built container (hidden on collapse) if present
  let childWrap = row._childWrap;
  if (childWrap) {
    childWrap.style.display = "";
    return;
  }
  childWrap = document.createElement("div");
  childWrap.className = "tree-children";
  row._childWrap = childWrap;
  row.after(childWrap);
  childWrap.innerHTML = `<div class="muted pad">loading…</div>`;
  const data = await api(`api/node?id=${id}`);
  childWrap.innerHTML = "";
  const childDepth = parseInt(row.style.paddingLeft, 10) / 18 + 1;
  for (const c of data.children) {
    const childRow = nodeRow(c, childDepth);
    childWrap.appendChild(childRow);
    // Restore nested expansion state as well
    if (state.expanded.has(c.id)) {
      await expandRow(childRow, c);
    }
  }
  if (!data.children.length) {
    childWrap.innerHTML = `<div class="muted pad">no further branches</div>`;
  }
}

function collapseRow(row, node) {
  const id = node.id;
  state.expanded.delete(id);
  row.querySelector(".chevron").textContent = "▸";
  if (row._childWrap) {
    row._childWrap.style.display = "none";
  }
}

async function toggleExpand(row, node) {
  if (state.expanded.has(node.id)) {
    collapseRow(row, node);
  } else {
    await expandRow(row, node);
  }
}

// Expand every node along the path to the deepest leaf below `node`, so the
// longest thread in this branch is fully revealed without clicking each arrow.
async function drillDeep(row, node) {
  const data = await api(`api/deepest?id=${node.id}`);
  const path = data.path;
  if (!path.length) return;
  // Walk down the path, expanding each level. Reuse the passed-in row for the
  // first step; subsequent rows are found inside the previously-built childWrap.
  let curRow = row;
  for (let i = 0; i < path.length; i++) {
    const s = path[i];
    if (i === 0) {
      await expandRow(curRow, s);
      continue;
    }
    const childRow = curRow._childWrap
      ? curRow._childWrap.querySelector(`.tree-row[data-id="${s.id}"]`)
      : null;
    if (!childRow) break;
    await expandRow(childRow, s);
    curRow = childRow;
  }
  // Select the deepest node so the detail panel shows the full thread
  await selectNode(path[path.length - 1]);
}

// ---------------------------------------------------------------------------
// Detail panel
// ---------------------------------------------------------------------------

async function selectNode(node) {
  state.selected = node.id;
  state.searchMode = false;
  highlightTreeSelection(node.id);
  const detail = $("#detail");
  detail.classList.remove("hidden");
  $("#detail-empty").classList.add("hidden");

  detail.innerHTML = `<div class="muted pad">loading…</div>`;

  const [pathData, contentData] = await Promise.all([
    api(`api/path?id=${node.id}`),
    api(`api/content?id=${node.id}`),
  ]);

  await renderDetail(node, pathData, contentData);
}

function highlightTreeSelection(id) {
  document.querySelectorAll(".tree-row").forEach((r) => {
    r.classList.toggle("selected", parseInt(r.dataset.id, 10) === id);
  });
}

async function renderDetail(node, pathData, contentData) {
  const detail = $("#detail");
  const steps = pathData.steps;

  // Breadcrumb
  const crumb = document.createElement("div");
  crumb.className = "breadcrumb";
  steps.forEach((s, i) => {
    if (i > 0) crumb.appendChild(document.createTextNode(" / "));
    const a = document.createElement("button");
    a.className = "crumb-link";
    a.textContent = `${s.role}(${s.count})`;
    a.title = s.preview;
    a.addEventListener("click", () => navigateTo(s.id));
    crumb.appendChild(a);
  });
  detail.innerHTML = "";
  detail.appendChild(crumb);

  // Message content of the selected node
  const msgCard = document.createElement("div");
  msgCard.className = "card";
  const head = document.createElement("div");
  head.className = "card-head";
  head.innerHTML =
    roleBadge(contentData.role) +
    `<span class="muted">message ${steps.length} · ${fmtSize(contentData.content.length)} · ` +
    `shared by ${node.count} API call${node.count === 1 ? "" : "s"}` +
    (node.ends > 0 ? ` · ends ${node.ends} file${node.ends === 1 ? "" : "s"} here` : "") +
    `</span>`;
  msgCard.appendChild(head);
  const pre = document.createElement("pre");
  pre.className = "msg-content";
  pre.textContent = contentData.content;
  msgCard.appendChild(pre);
  detail.appendChild(msgCard);

  // Complete conversation from root to this node
  const convCard = document.createElement("div");
  convCard.className = "card";
  const convHead = document.createElement("div");
  convHead.className = "card-head";
  convHead.innerHTML = `<strong>Conversation</strong> <span class="muted">(path from root to here)</span>`;
  convCard.appendChild(convHead);
  for (let i = 0; i < steps.length; i++) {
    convCard.appendChild(conversationStep(steps, i));
  }
  detail.appendChild(convCard);

  // Files ending at this node
  if (node.ends > 0) {
    const filesCard = document.createElement("div");
    filesCard.className = "card";
    const fHead = document.createElement("div");
    fHead.className = "card-head";
    fHead.innerHTML = `<strong>Files ending here</strong> <span class="muted">(${node.ends} complete API calls)</span>`;
    filesCard.appendChild(fHead);
    const list = document.createElement("div");
    list.className = "file-list";
    const files = await api(`api/files?node=${node.id}`);
    for (const f of files.files) {
      const row = document.createElement("div");
      row.className = "file-row";
      const name = document.createElement("button");
      name.className = "file-name";
      name.textContent = f.name;
      name.addEventListener("click", () => openRaw(f.name));
      const meta = document.createElement("span");
      meta.className = "muted";
      meta.textContent = `${fmtSize(f.size)} · ${fmtTime(f.mtime)}`;
      row.append(name, meta);
      list.appendChild(row);
    }
    filesCard.appendChild(list);
    detail.appendChild(filesCard);
  }
}

function conversationStep(steps, i) {
  const s = steps[i];
  const step = document.createElement("div");
  step.className = `conv-step role-${s.role}`;

  const header = document.createElement("div");
  header.className = "conv-header";
  header.innerHTML =
    roleBadge(s.role) +
    `<span class="muted">#${i + 1}</span>` +
    `<span class="muted">${fmtSize(s.length)}</span>` +
    `<button class="load-full" data-id="${s.id}">show full</button>`;

  const body = document.createElement("div");
  body.className = "conv-body";
  body.textContent = s.preview;

  header.querySelector(".load-full").addEventListener("click", async () => {
    const btn = header.querySelector(".load-full");
    btn.disabled = true;
    btn.textContent = "loading…";
    const full = await api(`api/content?id=${s.id}`);
    body.textContent = full.content;
    btn.remove();
  });

  step.append(header, body);
  return step;
}

async function navigateTo(id) {
  const p = await api(`api/path?id=${id}`);
  const summary = p.steps[p.steps.length - 1];
  await selectNode({ ...summary, id });
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

let searchTimeout = null;
$("#search").addEventListener("input", () => {
  clearTimeout(searchTimeout);
  searchTimeout = setTimeout(doSearch, 250);
});

async function doSearch() {
  const q = $("#search").value.trim();
  if (!q) {
    if (state.searchMode) {
      state.searchMode = false;
      renderTree();
    }
    return;
  }
  state.searchMode = true;
  const detail = $("#detail");
  detail.classList.remove("hidden");
  $("#detail-empty").classList.add("hidden");
  detail.innerHTML = `<div class="muted pad">searching…</div>`;
  const data = await api(`api/search?q=${encodeURIComponent(q)}`);
  if (!data.results.length) {
    detail.innerHTML = `<div class="placeholder"><p>No messages contain “${esc(q)}”.</p></div>`;
    return;
  }
  const wrap = document.createElement("div");
  wrap.className = "card";
  const head = document.createElement("div");
  head.className = "card-head";
  head.innerHTML = `<strong>Search results</strong> <span class="muted">(${data.results.length})</span>`;
  wrap.appendChild(head);
  for (const r of data.results) {
    const row = document.createElement("div");
    row.className = "search-row";
    row.innerHTML = roleBadge(r.role);
    const btn = document.createElement("button");
    btn.className = "file-name";
    btn.textContent = r.preview;
    btn.addEventListener("click", () => navigateTo(r.id));
    const meta = document.createElement("span");
    meta.className = "muted";
    meta.textContent = `${r.count} calls · ${r.children} branches` + (r.ends ? ` · ⚑${r.ends} ends` : "");
    row.append(btn, meta);
    wrap.appendChild(row);
  }
  detail.innerHTML = "";
  detail.appendChild(wrap);
}

// ---------------------------------------------------------------------------
// Raw file modal
// ---------------------------------------------------------------------------

async function openRaw(name) {
  $("#raw-modal").classList.remove("hidden");
  $("#raw-title").textContent = name;
  $("#raw-content").textContent = "loading…";
  const data = await api(`api/raw?file=${encodeURIComponent(name)}`);
  $("#raw-content").textContent = data.content;
}

$("#raw-close").addEventListener("click", () => $("#raw-modal").classList.add("hidden"));
$("#raw-modal").addEventListener("click", (ev) => {
  if (ev.target.id === "raw-modal") $("#raw-modal").classList.add("hidden");
});

// ---------------------------------------------------------------------------
// Refresh
// ---------------------------------------------------------------------------

let lastFileCount = null;

$("#refresh").addEventListener("click", async () => {
  await renderTree();
  if (state.selected != null && !state.searchMode) {
    // re-select current node so counts refresh
    const p = await api(`api/path?id=${state.selected}`);
    const summary = p.steps[p.steps.length - 1];
    await selectNode(summary);
  }
});

$("#collapse-all").addEventListener("click", async () => {
  state.expanded.clear();
  await renderTree();
});

// Poll every 30s so new log files show up automatically
setInterval(async () => {
  const s = await refreshStats();
  if (!s) return;
  // Re-render the tree if the underlying data changed
  if (s.files !== lastFileCount) {
    lastFileCount = s.files;
    await renderTree();
  }
}, 30000);

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

(async function init() {
  const s = await refreshStats();
  lastFileCount = s ? s.files : null;
  await renderTree();
})();
