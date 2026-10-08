#!/usr/bin/env python3
"""brain: the deterministic core of the second brain.

Standard library only. Must run on the python3 that ships with macOS
(3.9), so no match statements or `X | Y` type syntax.
"""
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
BRAIN = os.environ.get("BRAIN_HOME") or os.path.join(HOME, "brain")
TASKS = os.path.join(BRAIN, "tasks")
ARCHIVE = os.path.join(BRAIN, "archive")
STATE = os.path.join(BRAIN, ".state")
DECISIONS = os.path.join(BRAIN, "decisions.md")
FOLLOWUPS = os.path.join(BRAIN, "followups.md")
INBOX = os.path.join(BRAIN, "inbox.md")
SESSIONS = os.path.join(BRAIN, "sessions.log")
CONFIG = os.path.join(BRAIN, "config")
BIN = os.path.join(BRAIN, "bin")
BRAIN_CMD = os.path.join(BIN, "brain")

TS = "%Y-%m-%d %H:%M"
DAY = "%Y-%m-%d"
LOG_LINE_MAX = 300
BOARD_TASKS = 25
BOARD_FOLLOWUPS = 10
BOARD_INBOX = 8
LINE_MAX = 160
TRANSCRIPT_TAIL_LINES = 200
STATUSES = ("active", "waiting", "blocked", "done")

DEFAULT_CONFIG = [
    ("TICK_MINUTES", "15"),
    ("WORK_HOURS", "08:00-18:00 Mon-Fri"),
    ("STALE_TASK_DAYS", "2"),
    ("STALLED_SESSION_MINUTES", "60"),
    ("ARCHIVE_AFTER_DAYS", "14"),
    ("AGENT_MODEL", "haiku"),
    ("NOTIFY", "on"),
    # Extras (not in the spec table, documented in README):
    ("SESSION_UPDATE_GAP_MINUTES", "30"),
    ("IDLE_ASK_MINUTES", "10"),
    ("AGENT_MAX_TRANSCRIPTS", "5"),
    ("AGENT_MAX_RESUMES", "2"),
    ("AGENT_TIMEOUT_MINUTES", "15"),
    ("CLAUDE_BIN", ""),
]

# Environment variables a nested `claude` must not inherit: they would make
# it reuse the parent's session id or think it is a child session.
SCRUB_ENV = ("CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_REMOTE_SESSION_ID",
             "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT")


class BrainError(Exception):
    pass


# --------------------------------------------------------------------------
# small helpers

def now():
    return dt.datetime.now().replace(second=0, microsecond=0)


def fmt(t):
    return t.strftime(TS)


def parse_ts(s):
    s = (s or "").strip()
    for f in (TS, DAY, "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S"):
        try:
            return dt.datetime.strptime(s, f)
        except ValueError:
            pass
    return None


def read(path, default=""):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (IOError, OSError):
        return default


def write_atomic(path, text):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def append_line(path, line):
    # O_APPEND: a single short write is atomic, so concurrent hooks are safe.
    with open(path, "a", encoding="utf-8") as f:
        f.write(line.rstrip("\n") + "\n")


def one_line(s, n=LINE_MAX):
    s = re.sub(r"\s+", " ", (s or "")).strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def short_id(text):
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:6]


def slug_ok(slug):
    return bool(re.match(r"^[a-z0-9]+(-[a-z0-9]+){1,3}$", slug or ""))


# --------------------------------------------------------------------------
# locking (mkdir is atomic on every filesystem we care about)

class Lock(object):
    def __init__(self, name, wait=10.0, stale=300):
        self.path = os.path.join(STATE, name + ".lock")
        self.wait = wait
        self.stale = stale
        self.held = False

    def _stale(self):
        try:
            pid = int(read(os.path.join(self.path, "pid")).strip() or 0)
        except ValueError:
            pid = 0
        if pid:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            except PermissionError:
                pass
        try:
            return time.time() - os.path.getmtime(self.path) > self.stale
        except OSError:
            return False

    def acquire(self):
        if not os.path.isdir(STATE):
            os.makedirs(STATE)
        deadline = time.time() + self.wait
        while True:
            try:
                os.mkdir(self.path)
                with open(os.path.join(self.path, "pid"), "w") as f:
                    f.write(str(os.getpid()))
                self.held = True
                return True
            except FileExistsError:
                if self._stale():
                    shutil.rmtree(self.path, ignore_errors=True)
                    continue
                if time.time() >= deadline:
                    return False
                time.sleep(0.1)

    def release(self):
        if self.held:
            shutil.rmtree(self.path, ignore_errors=True)
            self.held = False

    def __enter__(self):
        if not self.acquire():
            raise BrainError("store is busy (lock %s); try again" % self.path)
        return self

    def __exit__(self, *a):
        self.release()


def write_lock():
    return Lock("write", wait=15.0, stale=120)


# --------------------------------------------------------------------------
# config

def load_config():
    cfg = dict(DEFAULT_CONFIG)
    for line in read(CONFIG).splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        cfg[k.strip()] = v
    return cfg


def cfg_int(cfg, key):
    try:
        return int(cfg.get(key, ""))
    except ValueError:
        return int(dict(DEFAULT_CONFIG)[key])


DAYNAMES = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


def parse_work_hours(spec):
    """'08:00-18:00 Mon-Fri' -> (start_minute, end_minute, set_of_weekdays)."""
    m = re.match(r"^\s*(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*(.*)$", spec or "")
    if not m:
        return 8 * 60, 18 * 60, set(range(5))
    start = int(m.group(1)) * 60 + int(m.group(2))
    end = int(m.group(3)) * 60 + int(m.group(4))
    days = set()
    rest = m.group(5).strip().lower().replace(" ", "")
    if not rest:
        return start, end, set(range(5))
    for part in rest.split(","):
        if "-" in part:
            a, b = part.split("-", 1)
            if a[:3] in DAYNAMES and b[:3] in DAYNAMES:
                i, j = DAYNAMES.index(a[:3]), DAYNAMES.index(b[:3])
                k = i
                while True:
                    days.add(k)
                    if k == j:
                        break
                    k = (k + 1) % 7
        elif part[:3] in DAYNAMES:
            days.add(DAYNAMES.index(part[:3]))
    return start, end, days or set(range(5))


def in_work_hours(cfg, t):
    start, end, days = parse_work_hours(cfg.get("WORK_HOURS"))
    mins = t.hour * 60 + t.minute
    return t.weekday() in days and start <= mins < end


def working_days_since(cfg, then, t):
    """Working days strictly after `then`'s date, up to and including t's date."""
    _, _, days = parse_work_hours(cfg.get("WORK_HOURS"))
    n = 0
    d = then.date() + dt.timedelta(days=1)
    while d <= t.date():
        if d.weekday() in days:
            n += 1
        d += dt.timedelta(days=1)
    return n


def next_workday_at(cfg, t, hour=9, minute=0):
    _, _, days = parse_work_hours(cfg.get("WORK_HOURS"))
    d = t.date() + dt.timedelta(days=1)
    for _ in range(14):
        if d.weekday() in days:
            break
        d += dt.timedelta(days=1)
    return dt.datetime(d.year, d.month, d.day, hour, minute)


def parse_when(cfg, s, base=None):
    """+30m, +2h, +1d, next-workday, HH:MM, tomorrow [HH:MM], YYYY-MM-DD [HH:MM]."""
    base = base or now()
    s = (s or "").strip().lower()
    m = re.match(r"^\+(\d+)\s*(m|min|mins|h|hr|hrs|d|day|days)$", s)
    if m:
        n, u = int(m.group(1)), m.group(2)[0]
        delta = {"m": dt.timedelta(minutes=n), "h": dt.timedelta(hours=n),
                 "d": dt.timedelta(days=n)}[u]
        return base + delta
    if s in ("next-workday", "next-working-day", "nwd"):
        return next_workday_at(cfg, base)
    m = re.match(r"^tomorrow(?:\s+(\d{1,2}):(\d{2}))?$", s)
    if m:
        d = base.date() + dt.timedelta(days=1)
        h, mi = (int(m.group(1)), int(m.group(2))) if m.group(1) else (9, 0)
        return dt.datetime(d.year, d.month, d.day, h, mi)
    m = re.match(r"^(\d{1,2}):(\d{2})$", s)
    if m:
        t = base.replace(hour=int(m.group(1)), minute=int(m.group(2)))
        return t if t > base else t + dt.timedelta(days=1)
    t = parse_ts(s)
    if t:
        if len(s) <= 10:
            t = t.replace(hour=9, minute=0)
        return t
    raise BrainError("cannot read time %r (use +30m, +2h, +1d, next-workday, "
                     "HH:MM, tomorrow, or YYYY-MM-DD HH:MM)" % s)


# --------------------------------------------------------------------------
# task files

SECTION_ORDER = ["Goal", "Direction", "Next", "Log"]
# Log headings: "### YYYY-MM-DD | session abcd1234 (folder)" or "| background".
LOG_HEAD_RE = re.compile(r"^###\s+(\d{4}-\d{2}-\d{2})\s*\|\s*(.*?)\s*$")
LOG_ITEM_RE = re.compile(r"^\s*-\s*(\d{1,2}:\d{2})\s+(.*?)\s*$")
OLD_PROGRESS_RE = re.compile(r"^\s*-\s*(\d{4}-\d{2}-\d{2})\s+(\d{1,2}:\d{2})\s+(.*?)\s*$")
# Lines the brain writes itself; they do not count as a record of the work.
AUTO_LOG_PREFIXES = ("Session linked", "Task created")


class Task(object):
    def __init__(self, path):
        self.path = path
        self.slug = os.path.basename(path)[:-3]
        self.fm = []          # list of [key, value]
        self.sections = []    # list of [heading, [lines]]
        self.pre = []
        self.parse(read(path))

    # parsing ----------------------------------------------------------
    def parse(self, text):
        lines = text.splitlines()
        i = 0
        if lines and lines[0].strip() == "---":
            i = 1
            while i < len(lines) and lines[i].strip() != "---":
                ln = lines[i]
                if ":" in ln and not ln.startswith((" ", "\t")):
                    k, v = ln.split(":", 1)
                    v = re.sub(r"\s+#\s.*$", "", v).strip()
                    if v.startswith("#"):
                        v = ""
                    self.fm.append([k.strip(), v])
                i += 1
            i += 1
        cur = None
        for ln in lines[i:]:
            m = re.match(r"^##\s+(.*?)\s*$", ln)
            if m:
                cur = [m.group(1), []]
                self.sections.append(cur)
            elif cur is None:
                if ln.strip():
                    self.pre.append(ln)
            else:
                cur[1].append(ln)
        for s in self.sections:
            while s[1] and not s[1][-1].strip():
                s[1].pop()
            while s[1] and not s[1][0].strip():
                s[1].pop(0)

    def get(self, key, default=""):
        for k, v in self.fm:
            if k == key:
                return v
        return default

    def set(self, key, value):
        for kv in self.fm:
            if kv[0] == key:
                kv[1] = value
                return
        self.fm.append([key, value])

    def get_list(self, key):
        v = self.get(key).strip()
        if v.startswith("[") and v.endswith("]"):
            v = v[1:-1]
        return [x.strip().strip("\"'") for x in v.split(",") if x.strip().strip("\"'")]

    def set_list(self, key, items):
        self.set(key, "[" + ", ".join(items) + "]")

    def section(self, name):
        for s in self.sections:
            if s[0].lower() == name.lower():
                return s[1]
        return None

    def set_section(self, name, lines):
        for s in self.sections:
            if s[0].lower() == name.lower():
                s[1] = list(lines)
                return
        # insert in canonical order
        new = [name, list(lines)]
        if name in SECTION_ORDER:
            idx = SECTION_ORDER.index(name)
            for j, s in enumerate(self.sections):
                if s[0] in SECTION_ORDER and SECTION_ORDER.index(s[0]) > idx:
                    self.sections.insert(j, new)
                    return
        self.sections.append(new)

    def remove_section(self, name):
        self.sections = [s for s in self.sections if s[0].lower() != name.lower()]

    def text_of(self, name):
        return "\n".join(self.section(name) or []).strip()

    def log_entries(self):
        """[(datetime, source, text)] in file order (oldest first)."""
        out, day, src = [], None, ""
        for ln in self.section("Log") or []:
            m = LOG_HEAD_RE.match(ln)
            if m:
                day, src = m.group(1), m.group(2)
                continue
            m = LOG_ITEM_RE.match(ln)
            if m and day:
                out.append((parse_ts("%s %s" % (day, m.group(1))), src, m.group(2)))
        return out

    # rendering -------------------------------------------------------
    def render(self):
        out = ["---"]
        for k, v in self.fm:
            out.append(("%s: %s" % (k, v)).rstrip())
        out.append("---")
        out.extend(self.pre)
        for name, lines in self.sections:
            out.append("## " + name)
            out.extend(lines)
            out.append("")
        while out and not out[-1].strip():
            out.pop()
        return "\n".join(out) + "\n"

    def touch(self, t=None):
        self.set("updated", fmt(t or now()))

    def save(self):
        self.migrate()
        write_atomic(self.path, self.render())

    def migrate(self):
        """Move an old-format Progress section (newest first) into the Log."""
        prog = self.section("Progress")
        if prog is None:
            return False
        moved, day = [], None
        for ln in reversed([l for l in prog if l.strip()]):
            m = OLD_PROGRESS_RE.match(ln)
            if m:
                if m.group(1) != day:
                    day = m.group(1)
                    if moved:
                        moved.append("")
                    moved.append("### %s | earlier" % day)
                moved.append("- %s %s" % (m.group(2), m.group(3)))
            elif ln.strip():
                moved.append(ln)
        rest = self.section("Log") or []
        self.remove_section("Progress")
        self.set_section("Log", moved + ([""] if moved and rest else []) + rest)
        return True

    def as_dict(self, archived=False):
        return {
            "slug": self.slug,
            "archived": archived,
            "path": os.path.relpath(self.path, BRAIN),
            "title": self.get("title"),
            "status": self.get("status"),
            "ticket": self.get_list("ticket"),
            "created": self.get("created"),
            "updated": self.get("updated"),
            "sessions": self.get_list("sessions"),
            "goal": self.text_of("Goal"),
            "direction": self.text_of("Direction"),
            "log": [{"at": fmt(w) if w else "", "source": src, "text": txt}
                    for w, src, txt in self.log_entries()],
            "next": self.text_of("Next"),
            "markdown": read(self.path),
        }


def task_path(slug):
    return os.path.join(TASKS, slug + ".md")


def load_task(slug):
    p = task_path(slug)
    if not os.path.isfile(p):
        raise BrainError("no task %r (see `brain board`)" % slug)
    return Task(p)


def all_tasks():
    out = []
    if os.path.isdir(TASKS):
        for n in sorted(os.listdir(TASKS)):
            if n.endswith(".md") and not n.startswith("_"):
                out.append(Task(os.path.join(TASKS, n)))
    return out


def archived_tasks():
    out = []
    for root, _, files in os.walk(ARCHIVE):
        for n in sorted(files):
            if n.endswith(".md"):
                out.append(Task(os.path.join(root, n)))
    return out


def task_updated(t):
    return parse_ts(t.get("updated")) or parse_ts(t.get("created")) or \
        dt.datetime.fromtimestamp(os.path.getmtime(t.path))


def session_task_map(tasks=None):
    m = {}
    for t in tasks if tasks is not None else all_tasks():
        for sid in t.get_list("sessions"):
            m.setdefault(sid, []).append(t)
    return m


# --------------------------------------------------------------------------
# follow-ups

FU_RE = re.compile(r"^\s*-\s*\[( |x|X)\]\s*(\d{4}-\d{2}-\d{2} \d{1,2}:\d{2})\s*\|\s*([^|]*?)\s*\|\s*(.*?)\s*$")


class Followup(object):
    def __init__(self, idx, raw, m):
        self.idx = idx
        self.raw = raw
        self.done = m.group(1) != " "
        self.due = parse_ts(m.group(2))
        self.slug = m.group(3).strip()
        self.what = m.group(4).strip()
        self.id = short_id("%s|%s|%s" % (m.group(2), self.slug, self.what))

    @property
    def reminder(self):
        return self.what.lower().startswith("remind")

    def as_dict(self):
        return {"id": self.id, "done": self.done, "due": fmt(self.due) if self.due else "",
                "task": self.slug, "what": self.what, "reminder": self.reminder}


def load_followups():
    lines = read(FOLLOWUPS).splitlines()
    fus = []
    for i, ln in enumerate(lines):
        m = FU_RE.match(ln)
        if m:
            fus.append(Followup(i, ln, m))
    return lines, fus


def find_followup(fid):
    lines, fus = load_followups()
    for f in fus:
        if f.id == fid or f.id.startswith(fid):
            return lines, f
    raise BrainError("no follow-up with id %r" % fid)


def tick_followup(fid, result=None, source=None):
    """Tick a follow-up; note the result on the task. Caller holds write lock."""
    lines, f = find_followup(fid)
    if f.done:
        return f
    lines[f.idx] = re.sub(r"\[ \]", "[x]", lines[f.idx], count=1)
    write_atomic(FOLLOWUPS, "\n".join(lines) + "\n")
    if result and os.path.isfile(task_path(f.slug)):
        t = load_task(f.slug)
        add_log(t, "Follow-up checked (%s): %s" % (one_line(f.what, 80), result), source=source)
        t.save()
    return f


def log_source(session=None, source=None):
    """Heading source for a log entry: the session it came from, else background."""
    if source:
        return source
    sid = session
    if not sid and not is_agent_run():
        sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not sid:
        return "background"
    cwd = load_sessions().get(sid, {}).get("cwd", "")
    return "session %s%s" % (sid[:8], " (%s)" % os.path.basename(cwd.rstrip("/")) if cwd else "")


def log_blocks(lines):
    """Split Log lines into [[heading, [item lines]]]; text before any heading is kept."""
    blocks = [[None, []]]
    for ln in lines:
        if ln.startswith("### "):
            blocks.append([ln.strip(), []])
        elif ln.strip():
            blocks[-1][1].append(ln)
    return blocks if blocks[0][1] else blocks[1:]


def block_time(block, last=False):
    """Time of a block's first item (or last item), from its heading's day."""
    m = LOG_HEAD_RE.match(block[0] or "")
    items = [i for i in (LOG_ITEM_RE.match(l) for l in block[1]) if i]
    if last:
        items = items[::-1]
    hm = items[0].group(1) if items else "00:00"
    return parse_ts("%s %s" % (m.group(1), hm)) if m else None


def add_log(t, text, when=None, session=None, source=None):
    """Add one line to the task's Log under the heading for its day and source.

    A normal entry is appended. A backdated one (when < now) goes into the
    block for that day and source, or a new block placed in time order, so a
    summary written later still sits where the work happened."""
    at = when or now()
    head = "### %s | %s" % (at.strftime(DAY), log_source(session, source))
    item = "- %s %s" % (at.strftime("%H:%M"), one_line(text, LOG_LINE_MAX))
    blocks = log_blocks(t.section("Log") or [])
    backdated = when is not None and blocks and (block_time(blocks[-1], last=True) or at) > at
    if not backdated:
        if blocks and blocks[-1][0] == head:
            blocks[-1][1].append(item)
        else:
            blocks.append([head, [item]])
    else:
        same = [b for b in blocks if b[0] == head]
        if same:
            b = same[-1]
            pos = len(b[1])
            for i, ln in enumerate(b[1]):
                m = LOG_ITEM_RE.match(ln)
                if m and m.group(1).zfill(5) > at.strftime("%H:%M"):
                    pos = i
                    break
            b[1].insert(pos, item)
        else:
            pos = len(blocks)
            for i, b in enumerate(blocks):
                bt = block_time(b)
                if bt and bt > at:
                    pos = i
                    break
            blocks.insert(pos, [head, [item]])
    out = []
    for h, items in blocks:
        if out:
            out.append("")
        if h:
            out.append(h)
        out.extend(items)
    t.set_section("Log", out)
    t.touch(max(at, now()) if when else at)


def session_log_entries(t, sid):
    """Entries filed under this session's headings, minus the brain's own lines."""
    tag = "session " + sid[:8]
    return [(w, txt) for w, src, txt in t.log_entries()
            if src.startswith(tag) and not txt.startswith(AUTO_LOG_PREFIXES)]


# --------------------------------------------------------------------------
# sessions log

def load_sessions():
    """Return {sid: {start, end, cwd, transcript, last}} from sessions.log."""
    out = {}
    for ln in read(SESSIONS).splitlines():
        parts = [p.strip() for p in ln.split("|")]
        if len(parts) < 3:
            continue
        t = parse_ts(parts[0])
        kind, sid = parts[1], parts[2]
        if not sid or t is None:
            continue
        s = out.setdefault(sid, {"id": sid, "start": None, "end": None,
                                 "cwd": "", "transcript": ""})
        if kind == "start":
            s["start"] = s["start"] or t
            s["end"] = None if s["end"] and s["end"] < t else s["end"]
        elif kind == "end":
            s["end"] = t
        if len(parts) > 3 and parts[3] and not s["cwd"]:
            s["cwd"] = parts[3]
        if len(parts) > 4 and parts[4]:
            s["transcript"] = parts[4]
    return out


def find_transcript(sid, hint=""):
    if hint and os.path.isfile(hint):
        return hint
    base = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude"),
                        "projects")
    if os.path.isdir(base):
        for d in os.listdir(base):
            p = os.path.join(base, d, sid + ".jsonl")
            if os.path.isfile(p):
                return p
    return ""


def mtime(p):
    try:
        return dt.datetime.fromtimestamp(os.path.getmtime(p))
    except OSError:
        return None


# --------------------------------------------------------------------------
# state (tick bookkeeping, notification de-duplication, per-run limits)

def state_path(name):
    return os.path.join(STATE, name)


def load_state(name="state.json"):
    try:
        return json.loads(read(state_path(name)) or "{}")
    except ValueError:
        return {}


def save_state(st, name="state.json"):
    write_atomic(state_path(name), json.dumps(st, indent=1, sort_keys=True))


# --------------------------------------------------------------------------
# notifications and inbox

def notify(msg, task="", key=None, cfg=None):
    """Inbox line + macOS notification, at most once per key."""
    cfg = cfg or load_config()
    msg = one_line(msg, 200)
    if key:
        with Lock("notify", wait=10):
            st = load_state("notified.json")
            if key in st:
                return False
            st[key] = fmt(now())
            # forget keys older than 60 days
            cutoff = now() - dt.timedelta(days=60)
            st = dict((k, v) for k, v in st.items() if (parse_ts(v) or now()) >= cutoff)
            save_state(st, "notified.json")
    with write_lock():
        if not os.path.isfile(INBOX):
            write_atomic(INBOX, "# Inbox\n\n")
        append_line(INBOX, "- %s | %s | %s" % (fmt(now()), task or "-", msg))
    if cfg.get("NOTIFY", "on").lower() in ("on", "1", "yes", "true"):
        osa = shutil.which("osascript")
        if osa:
            title = "Brain" + (": " + task if task else "")
            script = 'display notification %s with title %s' % (
                applescript_str(msg), applescript_str(title))
            try:
                subprocess.run([osa, "-e", script], timeout=10,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
    return True


def applescript_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


INBOX_RE = re.compile(r"^\s*-\s*\d{4}-\d{2}-\d{2}")


def inbox_items():
    return [l for l in read(INBOX).splitlines() if INBOX_RE.match(l)]


def clear_inbox(shown):
    if not shown:
        return
    with write_lock():
        lines = read(INBOX).splitlines()
        shown_set = set(shown)
        keep = [l for l in lines if l not in shown_set]
        write_atomic(INBOX, "\n".join(keep).rstrip() + "\n")


# --------------------------------------------------------------------------
# git

def git(*args, **kw):
    return subprocess.run(["git", "-C", BRAIN] + list(args), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, universal_newlines=True, **kw)


def commit(message, push=True):
    """Commit everything; serialised by a lock, retried once. Returns True if committed."""
    if not os.path.isdir(os.path.join(BRAIN, ".git")):
        return False
    lk = Lock("commit", wait=20, stale=120)
    if not lk.acquire():
        return False
    try:
        committed = False
        for attempt in (1, 2):
            git("add", "-A")
            if git("diff", "--cached", "--quiet").returncode == 0:
                break
            r = git("commit", "-q", "-m", message)
            if r.returncode == 0:
                committed = True
                break
            # stale index.lock from a crashed git: remove if old, retry once
            il = os.path.join(BRAIN, ".git", "index.lock")
            if os.path.exists(il) and time.time() - os.path.getmtime(il) > 30:
                os.remove(il)
            time.sleep(0.5 * attempt)
    finally:
        lk.release()
    if committed and push and git("remote", "get-url", "origin").returncode == 0:
        log = open(state_path("push.log"), "a")
        subprocess.Popen(["git", "-C", BRAIN, "push", "-q", "origin", "HEAD"],
                         stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                         start_new_session=True)
    return committed


def spawn_detached(args):
    """Run `brain <args>` fully detached so hooks return at once."""
    if not os.path.isdir(STATE):
        os.makedirs(STATE)
    log = open(state_path("bg.log"), "a")
    subprocess.Popen([sys.executable, os.path.abspath(__file__)] + args,
                     stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                     start_new_session=True, cwd=BRAIN)


# --------------------------------------------------------------------------
# board

def board_text(session_id="", mark_read=False):
    cfg = load_config()
    t = now()
    out = ["# Brain board %s (%s)%s" % (fmt(t), t.strftime("%a"),
                                        (" | this session: " + session_id) if session_id else "")]
    out.append("Background bookkeeping, one line at most. As soon as this session starts "
               "real work (before the first file edit, before running a deploy, migration or "
               "release, or when a ticket/PR is named), use the `brain` skill to link this "
               "session to its task or create one, even for small work. Then record what "
               "happens as you go with `~/brain/bin/brain log SLUG \"...\"`: findings, "
               "changes, results, problems. Pure questions: do nothing, say nothing.")
    out.append("Add a follow-up (`~/brain/bin/brain followup`) BEFORE running a deploy/release "
               "(+30m), when a long build/test/migration starts, you wait on someone "
               "(next-workday), a task gets blocked (+1d), or the owner says 'remind me'.")
    tasks = [x for x in all_tasks() if x.get("status", "active") != "done"]
    order = {"blocked": 0, "active": 1, "waiting": 2}
    tasks.sort(key=lambda x: (order.get(x.get("status"), 3), -task_updated(x).timestamp()))
    out.append("")
    out.append("## Open tasks (%d)" % len(tasks))
    if not tasks:
        out.append("(none)")
    for x in tasks[:BOARD_TASKS]:
        upd = task_updated(x)
        stale = working_days_since(cfg, upd, t) > cfg_int(cfg, "STALE_TASK_DAYS") \
            and x.get("status") == "active"
        out.append(one_line("- %s [%s%s] %s | upd %s | next: %s" % (
            x.slug, x.get("status") or "active", ", stale" if stale else "",
            x.get("title"), upd.strftime("%m-%d %H:%M"), x.text_of("Next") or "-")))
    if len(tasks) > BOARD_TASKS:
        out.append("- … %d more: `~/brain/bin/brain board --all`" % (len(tasks) - BOARD_TASKS))
    _, fus = load_followups()
    open_fus = sorted([f for f in fus if not f.done], key=lambda f: f.due or t)
    out.append("")
    out.append("## Follow-ups (%d open, %d due)" % (
        len(open_fus), len([f for f in open_fus if f.due and f.due <= t])))
    if not open_fus:
        out.append("(none)")
    for f in open_fus[:BOARD_FOLLOWUPS]:
        mark = "DUE " if f.due and f.due <= t else ""
        out.append(one_line("- %s%s %s | %s | %s" % (mark, f.id, fmt(f.due), f.slug, f.what)))
    if len(open_fus) > BOARD_FOLLOWUPS:
        out.append("- … %d more in ~/brain/followups.md" % (len(open_fus) - BOARD_FOLLOWUPS))
    inbox = inbox_items()
    if inbox:
        out.append("")
        out.append("## Inbox (tell the owner briefly)")
        for l in inbox[-BOARD_INBOX:]:
            out.append(one_line(l))
        if len(inbox) > BOARD_INBOX:
            out.append("- … %d older notes cleared" % (len(inbox) - BOARD_INBOX))
        if mark_read:
            clear_inbox(inbox)
    return "\n".join(out) + "\n"


def board_all():
    out = []
    for x in all_tasks():
        out.append(one_line("- %s [%s] %s | upd %s | next: %s" % (
            x.slug, x.get("status"), x.get("title"), x.get("updated"),
            x.text_of("Next") or "-"), 200))
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------
# hooks

def read_hook_input():
    try:
        data = sys.stdin.read()
        return json.loads(data) if data.strip() else {}
    except Exception:
        return {}


def is_agent_run():
    return os.environ.get("BRAIN_AGENT") == "1"


def hook_start():
    if is_agent_run():
        return
    d = read_hook_input()
    sid = d.get("session_id", "")
    if not os.path.isdir(BRAIN):
        return
    try:
        if sid:
            append_line(SESSIONS, "%s | start | %s | %s | %s" % (
                fmt(now()), sid, d.get("cwd", ""), d.get("transcript_path", "")))
    except Exception:
        pass
    sys.stdout.write(board_text(sid, mark_read=True))


def hook_end():
    if is_agent_run():
        return
    d = read_hook_input()
    sid = d.get("session_id", "")
    if not os.path.isdir(BRAIN) or not sid:
        return
    append_line(SESSIONS, "%s | end | %s | %s | %s" % (
        fmt(now()), sid, d.get("cwd", ""), d.get("transcript_path", "")))
    spawn_detached(["commit", "session end %s" % sid[:8]])


# --------------------------------------------------------------------------
# transcripts

def tail_lines(path, n=TRANSCRIPT_TAIL_LINES, max_bytes=4 * 1024 * 1024):
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        block = 64 * 1024
        data = b""
        pos = size
        while pos > 0 and data.count(b"\n") <= n and size - pos < max_bytes:
            step = min(block, pos)
            pos -= step
            f.seek(pos)
            data = f.read(step) + data
    lines = data.split(b"\n")
    if pos > 0:
        lines = lines[1:]
    return [l.decode("utf-8", "replace") for l in lines if l.strip()][-n:]


def condense_entry(d):
    typ = d.get("type")
    msg = d.get("message") or {}
    if typ not in ("user", "assistant") or not isinstance(msg, dict):
        return None
    content = msg.get("content")
    parts = []
    if isinstance(content, str):
        parts.append(content)
    elif isinstance(content, list):
        for c in content:
            if not isinstance(c, dict):
                continue
            ct = c.get("type")
            if ct == "text":
                parts.append(c.get("text", ""))
            elif ct == "tool_use":
                inp = c.get("input") or {}
                arg = inp.get("command") or inp.get("file_path") or inp.get("pattern") \
                    or inp.get("description") or ""
                parts.append("[tool %s: %s]" % (c.get("name"), one_line(str(arg), 120)))
            elif ct == "tool_result":
                rc = c.get("content")
                if isinstance(rc, list):
                    rc = " ".join(x.get("text", "") for x in rc if isinstance(x, dict))
                parts.append("[result: %s]" % one_line(str(rc or ""), 160))
    text = one_line(" ".join(p for p in parts if p), 600)
    if not text:
        return None
    stamp = local_stamp(d.get("timestamp") or "")
    who = "OWNER" if typ == "user" and not text.startswith("[result") else typ.upper()
    return "%s %s: %s" % (stamp, who, text)


def local_stamp(iso):
    """'2026-10-08T18:07:12.345Z' (UTC) -> '2026-10-08 20:07' in local time."""
    try:
        u = dt.datetime.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return iso[:16].replace("T", " ")
    return u.astimezone().strftime(TS)


def transcript_summary(path):
    out = []
    for ln in tail_lines(path):
        try:
            d = json.loads(ln)
        except ValueError:
            continue
        c = condense_entry(d)
        if c:
            out.append(c)
    text = "\n".join(out)
    return text[-12000:]


EDIT_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")
TICKET_RE = re.compile(r"\b[A-Z][A-Z0-9]{1,9}-\d+\b|github\.com/[^\s/]+/[^\s/]+/(?:pull|issues)/\d+"
                       r"|linear\.app/|atlassian\.net/browse/")


def transcript_stats(path):
    """Cheap triviality check over the whole file: owner prompts, tool calls,
    file edits, and whether the owner mentioned a ticket."""
    prompts = tools = edits = 0
    ticket = False
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for ln in f:
                if '"type":"user"' not in ln and '"type":"assistant"' not in ln:
                    continue
                try:
                    d = json.loads(ln)
                except ValueError:
                    continue
                msg = d.get("message") or {}
                c = msg.get("content") if isinstance(msg, dict) else None
                if d.get("type") == "user":
                    texts = [c] if isinstance(c, str) else [
                        x.get("text", "") for x in (c or []) if isinstance(x, dict)
                        and x.get("type") == "text"] if isinstance(c, list) else []
                    if texts and not d.get("isMeta"):
                        prompts += 1
                        ticket = ticket or any(TICKET_RE.search(t or "") for t in texts)
                elif isinstance(c, list):
                    for x in c:
                        if isinstance(x, dict) and x.get("type") == "tool_use":
                            tools += 1
                            if x.get("name") in EDIT_TOOLS:
                                edits += 1
    except (IOError, OSError):
        pass
    return {"prompts": prompts, "tool_calls": tools, "edits": edits, "ticket": ticket}


def is_trivial(stats):
    return not stats["edits"] and not stats["ticket"] and stats["prompts"] <= 2 \
        and stats["tool_calls"] <= 2


def run_budget(kind):
    """Enforce per-run limits for agent transcript reads and resumes."""
    run = os.environ.get("BRAIN_RUN_ID")
    if not run:
        return
    cfg = load_config()
    limit = cfg_int(cfg, "AGENT_MAX_TRANSCRIPTS" if kind == "transcript" else "AGENT_MAX_RESUMES")
    with Lock("budget", wait=5):
        st = load_state("budget.json")
        if st.get("run") != run:
            st = {"run": run}
        used = st.get(kind, 0)
        if used >= limit:
            raise BrainError("limit reached: %d %s per run" % (limit, kind))
        st[kind] = used + 1
        save_state(st, "budget.json")


def clean_env(extra=None):
    env = dict(os.environ)
    for k in SCRUB_ENV:
        env.pop(k, None)
    env.update(extra or {})
    return env


def claude_bin(cfg):
    b = cfg.get("CLAUDE_BIN") or shutil.which("claude") or ""
    if not b:
        for c in (os.path.join(HOME, ".local/bin/claude"), os.path.join(HOME, ".claude/local/claude"),
                  "/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
            if os.path.isfile(c):
                return c
    return b


def cmd_ask(sid, question):
    cfg = load_config()
    sessions = load_sessions()
    s = sessions.get(sid)
    path = find_transcript(sid, s["transcript"] if s else "")
    if not path:
        raise BrainError("no transcript for session %s" % sid)
    idle = cfg_int(cfg, "IDLE_ASK_MINUTES")
    mt = mtime(path)
    if mt and now() - mt < dt.timedelta(minutes=idle):
        raise BrainError("session %s is live (transcript changed %s); not messaging it"
                         % (sid, fmt(mt)))
    cwd = (s or {}).get("cwd") or ""
    if not cwd or not os.path.isdir(cwd):
        raise BrainError("unknown or missing working directory for session %s" % sid)
    run_budget("resume")
    cb = claude_bin(cfg)
    if not cb:
        raise BrainError("claude CLI not found")
    args = [cb, "-p", "--resume", sid, "--fork-session", "--model", cfg.get("AGENT_MODEL", "haiku"),
            "--permission-mode", "dontAsk", "--max-turns", "2", "--output-format", "text"]
    r = subprocess.run(args, input=question, cwd=cwd, env=clean_env({"BRAIN_AGENT": "1"}),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       universal_newlines=True, timeout=300)
    return (r.stdout or r.stderr).strip()


# --------------------------------------------------------------------------
# tick

def archive_done(cfg, t):
    days = cfg_int(cfg, "ARCHIVE_AFTER_DAYS")
    moved = []
    for x in all_tasks():
        if x.get("status") != "done":
            continue
        upd = task_updated(x)
        if t - upd > dt.timedelta(days=days):
            d = os.path.join(ARCHIVE, upd.strftime("%Y"))
            if not os.path.isdir(d):
                os.makedirs(d)
            dest = os.path.join(d, x.slug + ".md")
            n = 2
            while os.path.exists(dest):
                dest = os.path.join(d, "%s-%d.md" % (x.slug, n))
                n += 1
            os.rename(x.path, dest)
            moved.append(x.slug)
    return moved


def prune_followups(t):
    """Drop ticked follow-ups older than 30 days (git keeps them)."""
    lines, fus = load_followups()
    drop = set(f.idx for f in fus if f.done and f.due and t - f.due > dt.timedelta(days=30))
    if drop:
        write_atomic(FOLLOWUPS, "\n".join(l for i, l in enumerate(lines) if i not in drop) + "\n")
    return len(drop)


def migrate_tasks():
    """Rewrite old-format tasks (Progress section) into the Log format."""
    fixed = []
    for x in all_tasks():
        if x.section("Progress") is not None:
            x.save()
            fixed.append(x.slug)
    return fixed


def find_work(cfg, t, st, in_hours):
    """Return (findings, direct_reminders). Pure inspection, no writes."""
    handled = st.setdefault("handled", {})
    findings = []
    reminders = []
    _, fus = load_followups()
    for f in fus:
        if f.done or not f.due or f.due > t:
            continue
        if f.reminder:
            reminders.append(f)
        elif in_hours:
            key = "fu:" + f.id
            tries = handled.get(key, {}).get("tries", 0)
            findings.append({"kind": "due_followup", "key": key, "tries": tries,
                             "id": f.id, "task": f.slug, "due": fmt(f.due), "what": f.what})
    if not in_hours:
        return findings, reminders

    tasks = all_tasks()
    smap = session_task_map(tasks)
    sessions = load_sessions()
    open_slugs = set(x.slug for x in tasks if x.get("status") != "done")
    gap = dt.timedelta(minutes=cfg_int(cfg, "SESSION_UPDATE_GAP_MINUTES"))
    stalled_after = dt.timedelta(minutes=cfg_int(cfg, "STALLED_SESSION_MINUTES"))
    recent = t - dt.timedelta(days=7)

    for sid, s in sessions.items():
        path = find_transcript(sid, s["transcript"])
        mt = mtime(path) if path else None
        linked = [x for x in smap.get(sid, [])]
        end = s["end"]
        if not end and not linked and mt and t - mt > stalled_after:
            # No end line (SessionEnd may not fire, e.g. app quit or crash):
            # an unlinked session idle this long is treated as ended.
            end = mt
        if end and end >= recent:
            if not linked:
                key = "unlinked:" + sid
                if key in handled:
                    continue
                if not path:
                    handled[key] = {"at": fmt(t), "note": "no transcript"}
                    continue
                stats = transcript_stats(path)
                if is_trivial(stats):
                    handled[key] = {"at": fmt(t), "note": "trivial"}
                    continue
                f = {"kind": "unlinked_session", "key": key, "session": sid,
                     "cwd": s["cwd"], "ended": fmt(end)}
                f.update(stats)
                findings.append(f)
            else:
                key = "update:%s:%s" % (sid, fmt(end))
                if key in handled or not mt:
                    continue
                for x in linked:
                    entries = session_log_entries(x, sid)
                    last = max([w for w, _ in entries if w] or [None]) if entries else None
                    if last is None or mt - last > gap:
                        if last is None and path and is_trivial(transcript_stats(path)):
                            continue
                        findings.append({"kind": "session_update", "key": key, "session": sid,
                                         "task": x.slug,
                                         "last_logged": fmt(last) if last else "nothing yet",
                                         "last_activity": fmt(mt), "ended": fmt(end)})
                        break
        elif not end and s["start"] and s["start"] >= recent - dt.timedelta(days=7):
            if not any(x.slug in open_slugs for x in linked) or not mt:
                continue
            if t - mt > stalled_after:
                key = "stalled:%s:%s" % (sid, fmt(mt))
                if key in handled:
                    continue
                findings.append({"kind": "stalled_session", "key": key, "session": sid,
                                 "task": linked[0].slug, "last_activity": fmt(mt),
                                 "cwd": s["cwd"]})

    stale_days = cfg_int(cfg, "STALE_TASK_DAYS")
    for x in tasks:
        if x.get("status", "active") != "active":
            continue
        upd = task_updated(x)
        if working_days_since(cfg, upd, t) > stale_days:
            key = "stale:%s:%s" % (x.slug, x.get("updated"))
            if key in handled:
                continue
            sids = x.get_list("sessions")
            findings.append({"kind": "stale_task", "key": key, "task": x.slug,
                             "updated": x.get("updated"),
                             "latest_session": sids[-1] if sids else ""})
    return findings, reminders


TRANSCRIPT_KINDS = ("session_update", "unlinked_session", "stalled_session", "stale_task")


def select_findings(cfg, findings):
    """Due follow-ups first; cap the ones that need transcripts."""
    cap = cfg_int(cfg, "AGENT_MAX_TRANSCRIPTS")
    order = {"due_followup": 0, "session_update": 1, "stalled_session": 2,
             "unlinked_session": 3, "stale_task": 4}
    findings = sorted(findings, key=lambda f: order[f["kind"]])
    chosen, n = [], 0
    for f in findings:
        if f["kind"] in TRANSCRIPT_KINDS:
            if n >= cap:
                continue
            n += 1
        chosen.append(f)
    return chosen[:12]


def run_agent(cfg, findings, run_id):
    prompt = read(os.path.join(BIN, "agent-prompt.md"))
    prompt = prompt.replace("{{NOW}}", fmt(now())).replace("{{BRAIN}}", BRAIN_CMD)
    prompt += "\n\n## Findings for this run\n\n```json\n%s\n```\n" % json.dumps(findings, indent=1)
    cb = claude_bin(cfg)
    if not cb:
        raise BrainError("claude CLI not found; set CLAUDE_BIN in ~/brain/config")
    allowed = ["Read", "Grep", "Glob",
               "Bash(%s *)" % BRAIN_CMD, "Bash(~/brain/bin/brain *)",
               "Bash(gh run view *)", "Bash(gh run list *)", "Bash(gh pr checks *)",
               "Bash(gh pr view *)", "Bash(gh release view *)", "Bash(curl -s *)",
               "Bash(curl -sS *)", "Bash(curl -I *)"]
    args = [cb, "-p", "--model", cfg.get("AGENT_MODEL") or "haiku",
            "--permission-mode", "dontAsk", "--allowedTools"] + allowed + \
        ["--max-turns", "40", "--output-format", "text"]
    r = subprocess.run(args, input=prompt, cwd=BRAIN,
                       env=clean_env({"BRAIN_AGENT": "1", "BRAIN_RUN_ID": run_id}),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                       timeout=60 * cfg_int(cfg, "AGENT_TIMEOUT_MINUTES"))
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def log(msg):
    try:
        append_line(state_path("tick.log"), "%s %s" % (fmt(now()), msg))
        p = state_path("tick.log")
        if os.path.getsize(p) > 512 * 1024:
            lines = read(p).splitlines()[-2000:]
            write_atomic(p, "\n".join(lines) + "\n")
    except Exception:
        pass


def cmd_tick(dry_run=False, no_agent=False, at=None):
    cfg = load_config()
    t = parse_ts(at) if at else now()
    lk = Lock("tick", wait=0, stale=60 * (cfg_int(cfg, "AGENT_TIMEOUT_MINUTES") + 5))
    if not lk.acquire():
        print("tick: another tick is running")
        return 0
    try:
        st = load_state()
        in_hours = in_work_hours(cfg, t)
        changed = []
        if not dry_run:
            with write_lock():
                moved = archive_done(cfg, t)
                pruned = prune_followups(t)
                migrated = migrate_tasks()
            if moved:
                changed.append("archived " + ", ".join(moved))
            if pruned:
                changed.append("pruned %d old follow-ups" % pruned)
            if migrated:
                changed.append("migrated " + ", ".join(migrated))
        findings, reminders = find_work(cfg, t, st, in_hours)

        # Reminders the owner set: deterministic, any hour.
        for f in reminders:
            if dry_run:
                print("reminder due: %s %s" % (f.id, f.what))
                continue
            notify(f.what, f.slug, key="reminder:" + f.id, cfg=cfg)
            with write_lock():
                tick_followup(f.id)
            changed.append("reminder " + f.id)

        # Give up on follow-ups the agent has failed twice: tell the owner instead.
        give_up = [f for f in findings if f["kind"] == "due_followup" and f["tries"] >= 2]
        findings = [f for f in findings if f not in give_up]
        for f in give_up:
            if not dry_run:
                notify("Could not check follow-up: %s" % f["what"], f["task"],
                       key="giveup:" + f["id"], cfg=cfg)
                with write_lock():
                    tick_followup(f["id"], "Follow-up not checked automatically: %s" % f["what"])
                changed.append("gave up " + f["id"])

        chosen = select_findings(cfg, findings)
        if dry_run:
            print(json.dumps({"in_work_hours": in_hours, "findings": chosen}, indent=1))
            return 0
        if not chosen:
            log("tick: nothing to do%s" % ("" if in_hours else " (quiet hours)"))
        else:
            run_id = "%s-%d" % (t.strftime("%Y%m%d%H%M"), os.getpid())
            ok = False
            if no_agent:
                out = "agent disabled (--no-agent)"
            else:
                try:
                    rc, out = run_agent(cfg, chosen, run_id)
                    ok = rc == 0
                except Exception as e:  # noqa
                    out = "agent failed: %s" % e
            log("tick: %d findings, agent %s\n%s" % (len(chosen), "ok" if ok else "FAILED",
                                                    out[-4000:]))
            handled = st.setdefault("handled", {})
            for f in chosen:
                if f["kind"] == "due_followup":
                    # still open after the run? count a try
                    _, fus = load_followups()
                    still = [x for x in fus if x.id == f["id"] and not x.done]
                    if still:
                        handled[f["key"]] = {"at": fmt(t), "tries": f["tries"] + 1}
                elif ok:
                    handled[f["key"]] = {"at": fmt(t)}
            if not ok and not no_agent:
                notify("Brain agent failed; see ~/brain/.state/tick.log", "",
                       key="agentfail:" + t.strftime("%Y%m%d"), cfg=cfg)
            changed.append("agent run (%d findings)" % len(chosen))
        cutoff = t - dt.timedelta(days=30)
        st["handled"] = dict((k, v) for k, v in st.get("handled", {}).items()
                             if (parse_ts(v.get("at")) or t) >= cutoff)
        st["last_tick"] = fmt(t)
        save_state(st)
        if changed:
            commit("tick: " + "; ".join(changed)[:200])
        return 0
    finally:
        lk.release()


# --------------------------------------------------------------------------
# export

DEC_HEAD = re.compile(r"^##\s+(\d{4}-\d{2}-\d{2})\s*\|\s*([^|]*?)\s*\|\s*(.*?)\s*$")


def parse_decisions():
    out = []
    cur = None
    for ln in read(DECISIONS).splitlines():
        m = DEC_HEAD.match(ln)
        if m:
            cur = {"date": m.group(1), "task": m.group(2), "title": m.group(3),
                   "decision": "", "why": "", "rejected": "", "raw": ln}
            out.append(cur)
            continue
        if cur is None:
            continue
        cur["raw"] += "\n" + ln
        m = re.match(r"^\s*-\s*(Decision|Why|Rejected)\s*:\s*(.*)$", ln, re.I)
        if m:
            cur[m.group(1).lower()] = m.group(2).strip()
    for d in out:
        d["raw"] = d["raw"].rstrip()
    return out


def export_data():
    tasks = [x.as_dict() for x in all_tasks()] + [x.as_dict(True) for x in archived_tasks()]
    _, fus = load_followups()
    sessions = load_sessions()
    smap = {}
    for x in tasks:
        for sid in x["sessions"]:
            smap.setdefault(sid, []).append(x["slug"])
    sess = []
    for sid in sorted(set(list(sessions) + list(smap))):
        s = sessions.get(sid, {})
        sess.append({"session_id": sid,
                     "start": fmt(s["start"]) if s.get("start") else None,
                     "end": fmt(s["end"]) if s.get("end") else None,
                     "cwd": s.get("cwd", ""), "transcript_path": s.get("transcript", ""),
                     "tasks": smap.get(sid, [])})
    return {"format": "brain-export/1", "exported": fmt(now()), "tasks": tasks,
            "decisions": parse_decisions(), "followups": [f.as_dict() for f in fus],
            "sessions": sess, "inbox": inbox_items()}


# --------------------------------------------------------------------------
# write commands used by the skill and the agent

TEMPLATE = """---
title: {title}
status: active
ticket: {ticket}
created: {created}
updated: {updated}
sessions: [{sessions}]
---
## Goal
{goal}

## Direction
{direction}

## Next
{next}

## Log
"""


def limit_lines(text, n):
    lines = [l for l in (text or "").strip().splitlines() if l.strip()]
    return "\n".join(lines[:n])


def cmd_new(a):
    slug = a.slug
    if not slug_ok(slug):
        raise BrainError("slug must be kebab-case, 2 to 4 words: %r" % slug)
    if os.path.exists(task_path(slug)):
        raise BrainError("task %s already exists" % slug)
    t = now()
    text = TEMPLATE.format(title=one_line(a.title, 80), ticket=", ".join(a.ticket or []),
                           created=t.strftime(DAY), updated=fmt(t),
                           sessions=a.session or "", goal=limit_lines(a.goal or "TBD", 2),
                           direction=limit_lines(a.direction or "TBD", 4),
                           next=one_line(a.next or "TBD", 200))
    if a.ticket and len(a.ticket) > 1:
        text = text.replace("ticket: " + ", ".join(a.ticket), "ticket: [%s]" % ", ".join(a.ticket))
    with write_lock():
        write_atomic(task_path(slug), text)
        x = load_task(slug)
        add_log(x, "Task created", t, session=a.session)
        x.save()
    print("created task %s" % slug)


def cmd_link(slug, sid):
    with write_lock():
        x = load_task(slug)
        sids = x.get_list("sessions")
        if sid not in sids:
            x.set_list("sessions", sids + [sid])
            add_log(x, "Session linked", session=sid)
            x.save()
    print("linked %s to %s" % (sid[:8], slug))


FIELDS_SECTION = {"goal": ("Goal", 2), "direction": ("Direction", 4), "next": ("Next", 2)}
FIELD_LOG_LABEL = {"goal": "Goal changed to", "direction": "Direction changed to", "next": "Next"}


def change_note(label, new, old):
    """'Next: new (was: old)', with the old value left out when there was none."""
    new, old = one_line(new, 140), one_line(old, 140)
    return "%s: %s" % (label, new) + (" (was: %s)" % old if old and old != "TBD" else "")


def set_field(slug, field, value, source=None):
    """Change one field of a task and log the change. Raises BrainError."""
    field = field.lower()
    with write_lock():
        x = load_task(slug)
        note = None
        if field in FIELDS_SECTION:
            name, n = FIELDS_SECTION[field]
            old, new = x.text_of(name), limit_lines(value, n)
            x.set_section(name, new.splitlines())
            if new != old:
                note = change_note(FIELD_LOG_LABEL[field], new, old)
        elif field == "status":
            if value not in STATUSES:
                raise BrainError("status must be one of %s" % ", ".join(STATUSES))
            old = x.get("status") or "active"
            x.set("status", value)
            if value != old:
                note = "Status: %s -> %s" % (old, value)
        elif field == "title":
            old, new = x.get("title"), one_line(value, 80)
            x.set("title", new)
            if new != old:
                note = change_note("Title", new, old)
        elif field == "ticket":
            items = x.get_list("ticket")
            added = []
            for v in re.split(r"[,\s]+", value.strip()):
                if v and v not in items:
                    items.append(v)
                    added.append(v)
            x.set("ticket", items[0] if len(items) == 1 else "[" + ", ".join(items) + "]")
            if added:
                note = "Ticket added: " + ", ".join(added)
        else:
            raise BrainError("field must be goal, direction, next, status, title or ticket")
        if note:
            add_log(x, note, source=source)
        x.touch()
        x.save()


def cmd_set(slug, field, value):
    set_field(slug, field, value)
    print("%s: %s updated" % (slug, field))


def log_entry(slug, text, session=None, at=None, source=None):
    """Add a line to a task's log. Raises BrainError."""
    if not (text or "").strip():
        raise BrainError("nothing to log")
    when = None
    if at:
        when = parse_ts(at)
        if when is None:
            raise BrainError("--at must be 'YYYY-MM-DD HH:MM' (local time): %r" % at)
        if when > now() + dt.timedelta(minutes=5):
            raise BrainError("--at is in the future: %s" % at)
    with write_lock():
        x = load_task(slug)
        add_log(x, text, when, session=session, source=source)
        x.save()


def cmd_log(slug, text, session=None, at=None):
    log_entry(slug, text, session, at)
    print("%s: logged" % slug)


def cmd_done(slug, text):
    with write_lock():
        x = load_task(slug)
        add_log(x, text or "Done")
        if x.get("status") != "done":
            add_log(x, "Status: %s -> done" % (x.get("status") or "active"))
        x.set("status", "done")
        x.set_section("Next", ["None (done)."])
        x.save()
        lines, fus = load_followups()
        n = 0
        for f in fus:
            if f.slug == slug and not f.done:
                lines[f.idx] = lines[f.idx].replace("[ ]", "[x]", 1)
                n += 1
        if n:
            write_atomic(FOLLOWUPS, "\n".join(lines) + "\n")
    print("%s: done (%d follow-ups closed)" % (slug, n))


def cmd_decide(a):
    t = now()
    entry = "## %s | %s | %s\n- Decision: %s\n- Why: %s\n- Rejected: %s\n" % (
        t.strftime(DAY), a.slug, one_line(a.title, 80), one_line(a.decision, 300),
        one_line(a.why, 300), one_line(a.rejected or "none considered", 300))
    with write_lock():
        lines = read(DECISIONS, "# Decisions\n").splitlines()
        i = 0
        while i < len(lines) and not lines[i].startswith("## "):
            i += 1
        head = lines[:i]
        while head and not head[-1].strip():
            head.pop()
        text = "\n".join(head) + "\n\n" + entry + ("\n" + "\n".join(lines[i:]) if lines[i:] else "")
        write_atomic(DECISIONS, text.rstrip() + "\n")
        if os.path.isfile(task_path(a.slug)):
            x = load_task(a.slug)
            add_log(x, "Decision: %s (see decisions.md)" % one_line(a.title, 80))
            x.save()
    print("decision logged for %s" % a.slug)


def cmd_followup(when, slug, what, remind=False):
    cfg = load_config()
    t = parse_when(cfg, when)
    what = one_line(what, 160).replace("|", "/")
    if remind and not what.lower().startswith("remind"):
        what = "Remind: " + what
    line = "- [ ] %s | %s | %s" % (fmt(t), slug, what)
    with write_lock():
        if not os.path.isfile(FOLLOWUPS):
            write_atomic(FOLLOWUPS, "# Follow-ups\n\n")
        append_line(FOLLOWUPS, line)
    print("follow-up %s set for %s" % (short_id("%s|%s|%s" % (fmt(t), slug, what)), fmt(t)))


def cmd_fdone(fid, result):
    with write_lock():
        f = tick_followup(fid, result)
    print("follow-up %s ticked" % f.id)


def cmd_lint():
    bad = 0
    for x in all_tasks():
        probs = []
        if not slug_ok(x.slug):
            probs.append("slug not kebab-case 2-4 words")
        if x.section("Progress") is not None:
            probs.append("old Progress section (the next tick moves it into the Log)")
        for name, n in FIELDS_SECTION.values():
            got = len([l for l in (x.section(name) or []) if l.strip()])
            if got > n:
                probs.append("%s has %d lines (limit %d)" % (name, got, n))
        if x.get("status") not in STATUSES:
            probs.append("bad status %r" % x.get("status"))
        for k in ("title", "created", "updated"):
            if not x.get(k):
                probs.append("missing " + k)
        if probs:
            bad += 1
            print("%s: %s" % (x.slug, "; ".join(probs)))
    if not bad:
        print("all tasks within the rules")
    return 1 if bad else 0


# --------------------------------------------------------------------------
# settings.json merge (installer and uninstall)

def settings_file():
    return os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude"),
                        "settings.json")


def is_ours(cmd):
    return "/brain/bin/" in (cmd or "")


def our_permissions():
    return ["Bash(%s *)" % BRAIN_CMD, "Bash(~/brain/bin/brain *)", "Read(~/brain/**)"]


def settings_update(install):
    path = settings_file()
    raw = read(path, "")
    try:
        data = json.loads(raw) if raw.strip() else {}
    except ValueError:
        raise BrainError("%s is not valid JSON; fix it and re-run (nothing changed)" % path)
    if not isinstance(data, dict):
        raise BrainError("%s is not a JSON object; nothing changed" % path)
    before = json.dumps(data, sort_keys=True)
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    for ev in ("SessionStart", "SessionEnd"):
        groups = hooks.get(ev) or []
        kept = []
        for g in groups:
            hs = [h for h in (g.get("hooks") or []) if not is_ours(h.get("command"))]
            if hs:
                g = dict(g)
                g["hooks"] = hs
                kept.append(g)
        if install:
            script = os.path.join(BIN, "session-start.sh" if ev == "SessionStart" else "session-end.sh")
            h = {"type": "command", "command": '"%s"' % script, "timeout": 10 if ev == "SessionEnd" else 15}
            kept.append({"hooks": [h]})
        if kept:
            hooks[ev] = kept
        else:
            hooks.pop(ev, None)
    if hooks:
        data["hooks"] = hooks
    else:
        data.pop("hooks", None)
    perms = data.get("permissions")
    if not isinstance(perms, dict):
        perms = {}
    allow = [p for p in (perms.get("allow") or []) if p not in our_permissions()
             and "/brain/bin/brain" not in p]
    if install:
        allow += our_permissions()
    if allow:
        perms["allow"] = allow
    else:
        perms.pop("allow", None)
    if perms:
        data["permissions"] = perms
    else:
        data.pop("permissions", None)
    if json.dumps(data, sort_keys=True) == before:
        print("settings: %s already up to date" % path)
        return
    if os.path.isfile(path):
        bak = "%s.bak-%s" % (path, dt.datetime.now().strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(path, bak)
        print("settings: backed up to %s" % bak)
    write_atomic(path, json.dumps(data, indent=2) + "\n")
    print("settings: %s %s" % ("updated" if install else "brain entries removed from", path))


def config_merge():
    """Add missing keys to ~/brain/config, never change existing values."""
    have = read(CONFIG)
    keys = set()
    for line in have.splitlines():
        if "=" in line and not line.strip().startswith("#"):
            keys.add(line.split("=", 1)[0].strip())
    add = []
    for k, v in DEFAULT_CONFIG:
        if k in keys:
            continue
        if k == "CLAUDE_BIN":
            v = shutil.which("claude") or ""
        add.append("%s=%s" % (k, v))
    if not add:
        print("config: up to date")
        return
    if have and os.path.isfile(CONFIG):
        shutil.copy2(CONFIG, CONFIG + ".bak-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S"))
    head = have if have.strip() else (
        "# Brain settings. KEY=value. Edit freely; the installer only adds missing keys.\n"
        "# WORK_HOURS: HH:MM-HH:MM Days (e.g. 08:00-18:00 Mon-Fri). NOTIFY: on|off.\n")
    write_atomic(CONFIG, head.rstrip("\n") + "\n" + "\n".join(add) + "\n")
    print("config: added %s" % ", ".join(a.split("=")[0] for a in add))


# --------------------------------------------------------------------------
# CLI

USAGE = """brain: the second brain command

  board [--all]                 open tasks, follow-ups and inbox
  show SLUG                     print a task file
  tick [--dry-run] [--no-agent] run the periodic check now
  export [FILE|-]               all tasks, decisions, follow-ups, sessions as JSON
  lint                          check task files against the format rules
  commit [MESSAGE]              commit the store (and push in the background)

  new SLUG TITLE [--goal G] [--direction D] [--next N] [--ticket T]... [--session ID]
  link SLUG SESSION_ID
  set SLUG goal|direction|next|status|title|ticket VALUE
  log SLUG TEXT [--session ID] [--at 'YYYY-MM-DD HH:MM']
                                add a line to the task's log (progress is an alias);
                                --at files it at the time the work happened
  done SLUG [TEXT]              mark done, final log line, close follow-ups
  decide SLUG TITLE --decision D --why W [--rejected R]
  followup WHEN SLUG WHAT [--remind]   WHEN: +30m +2h +1d next-workday HH:MM tomorrow 'YYYY-MM-DD HH:MM'
  fdone ID [RESULT]             tick a follow-up, note RESULT on its task
  notify [--task SLUG] [--key KEY] MESSAGE

  serve [--port N] [--open]     local web page (127.0.0.1 only): today's tasks, with actions

  transcript SESSION_ID         condensed tail of a session transcript (agent use)
  ask SESSION_ID QUESTION       ask an idle session via a forked headless resume (agent use)
"""


def main(argv):
    import argparse
    if not argv or argv[0] in ("-h", "--help", "help"):
        sys.stdout.write(USAGE)
        return 0
    cmd, rest = argv[0], argv[1:]
    p = argparse.ArgumentParser(prog="brain " + cmd)

    if cmd == "hook-start":
        try:
            hook_start()
        except Exception as e:  # never fail the session
            sys.stderr.write("brain: %s\n" % e)
        return 0
    if cmd == "hook-end":
        try:
            hook_end()
        except Exception as e:
            sys.stderr.write("brain: %s\n" % e)
        return 0
    if cmd == "board":
        p.add_argument("--all", action="store_true")
        p.add_argument("--session", default="")
        a = p.parse_args(rest)
        sys.stdout.write(board_all() if a.all else board_text(a.session))
        return 0
    if cmd == "show":
        p.add_argument("slug")
        sys.stdout.write(read(load_task(p.parse_args(rest).slug).path))
        return 0
    if cmd == "tick":
        p.add_argument("--dry-run", action="store_true")
        p.add_argument("--no-agent", action="store_true")
        p.add_argument("--at", help=argparse.SUPPRESS)
        a = p.parse_args(rest)
        return cmd_tick(a.dry_run, a.no_agent, a.at)
    if cmd == "export":
        p.add_argument("file", nargs="?")
        a = p.parse_args(rest)
        data = json.dumps(export_data(), indent=1, ensure_ascii=False)
        if a.file == "-":
            sys.stdout.write(data + "\n")
        else:
            f = a.file or os.path.join(os.getcwd(), "brain-export-%s.json" % now().strftime("%Y%m%d-%H%M"))
            write_atomic(f, data + "\n")
            print(f)
        return 0
    if cmd == "lint":
        return cmd_lint()
    if cmd == "commit":
        p.add_argument("message", nargs="?", default="brain: update")
        a = p.parse_args(rest)
        commit(a.message)
        return 0
    if cmd == "new":
        p.add_argument("slug")
        p.add_argument("title")
        p.add_argument("--goal")
        p.add_argument("--direction")
        p.add_argument("--next")
        p.add_argument("--ticket", action="append")
        p.add_argument("--session")
        cmd_new(p.parse_args(rest))
        return 0
    if cmd == "link":
        p.add_argument("slug")
        p.add_argument("session")
        a = p.parse_args(rest)
        cmd_link(a.slug, a.session)
        return 0
    if cmd == "set":
        p.add_argument("slug")
        p.add_argument("field")
        p.add_argument("value")
        a = p.parse_args(rest)
        cmd_set(a.slug, a.field, a.value)
        return 0
    if cmd in ("log", "progress"):
        p.add_argument("slug")
        p.add_argument("text")
        p.add_argument("--session")
        p.add_argument("--at")
        a = p.parse_args(rest)
        cmd_log(a.slug, a.text, a.session, a.at)
        return 0
    if cmd == "serve":
        p.add_argument("--port", type=int, default=7477)
        p.add_argument("--open", action="store_true", help="open the page in a browser")
        a = p.parse_args(rest)
        import brain_web
        return brain_web.serve(a.port, a.open, sys.modules[__name__])
    if cmd == "_migrate":
        for slug in migrate_tasks():
            print("migrated %s to the log format" % slug)
        return 0
    if cmd == "done":
        p.add_argument("slug")
        p.add_argument("text", nargs="?", default="")
        a = p.parse_args(rest)
        cmd_done(a.slug, a.text)
        return 0
    if cmd == "decide":
        p.add_argument("slug")
        p.add_argument("title")
        p.add_argument("--decision", required=True)
        p.add_argument("--why", required=True)
        p.add_argument("--rejected", default="")
        cmd_decide(p.parse_args(rest))
        return 0
    if cmd == "followup":
        p.add_argument("when")
        p.add_argument("slug")
        p.add_argument("what")
        p.add_argument("--remind", action="store_true")
        a = p.parse_args(rest)
        cmd_followup(a.when, a.slug, a.what, a.remind)
        return 0
    if cmd == "fdone":
        p.add_argument("id")
        p.add_argument("result", nargs="?", default="")
        a = p.parse_args(rest)
        cmd_fdone(a.id, a.result)
        return 0
    if cmd == "notify":
        p.add_argument("message")
        p.add_argument("--task", default="")
        p.add_argument("--key")
        a = p.parse_args(rest)
        sent = notify(a.message, a.task, a.key)
        print("notified" if sent else "already notified (key %s)" % a.key)
        return 0
    if cmd == "transcript":
        p.add_argument("session")
        a = p.parse_args(rest)
        s = load_sessions().get(a.session)
        path = find_transcript(a.session, s["transcript"] if s else "")
        if not path:
            raise BrainError("no transcript found for %s" % a.session)
        run_budget("transcript")
        mt = mtime(path)
        print("# transcript tail %s (last activity %s, cwd %s)" % (
            a.session, fmt(mt) if mt else "?", (s or {}).get("cwd", "?")))
        print(transcript_summary(path))
        return 0
    if cmd == "ask":
        p.add_argument("session")
        p.add_argument("question")
        a = p.parse_args(rest)
        print(cmd_ask(a.session, a.question))
        return 0
    if cmd == "_settings":
        p.add_argument("action", choices=["install", "remove"])
        settings_update(p.parse_args(rest).action == "install")
        return 0
    if cmd == "_config":
        config_merge()
        return 0
    sys.stderr.write("brain: unknown command %r\n\n" % cmd + USAGE)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrainError as e:
        sys.stderr.write("brain: %s\n" % e)
        sys.exit(1)
