"""Search across the brain: tasks, their logs, decisions and archived tasks.

Every word of the query must appear (case-insensitive, any order) in one
field. Results are ranked by where they matched (title, then goal/next/
direction, then decisions, then log lines) and then by recency.
"""
import re

LIMIT = 30
RANK = {"task": 0, "archived": 1, "decision": 2, "log": 3}


def words(q):
    return [w for w in re.split(r"\s+", (q or "").lower().strip()) if w]


def matches(ws, *texts):
    hay = " ".join(t or "" for t in texts).lower()
    return all(w in hay for w in ws)


def task_hits(core, x, ws, archived=False):
    kind = "archived" if archived else "task"
    out = []
    upd = core.fmt(core.task_updated(x))
    if matches(ws, x.get("title"), x.slug, x.text_of("Goal"), x.text_of("Next"), x.text_of("Direction")):
        title_hit = matches(ws, x.get("title"), x.slug)
        out.append({"type": kind, "slug": x.slug, "label": x.get("title") or x.slug,
                    "hint": x.get("status") or "", "at": upd, "score": 0 if title_hit else 1})
    if archived:
        return out
    for w, src, txt in x.log_entries():
        if matches(ws, txt):
            out.append({"type": "log", "slug": x.slug, "label": txt,
                        "hint": x.get("title") or x.slug, "at": core.fmt(w) if w else "", "score": 3})
    return out


def search(core, q, limit=LIMIT):
    ws = words(q)
    if not ws:
        return []
    hits = []
    for x in core.all_tasks():
        hits.extend(task_hits(core, x, ws))
    for x in core.archived_tasks():
        hits.extend(task_hits(core, x, ws, archived=True))
    for d in core.parse_decisions():
        if matches(ws, d.get("title"), d.get("decision"), d.get("why"), d.get("rejected")):
            hits.append({"type": "decision", "slug": d.get("task", ""), "label": d.get("title", ""),
                         "hint": d.get("decision", ""), "at": d.get("date", ""), "score": 2})
    hits.sort(key=lambda h: h["at"], reverse=True)            # newest first...
    hits.sort(key=lambda h: (h["score"], RANK[h["type"]]))    # ...within each rank (stable)
    for h in hits:
        del h["score"]
    return hits[:limit]
