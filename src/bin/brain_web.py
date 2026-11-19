"""brain serve: a local web page for today's tasks, with a few actions.

Listens on 127.0.0.1 only. Every API call must carry the per-run token that
is embedded in the page, come with this server's own Host header (blocks DNS
rebinding) and, for writes, a JSON body from no foreign Origin (blocks CSRF).
All writes go through the same functions as the `brain` command, so formats
and locks stay consistent.
"""
import hmac
import json
import os
import re
import secrets
import sys
import threading
import webbrowser

import brain_ask
import brain_captures
import brain_graph
import brain_meet
import brain_projects
import brain_search
import brain_status

try:
    from http.server import ThreadingHTTPServer as HTTPServer
except ImportError:  # python < 3.7
    from http.server import HTTPServer
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlsplit

WEB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
PAGES = ("/", "/index.html")
ASSET_RE = re.compile(r"^/([a-z][a-z0-9-]*)\.(js|css)$")
CTYPES = {"js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
          "html": "text/html; charset=utf-8"}
TOKEN_PLACEHOLDER = "__BRAIN_TOKEN__"
MAX_BODY = 64 * 1024
FOLLOWUP_ID_RE = re.compile(r"^[0-9a-f]{4,6}$")
NOTE_RE = re.compile(r"^\s*-\s*(\d{4}-\d{2}-\d{2} \d{1,2}:\d{2})\s*\|\s*([^|]*?)\s*\|\s*(.*?)\s*$")
ROUTES = [
    (re.compile(r"^/api/tasks/([^/]+)/status$"), "status"),
    (re.compile(r"^/api/tasks/([^/]+)/log$"), "log"),
    (re.compile(r"^/api/followups/([^/]+)/done$"), "fdone"),
    (re.compile(r"^/api/captures()$"), "capture"),
    (re.compile(r"^/api/captures/([^/]+)/accept$"), "accept"),
    (re.compile(r"^/api/captures/([^/]+)/dismiss$"), "dismiss"),
    (re.compile(r"^/api/notes/([^/]+)/dismiss$"), "note"),
    (re.compile(r"^/api/config()$"), "config"),
    (re.compile(r"^/api/meet/settings()$"), "meet-setting"),
    (re.compile(r"^/api/meet/([^/]+)/link$"), "meet-link"),
    (re.compile(r"^/api/meet/([^/]+/cards/[^/]+)$"), "meet-card"),
]
MEET_GET_RE = re.compile(r"^/api/meet/([^/]+)/(live|detail)$")
CSP = ("default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; "
       "font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; "
       "frame-ancestors 'none'; base-uri 'none'; form-action 'none'")


class HttpError(Exception):
    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code


# ---------------------------------------------------------------- state

def session_info(core, sid, sessions):
    s = sessions.get(sid) or {}
    cwd = s.get("cwd", "")
    return {"id": sid, "short": sid[:8], "folder": os.path.basename(cwd.rstrip("/")) if cwd else "",
            "start": core.fmt(s["start"]) if s.get("start") else "",
            "end": core.fmt(s["end"]) if s.get("end") else ""}


def task_info(core, x, fus, sessions, meetings):
    sess = [session_info(core, sid, sessions) for sid in x.get_list("sessions")]
    project = brain_projects.task_project(x, sessions)
    return {
        "slug": x.slug,
        "title": x.get("title"),
        "status": x.get("status") or "active",
        "created": x.get("created"),
        "updated": core.fmt(core.task_updated(x)),
        "goal": x.text_of("Goal"),
        "direction": x.text_of("Direction"),
        "next": x.text_of("Next"),
        "tickets": x.get_list("ticket"),
        "project": "" if project == brain_projects.UNFILED else project,
        "sessions": sess,
        "work_done": x.work_done(),
        "followups": [f.as_dict() for f in fus if f.slug == x.slug],
        "meetings": meetings.get(x.slug, []),
    }


def state(core):
    """Open tasks, plus tasks finished today."""
    t = core.now()
    _, fus = core.load_followups()
    sessions = core.load_sessions()
    meetings = brain_meet.task_meetings(core)
    out = []
    for x in core.all_tasks():
        if x.get("status") == "done" and core.task_updated(x).date() != t.date():
            continue
        out.append(task_info(core, x, fus, sessions, meetings))
    loose = [f.as_dict() for f in fus if not f.done and not os.path.isfile(core.task_path(f.slug))]
    return {"now": core.fmt(t), "model": core.load_config().get("AGENT_MODEL") or "haiku", "tasks": out, "captures": brain_captures.open_captures(core),
            "notes": notes(core), "reminders": loose, "projects": brain_projects.projects(core),
            "meet": brain_meet.overview(core)}


def notes(core):
    """The brain's messages to the owner (inbox.md), newest last."""
    out = []
    for line in core.inbox_items():
        m = NOTE_RE.match(line)
        at, task, text = m.groups() if m else ("", "", line.lstrip("- "))
        out.append({"id": core.short_id(line), "at": at, "task": task, "text": text})
    return out


# ---------------------------------------------------------------- actions

def require_task(core, slug):
    if not core.slug_ok(slug) or not os.path.isfile(core.task_path(slug)):
        raise HttpError(404, "no task %r" % slug)


def act(core, kind, ident, body):
    if kind == "status":
        require_task(core, ident)
        status = body.get("status")
        if status not in core.STATUSES:
            raise HttpError(400, "status must be one of %s" % ", ".join(core.STATUSES))
        core.set_field(ident, "status", status)
    elif kind == "log":
        require_task(core, ident)
        text = body.get("text")
        if not isinstance(text, str) or not text.strip():
            raise HttpError(400, "write something to post")
        core.log_entry(ident, text)
    elif kind == "fdone":
        if not FOLLOWUP_ID_RE.match(ident):
            raise HttpError(404, "no follow-up %r" % ident)
        result = body.get("result") or "done"
        if not isinstance(result, str):
            raise HttpError(400, "result must be text")
        with core.write_lock():
            core.tick_followup(ident, core.one_line(result, 200))
    elif kind == "capture":
        text = body.get("text")
        if not isinstance(text, str) or not text.strip():
            raise HttpError(400, "write something to capture")
        brain_captures.add(core, text, "WEB")
    elif kind in ("accept", "dismiss"):
        if not FOLLOWUP_ID_RE.match(ident):
            raise HttpError(404, "no capture %r" % ident)
        if kind == "dismiss":
            brain_captures.dismiss(core, ident)
            return
        ckind, dest = body.get("kind"), body.get("dest")
        if ckind is not None and ckind not in brain_captures.KINDS:
            raise HttpError(400, "kind must be one of %s" % ", ".join(brain_captures.KINDS))
        if dest is not None and (not isinstance(dest, str) or (dest and not core.slug_ok(dest))):
            raise HttpError(400, "dest must be a task slug")
        brain_captures.accept(core, ident, ckind, dest or None)
    elif kind == "config":
        key, value = body.get("key"), body.get("value")
        if not isinstance(key, str) or not isinstance(value, str):
            raise HttpError(400, "send key and value")
        brain_status.set_config(core, key, value, page=True)
    elif kind == "note":
        lines = [l for l in core.inbox_items() if core.short_id(l) == ident]
        if not lines:
            raise HttpError(404, "no note %r" % ident)
        core.clear_inbox(lines)
    elif kind == "meet-setting":
        key, value = body.get("key"), body.get("value")
        if not isinstance(key, str) or not isinstance(value, bool):
            raise HttpError(400, "send key and an on/off value")
        brain_meet.set_setting(core, key, value)
    elif kind == "meet-link":
        slug = body.get("slug")
        if not isinstance(slug, str):
            raise HttpError(400, "send the task slug")
        brain_meet.link(core, ident, slug)
    elif kind == "meet-card":
        mid, _, cid = ident.partition("/cards/")
        action, dest = body.get("action"), body.get("dest")
        if not isinstance(action, str) or (dest is not None and not isinstance(dest, str)):
            raise HttpError(400, "send an action")
        brain_meet.card_act(core, mid, cid, action, dest)


# ---------------------------------------------------------------- http

class Handler(BaseHTTPRequestHandler):
    server_version = "brain"
    sys_version = ""

    # -- checks -------------------------------------------------------
    def allowed_hosts(self):
        port = self.server.server_address[1]
        return ("127.0.0.1:%d" % port, "localhost:%d" % port)

    def check_host(self):
        if self.headers.get("Host", "") not in self.allowed_hosts():
            raise HttpError(403, "wrong host")

    def check_token(self):
        given = self.headers.get("X-Brain-Token", "")
        if not hmac.compare_digest(given.encode(), self.server.token.encode()):
            raise HttpError(403, "missing or wrong token")

    def check_origin(self):
        origin = self.headers.get("Origin")
        if origin and origin not in ["http://" + h for h in self.allowed_hosts()]:
            raise HttpError(403, "cross-site request refused")

    def read_json(self):
        ctype = self.headers.get("Content-Type", "").split(";")[0].strip().lower()
        if ctype != "application/json":
            raise HttpError(415, "send application/json")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise HttpError(400, "bad Content-Length")
        if length > MAX_BODY:
            raise HttpError(413, "body too large")
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError):
            raise HttpError(400, "body is not valid JSON")
        if not isinstance(body, dict):
            raise HttpError(400, "body must be a JSON object")
        return body

    # -- responses ----------------------------------------------------
    def send(self, code, data, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CSP)
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, code, obj):
        self.send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                  "application/json; charset=utf-8")

    def fail(self, e):
        if isinstance(e, HttpError):
            self.send_json(e.code, {"ok": False, "error": str(e)})
        elif isinstance(e, self.server.core.BrainError):
            self.send_json(400, {"ok": False, "error": str(e)})
        else:
            sys.stderr.write("brain serve: %s: %s\n" % (type(e).__name__, e))
            self.send_json(500, {"ok": False, "error": "internal error; see the serve terminal"})

    # -- methods ------------------------------------------------------
    def do_GET(self):
        try:
            self.check_host()
            path = urlsplit(self.path).path
            m = ASSET_RE.match(path)
            if path in PAGES or (m and os.path.isfile(os.path.join(WEB_DIR, path[1:]))):
                name = "index.html" if path in PAGES else path[1:]
                with open(os.path.join(WEB_DIR, name), "rb") as f:
                    data = f.read()
                if name == "index.html":
                    data = data.replace(TOKEN_PLACEHOLDER.encode(), self.server.token.encode())
                return self.send(200, data, CTYPES[name.rsplit(".", 1)[1]])
            if path == "/api/state":
                self.check_token()
                return self.send_json(200, state(self.server.core))
            if path == "/api/ask":
                self.check_token()
                return self.send_json(200, {"history": brain_ask.history(self.server.core)})
            if path == "/api/graph":
                self.check_token()
                return self.send_json(200, brain_graph.graph(self.server.core))
            if path == "/api/status":
                self.check_token()
                return self.send_json(200, brain_status.status(self.server.core))
            if path == "/api/meet":
                self.check_token()
                return self.send_json(200, brain_meet.status(self.server.core))
            m = MEET_GET_RE.match(path)
            if m:
                self.check_token()
                fn = brain_meet.live if m.group(2) == "live" else brain_meet.detail
                return self.send_json(200, fn(self.server.core, m.group(1)))
            if path == "/api/search":
                self.check_token()
                q = parse_qs(urlsplit(self.path).query).get("q", [""])[0][:200]
                return self.send_json(200, {"results": brain_search.search(self.server.core, q)})
            raise HttpError(404, "not found")
        except Exception as e:  # every error becomes a JSON reply
            self.fail(e)

    def do_POST(self):
        try:
            self.check_host()
            self.check_origin()
            self.check_token()
            path = urlsplit(self.path).path
            if path == "/api/ask":
                body = self.read_json()
                q = body.get("question")
                if not isinstance(q, str) or not q.strip():
                    raise HttpError(400, "ask a question")
                try:
                    return self.send_json(200, brain_ask.ask(self.server.core, q))
                except brain_ask.AskError as e:
                    raise HttpError(429, str(e))
            if path in ("/api/meet/start", "/api/meet/stop"):
                body = self.read_json()
                core = self.server.core
                try:
                    if path.endswith("start"):
                        title, task, app = body.get("title") or "", body.get("task") or None, body.get("app") or ""
                        if not all(isinstance(v, str) for v in (title, app)) or (task and not isinstance(task, str)):
                            raise HttpError(400, "title, task and app must be text")
                        m = brain_meet.start(core, title, task, core.one_line(app, 40))
                    else:
                        m = brain_meet.stop(core)
                except brain_meet.MeetError as e:
                    raise HttpError(409, str(e))
                return self.send_json(200, {"ok": True, "meeting": m})
            for rx, kind in ROUTES:
                m = rx.match(path)
                if m:
                    act(self.server.core, kind, m.group(1), self.read_json())
                    return self.send_json(200, {"ok": True, "state": state(self.server.core)})
            raise HttpError(404, "not found")
        except Exception as e:
            self.fail(e)

    def log_message(self, fmt, *args):
        if len(args) > 1 and str(args[1])[:1] in ("4", "5"):
            sys.stderr.write("brain serve: %s\n" % (fmt % args))


def serve(port, open_browser, core):
    try:
        httpd = HTTPServer(("127.0.0.1", port), Handler)
    except OSError as e:
        raise core.BrainError("cannot listen on 127.0.0.1:%d (%s); try --port N" % (port, e))
    httpd.token = secrets.token_hex(24)
    httpd.core = core
    # Calls are watched while the server runs: a pop-up when one starts, a stop when it ends.
    threading.Thread(target=brain_meet.watch, args=(core,), daemon=True).start()
    url = "http://127.0.0.1:%d/" % httpd.server_address[1]
    sys.stdout.write("brain serve: %s  (Rami; Ctrl-C to stop)\n" % url)
    sys.stdout.flush()
    if open_browser:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0
