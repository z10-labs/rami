"""Captures: the owner's quick notes, sorted into the brain on accept.

captures.md holds one line per capture:
    - [ ] 2026-10-08 21:40 | TEXT | call the printer about the sleeves
    - [x] 2026-10-08 21:41 | VOICE | buy batteries -> task buy-batteries
A suggestion (log on a task / new task / reminder) is computed when listed,
from the text alone, without a model. Accepting applies it (or an override)
through the same functions as the CLI; entries are logged as "you".
"""
import datetime as dt
import os
import re

CAP_RE = re.compile(r"^\s*-\s*\[( |x|X)\]\s*(\d{4}-\d{2}-\d{2} \d{1,2}:\d{2})\s*\|\s*([A-Z]+)\s*\|\s*(.*?)\s*$")
KINDS = ("log", "task", "remind")
SOURCES = ("TEXT", "VOICE", "CLIP", "WEB")
TEXT_MAX = 300
SOURCE = "you"
REMIND_RE = re.compile(r"^\s*(remind|reminder|don'?t forget|follow ?up)\b", re.I)
STOP = set("""a an and are as at be but by can do for from get got had has have how i if in into is it
its just me my need needs not of on or our so some that the their then there this to too up us was we
were what when will with you your about after again also all any back been before being both could
does done each else even ever few here into more most much must new now off once only other over same
should since still such than them these they those through under until very want way well which while
who why would yet look looks fine maybe should today tomorrow""".split())


DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
DAY_RE = re.compile(r"\b(today|tonight|tomorrow|mon(?:day)?|tue(?:s|sday)?|wed(?:s|nesday)?|"
                    r"thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\b", re.I)
TIME_RE = re.compile(r"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b|\b(\d{1,2}):(\d{2})\b", re.I)


def when_from(core, text, base=None):
    """When a reminder in this text should fire: a day (weekday, today,
    tomorrow) and/or a time (16:30, 4pm, at 9am); else the next workday 09:00."""
    base = base or core.now()
    day_m, time_m = DAY_RE.search(text), TIME_RE.search(text)
    hour, minute = 9, 0
    if time_m:
        if time_m.group(1):
            hour, minute = int(time_m.group(1)) % 12, int(time_m.group(2) or 0)
            if time_m.group(3).lower() == "pm":
                hour += 12
        else:
            hour, minute = int(time_m.group(4)), int(time_m.group(5))
        if hour > 23 or minute > 59:
            time_m, hour, minute = None, 9, 0
    if day_m:
        word = day_m.group(1).lower()
        if word in ("today", "tonight"):
            day = base.date()
            if word == "tonight" and not time_m:
                hour = 19
        elif word == "tomorrow":
            day = base.date() + dt.timedelta(days=1)
        else:
            ahead = (DAYS.index(word[:3]) - base.weekday()) % 7 or 7
            day = base.date() + dt.timedelta(days=ahead)
        return core.fmt(dt.datetime(day.year, day.month, day.day, hour, minute))
    if time_m:
        t = base.replace(hour=hour, minute=minute, second=0, microsecond=0)
        return core.fmt(t if t > base else t + dt.timedelta(days=1))
    return core.fmt(core.next_workday_at(core.load_config(), base))


def tokens(text):
    out = set()
    for w in re.findall(r"[a-z0-9]+", (text or "").lower()):
        if len(w) < 3 or w in STOP:
            continue
        if len(w) > 4 and w.endswith("s"):
            w = w[:-1]
        out.add(w)
    return out


def slug_from(core, text):
    words = [w for w in re.findall(r"[a-z0-9]+", text.lower()) if len(w) > 1 and w not in STOP]
    base = "-".join(words[:3]) or "captured-note"
    if not core.slug_ok(base):
        base = (base + "-note") if "-" not in base else base
    slug, n = base, 2
    while os.path.exists(core.task_path(slug)) or not core.slug_ok(slug):
        slug = "%s-%d" % ("-".join(base.split("-")[:3]), n)
        n += 1
    return slug


def suggest(core, text, tasks):
    """(kind, dest): a reminder, a log entry on the best-matching open task, or a new task."""
    if REMIND_RE.search(text):
        best = best_task(text, tasks)
        return "remind", best or ""
    best = best_task(text, tasks)
    if best:
        return "log", best
    return "task", slug_from(core, text)


def best_task(text, tasks):
    words = tokens(text)
    best, score = None, 0
    for x in tasks:
        if x.get("status") == "done":
            continue
        slug_words = tokens(x.slug.replace("-", " "))
        task_words = slug_words | tokens(x.get("title")) | tokens(x.text_of("Goal"))
        shared = words & task_words
        s = len(shared) + (1 if any(len(w) >= 5 for w in shared & slug_words) else 0)
        if s > score:
            best, score = x.slug, s
    return best if score >= 2 else None


class Capture(object):
    def __init__(self, core, idx, line, m, nth=0):
        self.idx = idx
        self.line = line
        self.done = m.group(1) != " "
        self.at = m.group(2)
        self.src = m.group(3)
        rest = m.group(4)
        self.text, _, self.result = rest.partition(" -> ")
        # Identical captures in the same minute are told apart by their order.
        key = "%s|%s|%s" % (self.at, self.src, self.text)
        self.id = core.short_id(key if nth == 0 else "%s|%d" % (key, nth))

    def as_dict(self, core, tasks):
        kind, dest = suggest(core, self.text, tasks)
        titles = dict((x.slug, x.get("title")) for x in tasks)
        return {"id": self.id, "at": self.at, "src": self.src, "text": self.text, "done": self.done,
                "result": self.result, "kind": kind, "dest": dest, "when": when_from(core, self.text),
                "destTitle": titles.get(dest, "")}


def path(core):
    return os.path.join(core.BRAIN, "captures.md")


def load(core):
    lines = core.read(path(core), "# Captures\n\n").splitlines()
    caps, seen = [], {}
    for i, ln in enumerate(lines):
        m = CAP_RE.match(ln)
        if m:
            key = (m.group(2), m.group(3), m.group(4).partition(" -> ")[0])
            caps.append(Capture(core, i, ln, m, seen.get(key, 0)))
            seen[key] = seen.get(key, 0) + 1
    return lines, caps


def open_captures(core):
    tasks = core.all_tasks()
    return [c.as_dict(core, tasks) for c in load(core)[1] if not c.done]


def find(core, cid):
    lines, caps = load(core)
    for c in caps:
        if c.id == cid:
            if c.done:
                raise core.BrainError("capture %s is already %s" % (cid, c.result or "closed"))
            return lines, c
    raise core.BrainError("no open capture %r" % cid)


def add(core, text, src="TEXT"):
    text = core.one_line((text or "").replace("|", "/"), TEXT_MAX)
    if not text:
        raise core.BrainError("nothing to capture")
    src = (src or "TEXT").upper()
    if src not in SOURCES:
        raise core.BrainError("source must be one of %s" % ", ".join(SOURCES))
    at = core.fmt(core.now())
    with core.write_lock():
        if not os.path.isfile(path(core)):
            core.write_atomic(path(core), "# Captures\n\n")
        core.append_line(path(core), "- [ ] %s | %s | %s" % (at, src, text))
    return load(core)[1][-1].id


def close(core, lines, c, result):
    lines[c.idx] = "- [x] %s | %s | %s -> %s" % (c.at, c.src, c.text, result)
    core.write_atomic(path(core), "\n".join(lines) + "\n")


def accept(core, cid, kind=None, dest=None):
    """Apply the suggestion (or the given kind/dest). Returns 'kind dest'."""
    if kind is not None and kind not in KINDS:
        raise core.BrainError("kind must be one of %s" % ", ".join(KINDS))
    _, c = find(core, cid)
    s_kind, s_dest = suggest(core, c.text, core.all_tasks())
    kind = kind or s_kind
    dest = dest if dest is not None else (s_dest if kind == s_kind else "")
    if kind == "log":
        if not dest or not os.path.isfile(core.task_path(dest)):
            raise core.BrainError("no task %r to log to" % dest)
        core.log_entry(dest, c.text, source=SOURCE)
    elif kind == "task":
        dest = dest or slug_from(core, c.text)
        if not core.slug_ok(dest):
            raise core.BrainError("slug must be kebab-case, 2 to 4 words: %r" % dest)
        if os.path.exists(core.task_path(dest)):
            raise core.BrainError("task %s already exists" % dest)
        new_task(core, dest, c.text)
    elif kind == "remind":
        core.cmd_followup(when_from(core, c.text), dest or "inbox", c.text, remind=True, quiet=True)
    with core.write_lock():
        lines, c = find(core, cid)
        close(core, lines, c, "%s %s" % (kind, dest or "inbox"))
    return "%s %s" % (kind, dest or "inbox")


def new_task(core, slug, text):
    class A(object):
        pass
    a = A()
    a.slug, a.title, a.goal, a.direction, a.next = slug, text, None, None, text
    a.ticket, a.session = None, None
    core.cmd_new(a, quiet=True, note="Task created from capture", source=SOURCE)


def dismiss(core, cid):
    with core.write_lock():
        lines, c = find(core, cid)
        close(core, lines, c, "dismissed")
