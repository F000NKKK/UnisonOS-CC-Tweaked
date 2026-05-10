import http from "node:http";
import { URL } from "node:url";
import { bridge } from "./bridge.js";
import { config } from "./config.js";
import { log } from "./logger.js";
import { KNOWN_PATHS } from "./paths.js";
import type { LuaPlain } from "./lua.js";

// Простой веб-дашборд: статический HTML (single-file) + крошечный
// JSON-API поверх Bridge. gRPC остаётся первичным каналом, это —
// удобство для оператора: посмотреть кто в онлайне и что-то быстро
// дёрнуть, не открывая ts-клиент.

const HTML = /* html */ `<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>UnisonOS dashboard</title>
<style>
:root{
  --bg:#0e1116; --panel:#161b22; --line:#30363d; --fg:#e6edf3;
  --mute:#7d8590; --accent:#58a6ff; --ok:#3fb950; --err:#f85149;
  --warn:#d29922;
  font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  color-scheme:dark;
}
*{box-sizing:border-box}
html,body{margin:0;padding:0;background:var(--bg);color:var(--fg);
  font:14px/1.45 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,sans-serif;}
body{display:grid;grid-template-columns:340px 1fr;height:100vh;}
header{grid-column:1/-1;display:flex;gap:16px;align-items:center;
  padding:10px 16px;border-bottom:1px solid var(--line);background:var(--panel);}
header h1{margin:0;font-size:14px;font-weight:600;letter-spacing:.4px;}
header .pill{padding:2px 8px;border:1px solid var(--line);border-radius:99px;
  font-size:12px;color:var(--mute);}
aside{border-right:1px solid var(--line);overflow:auto;}
.dev{padding:10px 14px;border-bottom:1px solid var(--line);cursor:pointer;
  display:flex;flex-direction:column;gap:2px;}
.dev:hover{background:#1c222b;}
.dev.active{background:#1f2a3a;border-left:2px solid var(--accent);}
.dev .id{font-weight:600;}
.dev .meta{color:var(--mute);font-size:12px;display:flex;gap:8px;}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;}
.dot.on{background:var(--ok);} .dot.off{background:var(--mute);}
main{padding:16px 18px;overflow:auto;display:flex;flex-direction:column;gap:14px;}
.section{border:1px solid var(--line);background:var(--panel);border-radius:8px;
  padding:12px 14px;}
.section h2{margin:0 0 8px;font-size:12px;text-transform:uppercase;
  letter-spacing:.6px;color:var(--mute);font-weight:600;}
.kv{display:grid;grid-template-columns:160px 1fr;gap:4px 12px;font-size:13px;}
.kv dt{color:var(--mute);}
.row{display:flex;gap:8px;align-items:center;}
input,textarea,select{background:#0d1117;color:var(--fg);border:1px solid var(--line);
  border-radius:6px;padding:6px 9px;font:inherit;font-family:ui-monospace,monospace;
  width:100%;}
button{background:#21262d;color:var(--fg);border:1px solid var(--line);
  border-radius:6px;padding:6px 12px;font:inherit;cursor:pointer;}
button.primary{background:#1f6feb;border-color:#1f6feb;}
button:hover{background:#2d333b;}
button.primary:hover{background:#388bfd;}
.callbox{position:relative;}
.suggestions{position:absolute;left:0;right:0;top:100%;z-index:10;
  background:var(--panel);border:1px solid var(--line);border-top:0;
  border-radius:0 0 6px 6px;max-height:240px;overflow:auto;display:none;}
.suggestions.open{display:block;}
.sug{padding:6px 10px;cursor:pointer;display:flex;justify-content:space-between;
  font-family:ui-monospace,monospace;font-size:13px;}
.sug:hover,.sug.active{background:#1f2a3a;}
.sug .sig{color:var(--mute);font-size:12px;}
pre{margin:0;white-space:pre-wrap;word-break:break-word;font-size:12.5px;
  background:#0d1117;border:1px solid var(--line);border-radius:6px;
  padding:10px 12px;max-height:320px;overflow:auto;}
.tag{display:inline-block;padding:1px 7px;border-radius:99px;
  background:#1c222b;color:var(--mute);font-size:11px;}
.empty{color:var(--mute);font-style:italic;}
.tabs{display:flex;gap:4px;margin-bottom:8px;}
.tab{padding:5px 10px;border-radius:6px;cursor:pointer;font-size:12px;
  color:var(--mute);}
.tab.active{background:#1f2a3a;color:var(--fg);}
</style>
</head><body>
<header>
  <h1>UnisonOS · dashboard</h1>
  <span class="pill" id="conn">connecting…</span>
  <span class="pill" id="count">0 devices</span>
</header>

<aside id="devList"></aside>

<main id="detail">
  <div class="section"><span class="empty">Выбери устройство слева</span></div>
</main>

<script>
const KNOWN = ${JSON.stringify(KNOWN_PATHS)};
let state = { devices: [], selected: null, lastResult: null, methodsCache: {} };

const $ = (sel) => document.querySelector(sel);

async function fetchJSON(url, opts) {
  const r = await fetch(url, opts);
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

async function refresh() {
  try {
    const { devices } = await fetchJSON("/api/devices");
    state.devices = devices;
    $("#conn").textContent = "live";
    $("#count").textContent = devices.length + " devices";
    renderList();
    if (state.selected && !devices.find(d => d.device_id === state.selected.device_id && d.world_id === state.selected.world_id)) {
      // выбранное отсоединилось
      state.selected = null;
      renderDetail();
    } else if (state.selected) {
      const fresh = devices.find(d => d.device_id === state.selected.device_id && d.world_id === state.selected.world_id);
      if (fresh) state.selected = { ...state.selected, ...fresh };
      renderDetail();
    }
  } catch (e) {
    $("#conn").textContent = "offline: " + e.message;
  }
}

function renderList() {
  const list = $("#devList");
  list.innerHTML = "";
  for (const d of state.devices) {
    const sel = state.selected && state.selected.device_id === d.device_id && state.selected.world_id === d.world_id;
    const div = document.createElement("div");
    div.className = "dev" + (sel ? " active" : "");
    div.innerHTML = \`
      <div class="id"><span class="dot \${d.online ? "on" : "off"}"></span> \${d.device_id} <span class="tag">\${d.role||"?"}</span></div>
      <div class="meta">
        <span>\${d.world_id}</span>
        <span>\${d.label || ""}</span>
        <span>\${d.version || ""}</span>
      </div>\`;
    div.onclick = () => { state.selected = d; renderDetail(); renderList(); };
    list.appendChild(div);
  }
  if (!state.devices.length) {
    list.innerHTML = '<div style="padding:14px;color:var(--mute);font-size:13px">Нет подключённых устройств.</div>';
  }
}

function renderDetail() {
  const main = $("#detail");
  if (!state.selected) {
    main.innerHTML = '<div class="section"><span class="empty">Выбери устройство слева</span></div>';
    return;
  }
  const d = state.selected;
  main.innerHTML = \`
    <div class="section">
      <h2>device</h2>
      <dl class="kv">
        <dt>id</dt><dd>\${d.device_id}</dd>
        <dt>world</dt><dd>\${d.world_id}</dd>
        <dt>role</dt><dd>\${d.role}</dd>
        <dt>label</dt><dd>\${d.label || "—"}</dd>
        <dt>version</dt><dd>\${d.version || "—"}</dd>
        <dt>capabilities</dt><dd>\${(d.capabilities||[]).join(", ") || "—"}</dd>
        <dt>last seen</dt><dd>\${new Date(d.last_seen_ms).toLocaleString()}</dd>
      </dl>
    </div>

    <div class="section">
      <h2>call</h2>
      <div class="callbox">
        <input id="path" placeholder="path, e.g. turtle.forward" autocomplete="off">
        <div id="sug" class="suggestions"></div>
      </div>
      <div style="height:8px"></div>
      <textarea id="args" rows="2" placeholder='args (JSON array), e.g. [1, "left"]'>[]</textarea>
      <div style="height:8px"></div>
      <div class="row">
        <button class="primary" id="run">Call</button>
        <button id="discover">peripheral.getNames</button>
        <span id="hint" style="color:var(--mute);font-size:12px;"></span>
      </div>
      <div style="height:10px"></div>
      <pre id="out"><span class="empty">— ничего не выполнено —</span></pre>
    </div>\`;

  setupAutocomplete();
  $("#run").onclick = doCall;
  $("#discover").onclick = () => doCall("peripheral.getNames", []);
}

function setupAutocomplete() {
  const inp = $("#path");
  const box = $("#sug");
  let activeIdx = -1;
  let items = [];

  function render(q) {
    items = KNOWN.filter(p => p.path.toLowerCase().includes(q.toLowerCase())).slice(0, 30);
    if (!items.length || !q) { box.classList.remove("open"); return; }
    box.innerHTML = items.map((p, i) =>
      \`<div class="sug\${i === activeIdx ? " active" : ""}" data-i="\${i}">
         <span>\${p.path}</span><span class="sig">\${p.signature || ""}</span>
       </div>\`).join("");
    box.classList.add("open");
    box.querySelectorAll(".sug").forEach(el => {
      el.onclick = () => { inp.value = items[+el.dataset.i].path; box.classList.remove("open"); };
    });
  }

  inp.oninput = (e) => { activeIdx = -1; render(e.target.value); };
  inp.onfocus = () => render(inp.value);
  inp.onblur  = () => setTimeout(() => box.classList.remove("open"), 150);
  inp.onkeydown = (e) => {
    if (!box.classList.contains("open")) return;
    if (e.key === "ArrowDown") { activeIdx = Math.min(activeIdx + 1, items.length - 1); render(inp.value); e.preventDefault(); }
    else if (e.key === "ArrowUp") { activeIdx = Math.max(activeIdx - 1, 0); render(inp.value); e.preventDefault(); }
    else if (e.key === "Enter" && activeIdx >= 0) {
      inp.value = items[activeIdx].path; box.classList.remove("open"); e.preventDefault();
    } else if (e.key === "Escape") { box.classList.remove("open"); }
  };
}

async function doCall(forcePath, forceArgs) {
  const out = $("#out");
  const path = forcePath ?? $("#path").value.trim();
  if (!path) { out.textContent = "no path"; return; }
  let args;
  try { args = forceArgs ?? JSON.parse($("#args").value || "[]"); }
  catch (e) { out.textContent = "bad args JSON: " + e.message; return; }
  if (!Array.isArray(args)) { out.textContent = "args must be JSON array"; return; }

  out.textContent = "calling…";
  try {
    const t = state.selected;
    const r = await fetchJSON("/api/call", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: t.device_id, world_id: t.world_id, path, args })
    });
    out.textContent = JSON.stringify(r, null, 2);
  } catch (e) {
    out.innerHTML = '<span style="color:var(--err)">' + e.message + '</span>';
  }
}

refresh();
setInterval(refresh, 2000);
</script>
</body></html>
`;

export function startWeb() {
  const port = Number(process.env.UNISON_WEB_PORT ?? 9280);
  const host = process.env.UNISON_WEB_HOST ?? "0.0.0.0";

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
      const p = url.pathname;

      if (req.method === "GET" && p === "/") {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        return res.end(HTML);
      }

      if (req.method === "GET" && p === "/api/devices") {
        const wid = url.searchParams.get("world_id") ?? undefined;
        return json(res, 200, { devices: bridge.list(wid) });
      }

      if (req.method === "POST" && p === "/api/call") {
        const body = await readJson(req);
        const target = {
          device_id: String(body?.device_id ?? ""),
          world_id:  String(body?.world_id  ?? "default") || "default",
        };
        const path = String(body?.path ?? "");
        const args = Array.isArray(body?.args) ? (body.args as LuaPlain[]) : [];
        if (!target.device_id || !path) return json(res, 400, { error: "device_id and path required" });
        try {
          const dev = bridge.require(target);
          const values = await dev.call(path, args, config.defaultRpcTimeoutMs);
          return json(res, 200, { ok: true, values });
        } catch (e) {
          return json(res, 200, { ok: false, error: (e as Error).message });
        }
      }

      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("not found");
    } catch (e) {
      log.error({ err: (e as Error).message }, "web error");
      res.writeHead(500, { "Content-Type": "text/plain" });
      res.end("server error");
    }
  });

  server.listen(port, host, () => {
    log.info({ host, port }, "dashboard listening");
  });
  return server;
}

function json(res: http.ServerResponse, status: number, body: unknown) {
  const data = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) });
  res.end(data);
}

function readJson(req: http.IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) return resolve({});
      try { resolve(JSON.parse(raw)); } catch (e) { reject(e); }
    });
    req.on("error", reject);
  });
}
