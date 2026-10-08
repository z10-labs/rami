"""Projects: tasks grouped by the repository their sessions ran in.

A task's project is the git repository (or, failing that, the folder) where
its most recent linked session started. Tasks with no session are "unfiled".
A project's state is its most urgent open task: blocked, active, waiting;
"quiet" when nothing is open.
"""
import os

UNFILED = "unfiled"
STATES = ("blocked", "active", "waiting", "quiet")


def project_of(cwd):
    """Name of the git repo containing cwd, else the folder's own name."""
    cwd = (cwd or "").rstrip("/")
    if not cwd:
        return ""
    d = cwd
    while d and d != os.path.dirname(d):
        if os.path.exists(os.path.join(d, ".git")):
            return os.path.basename(d)
        d = os.path.dirname(d)
    return os.path.basename(cwd)


def task_project(x, sessions):
    for sid in reversed(x.get_list("sessions")):
        name = project_of((sessions.get(sid) or {}).get("cwd", ""))
        if name:
            return name
    return UNFILED


def projects(core):
    sessions = core.load_sessions()
    groups = {}
    for x in core.all_tasks():
        name = task_project(x, sessions)
        g = groups.setdefault(name, {"name": name, "total": 0, "active": 0, "waiting": 0,
                                     "blocked": 0, "done": 0, "updated": "", "tasks": []})
        status = x.get("status") or "active"
        g["total"] += 1
        g[status if status in g else "active"] += 1
        g["updated"] = max(g["updated"], core.fmt(core.task_updated(x)))
        g["tasks"].append(x.slug)
    out = list(groups.values())
    for g in out:
        g["state"] = next((s for s in STATES[:3] if g[s]), "quiet")
    out.sort(key=lambda g: g["updated"], reverse=True)
    out.sort(key=lambda g: STATES.index(g["state"]))
    return out
