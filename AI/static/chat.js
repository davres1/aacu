const chat  = document.getElementById("chat");
const form  = document.getElementById("composer");
const input = document.getElementById("input");

function escapeHtml(s) {
  return String(s ?? "").replace(/[&<>"']/g, c => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

function renderMarkdown(md) {
  let html = escapeHtml(md);
  html = html.replace(/```([\s\S]*?)```/g, (_, code) => `<pre>${code.trim()}</pre>`);
  html = html.replace(/`([^`]+)`/g, "<code>$1</code>");
  html = html.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  html = html.replace(/\n/g, "<br>");
  return html;
}

// --- Table renderer for SQL rows -------------------------------------------

function renderTable(rows, caption) {
  if (!Array.isArray(rows) || rows.length === 0) return null;
  const cols = [...rows.reduce((set, r) => {
    Object.keys(r || {}).forEach(k => set.add(k));
    return set;
  }, new Set())];
  const table = document.createElement("table");
  if (caption) {
    const cap = document.createElement("caption");
    cap.textContent = caption;
    table.appendChild(cap);
  }
  const thead = document.createElement("thead");
  thead.innerHTML = "<tr>" + cols.map(c => `<th>${escapeHtml(c)}</th>`).join("") + "</tr>";
  table.appendChild(thead);
  const tbody = document.createElement("tbody");
  rows.slice(0, 200).forEach(r => {
    const tr = document.createElement("tr");
    tr.innerHTML = cols.map(c => `<td>${escapeHtml(r[c])}</td>`).join("");
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  return table;
}

// --- Chart renderer for InfluxDB time series -------------------------------

let chartSeq = 0;

const PALETTE = [
  "#60a5fa", "#34d399", "#fbbf24", "#f472b6",
  "#a78bfa", "#f87171", "#22d3ee", "#fb923c",
];

function renderChart(influxData) {
  if (!influxData || !Array.isArray(influxData.series) || influxData.series.length === 0) return null;

  const container = document.createElement("div");
  container.className = "chart-wrap";

  const title = document.createElement("div");
  title.className = "chart-title";
  title.textContent =
    `${influxData.measurement} • ${influxData.aggregation || "mean"} • last ${influxData.time_range || "1h"}`;
  container.appendChild(title);

  const canvas = document.createElement("canvas");
  canvas.id = `chart-${++chartSeq}`;
  canvas.height = 220;
  container.appendChild(canvas);

  const datasets = influxData.series
    .filter(s => Array.isArray(s.points) && s.points.length)
    .map((s, i) => ({
      label: s.host || "value",
      data: s.points.map(p => ({ x: p.time, y: Number(p.value) })),
      borderColor: PALETTE[i % PALETTE.length],
      backgroundColor: PALETTE[i % PALETTE.length] + "33",
      borderWidth: 1.5,
      pointRadius: 0,
      tension: 0.25,
      fill: false,
    }));

  // Render after the canvas is attached to the DOM so Chart.js can size it.
  queueMicrotask(() => {
    if (typeof Chart === "undefined") {
      container.innerHTML += "<em>Chart.js failed to load.</em>";
      return;
    }
    new Chart(canvas, {
      type: "line",
      data: { datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        plugins: {
          legend: { labels: { color: "#cbd5e1", boxWidth: 12 } },
        },
        scales: {
          x: {
            type: "time",
            time: { unit: pickTimeUnit(influxData.time_range) },
            ticks: { color: "#94a3b8", maxRotation: 0, autoSkip: true, maxTicksLimit: 6 },
            grid:  { color: "#1f2937" },
          },
          y: {
            ticks: { color: "#94a3b8" },
            grid:  { color: "#1f2937" },
          },
        },
      },
    });
  });

  return container;
}

function pickTimeUnit(range) {
  const m = String(range || "1h").match(/^(\d+)([smhdw])$/);
  if (!m) return "hour";
  const n = Number(m[1]), u = m[2];
  if (u === "s" || u === "m" || (u === "h" && n <= 6))  return "minute";
  if (u === "h" && n <= 48)                              return "hour";
  if (u === "d" && n <= 14)                              return "hour";
  return "day";
}

// --- Render the structured data block --------------------------------------

function renderData(data, intent) {
  if (!data || typeof data !== "object") return null;
  const block = document.createElement("div");
  block.className = "data-block";

  const action = intent && intent.action;

  if (action === "sql_query" && Array.isArray(data.rows)) {
    const t = renderTable(data.rows, `${data.server || ""} • ${data.database || ""} • ${data.row_count ?? data.rows.length} rows`);
    if (t) block.appendChild(t);
    else block.appendChild(emptyHint("No rows returned."));
  } else if (action === "influx_query") {
    const c = renderChart(data);
    if (c) block.appendChild(c);
    else if (data.error) block.appendChild(emptyHint(`Influx error: ${data.error}`));
    else block.appendChild(emptyHint("No data points in range."));
  } else if (action === "combo_query") {
    if (data.sql && Array.isArray(data.sql.rows)) {
      const t = renderTable(data.sql.rows, `${data.sql.server || ""} • ${data.sql.database || ""} • ${data.sql.row_count ?? data.sql.rows.length} rows`);
      if (t) block.appendChild(t);
    }
    if (data.influx) {
      const c = renderChart(data.influx);
      if (c) block.appendChild(c);
    }
    if (!block.children.length) block.appendChild(emptyHint("Combo query returned no rows or points."));
  } else if (action === "health_check") {
    if (data.inventory && data.inventory.mssql) {
      Object.entries(data.inventory.mssql).forEach(([inst, info]) => {
        if (!info || !Array.isArray(info.databases)) return;
        const t = renderTable(info.databases, `${inst} • ${info.databases.length} databases`);
        if (t) block.appendChild(t);
      });
    }
  } else if (data && data.summary) {
    // Generic renderer for the scripts that emit a JSON summary (backups,
    // checkdb, disk, jobs, tempdb, security, patch, alwayson). Each one
    // exposes a different shape, so we surface the most useful tables.
    renderSummaryTables(action, data.summary, block);
  }

  return block.children.length ? block : null;
}

function renderSummaryTables(action, s, block) {
  const add = (rows, caption) => {
    if (!rows || !rows.length) return;
    const t = renderTable(rows, caption);
    if (t) block.appendChild(t);
  };
  if (action === "backup_status") {
    add(s.ages,     `Backup ages • stale_full=${s.stale_full ?? 0} stale_log=${s.stale_log ?? 0}`);
    add(s.verifies, "Backup verifications");
  } else if (action === "integrity_status") {
    add(s.items, `DBCC CHECKDB • clean=${s.clean ?? 0} errors=${s.errors ?? 0} failed=${s.failed ?? 0}`);
  } else if (action === "disk_status") {
    add(s.drives,    "Drives");
    add(s.datafiles, "Datafiles");
  } else if (action === "agent_jobs") {
    add(s.failed,       `Failed jobs (${s.failed_count ?? 0})`);
    add(s.long_running, `Long-running jobs (${s.long_running_count ?? 0})`);
    add(s.disabled,     `Disabled jobs (${s.disabled_jobs ?? 0})`);
  } else if (action === "tempdb_status") {
    (s.instances || []).forEach(inst => {
      add(inst.files,         `${inst.instance} • tempdb files`);
      add(inst.top_consumers, `${inst.instance} • top tempdb consumers`);
      add(inst.pagelatch,     `${inst.instance} • PAGELATCH waits`);
    });
  } else if (action === "security_audit") {
    (s.instances || []).forEach(inst => {
      add(inst.sysadmins,      `${inst.instance} • sysadmin members`);
      add(inst.weak_logins,    `${inst.instance} • weak login policy`);
      add(inst.stale_logins,   `${inst.instance} • stale logins`);
      add(inst.orphaned_users, `${inst.instance} • orphaned users`);
      add(inst.public_perms,   `${inst.instance} • PUBLIC role grants`);
      add(inst.tde_databases,  `${inst.instance} • TDE state`);
      add(inst.cert_expiry,    `${inst.instance} • certificates`);
      if (inst.issues && inst.issues.length) {
        add(inst.issues.map(x => ({ issue: x })), `${inst.instance} • issues`);
      }
    });
  } else if (action === "patch_level") {
    add(s.sql_instances, "SQL build/CU level");
    if (s.os) add([s.os], "Windows host");
  } else if (action === "alwayson_status") {
    (s.instances || []).forEach(inst => {
      add(inst.replicas,  `${inst.instance} • replicas`);
      add(inst.databases, `${inst.instance} • databases (crit=${inst.critical_count ?? 0} warn=${inst.warning_count ?? 0})`);
      add(inst.listeners, `${inst.instance} • listeners`);
    });
  }
}

function emptyHint(text) {
  const d = document.createElement("div");
  d.className = "empty";
  d.textContent = text;
  return d;
}

// --- Chat plumbing ---------------------------------------------------------

function appendMessage(role, body, intent, data) {
  const el = document.createElement("div");
  el.className = `msg ${role}`;
  el.innerHTML = renderMarkdown(body);
  const block = renderData(data, intent);
  if (block) el.appendChild(block);
  if (intent) {
    const tag = document.createElement("div");
    tag.className = "intent";
    tag.textContent = `intent: ${intent.action}`;
    el.appendChild(tag);
  }
  chat.appendChild(el);
  chat.scrollTop = chat.scrollHeight;
}

async function send(message) {
  appendMessage("user", message);
  const thinking = document.createElement("div");
  thinking.className = "msg assistant";
  thinking.textContent = "Thinking…";
  chat.appendChild(thinking);
  chat.scrollTop = chat.scrollHeight;

  try {
    const resp = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message }),
    });
    const data = await resp.json();
    thinking.remove();
    if (!resp.ok) {
      appendMessage("error", data.error || "Request failed.");
      return;
    }
    appendMessage("assistant", data.reply || "(empty reply)", data.intent, data.data);
  } catch (err) {
    thinking.remove();
    appendMessage("error", `Network error: ${err}`);
  }
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  const text = input.value.trim();
  if (!text) return;
  input.value = "";
  send(text);
});

input.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    form.requestSubmit();
  }
});

appendMessage("assistant",
  "Hi — I'm your DB info chatbot. I can run **read-only** SQL via Ansible, " +
  "query InfluxDB for CheckMK stats (charted), and combine both for a holistic view. " +
  "I can also check blocking locks, grow datafiles, and run health checks.");
