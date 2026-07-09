/* localai Control Center - wires the Claude Design comp to the live API. */

const ICONS = {
  bolt: '<path d="M13 2 3 14h7l-1 8 10-12h-7l1-8z" fill="currentColor" stroke="none"/>',
  play: '<polygon points="6,4 20,12 6,20" fill="currentColor" stroke="none"/>',
  playline: '<polygon points="6,4 20,12 6,20"/>',
  shuffle: '<polyline points="16 3 21 3 21 8"/><line x1="4" y1="20" x2="21" y2="3"/><polyline points="21 16 21 21 16 21"/><line x1="15" y1="15" x2="21" y2="21"/><line x1="4" y1="4" x2="9" y2="9"/>',
  chat: '<path d="M21 11.5a8.4 8.4 0 0 1-8.9 8.4 8.9 8.9 0 0 1-3.8-.9L3 21l1.9-5.7A8.4 8.4 0 1 1 21 11.5z"/>',
  code: '<polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/>',
  activity: '<polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>',
  zap: '<polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/>',
  battery: '<rect x="1" y="6" width="18" height="12" rx="2"/><line x1="23" y1="13" x2="23" y2="11"/>',
  terminal: '<polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/>',
  globe: '<circle cx="12" cy="12" r="9"/><line x1="3" y1="12" x2="21" y2="12"/><path d="M12 3a14 14 0 0 1 3.5 9A14 14 0 0 1 12 21a14 14 0 0 1-3.5-9A14 14 0 0 1 12 3z"/>',
  shield: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>',
  flask: '<path d="M9 2v6l-6 10a2 2 0 0 0 2 3h14a2 2 0 0 0 2-3l-6-10V2"/><line x1="9" y1="2" x2="15" y2="2"/>',
  refresh: '<polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.5 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.65 4.36A9 9 0 0 0 20.5 15"/>',
  search: '<circle cx="11" cy="11" r="7"/><line x1="21" y1="21" x2="16.5" y2="16.5"/>',
  archive: '<polyline points="21 8 21 21 3 21 3 8"/><rect x="1" y="3" width="22" height="5"/><line x1="10" y1="12" x2="14" y2="12"/>',
  gamepad: '<rect x="2" y="6" width="20" height="12" rx="3"/><line x1="6" y1="12" x2="10" y2="12"/><line x1="8" y1="10" x2="8" y2="14"/><circle cx="15" cy="13" r="1"/><circle cx="18" cy="11" r="1"/>',
  image: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/>',
  copy: '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  chevronR: '<polyline points="9 6 15 12 9 18"/>',
  arrowUpRight: '<line x1="7" y1="17" x2="17" y2="7"/><polyline points="7 7 17 7 17 17"/>',
  ok: '<path d="M20 6 9 17l-5-5"/>',
  power: '<path d="M12 4v8"/><path d="M7.6 7a6 6 0 1 0 8.8 0"/>',
  clipboard: '<rect x="8" y="3" width="8" height="4" rx="1"/><path d="M9 5H7a1 1 0 0 0-1 1v13a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1h-2"/><path d="M9 13l2 2 4-4"/>',
  lock: '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="3" x2="12" y2="15"/>',
  cpu: '<rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><line x1="9" y1="1" x2="9" y2="4"/><line x1="15" y1="1" x2="15" y2="4"/><line x1="9" y1="20" x2="9" y2="23"/><line x1="15" y1="20" x2="15" y2="23"/><line x1="20" y1="9" x2="23" y2="9"/><line x1="20" y1="14" x2="23" y2="14"/><line x1="1" y1="9" x2="4" y2="9"/><line x1="1" y1="14" x2="4" y2="14"/>',
  drive: '<line x1="22" y1="12" x2="2" y2="12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><line x1="6" y1="16" x2="6.01" y2="16"/><line x1="10" y1="16" x2="10.01" y2="16"/>',
};

const CHECK_ICON = {
  start: "playline", "start-dry-run": "flask", "nanobrowser-proxy": "shuffle",
  cherry: "chat", agent: "code", health: "activity", perf: "zap",
  power: "battery", terminal: "terminal", anywhere: "globe", firewall: "shield",
  "update-check": "refresh", "update-now": "refresh", "model-scout": "search",
  "scout-prepare": "download",
  backup: "archive", "game-mode": "gamepad", "game-dry-run": "gamepad",
  stop: "power", doctor: "clipboard",
};
const CHECK_VERB = {
  start: "Start", "nanobrowser-proxy": "Start", cherry: "Open", agent: "Open",
  stop: "Stop",
};
const DANGER = new Set(["stop", "game-mode"]);
const GROUP_ORDER = ["Everyday", "Status", "Maintenance"];

const state = {
  checks: new Map(),
  links: [],
  pending: [],
  selected: "health",
  reports: new Map(),
  running: new Set(),
  folds: { details: false, passing: false, raw: false },
  runtime: null,
  checkedAt: null,
  models: null,
  history: { vram: [], gpu: [] },
  system: null,
  sysHistory: { cpu: [], ram: [], gpu: [], vram: [] },
  scout: null, // { generated, groups, lines? } from /api/scout[/refresh]
  scoutDropped: new Set(), // category ids whose dropped-for-VRAM fold is open
  scoutPrepare: new Map(), // category id -> { status, lines } after a Prepare launch
};

const HISTORY_MAX = 48; // 48 samples x 15s poll = 12 minutes of telemetry

const $ = (s) => document.querySelector(s);

function svg(name, size = 16, strokeWidth = 2) {
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${strokeWidth}" stroke-linecap="round" stroke-linejoin="round">${ICONS[name] || ICONS.terminal}</svg>`;
}

/* ---------------------------------------------------------- report parsing */

function parseReport(lines) {
  const entries = [];
  for (const line of lines || []) {
    const m = /^\[(OK|WARN|FAIL)\]\s+(.*)$/.exec(line);
    if (m) {
      const rest = m[2];
      const split = /^(\S.*?)\s{2,}(.*)$/.exec(rest);
      entries.push({
        status: m[1].toLowerCase(),
        label: split ? split[1] : rest,
        detail: split ? split[2] : "",
      });
    } else if (entries.length && line.trim() && !line.startsWith("====")) {
      const last = entries[entries.length - 1];
      last.detail = (last.detail ? last.detail + " " : "") + line.trim();
    }
  }
  return entries;
}

function countBy(entries) {
  const c = { ok: 0, warn: 0, fail: 0 };
  for (const e of entries) c[e.status] += 1;
  return c;
}

/* Model Scout renders from structured /api/scout JSON (a best pick per task
   category), not by scraping console text. See renderScoutView below. */
function scoutFitClass(verdict) {
  return `fit-badge ${(verdict || "").toLowerCase()}`;
}

function buildScoutPick(pick, { top } = {}) {
  const row = document.createElement("div");
  row.className = "scout-row" + (top ? " top" : "");
  const fit = document.createElement("span");
  fit.className = scoutFitClass(pick.verdict);
  fit.textContent = pick.verdict || "—";
  const name = document.createElement("span");
  name.className = "scout-name";
  name.textContent = pick.name;
  name.title = pick.id || pick.name;
  const gb = document.createElement("span");
  gb.className = "scout-gb";
  gb.textContent = pick.sizeGb != null ? `${pick.sizeGb} GB` : "—";
  const why = document.createElement("span");
  why.className = "scout-why";
  why.textContent = pick.why || "";
  row.append(fit, name, gb, why);
  if (pick.curated) {
    const chip = document.createElement("span");
    chip.className = "scout-chip";
    chip.textContent = "curated";
    row.append(chip);
  }
  if (pick.reasoning) {
    const chip = document.createElement("span");
    chip.className = "think-chip";
    chip.textContent = "thinking";
    row.append(chip);
  }
  return row;
}

function buildScoutCategory(catId, group) {
  const section = document.createElement("section");
  section.className = "scout-cat";

  const head = document.createElement("div");
  head.className = "scout-cat-head";
  const label = document.createElement("span");
  label.className = "scout-cat-name";
  label.textContent = catId;
  head.append(label);

  if (group.top) {
    const prep = document.createElement("button");
    prep.type = "button";
    prep.className = "mini-btn scout-prep";
    prep.innerHTML = svg("download", 13);
    prep.append(document.createTextNode(" Prepare"));
    prep.title = `Pull + ground + benchmark the ${catId} top pick`;
    prep.addEventListener("click", () => prepareCategory(catId));
    head.append(prep);
  }
  section.append(head);

  if (!group.top) {
    const quiet = document.createElement("div");
    quiet.className = "report-quiet";
    quiet.textContent = group.why || "No VRAM-feasible pick.";
    section.append(quiet);
  } else {
    section.append(buildScoutPick(group.top, { top: true }));
    for (const runner of group.runnersUp || []) {
      section.append(buildScoutPick(runner, {}));
    }
    const why = document.createElement("div");
    why.className = "scout-why-line";
    why.textContent = group.why || "";
    section.append(why);
  }

  const msg = state.scoutPrepare.get(catId);
  if (msg) {
    const note = document.createElement("div");
    note.className = `scout-prep-note ${msg.status || ""}`;
    note.textContent = (msg.lines || []).join(" ");
    section.append(note);
  }

  const dropped = group.dropped || [];
  if (dropped.length) {
    const open = state.scoutDropped.has(catId);
    const toggle = document.createElement("div");
    toggle.className = "fold-toggle scout-dropped-toggle";
    toggle.setAttribute("role", "button");
    toggle.tabIndex = 0;
    toggle.innerHTML = `<span class="chev${open ? " open" : ""}">${svg("chevronR", 12)}</span>`;
    const tl = document.createElement("span");
    tl.className = "fold-label";
    tl.textContent = `${dropped.length} dropped for VRAM`;
    toggle.append(tl);
    const flip = () => {
      if (state.scoutDropped.has(catId)) state.scoutDropped.delete(catId);
      else state.scoutDropped.add(catId);
      renderSelectedView();
    };
    toggle.addEventListener("click", flip);
    toggle.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); flip(); }
    });
    section.append(toggle);
    if (open) {
      for (const d of dropped) {
        const row = document.createElement("div");
        row.className = "scout-drop-row";
        const dn = document.createElement("span");
        dn.className = "scout-name";
        dn.textContent = d.name;
        dn.title = d.name;
        const dr = document.createElement("span");
        dr.className = "scout-why";
        dr.textContent = d.reason;
        row.append(dn, dr);
        section.append(row);
      }
    }
  }
  return section;
}

/* ---------------------------------------------------------- rail */

function renderRail() {
  const rail = $("#rail");
  rail.replaceChildren();
  const groups = new Map();
  for (const check of state.checks.values()) {
    if (!groups.has(check.group)) groups.set(check.group, []);
    groups.get(check.group).push(check);
  }
  const names = [
    ...GROUP_ORDER.filter((g) => groups.has(g)),
    ...[...groups.keys()].filter((g) => !GROUP_ORDER.includes(g)),
  ];
  for (const name of names) {
    const wrap = document.createElement("div");
    const label = document.createElement("div");
    label.className = "rail-label";
    label.textContent = name;
    const items = document.createElement("div");
    items.className = "rail-items";
    for (const check of groups.get(name)) {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "rail-row" + (DANGER.has(check.id) ? " danger" : "");
      row.dataset.id = check.id;
      if (check.id === state.selected) row.classList.add("active");
      row.innerHTML = `<span class="rail-icon">${svg(CHECK_ICON[check.id], 16)}</span>`;
      const title = document.createElement("span");
      title.className = "rail-title";
      title.textContent = check.label;
      row.append(title);
      row.title = check.command;
      row.addEventListener("click", () => select(check.id));
      items.append(row);
    }
    wrap.append(label, items);
    rail.append(wrap);
  }
  if (state.pending.length) {
    const wrap = document.createElement("div");
    const label = document.createElement("div");
    label.className = "rail-label";
    label.textContent = "manual only";
    const items = document.createElement("div");
    items.className = "rail-items";
    for (const item of state.pending) {
      const row = document.createElement("div");
      row.className = "rail-row manual";
      row.innerHTML = `<span class="rail-icon">${svg("lock", 15)}</span>`;
      const title = document.createElement("span");
      title.className = "rail-title";
      title.textContent = item.label;
      row.append(title);
      row.title = item.state;
      items.append(row);
    }
    wrap.append(label, items);
    rail.append(wrap);
  }
}

/* ---------------------------------------------------------- masthead */

function renderMeta() {
  const rt = state.runtime;
  $("#meta-version").textContent = rt ? `v${rt.version}` : "v—";
  $("#meta-host").textContent = rt ? `host ${rt.host}` : "host —";
  const dot = $("#host-dot");
  dot.className = "host-dot" + (rt && rt.engine === "ok" ? " ok" : "");
  $("#meta-checked").textContent = state.checkedAt
    ? `checked ${state.checkedAt}`
    : "not checked yet";
}

function renderQuickActions() {
  const box = $("#quick-actions");
  box.replaceChildren();
  const iconFor = { chat: "chat", image: "image" };
  for (const link of state.links) {
    const a = document.createElement("a");
    a.className = "ghost-btn";
    a.href = link.url;
    a.innerHTML = svg(iconFor[link.id] || "arrowUpRight", 15);
    a.append(document.createTextNode(" " + link.label));
    box.append(a);
  }
}

/* ---------------------------------------------------------- home view */

function healthReport() {
  return state.reports.get("health") || null;
}

function renderHealthCard() {
  const report = healthReport();
  const dot = $("#health-dot");
  const word = $("#health-word");
  const rerun = $("#health-rerun");
  rerun.innerHTML = svg("refresh", 13);
  rerun.classList.toggle("spin", state.running.has("health"));

  if (state.running.has("health") && !report) {
    dot.className = "health-dot";
    word.className = "health-word";
    word.textContent = "checking…";
  } else if (!report) {
    dot.className = "health-dot";
    word.className = "health-word";
    word.textContent = "not checked";
  } else {
    const c = countBy(parseReport(report.lines));
    const level = c.fail ? "fail" : c.warn ? "warn" : "ok";
    const words = { fail: "Attention", warn: "Watch", ok: "Healthy" };
    dot.className = `health-dot live ${level}`;
    word.className = `health-word ${level}`;
    word.textContent = words[level];
    $("#count-fail").textContent = c.fail;
    $("#count-warn").textContent = c.warn;
    $("#count-ok").textContent = c.ok;
  }
  if (!report) {
    $("#count-fail").textContent = "–";
    $("#count-warn").textContent = "–";
    $("#count-ok").textContent = "–";
  }
  $("#health-toggle-label").textContent = state.folds.details ? "Hide details" : "Details";
  $("#health-chev").innerHTML = svg("chevronR", 13);
  $("#health-chev").classList.toggle("open", state.folds.details);
}

function buildReportDetails(container, report) {
  container.replaceChildren();
  const entries = parseReport(report.lines);
  const attention = entries.filter((e) => e.status !== "ok");
  const passing = entries.filter((e) => e.status === "ok");

  const label = document.createElement("div");
  label.className = "report-label";
  label.textContent = "Needs attention";
  container.append(label);

  if (!attention.length) {
    const quiet = document.createElement("div");
    quiet.className = "report-quiet";
    quiet.textContent = entries.length
      ? "Nothing needs attention."
      : "No structured check lines in this report — see the raw log below.";
    container.append(quiet);
  }
  for (const e of attention) {
    const row = document.createElement("div");
    row.className = "attention-row";
    row.innerHTML = `<span class="a-dot ${e.status}"></span>`;
    const l = document.createElement("div");
    l.className = "a-label";
    l.textContent = e.label;
    const d = document.createElement("div");
    d.className = "a-detail";
    d.textContent = e.detail;
    row.append(l, d);
    container.append(row);
  }

  if (passing.length) {
    const toggle = document.createElement("div");
    toggle.className = "fold-toggle";
    toggle.setAttribute("role", "button");
    toggle.tabIndex = 0;
    toggle.innerHTML = `<span class="chev${state.folds.passing ? " open" : ""}">${svg("chevronR", 13)}</span>`;
    const t = document.createElement("span");
    t.className = "fold-label";
    t.textContent = `${passing.length} passing checks`;
    toggle.append(t);
    const flip = () => { state.folds.passing = !state.folds.passing; renderSelectedView(); };
    toggle.addEventListener("click", flip);
    toggle.addEventListener("keydown", (ev) => { if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); flip(); } });
    container.append(toggle);

    if (state.folds.passing) {
      const grid = document.createElement("div");
      grid.className = "passing-grid";
      for (const e of passing) {
        const row = document.createElement("div");
        row.className = "passing-row";
        row.innerHTML = `<span class="p-icon">${svg("ok", 13, 2.5)}</span>`;
        const l = document.createElement("span");
        l.className = "p-label";
        l.textContent = e.label;
        const d = document.createElement("span");
        d.className = "p-detail";
        d.textContent = e.detail;
        row.append(l, d);
        grid.append(row);
      }
      container.append(grid);
    }
  }

  appendRawBar(container, report);
}

function appendRawBar(container, report) {
  const rawBar = document.createElement("div");
  rawBar.className = "raw-bar";
  const rawToggle = document.createElement("div");
  rawToggle.className = "fold-toggle";
  rawToggle.setAttribute("role", "button");
  rawToggle.tabIndex = 0;
  rawToggle.innerHTML = `<span class="chev${state.folds.raw ? " open" : ""}">${svg("chevronR", 13)}</span>`;
  const rl = document.createElement("span");
  rl.className = "fold-label";
  rl.textContent = "Raw log output";
  rawToggle.append(rl);
  const flipRaw = () => { state.folds.raw = !state.folds.raw; renderSelectedView(); };
  rawToggle.addEventListener("click", flipRaw);
  rawToggle.addEventListener("keydown", (ev) => { if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); flipRaw(); } });

  const copyBtn = document.createElement("button");
  copyBtn.type = "button";
  copyBtn.className = "mini-btn";
  copyBtn.innerHTML = svg("copy", 13);
  copyBtn.append(document.createTextNode(" Copy log"));
  copyBtn.addEventListener("click", () => copyReport(report, copyBtn));
  rawBar.append(rawToggle, copyBtn);
  container.append(rawBar);

  if (state.folds.raw) {
    const pre = document.createElement("pre");
    pre.className = "rawlog";
    pre.textContent = (report.lines || []).join("\n") || "No output.";
    container.append(pre);
  }
}

function renderHomeReport() {
  const panel = $("#home-report");
  const report = healthReport();
  if (!state.folds.details || !report) {
    panel.hidden = true;
    return;
  }
  panel.hidden = false;
  buildReportDetails(panel, report);
}

function renderTiles() {
  const box = $("#tiles");
  box.replaceChildren();
  const defs = [];
  for (const link of state.links) {
    defs.push({
      title: link.label,
      sub: link.url.replace(/^https?:\/\//, ""),
      icon: link.id === "image" ? "image" : "chat",
      corner: "arrowUpRight",
      onClick: () => window.open(link.url, "_blank"),
    });
  }
  for (const id of ["nanobrowser-proxy", "cherry", "agent"]) {
    const check = state.checks.get(id);
    if (!check) continue;
    defs.push({
      title: check.label,
      sub: check.command,
      icon: CHECK_ICON[id],
      corner: "playline",
      onClick: () => runTask(id),
      id,
    });
  }
  for (const def of defs) {
    const tile = document.createElement("button");
    tile.type = "button";
    tile.className = "tile";
    const top = document.createElement("div");
    top.className = "tile-top";
    top.innerHTML =
      `<span class="tile-icon">${svg(def.icon, 18)}</span>` +
      `<span class="tile-corner">${svg(def.corner, 15)}</span>`;
    const title = document.createElement("div");
    title.className = "tile-title";
    title.textContent = def.title;
    const sub = document.createElement("div");
    sub.className = "tile-sub";
    sub.textContent = def.sub;
    const body = document.createElement("div");
    body.append(title, sub);
    tile.append(top, body);
    tile.addEventListener("click", def.onClick);
    box.append(tile);
  }
}

function sparkline(values, max) {
  if (values.length < 2) return "";
  const top = Math.max(max, ...values, 1);
  const w = 100, h = 30, pad = 2;
  const pts = values.map((v, i) => {
    const x = (i / (values.length - 1)) * w;
    const y = h - pad - (Math.max(0, v) / top) * (h - 2 * pad);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  });
  const area = `0,${h} ${pts.join(" ")} ${w},${h}`;
  return (
    `<svg class="stat-spark" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" aria-hidden="true">` +
    `<polygon points="${area}"/><polyline points="${pts.join(" ")}"/></svg>`
  );
}

function renderStats() {
  const box = $("#stats");
  box.replaceChildren();
  const rt = state.runtime;
  const offline = !rt || rt.engine !== "ok";
  const defs = [
    {
      icon: "activity", label: "Active model",
      value: rt && rt.model ? rt.model : "—",
      sub: offline ? "engine offline" : rt.model ? "warm · ready" : "idle · nothing loaded",
    },
    {
      icon: "zap", label: "GPU",
      value: rt && rt.gpuPercent != null ? `${rt.gpuPercent}%` : "—",
      sub: offline ? "engine offline" : rt.gpuPercent != null ? "offloaded to GPU" : "no model loaded",
      spark: sparkline(state.history.gpu, 100),
    },
    {
      icon: "archive", label: "VRAM",
      value: rt && rt.vramGb != null ? `${rt.vramGb} GB` : "—",
      sub: offline ? "engine offline" : rt.vramGb != null ? "model resident" : "nothing resident",
      spark: sparkline(state.history.vram, 12),
    },
    {
      icon: "battery", label: "Keep-alive",
      value: rt && rt.keepAliveMin != null ? `${rt.keepAliveMin} min` : "—",
      sub: offline ? "engine offline" : "idle unload timer",
    },
  ];
  for (const def of defs) {
    const stat = document.createElement("div");
    stat.className = "stat";
    stat.innerHTML =
      `<div class="stat-head">${svg(def.icon, 15)}<span class="stat-label"></span></div>` +
      `<div class="stat-value"></div><div class="stat-sub"></div>` +
      (def.spark || "");
    stat.querySelector(".stat-label").textContent = def.label;
    stat.querySelector(".stat-value").textContent = def.value;
    stat.querySelector(".stat-sub").textContent = def.sub;
    box.append(stat);
  }
}

function pushHistory(series, value) {
  series.push(value);
  if (series.length > HISTORY_MAX) series.shift();
}

function renderSystem() {
  const box = $("#system-stats");
  if (!box) return;
  box.replaceChildren();
  const s = state.system;
  const defs = [
    {
      icon: "cpu", label: "CPU",
      value: s && s.cpuPercent != null ? `${s.cpuPercent}%` : "—",
      sub: s ? "whole machine" : "no reading",
      spark: sparkline(state.sysHistory.cpu, 100),
    },
    {
      icon: "archive", label: "Memory",
      value: s && s.ramUsedGb != null ? `${s.ramUsedGb} / ${s.ramTotalGb} GB` : "—",
      sub: s && s.ramPercent != null ? `${s.ramPercent}% used` : "no reading",
      spark: sparkline(state.sysHistory.ram, s && s.ramTotalGb ? s.ramTotalGb : 32),
    },
    {
      icon: "zap", label: "GPU util",
      value: s && s.gpuPercent != null ? `${s.gpuPercent}%` : "—",
      sub: s && s.gpuTempC != null ? `${s.gpuTempC}°C core` : "nvidia-smi",
      spark: sparkline(state.sysHistory.gpu, 100),
    },
    {
      icon: "image", label: "VRAM",
      value:
        s && s.vramUsedGb != null ? `${s.vramUsedGb} / ${s.vramTotalGb} GB` : "—",
      sub: "whole GPU",
      spark: sparkline(
        state.sysHistory.vram,
        s && s.vramTotalGb ? s.vramTotalGb : 12,
      ),
    },
    {
      icon: "drive", label: "Disk",
      value: s && s.diskFreeGb != null ? `${s.diskFreeGb} GB` : "—",
      sub: "free on this drive",
    },
    {
      icon: "battery", label: "Battery",
      value:
        s && s.batteryPercent != null
          ? `${s.batteryPercent}%`
          : s && s.onAc
            ? "AC"
            : "—",
      sub:
        s && s.onAc != null
          ? s.onAc
            ? "plugged in"
            : "on battery"
          : "power state unknown",
    },
  ];
  for (const def of defs) {
    const stat = document.createElement("div");
    stat.className = "stat";
    stat.innerHTML =
      `<div class="stat-head">${svg(def.icon, 15)}<span class="stat-label"></span></div>` +
      `<div class="stat-value"></div><div class="stat-sub"></div>` +
      (def.spark || "");
    stat.querySelector(".stat-label").textContent = def.label;
    stat.querySelector(".stat-value").textContent = def.value;
    stat.querySelector(".stat-sub").textContent = def.sub;
    box.append(stat);
  }
}

async function fetchSystem() {
  try {
    const response = await fetch("/api/system");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    state.system = await response.json();
  } catch {
    state.system = null;
  }
  const s = state.system;
  pushHistory(state.sysHistory.cpu, s && s.cpuPercent != null ? s.cpuPercent : 0);
  pushHistory(state.sysHistory.ram, s && s.ramUsedGb != null ? s.ramUsedGb : 0);
  pushHistory(state.sysHistory.gpu, s && s.gpuPercent != null ? s.gpuPercent : 0);
  pushHistory(state.sysHistory.vram, s && s.vramUsedGb != null ? s.vramUsedGb : 0);
  if (state.selected === "health") renderSystem();
}

/* ---------------------------------------------------------- task view */

function renderScoutView(view, check) {
  const running = state.running.has(check.id);
  const scout = state.scout;

  const header = document.createElement("div");
  header.className = "task-header";
  const icon = document.createElement("div");
  icon.className = "task-icon";
  icon.innerHTML = svg(CHECK_ICON[check.id], 20);
  const idBox = document.createElement("div");
  const title = document.createElement("div");
  title.className = "th-title";
  title.textContent = "Model Scout — best pick per task";
  const cmd = document.createElement("div");
  cmd.className = "th-cmd";
  cmd.textContent = "localai scout";
  idBox.append(title, cmd);
  const actions = document.createElement("div");
  actions.className = "th-actions";
  const refresh = document.createElement("button");
  refresh.type = "button";
  refresh.className = "mini-btn";
  refresh.disabled = running;
  refresh.innerHTML = svg("refresh", 13);
  refresh.append(document.createTextNode(running ? " Scouting…" : " Rescan"));
  refresh.addEventListener("click", refreshScout);
  actions.append(refresh);
  header.append(icon, idBox, actions);
  view.append(header);

  const panel = document.createElement("div");
  panel.className = "report-panel";

  if (running && !scout) {
    const quiet = document.createElement("div");
    quiet.className = "report-quiet";
    quiet.textContent = "Scanning HuggingFace for models that fit this machine…";
    panel.append(quiet);
    view.append(panel);
    return;
  }
  if (!scout || !scout.groups) {
    const quiet = document.createElement("div");
    quiet.className = "report-quiet";
    quiet.textContent = scout
      ? "No scout cache yet. Rescan to discover models sized for this machine's VRAM."
      : "Loading the last scout…";
    panel.append(quiet);
    view.append(panel);
    return;
  }

  if (scout.generated) {
    const meta = document.createElement("div");
    meta.className = "scout-budget";
    meta.textContent = `Scouted ${scout.generated} · VRAM-gated for this machine`;
    panel.append(meta);
  }
  for (const [catId, group] of Object.entries(scout.groups)) {
    panel.append(buildScoutCategory(catId, group));
  }
  view.append(panel);

  if (scout.lines && scout.lines.length) {
    appendRawBar(panel, { id: "model-scout", lines: scout.lines });
  }
}

function renderTaskView() {
  const view = $("#task-view");
  view.replaceChildren();
  const check = state.checks.get(state.selected);
  if (!check) return;
  if (check.id === "model-scout") {
    renderScoutView(view, check);
    return;
  }
  const report = state.reports.get(check.id);
  const running = state.running.has(check.id);
  const verb = CHECK_VERB[check.id] || "Run";

  if (!report) {
    const wrap = document.createElement("div");
    wrap.className = "task-empty";
    const icon = document.createElement("div");
    icon.className = "task-icon";
    icon.innerHTML = svg(CHECK_ICON[check.id], 24);
    const title = document.createElement("div");
    title.className = "task-title";
    title.textContent = check.label;
    const cmd = document.createElement("div");
    cmd.className = "task-cmd";
    cmd.textContent = check.command;
    const desc = document.createElement("div");
    desc.className = "task-desc";
    desc.textContent = running
      ? "Running — output lands here when it finishes."
      : "No report yet for this task. Run it to see output here.";
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "accent-btn" + (DANGER.has(check.id) ? " danger" : "");
    btn.disabled = running;
    btn.innerHTML = svg("play", 14);
    btn.append(document.createTextNode(` ${running ? "Running…" : `${verb} ${check.label}`}`));
    btn.addEventListener("click", () => runTask(check.id));
    wrap.append(icon, title, cmd, desc, btn);
    view.append(wrap);
    return;
  }

  const header = document.createElement("div");
  header.className = "task-header";
  const icon = document.createElement("div");
  icon.className = "task-icon";
  icon.innerHTML = svg(CHECK_ICON[check.id], 20);
  const idBox = document.createElement("div");
  const title = document.createElement("div");
  title.className = "th-title";
  title.textContent = check.label;
  const cmd = document.createElement("div");
  cmd.className = "th-cmd";
  cmd.textContent = check.command;
  idBox.append(title, cmd);
  const actions = document.createElement("div");
  actions.className = "th-actions";
  const rerun = document.createElement("button");
  rerun.type = "button";
  rerun.className = "mini-btn";
  rerun.disabled = running;
  rerun.innerHTML = svg("refresh", 13);
  rerun.append(document.createTextNode(running ? " Running…" : ` ${verb} again`));
  rerun.addEventListener("click", () => runTask(check.id));
  actions.append(rerun);
  header.append(icon, idBox, actions);
  view.append(header);

  if (check.id !== "model-scout") {
    // Scout reports are a candidate table, not pass/fail checks - the
    // structured list below carries its own summary.
    const entries = parseReport(report.lines);
    const c = countBy(entries);
    const counts = document.createElement("div");
    counts.className = "task-counts";
    const parts = [
      ["fail", c.fail, "Failed"],
      ["warn", c.warn, "Warnings"],
      ["ok", c.ok, "Passing"],
    ];
    for (const [cls, num, lbl] of parts) {
      const tc = document.createElement("div");
      tc.className = "tc";
      tc.innerHTML = `<span class="tc-num count-num ${cls}"></span><span class="tc-label"></span>`;
      tc.querySelector(".tc-num").textContent = num;
      tc.querySelector(".tc-label").textContent = lbl;
      counts.append(tc);
    }
    view.append(counts);
  }

  const panel = document.createElement("div");
  panel.className = "report-panel";
  buildReportDetails(panel, report);
  view.append(panel);
}

/* ---------------------------------------------------------- actions */

function renderSelectedView() {
  const home = $("#home-view");
  const task = $("#task-view");
  const isHome = state.selected === "health";
  home.hidden = !isHome;
  task.hidden = isHome;
  if (isHome) {
    $("#start-card").classList.toggle("busy", state.running.has("start"));
    renderHealthCard();
    renderHomeReport();
    renderTiles();
    renderStats();
    renderSystem();
  } else {
    renderTaskView();
  }
  renderRail();
  renderMeta();
}

function select(id) {
  state.selected = id;
  state.folds.passing = false;
  state.folds.raw = false;
  if (id === "model-scout" && state.scout === null && !state.running.has(id)) {
    loadScout();
  }
  renderSelectedView();
}

async function runTask(id) {
  const check = state.checks.get(id);
  if (!check || state.running.has(id)) return;
  if (
    check.requiresConfirmation &&
    !window.confirm(`Run "${check.label}"? This may change local services.`)
  ) {
    return;
  }
  state.running.add(id);
  renderSelectedView();
  try {
    const response = await fetch(`/api/checks/${id}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ confirmed: true }),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const report = await response.json();
    state.reports.set(id, report);
    if (id === "health") {
      const now = new Date();
      state.checkedAt = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
      state.folds.details = countBy(parseReport(report.lines)).fail > 0
        ? true
        : state.folds.details;
    }
  } catch (error) {
    state.reports.set(id, {
      label: check.label,
      status: "fail",
      exitCode: -1,
      lines: [`[FAIL] Request                    ${String(error)}`],
    });
  } finally {
    state.running.delete(id);
    renderSelectedView();
    fetchRuntime();
  }
}

async function loadScout() {
  // Show the last scout immediately on open, without re-running discovery.
  try {
    const response = await fetch("/api/scout");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    state.scout = await response.json();
  } catch {
    state.scout = { generated: null, groups: null };
  }
  if (state.selected === "model-scout") renderSelectedView();
}

async function refreshScout() {
  if (state.running.has("model-scout")) return;
  state.running.add("model-scout");
  state.scoutPrepare.clear();
  renderSelectedView();
  try {
    const response = await fetch("/api/scout/refresh", { method: "POST" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    state.scout = await response.json();
  } catch (error) {
    state.scout = {
      generated: null,
      groups: null,
      lines: [`[FAIL] Rescan                    ${String(error)}`],
    };
  } finally {
    state.running.delete("model-scout");
    renderSelectedView();
  }
}

async function prepareCategory(catId) {
  if (
    !window.confirm(
      `Prepare the ${catId} top pick? This pulls a multi-GB model and builds a ` +
        "grounded wrapper in a new console window. It never changes your default.",
    )
  ) {
    return;
  }
  state.scoutPrepare.set(catId, { status: "warn", lines: ["Launching…"] });
  renderSelectedView();
  try {
    const response = await fetch("/api/scout/prepare", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ category: catId, confirmed: true }),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const result = await response.json();
    state.scoutPrepare.set(catId, {
      status: result.status,
      lines: result.lines || [],
    });
  } catch (error) {
    state.scoutPrepare.set(catId, {
      status: "fail",
      lines: [`Prepare failed: ${String(error)}`],
    });
  } finally {
    renderSelectedView();
  }
}

async function copyReport(report, button) {
  const text = (report.lines || []).join("\n");
  if (!text) return;
  let ok = false;
  try {
    await navigator.clipboard.writeText(text);
    ok = true;
  } catch {
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.append(ta);
      ta.select();
      ok = document.execCommand("copy");
      ta.remove();
    } catch {
      ok = false;
    }
  }
  const original = button.lastChild;
  original.textContent = ok ? " Copied" : " Failed";
  setTimeout(() => { original.textContent = " Copy log"; }, 1400);
}

async function fetchRuntime() {
  try {
    const response = await fetch("/api/runtime");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    state.runtime = await response.json();
  } catch {
    state.runtime = null;
  }
  const rt = state.runtime;
  state.history.gpu.push(rt && rt.gpuPercent != null ? rt.gpuPercent : 0);
  state.history.vram.push(rt && rt.vramGb != null ? rt.vramGb : 0);
  if (state.history.gpu.length > HISTORY_MAX) state.history.gpu.shift();
  if (state.history.vram.length > HISTORY_MAX) state.history.vram.shift();
  // Tags become listable once the engine comes up; refresh the model menu.
  if (rt && rt.engine === "ok" && (!state.models || state.models.source !== "ollama")) {
    loadModels();
  }
  renderMeta();
  if (state.selected === "health") renderStats();
}

async function loadModels() {
  try {
    const response = await fetch("/api/models");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    state.models = await response.json();
  } catch {
    state.models = null;
  }
  renderWarmSelect();
}

function renderWarmSelect() {
  const wrap = $("#start-warm");
  const select = $("#warm-select");
  const m = state.models;
  if (!m || !m.models.length) {
    wrap.hidden = true;
    return;
  }
  wrap.hidden = false;
  select.replaceChildren();
  for (const name of m.models) {
    const option = document.createElement("option");
    option.value = name;
    option.textContent = name === m.default ? `${name} · default` : name;
    if (name === m.selected) option.selected = true;
    select.append(option);
  }
}

async function setWarmModel(value) {
  try {
    const response = await fetch("/api/warm-model", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: value }),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const result = await response.json();
    if (state.models) state.models.selected = result.selected;
  } catch {
    renderWarmSelect(); // revert the visible choice to the persisted one
  }
}

/* ---------------------------------------------------------- boot */

async function boot() {
  $("#start-chip").innerHTML = svg("play", 24);
  $("#start-watermark").innerHTML = svg("bolt", 240);
  const startCard = $("#start-card");
  startCard.addEventListener("click", (ev) => {
    if (ev.target.closest(".start-warm")) return;
    runTask("start");
  });
  startCard.addEventListener("keydown", (ev) => {
    if (ev.target.closest(".start-warm")) return;
    if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); runTask("start"); }
  });
  const warmWrap = $("#start-warm");
  for (const evt of ["click", "keydown", "keyup", "pointerdown"]) {
    warmWrap.addEventListener(evt, (ev) => ev.stopPropagation());
  }
  $("#warm-select").addEventListener("change", (ev) => setWarmModel(ev.target.value));
  $("#health-toggle").addEventListener("click", () => {
    state.folds.details = !state.folds.details;
    renderSelectedView();
  });
  $("#health-rerun").addEventListener("click", () => runTask("health"));

  const manifest = await (await fetch("/api/dashboard")).json();
  for (const check of manifest.checks) state.checks.set(check.id, check);
  state.links = manifest.links;
  state.pending = manifest.pendingActions;

  renderQuickActions();
  renderSelectedView();
  loadModels();
  fetchRuntime();
  fetchSystem();
  setInterval(fetchRuntime, 15000);
  setInterval(fetchSystem, 15000);
  if (state.checks.has("health")) await runTask("health");
}

boot().catch((error) => {
  const view = $("#home-view");
  if (view) {
    const fail = document.createElement("div");
    fail.className = "report-quiet";
    fail.textContent = `Dashboard failed to load: ${error}`;
    view.prepend(fail);
  }
});
