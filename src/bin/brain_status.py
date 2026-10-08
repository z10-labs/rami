"""System status: is the brain healthy, and what has it been doing.

Read-only except `set_config`, which changes one known key with validation.
"""
import datetime as dt
import json
import os
import re
import subprocess
import sys

TICK_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{1,2}:\d{2}) tick: (.*)$")
LABEL = "com.brain.tick"
# Keys the web page may change, with their allowed values.
PAGE_KEYS = {"NOTIFY": ("on", "off"), "AGENT_MODEL": ("haiku", "sonnet", "opus")}
INT_KEYS = ("TICK_MINUTES", "STALE_TASK_DAYS", "STALLED_SESSION_MINUTES", "ARCHIVE_AFTER_DAYS",
            "SESSION_UPDATE_GAP_MINUTES", "IDLE_ASK_MINUTES", "AGENT_MAX_TRANSCRIPTS",
            "AGENT_MAX_RESUMES", "AGENT_TIMEOUT_MINUTES")


def tick_lines(core):
    out = []
    for ln in core.read(core.state_path("tick.log")).splitlines():
        m = TICK_RE.match(ln)
        if m:
            out.append((core.parse_ts(m.group(1)), m.group(2)))
    return out


def tick_info(core, cfg, t):
    lines = tick_lines(core)
    last = lines[-1] if lines else (None, "")
    today = [r for w, r in lines if w and w.date() == t.date()]
    agent = [(w, r) for w, r in lines if "agent" in r]
    failed = [x for x in agent if "FAILED" in x[1] or "gave up" in x[1]]
    return ({"last": core.fmt(last[0]) if last[0] else "", "last_result": last[1],
             "every_minutes": core.cfg_int(cfg, "TICK_MINUTES"), "today": len(today),
             "recent": [{"at": core.fmt(w), "result": r} for w, r in lines[-12:][::-1]]},
            {"runs": len(agent), "failed": len(failed), "today": len([1 for w, _ in agent if w.date() == t.date()]),
             "last": core.fmt(agent[-1][0]) if agent else "", "last_result": agent[-1][1] if agent else "",
             "model": cfg.get("AGENT_MODEL") or "haiku"})


def check(cid, label, level, detail):
    return {"id": cid, "label": label, "level": level, "detail": detail}


def hooks_check(core):
    try:
        with open(core.settings_file(), encoding="utf-8") as f:
            hooks = (json.load(f) or {}).get("hooks") or {}
    except (OSError, ValueError) as e:
        return check("hooks", "session hooks", "bad", "settings.json unreadable: %s" % e)
    have = [ev for ev in ("SessionStart", "SessionEnd")
            if any(core.is_ours(h.get("command")) for grp in hooks.get(ev) or [] for h in grp.get("hooks") or [])]
    if len(have) == 2:
        return check("hooks", "session hooks", "ok", "start and end hooks installed")
    return check("hooks", "session hooks", "bad", "missing: " + ", ".join(
        ev for ev in ("SessionStart", "SessionEnd") if ev not in have))


def launchd_check():
    if sys.platform != "darwin" or os.environ.get("BRAIN_NO_LAUNCHD") == "1":
        return None
    try:
        r = subprocess.run(["launchctl", "print", "gui/%d/%s" % (os.getuid(), LABEL)],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=5)
    except (OSError, subprocess.SubprocessError) as e:
        return check("launchd", "background job", "warn", "could not ask launchd: %s" % e)
    if r.returncode != 0:
        return check("launchd", "background job", "bad",
                     "not loaded; run ~/brain/bin/install-brain.sh to load it again")
    m = re.search(r"last exit code = (.*)", r.stdout)
    return check("launchd", "background job", "ok", "loaded; last exit " + (m.group(1).strip() if m else "?"))


def tick_check(tick, t):
    if not tick["last"]:
        return check("tick", "last tick", "warn", "no tick yet")
    age = (t - dt.datetime.strptime(tick["last"], "%Y-%m-%d %H:%M")).total_seconds() / 60
    level = "ok" if age <= 2 * tick["every_minutes"] + 1 else ("warn" if age < 24 * 60 else "bad")
    return check("tick", "last tick", level, "%s (%d min ago): %s" % (tick["last"], age, tick["last_result"]))


def git_check(core):
    if not os.path.isdir(os.path.join(core.BRAIN, ".git")):
        return check("git", "history", "bad", "~/brain is not a git repository")
    last = core.git("log", "-1", "--format=%cd · %s", "--date=format:%Y-%m-%d %H:%M")
    remote = core.git("remote", "get-url", "origin")
    last_s = (last.stdout or "").strip() if last.returncode == 0 else "no commits"
    if remote.returncode != 0:
        return check("git", "history", "warn", "last commit %s; no backup remote" % last_s)
    return check("git", "history", "ok", "last commit %s; backed up to %s" % (last_s, remote.stdout.strip()))


def activity(core, t):
    """Sessions started and log lines written per hour, oldest hour first (24 buckets)."""
    start = (t - dt.timedelta(hours=23)).replace(minute=0)
    buckets = lambda: [0] * 24
    sess, logs = buckets(), buckets()

    def put(arr, w):
        if w and w >= start:
            i = int((w - start).total_seconds() // 3600)
            if 0 <= i < 24:
                arr[i] += 1
    for s in core.load_sessions().values():
        put(sess, s.get("start"))
    for x in core.all_tasks():
        for w, _, _ in x.log_entries():
            put(logs, w)
    return {"from": core.fmt(start), "sessions": sess, "log": logs}


def status(core):
    cfg = core.load_config()
    t = core.now()
    tick, agent = tick_info(core, cfg, t)
    cb = core.claude_bin(cfg)
    import brain_captures
    checks = [c for c in (
        launchd_check(),
        tick_check(tick, t),
        check("agent", "brain agent", "warn" if agent["failed"] and agent["last_result"].endswith(("FAILED", "gave up")) else "ok",
              "%d runs, %d failed; last %s" % (agent["runs"], agent["failed"], agent["last"] or "never")),
        check("claude", "claude cli", "ok" if cb and os.path.isfile(cb) else "bad", cb or "not found; set CLAUDE_BIN"),
        hooks_check(core),
        git_check(core),
    ) if c]
    _, fus = core.load_followups()
    return {
        "now": core.fmt(t), "checks": checks, "tick": tick, "agent": agent,
        "store": {"tasks": len(core.all_tasks()), "archived": len(core.archived_tasks()),
                  "decisions": len(core.parse_decisions()), "followups_open": len([f for f in fus if not f.done]),
                  "captures": len([c for c in brain_captures.load(core)[1] if not c.done]),
                  "sessions": len(core.load_sessions()),
                  "path": core.BRAIN.replace(core.HOME, "~", 1) if core.BRAIN.startswith(core.HOME + "/") else core.BRAIN},
        "activity": activity(core, t),
        "config": dict((k, cfg.get(k, "")) for k, _ in core.DEFAULT_CONFIG),
        "page_keys": dict((k, list(v)) for k, v in PAGE_KEYS.items()),
    }


def validate(core, key, value):
    known = [k for k, _ in core.DEFAULT_CONFIG]
    if key not in known:
        raise core.BrainError("unknown key %r (known: %s)" % (key, ", ".join(known)))
    if key in PAGE_KEYS and value not in PAGE_KEYS[key]:
        raise core.BrainError("%s must be one of %s" % (key, ", ".join(PAGE_KEYS[key])))
    if key in INT_KEYS and not re.match(r"^[1-9]\d{0,3}$", value):
        raise core.BrainError("%s must be a whole number" % key)
    if key == "WORK_HOURS" and not re.match(r"^\d{1,2}:\d{2}-\d{1,2}:\d{2}(\s+\S+)?$", value):
        raise core.BrainError("WORK_HOURS looks like 08:00-18:00 Mon-Fri")
    if key == "CLAUDE_BIN" and value and not os.access(value, os.X_OK):
        raise core.BrainError("CLAUDE_BIN must be an executable file")


def set_config(core, key, value, page=False):
    value = (value or "").strip()
    if page and key not in PAGE_KEYS:
        raise core.BrainError("the page can only change %s" % ", ".join(PAGE_KEYS))
    validate(core, key, value)
    with core.write_lock():
        lines = core.read(core.CONFIG).splitlines()
        found = False
        for i, ln in enumerate(lines):
            if re.match(r"^\s*%s\s*=" % re.escape(key), ln):
                lines[i] = "%s=%s" % (key, value)
                found = True
        if not found:
            lines.append("%s=%s" % (key, value))
        core.write_atomic(core.CONFIG, "\n".join(lines).rstrip() + "\n")
