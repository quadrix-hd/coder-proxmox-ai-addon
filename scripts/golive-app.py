#!/usr/bin/env python3
# "Go live"-App, laeuft IM Dev-Workspace auf 127.0.0.1:7777 und wird ueber
# einen coder_app-Button direkt in Coder geoeffnet (Coders eigener Login,
# kein Terminal, kein separates Passwort). Nur Python-Standardbibliothek.
#
# Ablauf: aktuelle Seite (Container auf Port 8080) erkennen -> Image in die
# private Registry pushen -> zentrale admin-ui per API beauftragen ->
# Fortschritt live anzeigen. Bestehende Live-Seiten lassen sich mit einem
# Klick auf den aktuellen Stand des Workspaces aktualisieren.
#
# Konfiguration per Umgebung (vom startup_script in /etc/golive-app.env):
#   REGISTRY_URL, ADMIN_UI_URL, ADMIN_UI_TOKEN, WORKSPACE_NAME, PORT
import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGISTRY_URL = os.environ.get("REGISTRY_URL", "")
ADMIN_UI_URL = os.environ.get("ADMIN_UI_URL", "").rstrip("/")
ADMIN_UI_TOKEN = os.environ.get("ADMIN_UI_TOKEN", "")
WORKSPACE_NAME = os.environ.get("WORKSPACE_NAME", "")
PORT = int(os.environ.get("PORT", "7777"))

FINAL_STATES = {"live", "error"}
NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$")

_job_lock = threading.Lock()
_job = None  # {"kind", "site_name", "phase", "status", "error", "domain", "started"}


# ---------------------------------------------------------------- helpers

def _set_job(**fields):
    with _job_lock:
        if _job is not None:
            _job.update(fields)


def admin(method, path, body=None, timeout=30):
    """Aufruf der admin-ui-API. Gibt (status_code, json) zurueck."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        ADMIN_UI_URL + path,
        data=data,
        method=method,
        headers={"Authorization": f"Bearer {ADMIN_UI_TOKEN}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        try:
            payload = json.loads(exc.read() or b"{}")
        except ValueError:
            payload = {}
        return exc.code, payload
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return 0, {"error": f"Go-live-Server nicht erreichbar ({ADMIN_UI_URL}): {exc}"}


def current_site():
    """Container, der im Workspace auf Port 8080 laeuft (Demo-Konvention)."""
    try:
        name = subprocess.run(
            ["docker", "ps", "--filter", "publish=8080", "--format", "{{.Names}}"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip().splitlines()
    except (OSError, subprocess.TimeoutExpired):
        return None
    if not name:
        return None
    image = subprocess.run(
        ["docker", "inspect", "--format", "{{.Config.Image}}", name[0]],
        capture_output=True, text=True, timeout=10,
    ).stdout.strip()
    return {"container": name[0], "image": image}


def suggested_name():
    s = re.sub(r"[^a-z0-9-]+", "-", WORKSPACE_NAME.lower()).strip("-")
    return s[:42] or "meine-seite"


def push_current_image(site_name):
    site = current_site()
    if not site:
        raise RuntimeError("Keine laufende Seite auf Port 8080 gefunden. Seite zuerst im Workspace starten (docker run -p 8080:80 ...).")
    tag = f"{site_name}:{time.strftime('%Y%m%d%H%M%S')}"
    target = f"{REGISTRY_URL}/{tag}"
    for cmd in (["docker", "tag", site["image"], target], ["docker", "push", target]):
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
        if res.returncode != 0:
            raise RuntimeError(f"{' '.join(cmd[:2])} fehlgeschlagen:\n{(res.stderr or res.stdout)[-1500:]}")
    return tag


def wait_for_admin(site_name):
    deadline = time.time() + 30 * 60
    while time.time() < deadline:
        code, site = admin("GET", f"/api/sites/{site_name}")
        if code == 200:
            _set_job(phase=site.get("status", ""), domain=site.get("customer_domain", ""))
            if site.get("status") in FINAL_STATES:
                if site.get("status") == "error":
                    _set_job(error=site.get("last_error") or "Unbekannter Fehler")
                return
        time.sleep(3)
    _set_job(phase="error", error="Zeitueberschreitung - Status in der Go-live-Verwaltung pruefen.")


def run_job(kind, payload):
    site_name = payload["site_name"]
    try:
        _set_job(phase="push")
        tag = push_current_image(site_name)

        _set_job(phase="register")
        if kind == "deploy":
            body = {
                "site_name": site_name,
                "docker_image": tag,
                "customer_domain": payload.get("customer_domain", ""),
                "pangolin_domain_id": payload.get("domain_id", ""),
                "pangolin_subdomain": payload.get("subdomain", ""),
                "newt_id": payload.get("newt_id", ""),
                "newt_secret": payload.get("newt_secret", ""),
            }
            code, resp = admin("POST", "/api/sites", body)
        else:
            code, resp = admin("POST", f"/api/sites/{site_name}/redeploy", {"docker_image": tag})
        if code not in (200, 202):
            raise RuntimeError(resp.get("error") or f"Go-live-Server antwortete mit HTTP {code}")

        wait_for_admin(site_name)
    except Exception as exc:  # noqa: BLE001 - alles in der Oberflaeche anzeigen
        _set_job(phase="error", error=str(exc))


def start_job(kind, payload):
    global _job
    with _job_lock:
        if _job and _job["phase"] not in FINAL_STATES:
            return False, "Es laeuft bereits ein Vorgang."
        _job = {
            "kind": kind, "site_name": payload["site_name"], "phase": "push",
            "error": "", "domain": payload.get("customer_domain", ""), "started": time.time(),
        }
    threading.Thread(target=run_job, args=(kind, payload), daemon=True).start()
    return True, ""


def state():
    code_s, sites = admin("GET", "/api/sites")
    code_d, domains = admin("GET", "/api/domains")
    with _job_lock:
        job = dict(_job) if _job else None
    errors = [r.get("error") for c, r in ((code_s, sites), (code_d, domains)) if c != 200 and isinstance(r, dict) and r.get("error")]
    return {
        "workspace": WORKSPACE_NAME,
        "suggested_name": suggested_name(),
        "current": current_site(),
        "sites": sites.get("sites", []) if code_s == 200 else [],
        "pangolin": domains.get("pangolin", False) if code_d == 200 else False,
        "domains": domains.get("domains", []) if code_d == 200 else [],
        "domain_error": domains.get("error", "") if code_d == 200 else "",
        "error": errors[0] if errors else "",
        "job": job,
    }


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _path(self):
        # Coder leitet ueber einen Pfad-Praefix weiter - nur das Ende zaehlt.
        return self.path.split("?", 1)[0].rstrip("/")

    def do_GET(self):
        if self._path().endswith("/api/state"):
            return self._send(200, state())
        return self._send(200, PAGE.encode(), "text/html; charset=utf-8")

    def do_POST(self):
        path = self._path()
        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self._send(400, {"error": "Ungueltige Anfrage"})
        name = (payload.get("site_name") or "").strip()
        if not NAME_RE.match(name):
            return self._send(400, {"error": "Name: nur Kleinbuchstaben, Ziffern und Bindestriche (max. 42 Zeichen)."})
        payload["site_name"] = name

        if path.endswith("/api/deploy"):
            kind = "deploy"
        elif path.endswith("/api/update"):
            kind = "update"
        else:
            return self._send(404, {"error": "not found"})

        # Namen vorab pruefen, statt erst Minuten lang ein Image hochzuladen
        # und dann abgelehnt zu werden.
        code, _ = admin("GET", f"/api/sites/{name}")
        if kind == "deploy" and code == 200:
            return self._send(409, {"error": f"Eine Live-Seite '{name}' gibt es schon - anderen Namen waehlen oder sie in der Liste aktualisieren."})
        if kind == "update" and code == 404:
            return self._send(404, {"error": f"Live-Seite '{name}' nicht gefunden."})
        if code == 0:
            return self._send(502, {"error": f"Go-live-Server nicht erreichbar ({ADMIN_UI_URL})."})

        ok, err = start_job(kind, payload)
        return self._send(202 if ok else 409, {"ok": ok, "error": err})


PAGE = r"""<!doctype html>
<html lang="de"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Go live</title>
<style>
:root{--bg:#09090b;--surface:#111113;--surface2:#18181b;--border:#27272a;--text:#fafafa;--muted:#a1a1aa;
--faint:#71717a;--green:#22c55e;--red:#ef4444;--amber:#f59e0b;--blue:#3b82f6;--mono:ui-monospace,SFMono-Regular,Menlo,monospace}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif;-webkit-font-smoothing:antialiased}
main{max-width:760px;margin:0 auto;padding:40px 20px 80px}
h1{font-size:22px;font-weight:600;margin:0}.sub{color:var(--muted);margin:4px 0 28px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:20px;margin-bottom:16px}
h2{font-size:14px;font-weight:600;margin:0 0 14px}
label{display:block;font-size:13px;color:var(--muted);margin:14px 0 6px}label:first-of-type{margin-top:0}
input,select{width:100%;background:var(--surface2);color:var(--text);border:1px solid var(--border);border-radius:6px;padding:9px 11px;font:inherit}
input:focus,select:focus{outline:none;border-color:#52525b}
.row{display:flex;gap:8px;align-items:center}.row .dot-sep{color:var(--faint)}
button{font:inherit;font-weight:500;border-radius:6px;padding:9px 16px;cursor:pointer;border:1px solid var(--border);background:var(--surface2);color:var(--text)}
button.primary{background:var(--text);color:var(--bg);border-color:var(--text)}button:disabled{opacity:.45;cursor:not-allowed}
.mono{font-family:var(--mono);font-size:12.5px;color:var(--muted)}
.notice{border:1px solid var(--border);background:var(--surface2);border-radius:6px;padding:12px 14px;color:var(--muted)}
.notice.err{border-color:#7f1d1d;background:#1c0a0a;color:#fca5a5;white-space:pre-wrap}
table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:10px 6px;border-bottom:1px solid var(--border)}
th{font-size:12px;color:var(--faint);font-weight:500}tr:last-child td{border-bottom:none}
.st{display:inline-flex;align-items:center;gap:7px}.d{width:8px;height:8px;border-radius:50%;background:var(--faint)}
.d.live{background:var(--green)}.d.error{background:var(--red)}.d.busy{background:var(--amber);animation:p 1.2s infinite}
@keyframes p{50%{opacity:.35}}
.steps{list-style:none;margin:0;padding:0}.steps li{display:flex;gap:10px;align-items:center;padding:7px 0;color:var(--faint)}
.steps li.done{color:var(--text)}.steps li.now{color:var(--text);font-weight:500}
.ic{width:18px;height:18px;border-radius:50%;border:1.5px solid var(--border);display:inline-flex;align-items:center;justify-content:center;font-size:11px;flex-shrink:0}
li.done .ic{background:var(--green);border-color:var(--green);color:#000}li.now .ic{border-color:var(--amber);animation:p 1.2s infinite}
li.fail .ic{background:var(--red);border-color:var(--red);color:#fff}
a{color:var(--blue);text-decoration:none}a:hover{text-decoration:underline}.hidden{display:none}
</style></head><body><main>
<h1>Go live</h1><p class="sub" id="sub">Seite aus diesem Workspace dauerhaft veroeffentlichen</p>
<div id="globalErr" class="notice err hidden" style="margin-bottom:16px"></div>

<div class="card hidden" id="progressCard"><h2 id="progTitle">Wird veroeffentlicht</h2>
<ul class="steps" id="steps"></ul><div id="progResult" style="margin-top:12px"></div>
<div style="margin-top:14px"><button id="progClose" class="hidden" onclick="closeJob()">Fertig</button></div></div>

<div class="card"><h2>Aktuelle Seite im Workspace</h2><div id="current" class="mono">Wird geladen...</div></div>

<div class="card" id="newCard"><h2>Neue Live-Seite</h2>
<form id="newForm" onsubmit="deploy(event)">
<label>Name</label><input id="name" required pattern="[a-z0-9]([a-z0-9-]*[a-z0-9])?" maxlength="42">
<div id="domPangolin" class="hidden"><label>Adresse</label>
<div class="row"><input id="subdomain" placeholder="kunde"><span class="dot-sep">.</span><select id="baseDomain"></select></div></div>
<div id="domManual" class="hidden"><label>Domain (nur zur Info)</label><input id="customDomain" placeholder="kunde.example.com">
<label>Newt-ID (aus Pangolin)</label><input id="newtId"><label>Newt-Secret</label><input id="newtSecret" type="password"></div>
<div style="margin-top:18px"><button class="primary" id="deployBtn" type="submit">Go live</button></div>
</form></div>

<div class="card"><h2>Live-Seiten</h2><div id="sites" class="mono">Wird geladen...</div></div>
</main>
<script>
const base = location.href.split('?')[0].replace(/\/?$/, '/');
let S = null, nameTouched = false, dismissedStarted = null;
const lastIdx = {};
const busy = s => s && !['live','error'].includes(s);
const STEPS = {
  deploy: [['push','Image hochladen'],['register','Auftrag senden'],['creating_pangolin_site','Tunnel anlegen'],
           ['provisioning_lxc','Server erstellen & Seite starten'],['creating_pangolin_resource','Domain verbinden'],['live','Live']],
  update: [['push','Image hochladen'],['register','Update anstossen'],['redeploying','Neue Version ausrollen'],['live','Live']]
};
function el(tag, attrs, ...kids){const e=document.createElement(tag);Object.assign(e,attrs||{});kids.forEach(k=>e.append(k));return e;}
function dot(status){return el('span',{className:'st'},el('span',{className:'d '+(status==='live'?'live':status==='error'?'error':'busy')}),status);}

async function load(){
  try{ const r = await fetch(base+'api/state'); S = await r.json(); }catch(e){ return; }
  document.getElementById('sub').textContent = 'Workspace ' + S.workspace + ' – Seite dauerhaft veroeffentlichen';
  const g = document.getElementById('globalErr'); g.textContent = S.error || ''; g.classList.toggle('hidden', !S.error);

  const cur = document.getElementById('current'); cur.replaceChildren();
  if (S.current) cur.append(el('span',{style:'color:var(--text)'},S.current.container), '  ·  ', S.current.image);
  else cur.append(el('span',{style:'color:var(--amber)'},'Keine Seite auf Port 8080 gefunden.'),' Seite zuerst im Workspace starten (docker run -p 8080:80 ...).');

  if (!nameTouched && !document.getElementById('name').value) document.getElementById('name').value = S.suggested_name;
  document.getElementById('domPangolin').classList.toggle('hidden', !S.pangolin);
  document.getElementById('domManual').classList.toggle('hidden', S.pangolin);
  const sel = document.getElementById('baseDomain');
  if (S.pangolin && sel.options.length !== S.domains.length) {
    sel.replaceChildren(...S.domains.map(d => el('option',{value:d.id,textContent:d.name})));
  }

  const box = document.getElementById('sites'); box.replaceChildren();
  if (!S.sites.length) box.append('Noch keine Live-Seiten.');
  else {
    const t = el('table',{}, el('tr',{}, el('th',{},'Name'), el('th',{},'Adresse'), el('th',{},'Status'), el('th',{})));
    S.sites.forEach(s => {
      const dom = s.customer_domain ? el('a',{href:'https://'+s.customer_domain,target:'_blank',textContent:s.customer_domain}) : '–';
      const btn = el('button',{textContent:'Aktualisieren',disabled:!S.current||busy(s.status)||jobRunning(),onclick:()=>update(s.site_name)});
      t.append(el('tr',{}, el('td',{style:'color:var(--text)'},s.site_name), el('td',{},dom), el('td',{},dot(s.status)), el('td',{style:'text-align:right'},btn)));
    });
    box.append(t);
  }
  document.getElementById('deployBtn').disabled = !S.current || jobRunning();
  renderJob();
}
function jobRunning(){ return S && S.job && busy(S.job.phase); }

function renderJob(){
  const card = document.getElementById('progressCard'), j = S.job;
  if (!j || j.started === dismissedStarted) { card.classList.add('hidden'); return; }
  card.classList.remove('hidden');
  const steps = STEPS[j.kind]; const failed = j.phase === 'error';
  let idx = steps.findIndex(s => s[0] === j.phase);
  if (j.phase === 'provisioning') idx = 1;
  if (failed) idx = Math.max(0, lastIdx[j.site_name] ?? 0); else lastIdx[j.site_name] = idx;
  document.getElementById('progTitle').textContent = (j.kind==='deploy'?'Veroeffentlichen: ':'Aktualisieren: ') + j.site_name;
  document.getElementById('steps').replaceChildren(...steps.map((s,i) => {
    const done = j.phase==='live' || i < idx, now = !failed && i === idx && j.phase!=='live', fail = failed && i === idx;
    return el('li',{className: fail?'fail':done?'done':now?'now':''}, el('span',{className:'ic'}, fail?'!':done?'✓':''), s[1]);
  }));
  const res = document.getElementById('progResult'); res.replaceChildren();
  if (failed) res.append(el('div',{className:'notice err'}, j.error));
  if (j.phase === 'live') res.append(el('div',{className:'notice'}, 'Die Seite ist live',
      ...(j.domain ? [': ', el('a',{href:'https://'+j.domain,target:'_blank',textContent:j.domain})] : ['.'])));
  document.getElementById('progClose').classList.toggle('hidden', !['live','error'].includes(j.phase));
}
function closeJob(){ if (S.job) dismissedStarted = S.job.started; renderJob(); }

async function post(path, body){
  const r = await fetch(base+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  const d = await r.json().catch(()=>({}));
  if (!r.ok) { alert(d.error || ('Fehler '+r.status)); return false; }
  return true;
}
async function deploy(ev){
  ev.preventDefault();
  const body = {site_name: document.getElementById('name').value.trim()};
  if (S.pangolin) {
    const sel = document.getElementById('baseDomain'), sub = document.getElementById('subdomain').value.trim();
    body.domain_id = sel.value; body.subdomain = sub;
    const baseName = sel.selectedOptions[0] ? sel.selectedOptions[0].textContent : '';
    body.customer_domain = sub ? sub + '.' + baseName : baseName;
  } else {
    body.customer_domain = document.getElementById('customDomain').value.trim();
    body.newt_id = document.getElementById('newtId').value.trim();
    body.newt_secret = document.getElementById('newtSecret').value.trim();
  }
  if (await post('api/deploy', body)) load();
}
async function update(name){
  if (!confirm('Live-Seite "'+name+'" mit dem aktuellen Stand dieses Workspaces ueberschreiben?')) return;
  if (await post('api/update', {site_name: name})) load();
}
document.getElementById('name').addEventListener('input', () => nameTouched = true);
load(); setInterval(load, 2500);
</script></body></html>
"""


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
