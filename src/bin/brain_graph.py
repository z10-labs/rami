"""Graph: how the brain's pieces connect.

Nodes are projects, tasks and decisions. A task links to its project and to
any other task a session worked on as well; a decision links to its task.
Done tasks are left out unless all=True (their decisions go with them).
"""
import brain_projects


def graph(core, all_tasks=False):
    sessions = core.load_sessions()
    tasks = [x for x in core.all_tasks() if all_tasks or x.get("status") != "done"]
    nodes, edges, seen = [], [], set()

    def node(nid, kind, label, **extra):
        if nid not in seen:
            seen.add(nid)
            nodes.append(dict(id=nid, kind=kind, label=label, **extra))

    by_session = {}
    for x in tasks:
        tid = "task:" + x.slug
        node(tid, "task", x.get("title") or x.slug, slug=x.slug, status=x.get("status") or "active",
             log=len(x.log_entries()))
        project = brain_projects.task_project(x, sessions)
        pid = "project:" + project
        node(pid, "project", project)
        edges.append({"a": tid, "b": pid, "kind": "project"})
        for sid in x.get_list("sessions"):
            by_session.setdefault(sid, []).append(tid)
    pairs = set()
    for tids in by_session.values():
        for i, a in enumerate(tids):
            for b in tids[i + 1:]:
                if a != b and (b, a) not in pairs:
                    pairs.add((a, b))
    edges.extend({"a": a, "b": b, "kind": "session"} for a, b in sorted(pairs))
    for i, d in enumerate(core.parse_decisions()):
        tid = "task:" + d.get("task", "")
        if tid in seen:
            did = "decision:%d" % i
            node(did, "decision", d.get("title", ""), date=d.get("date", ""), decision=d.get("decision", ""))
            edges.append({"a": did, "b": tid, "kind": "decision"})
    return {"nodes": nodes, "edges": edges}
