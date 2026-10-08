"""Ask: answer the owner's questions from the brain with a read-only model run.

The model runs headless in ~/brain as an agent run (hooks skip it), with only
Read/Grep/Glob and the read-only `brain` commands (board, show, search,
projects). It may not edit anything. Questions and answers are kept in
.state/ask.jsonl so the page can show the conversation.
"""
import json
import os
import re
import subprocess
import threading

QUESTION_MAX = 500
HISTORY_MAX = 200
TIMEOUT_SECONDS = 180
REFS_RE = re.compile(r"^\s*REFS:\s*(.*)$", re.I | re.M)
_busy = threading.Lock()

PROMPT = """You answer the owner's question about their own work, using only their
second brain at {brain} (your working directory). It is {now} local time.

How to look things up (read-only; you cannot and must not change anything):
- The board below lists open tasks, follow-ups and captures.
- `{cmd} show SLUG` prints a task: Goal, Direction, Next and its full Log.
- `{cmd} search "words"` finds tasks, log lines, decisions and archived tasks.
- `{cmd} projects` groups tasks by repository.
- decisions.md holds big decisions; archive/ holds finished tasks.
Call the brain command by its full path, one command per Bash call.

Answer in at most 6 short lines, plainly, with dates and task names where they
help. Say so if the brain does not say. Then end with one line:
REFS: slug-one, slug-two   (the tasks you used; empty if none)

{board}
Question: {question}
"""


class AskError(Exception):
    pass


def history_path(core):
    return core.state_path("ask.jsonl")


def history(core, limit=50):
    out = []
    for ln in core.read(history_path(core)).splitlines()[-limit:]:
        try:
            out.append(json.loads(ln))
        except ValueError:
            continue
    return out


def remember(core, item):
    p = history_path(core)
    core.append_line(p, json.dumps(item, ensure_ascii=False))
    lines = core.read(p).splitlines()
    if len(lines) > HISTORY_MAX:
        core.write_atomic(p, "\n".join(lines[-HISTORY_MAX:]) + "\n")


def split_refs(core, text):
    m = REFS_RE.search(text)
    refs = []
    if m:
        for r in re.split(r"[,\s]+", m.group(1)):
            r = r.strip("`'\". ")
            if r and core.slug_ok(r) and r not in refs and (
                    os.path.isfile(core.task_path(r)) or any(x.slug == r for x in core.archived_tasks())):
                refs.append(r)
        text = REFS_RE.sub("", text)
    return text.strip(), refs


def ask(core, question):
    question = core.one_line(question or "", QUESTION_MAX + 1)
    if not question:
        raise core.BrainError("ask a question")
    if len(question) > QUESTION_MAX:
        raise core.BrainError("question too long (max %d characters)" % QUESTION_MAX)
    cfg = core.load_config()
    cb = core.claude_bin(cfg)
    if not cb:
        raise core.BrainError("claude CLI not found; set CLAUDE_BIN in ~/brain/config")
    if not _busy.acquire(False):
        raise AskError("already answering a question; try again in a moment")
    try:
        prompt = PROMPT.format(brain=core.BRAIN, now=core.fmt(core.now()), cmd=core.BRAIN_CMD,
                               board=core.board_text(), question=question)
        allowed = ["Read", "Grep", "Glob"] + [
            "Bash(%s %s *)" % (c, sub) for c in (core.BRAIN_CMD, "~/brain/bin/brain")
            for sub in ("show", "search", "projects", "board")]
        args = [cb, "-p", "--model", cfg.get("AGENT_MODEL") or "haiku", "--permission-mode", "dontAsk",
                "--allowedTools"] + allowed + ["--max-turns", "12", "--output-format", "text"]
        try:
            r = subprocess.run(args, input=prompt, cwd=core.BRAIN, env=core.clean_env({"BRAIN_AGENT": "1"}),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                               timeout=TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            raise core.BrainError("claude took longer than %d s; try a narrower question" % TIMEOUT_SECONDS)
        except OSError as e:
            raise core.BrainError("could not run claude (%s): %s" % (cb, e))
        if r.returncode != 0 or not (r.stdout or "").strip():
            detail = core.one_line((r.stderr or r.stdout or "no output").strip(), 200)
            raise core.BrainError("claude failed (exit %d): %s" % (r.returncode, detail))
        answer, refs = split_refs(core, r.stdout)
        item = {"at": core.fmt(core.now()), "question": question, "answer": answer, "refs": refs,
                "model": cfg.get("AGENT_MODEL") or "haiku"}
        remember(core, item)
        return item
    finally:
        _busy.release()
