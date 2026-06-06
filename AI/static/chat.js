/* ====================================================================
   Database Assistant — chat client
   - Sessions persisted in localStorage (no backend changes).
   - Each session is a flat list of messages (user / assistant / error).
   - Sidebar lists sessions; clicking one swaps it into the chat pane.
   ==================================================================== */

const STORAGE_KEY = 'dba-chatbot.sessions.v1';
const CURRENT_KEY = 'dba-chatbot.current.v1';
const SERVER_KEY  = 'dba-chatbot.server.v1';      // per-flavor: SERVER_KEY + '.' + flavor
const FLAVOR_KEY  = 'dba-chatbot.flavor.v1';
const MAX_HISTORY = 50;
const PALETTE = ['#60a5fa','#34d399','#fbbf24','#f472b6','#a78bfa','#f87171','#22d3ee','#fb923c'];

// ---------- DOM ----------
const $ = (sel) => document.querySelector(sel);
const chat          = $('#chat');
const form          = $('#composer');
const input         = $('#input');
const sendBtn       = $('#send-btn');
const newChatBtn    = $('#new-chat');
const historyList   = $('#history-list');
const clearHistBtn  = $('#clear-history');
const chatTitle     = $('#chat-title');
const serverPicker  = $('#server-picker');
const statusDot     = $('#status-dot');
const statusText    = $('#status-text');
const toggleSidebar = $('#toggle-sidebar');
const flavorTabs    = document.querySelectorAll('.flavor-tab');

// ---------- State ----------
let sessions     = loadSessions();
let currentId    = localStorage.getItem(CURRENT_KEY) || null;
let activeFlavor = localStorage.getItem(FLAVOR_KEY) || 'mssql';
let pendingCall  = false;

// Ensure the current session matches the active flavor; otherwise pick the
// most-recent session for that flavor, or create a fresh one.
function _ensureCurrentMatchesFlavor() {
  const cur = sessions[currentId];
  if (cur && (cur.flavor || 'mssql') === activeFlavor) return;
  const ids = Object.keys(sessions)
    .filter(id => (sessions[id].flavor || 'mssql') === activeFlavor)
    .sort((a, b) => sessions[b].updated - sessions[a].updated);
  if (ids.length) {
    currentId = ids[0];
  } else {
    currentId = newSessionId();
    sessions[currentId] = {
      id: currentId, title: 'New conversation', flavor: activeFlavor,
      created: Date.now(), updated: Date.now(), messages: [],
    };
  }
  saveSessions();
}
_ensureCurrentMatchesFlavor();

// ============================================================
// Session storage
// ============================================================
function loadSessions() {
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY)) || {}; }
  catch { return {}; }
}
function saveSessions() {
  // Cap to MAX_HISTORY entries — drop oldest.
  const ids = Object.keys(sessions);
  if (ids.length > MAX_HISTORY) {
    ids.sort((a,b) => sessions[a].updated - sessions[b].updated)
       .slice(0, ids.length - MAX_HISTORY)
       .forEach(id => delete sessions[id]);
  }
  localStorage.setItem(STORAGE_KEY, JSON.stringify(sessions));
  localStorage.setItem(CURRENT_KEY, currentId);
}
function newSessionId() { return 'c_' + Date.now().toString(36) + '_' + Math.random().toString(36).slice(2,8); }

function currentSession()    { return sessions[currentId]; }
function setSessionTitle(text) {
  const s = currentSession();
  if (!s.title || s.title === 'New conversation') {
    s.title = (text || '').slice(0, 60);
    saveSessions();
  }
}

// ============================================================
// Sidebar history rendering
// ============================================================
function renderHistory() {
  // Only show sessions belonging to the currently-active flavor.
  const ids = Object.keys(sessions)
    .filter(id => (sessions[id].flavor || 'mssql') === activeFlavor)
    .sort((a, b) => sessions[b].updated - sessions[a].updated);
  historyList.innerHTML = '';
  if (ids.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'history-empty';
    empty.textContent = 'No conversations yet';
    historyList.appendChild(empty);
    return;
  }
  for (const id of ids) {
    const s = sessions[id];
    const row = document.createElement('div');
    row.className = 'history-item' + (id === currentId ? ' active' : '');
    row.dataset.id = id;
    row.title = s.title;

    const text = document.createElement('div');
    text.className = 'history-item-text';
    text.textContent = s.title || 'Untitled';

    const time = document.createElement('div');
    time.className = 'history-item-time';
    time.textContent = relativeTime(s.updated);

    const del = document.createElement('button');
    del.className = 'history-item-del';
    del.title = 'Delete';
    del.innerHTML = '×';
    del.addEventListener('click', (e) => {
      e.stopPropagation();
      deleteSession(id);
    });

    row.append(text, time, del);
    row.addEventListener('click', () => switchSession(id));
    historyList.appendChild(row);
  }
}

function relativeTime(ts) {
  const s = Math.floor((Date.now() - ts) / 1000);
  if (s < 60)    return `${s}s`;
  if (s < 3600)  return `${Math.floor(s/60)}m`;
  if (s < 86400) return `${Math.floor(s/3600)}h`;
  return `${Math.floor(s/86400)}d`;
}

function switchSession(id) {
  if (id === currentId || !sessions[id]) return;
  currentId = id;
  localStorage.setItem(CURRENT_KEY, id);
  renderChat();
  renderHistory();
}

function deleteSession(id) {
  delete sessions[id];
  if (id === currentId) {
    const next = Object.keys(sessions).sort((a,b) => sessions[b].updated - sessions[a].updated)[0];
    if (next) { currentId = next; }
    else {
      currentId = newSessionId();
      sessions[currentId] = { id: currentId, title: 'New conversation', created: Date.now(), updated: Date.now(), messages: [] };
    }
  }
  saveSessions();
  renderHistory();
  renderChat();
}

function startNewChat() {
  // If the current session is already empty (and in this flavor), reuse it.
  const s = currentSession();
  if (s && s.messages.length === 0 && (s.flavor || 'mssql') === activeFlavor) {
    renderChat(); return;
  }
  currentId = newSessionId();
  sessions[currentId] = {
    id: currentId, title: 'New conversation', flavor: activeFlavor,
    created: Date.now(), updated: Date.now(), messages: [],
  };
  saveSessions();
  renderChat();
  renderHistory();
  input.focus();
}

// ============================================================
// Chat rendering
// ============================================================
function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c =>
    ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])
  );
}

function renderMarkdown(md) {
  let html = escapeHtml(md);
  html = html.replace(/```([\s\S]*?)```/g, (_, code) => `<pre>${code.trim()}</pre>`);
  html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
  html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  html = html.replace(/\n/g, '<br>');
  return html;
}

function renderTable(rows, caption) {
  if (!Array.isArray(rows) || rows.length === 0) return null;
  const cols = [...rows.reduce((set, r) => { Object.keys(r || {}).forEach(k => set.add(k)); return set; }, new Set())];
  const table = document.createElement('table');
  if (caption) {
    const cap = document.createElement('caption'); cap.textContent = caption; table.appendChild(cap);
  }
  const thead = document.createElement('thead');
  thead.innerHTML = '<tr>' + cols.map(c => `<th>${escapeHtml(c)}</th>`).join('') + '</tr>';
  table.appendChild(thead);
  const tbody = document.createElement('tbody');
  rows.slice(0, 200).forEach(r => {
    const tr = document.createElement('tr');
    tr.innerHTML = cols.map(c => `<td>${escapeHtml(r[c])}</td>`).join('');
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  return table;
}

let chartSeq = 0;
function renderChart(influxData) {
  if (!influxData || !Array.isArray(influxData.series) || influxData.series.length === 0) return null;
  const wrap = document.createElement('div');
  wrap.className = 'chart-wrap';
  const title = document.createElement('div');
  title.className = 'chart-title';
  title.textContent = `${influxData.measurement} • ${influxData.aggregation || 'mean'} • last ${influxData.time_range || '1h'}`;
  wrap.appendChild(title);
  const canvas = document.createElement('canvas');
  canvas.id = `chart-${++chartSeq}`;
  wrap.appendChild(canvas);

  const datasets = influxData.series
    .filter(s => Array.isArray(s.points) && s.points.length)
    .map((s, i) => ({
      label: s.host || 'value',
      data: s.points.map(p => ({ x: p.time, y: Number(p.value) })),
      borderColor: PALETTE[i % PALETTE.length],
      backgroundColor: PALETTE[i % PALETTE.length] + '33',
      borderWidth: 1.5, pointRadius: 0, tension: 0.25, fill: false,
    }));

  queueMicrotask(() => {
    if (typeof Chart === 'undefined') { wrap.innerHTML += '<em>Chart.js failed to load.</em>'; return; }
    new Chart(canvas, {
      type: 'line', data: { datasets },
      options: {
        responsive: true, maintainAspectRatio: false, animation: false,
        plugins: { legend: { labels: { color: '#cbd5e1', boxWidth: 12 } } },
        scales: {
          x: { type: 'time', time: { unit: pickTimeUnit(influxData.time_range) },
               ticks: { color: '#94a3b8', maxRotation: 0, autoSkip: true, maxTicksLimit: 6 },
               grid: { color: '#1f2937' } },
          y: { ticks: { color: '#94a3b8' }, grid: { color: '#1f2937' } },
        },
      },
    });
  });
  return wrap;
}
function pickTimeUnit(range) {
  const m = String(range || '1h').match(/^(\d+)([smhdw])$/);
  if (!m) return 'hour';
  const n = +m[1], u = m[2];
  if (u === 's' || u === 'm' || (u === 'h' && n <= 6)) return 'minute';
  if (u === 'h' && n <= 48)                            return 'hour';
  if (u === 'd' && n <= 14)                            return 'hour';
  return 'day';
}

/**
 * Walk `data` and any nested objects, returning [{label, meta}, ...] for
 * every `_ansible`/`_ansible_*` block we find. Lets combo_query and
 * health_check (which run multiple playbooks) render multiple disclosures.
 */
function collectAnsibleMeta(data, prefix = '') {
  const out = [];
  if (!data || typeof data !== 'object') return out;
  for (const [key, val] of Object.entries(data)) {
    if (!val) continue;
    if (key === '_ansible' || key.startsWith('_ansible_')) {
      const suffix = key === '_ansible' ? '' : key.replace(/^_ansible_/, '');
      const label = [prefix, suffix].filter(Boolean).join(' / ');
      out.push({ label, meta: val });
    } else if (typeof val === 'object' && !Array.isArray(val)) {
      out.push(...collectAnsibleMeta(val, key));
    }
  }
  return out;
}

function renderAnsibleOutput(meta, label) {
  if (!meta || typeof meta !== 'object') return null;
  const wrap = document.createElement('details');
  wrap.className = 'ansible-out';

  const summary = document.createElement('summary');
  const rc = (meta.rc === null || meta.rc === undefined) ? '?' : meta.rc;
  const sev = (rc === 0 || rc === '0') ? 'ok' : (rc === '?' ? 'unknown' : 'err');
  summary.innerHTML =
    `<span class="ansible-chev">▸</span>` +
    `<span class="ansible-title">Ansible output${label ? ` · ${escapeHtml(label)}` : ''}</span>` +
    `<span class="ansible-rc rc-${sev}">rc=${escapeHtml(String(rc))}</span>` +
    (meta.task ? `<span class="ansible-task">${escapeHtml(meta.task)}</span>` : '');
  wrap.appendChild(summary);

  if (meta.cmd) {
    const sec = document.createElement('div');
    sec.className = 'ansible-section';
    sec.innerHTML =
      `<div class="ansible-label">Command</div>` +
      `<pre class="ansible-pre cmd">${escapeHtml(meta.cmd)}</pre>`;
    wrap.appendChild(sec);
  }

  if (meta.stdout && meta.stdout.length) {
    const sec = document.createElement('div');
    sec.className = 'ansible-section';
    sec.innerHTML =
      `<div class="ansible-label">stdout${meta.stdout_truncated ? ' <span class="ansible-trunc">(truncated)</span>' : ''}</div>` +
      `<pre class="ansible-pre">${escapeHtml(meta.stdout)}</pre>`;
    wrap.appendChild(sec);
  }

  if (meta.stderr && meta.stderr.trim()) {
    const sec = document.createElement('div');
    sec.className = 'ansible-section';
    sec.innerHTML =
      `<div class="ansible-label warn">stderr${meta.stderr_truncated ? ' <span class="ansible-trunc">(truncated)</span>' : ''}</div>` +
      `<pre class="ansible-pre err">${escapeHtml(meta.stderr)}</pre>`;
    wrap.appendChild(sec);
  }
  return wrap;
}

function renderData(data, intent) {
  if (!data || typeof data !== 'object') return null;
  const block = document.createElement('div');
  block.className = 'data-block';
  const action = intent && intent.action;

  if (action === 'sql_query' && Array.isArray(data.rows)) {
    const t = renderTable(data.rows, `${data.server || ''} • ${data.database || ''} • ${data.row_count ?? data.rows.length} rows`);
    if (t) block.appendChild(t); else block.appendChild(emptyHint('No rows returned.'));
  } else if (action === 'influx_query') {
    const c = renderChart(data);
    if (c) block.appendChild(c);
    else if (data.error) block.appendChild(emptyHint(`Influx error: ${data.error}`));
    else block.appendChild(emptyHint('No data points in range.'));
  } else if (action === 'combo_query') {
    if (data.sql && Array.isArray(data.sql.rows)) {
      const t = renderTable(data.sql.rows, `${data.sql.server || ''} • ${data.sql.database || ''} • ${data.sql.row_count ?? data.sql.rows.length} rows`);
      if (t) block.appendChild(t);
    }
    if (data.influx) { const c = renderChart(data.influx); if (c) block.appendChild(c); }
    if (!block.children.length) block.appendChild(emptyHint('Combo query returned no rows or points.'));
  } else if (action === 'health_check') {
    // mssql + db2 share the instance->databases inventory shape.
    const instances = data.inventory && (data.inventory.mssql || data.inventory.db2);
    if (instances) {
      Object.entries(instances).forEach(([inst, info]) => {
        if (!info || !Array.isArray(info.databases)) return;
        const t = renderTable(info.databases, `${inst} • ${info.databases.length} databases`);
        if (t) block.appendChild(t);
      });
    }
  } else if (data && data.summary) {
    renderSummaryTables(action, data.summary, block);
  }
  return block.children.length ? block : null;
}

function renderSummaryTables(action, s, block) {
  const add = (rows, cap) => { if (rows && rows.length) { const t = renderTable(rows, cap); if (t) block.appendChild(t); } };
  if (action === 'backup_status') {
    add(s.ages, `Backup ages • stale_full=${s.stale_full ?? 0} stale_log=${s.stale_log ?? 0}`);
    add(s.verifies, 'Backup verifications');
  } else if (action === 'integrity_status') {
    add(s.items, `DBCC CHECKDB • clean=${s.clean ?? 0} errors=${s.errors ?? 0} failed=${s.failed ?? 0}`);
  } else if (action === 'disk_status') {
    add(s.drives, 'Drives'); add(s.datafiles, 'Datafiles');
  } else if (action === 'agent_jobs') {
    add(s.failed,       `Failed jobs (${s.failed_count ?? 0})`);
    add(s.long_running, `Long-running jobs (${s.long_running_count ?? 0})`);
    add(s.disabled,     `Disabled jobs (${s.disabled_jobs ?? 0})`);
  } else if (action === 'tempdb_status') {
    (s.instances || []).forEach(i => {
      add(i.files, `${i.instance} • tempdb files`);
      add(i.top_consumers, `${i.instance} • top consumers`);
      add(i.pagelatch, `${i.instance} • PAGELATCH waits`);
    });
  } else if (action === 'security_audit') {
    (s.instances || []).forEach(i => {
      add(i.sysadmins, `${i.instance} • sysadmin members`);
      add(i.weak_logins, `${i.instance} • weak login policy`);
      add(i.stale_logins, `${i.instance} • stale logins`);
      add(i.orphaned_users, `${i.instance} • orphaned users`);
      add(i.public_perms, `${i.instance} • PUBLIC role grants`);
      add(i.tde_databases, `${i.instance} • TDE state`);
      add(i.cert_expiry, `${i.instance} • certificates`);
      if (i.issues && i.issues.length) add(i.issues.map(x => ({ issue: x })), `${i.instance} • issues`);
    });
  } else if (action === 'patch_level') {
    add(s.sql_instances, 'SQL build/CU level');
    if (s.os) add([s.os], 'Windows host');
  } else if (action === 'alwayson_status') {
    (s.instances || []).forEach(i => {
      add(i.replicas, `${i.instance} • replicas`);
      add(i.databases, `${i.instance} • databases (crit=${i.critical_count ?? 0} warn=${i.warning_count ?? 0})`);
      add(i.listeners, `${i.instance} • listeners`);
    });
  }
}

function emptyHint(text) {
  const d = document.createElement('div'); d.className = 'empty'; d.textContent = text; return d;
}

function appendMessageElement(msg) {
  const el = document.createElement('div');
  el.className = `msg ${msg.role}`;
  el.innerHTML = renderMarkdown(msg.body || '');
  const block = renderData(msg.data, msg.intent);
  if (block) el.appendChild(block);

  // Collapsible "Ansible output" disclosure(s). One per playbook that ran;
  // health_check / combo_query may surface multiple.
  for (const { label, meta } of collectAnsibleMeta(msg.data || {})) {
    const out = renderAnsibleOutput(meta, label);
    if (out) el.appendChild(out);
  }

  if (msg.intent) {
    const tag = document.createElement('div');
    tag.className = 'intent';
    tag.textContent = `intent: ${msg.intent.action}`;
    el.appendChild(tag);
  }
  chat.appendChild(el);
  chat.scrollTop = chat.scrollHeight;
  return el;
}

function renderChat() {
  chat.innerHTML = '';
  const s = currentSession();
  chatTitle.textContent = s.title || 'New conversation';
  if (s.messages.length === 0) {
    appendMessageElement({
      role: 'assistant',
      body: "Hi — I'm your Database Assistant. I can run **read-only** SQL via Ansible, query CheckMK metrics from InfluxDB (charted), and combine both for a holistic view. I can also check blocking locks, grow datafiles, run health/backup/security checks, and report on AlwaysOn AG health. Pick a quick action on the left or just type a question.",
    });
    return;
  }
  for (const m of s.messages) appendMessageElement(m);
}

// ============================================================
// Send pipeline
// ============================================================
async function send(message) {
  if (!message.trim() || pendingCall) return;
  pendingCall = true;
  sendBtn.disabled = true;

  const s = currentSession();
  s.messages.push({ role: 'user', body: message });
  s.updated = Date.now();
  setSessionTitle(message);
  appendMessageElement({ role: 'user', body: message });
  saveSessions();
  renderHistory();

  const thinking = document.createElement('div');
  thinking.className = 'msg assistant thinking';
  thinking.innerHTML = '<div class="thinking-dots"><span></span><span></span><span></span></div>';
  chat.appendChild(thinking);
  chat.scrollTop = chat.scrollHeight;

  try {
    const resp = await fetch('/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message,
        flavor:   activeFlavor,                  // 'mssql' or 'oracle'
        database: serverPicker.value || null,    // currently-picked DB
      }),
    });
    const data = await resp.json();
    thinking.remove();

    if (!resp.ok) {
      const err = { role: 'error', body: data.error || 'Request failed.' };
      s.messages.push(err);
      appendMessageElement(err);
    } else {
      const assistant = {
        role: 'assistant',
        body: data.reply || '(empty reply)',
        intent: data.intent,
        data: data.data,
      };
      s.messages.push(assistant);
      appendMessageElement(assistant);
    }
    s.updated = Date.now();
    saveSessions();
    renderHistory();
  } catch (err) {
    thinking.remove();
    const errMsg = { role: 'error', body: `Network error: ${err}` };
    s.messages.push(errMsg);
    appendMessageElement(errMsg);
    s.updated = Date.now();
    saveSessions();
  } finally {
    pendingCall = false;
    sendBtn.disabled = false;
    input.focus();
  }
}

// ============================================================
// UI wiring
// ============================================================
form.addEventListener('submit', (e) => {
  e.preventDefault();
  const t = input.value.trim();
  if (!t) return;
  input.value = '';
  autoResize();
  send(t);
});

input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); form.requestSubmit(); }
});
input.addEventListener('input', autoResize);

function autoResize() {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, 200) + 'px';
}

newChatBtn.addEventListener('click', startNewChat);

clearHistBtn.addEventListener('click', () => {
  if (!confirm('Clear all chat history?')) return;
  sessions = {};
  currentId = newSessionId();
  sessions[currentId] = { id: currentId, title: 'New conversation', created: Date.now(), updated: Date.now(), messages: [] };
  saveSessions();
  renderHistory();
  renderChat();
});

toggleSidebar.addEventListener('click', () => {
  document.body.classList.toggle('sidebar-collapsed');
});

// Quick actions: prefill the textarea with the prompt + selected server.
document.querySelectorAll('.quick').forEach(btn => {
  btn.addEventListener('click', () => {
    const prompt = btn.dataset.prompt || '';
    const srv = serverPicker.value || '';
    input.value = prompt + srv;
    autoResize();
    input.focus();
    // Place caret at the end so the user can immediately type a server / refine.
    input.setSelectionRange(input.value.length, input.value.length);
  });
});

// Database picker — populated from /api/<flavor>/databases. Each option is a
// database from the active flavor's databases.ini. Pick remembered per flavor.
serverPicker.addEventListener('change', () => {
  localStorage.setItem(SERVER_KEY + '.' + activeFlavor, serverPicker.value);
});

async function loadServers() {
  try {
    const r = await fetch('/api/' + activeFlavor + '/databases');
    const j = await r.json();
    const dbs = j.databases || [];

    serverPicker.innerHTML = '';
    const placeholder = document.createElement('option');
    placeholder.value = '';
    placeholder.textContent = dbs.length
      ? `— pick a database (${dbs.length}) —`
      : '— no databases configured —';
    serverPicker.appendChild(placeholder);

    for (const d of dbs) {
      const opt = document.createElement('option');
      opt.value = d.name;
      const tag = d.ansible_servername || '?';
      opt.textContent = d.in_inventory
        ? `${d.name}  ·  ${tag}`
        : `${d.name}  ·  ${tag} ⚠`;
      if (!d.in_inventory) opt.style.color = '#f59e0b';
      serverPicker.appendChild(opt);
    }

    const saved = localStorage.getItem(SERVER_KEY + '.' + activeFlavor) || '';
    if (saved && dbs.some(d => d.name === saved)) serverPicker.value = saved;

    serverPicker.disabled = dbs.length === 0;
    serverPicker.title = j.hint
      ? j.hint
      : `[${activeFlavor}] Databases read from ${j.databases_ini || 'databases.ini'} (${j.missing_server_count || 0} missing ansible_servername)`;
  } catch {
    serverPicker.innerHTML = '<option value="">— unavailable —</option>';
    serverPicker.disabled = true;
    serverPicker.title = 'Could not reach /api/' + activeFlavor + '/databases';
  }
}

// Tab switching: swap activeFlavor, refresh dropdown + history, and switch
// the chat pane to a session that belongs to the new flavor.
function switchFlavor(next) {
  if (next === activeFlavor) return;
  activeFlavor = next;
  localStorage.setItem(FLAVOR_KEY, next);
  for (const tab of flavorTabs) {
    const on = tab.dataset.flavor === next;
    tab.classList.toggle('is-active', on);
    tab.setAttribute('aria-selected', on ? 'true' : 'false');
  }
  _ensureCurrentMatchesFlavor();
  loadServers();
  renderHistory();
  renderChat();
}
flavorTabs.forEach(tab => {
  tab.addEventListener('click', () => switchFlavor(tab.dataset.flavor));
});
// Initialize tab visual state on boot.
for (const tab of flavorTabs) {
  const on = tab.dataset.flavor === activeFlavor;
  tab.classList.toggle('is-active', on);
  tab.setAttribute('aria-selected', on ? 'true' : 'false');
}

// Download PDF report for the active flavor. The browser handles the
// Content-Disposition attachment so we just navigate to the URL in a hidden
// anchor - no XHR / blob plumbing needed.
const pdfBtn = document.getElementById('download-pdf');
if (pdfBtn) {
  pdfBtn.addEventListener('click', () => {
    const flavor = activeFlavor || 'mssql';
    const a = document.createElement('a');
    a.href = `/api/${flavor}/report.pdf`;
    a.rel = 'noopener';
    document.body.appendChild(a);
    a.click();
    a.remove();
  });
}

async function pingHealth() {
  try {
    const r = await fetch('/api/health');
    const j = await r.json();
    statusDot.className = 'dot ok';
    statusText.textContent = j.ok ? `Online · ${j.model || j.provider || 'ready'}` : 'Server error';
  } catch {
    statusDot.className = 'dot err';
    statusText.textContent = 'Disconnected';
  }
}

// ============================================================
// Boot
// ============================================================
renderHistory();
renderChat();
loadServers();
pingHealth();
setInterval(pingHealth, 30000);     // status check every 30s
setInterval(renderHistory, 60000);  // refresh relative timestamps
input.focus();
