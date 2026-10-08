---
name: brain
description: Owner's second brain at ~/brain. Use in EVERY work session, without being asked, as soon as real work starts (first file edit, a deploy/migration/release, a ticket named) - match the session to a task, then log what happens, big decisions and follow-ups. Also use when the owner asks "what's on my board", "where was I on X", "what did we decide about Y", "remind me", or says a task is done.
---

# Brain: background task bookkeeping

The owner's tasks live in `~/brain` (plain markdown in git). Keep it current as a
side effect of normal work. **Stay quiet**: bookkeeping never interrupts work,
and you mention it in one short line at most (e.g. "Linked to task `auth-token-refresh`.").
Do it alongside the work, not instead of it.

The board printed at session start (open tasks, follow-ups, inbox, this
session's id) is your index. If it is missing, run `~/brain/bin/brain board`.

Make every change with the `brain` command. It enforces the formats and size
rules; do not hand-edit files unless a command cannot do it. Always call it by
its literal path `~/brain/bin/brain`, one command per Bash call, with no shell
variables, `cd` or `&&` chains (the pre-approved permission only matches that form):

```
~/brain/bin/brain show SLUG
~/brain/bin/brain new SLUG "Title" --goal "..." --direction "..." --next "..." [--ticket ID] --session SESSION_ID
~/brain/bin/brain link SLUG SESSION_ID
~/brain/bin/brain set SLUG next|direction|goal|status|title|ticket "VALUE"
~/brain/bin/brain log SLUG "what happened"
~/brain/bin/brain done SLUG "final line"
~/brain/bin/brain decide SLUG "short title" --decision "..." --why "..." --rejected "..."
~/brain/bin/brain followup WHEN SLUG "what to check"   # WHEN: +30m +2h +1d next-workday HH:MM tomorrow "YYYY-MM-DD HH:MM"
~/brain/bin/brain followup WHEN SLUG "what" --remind   # owner reminders (fire at any hour)
~/brain/bin/brain fdone FOLLOWUP_ID "result"
```

## 1. Match (as soon as real work starts)

Do this BEFORE the first file edit, before running a deploy, migration or
release, or as soon as a ticket/PR is named. Not at the end of the session:
sessions often end abruptly, and a deploy is exactly when the end comes late.

- Match the work to an open task on the board. Matched: `link SLUG SESSION_ID`.
- No match: `new` with Goal (1-2 lines: what done looks like), Direction (2-4
  lines: approach and why) and Next (the single next step), passing `--session`.
  Slug: kebab-case, 2 to 4 words.
- Match unclear (two plausible tasks, or new vs existing): ask the owner once,
  in one line.
- Trivial one-off questions (explain this, a quick lookup) are not tasks. Do
  nothing, and say nothing about it.
- It is real work, and needs a task, if files were changed, a ticket/PR was
  mentioned, or something was started that someone will care about later
  (a deploy, a migration, a release). Small but real work still gets a task.

## 2. Tickets

A Jira/Linear id, GitHub issue or PR URL mentioned for the task: `set SLUG ticket ID`
(adds to the list; a task may have several).

## 3. Log what happens

The task's Log is its history: the owner reads it later to learn what
actually happened. It is never trimmed, and entries are filed under this
session automatically.

- `log` as you go, one line per call: what you found, what you changed and
  where, results (tests, deploys, stacks), problems, what was left open.
- Not noise: no "read file", "ran ls", or each small edit.
- Before your final reply, make sure the session's outcome is in the log.
- Rewrite Direction and Next with `set` when they change. The old value is
  logged for you, so nothing is lost.
- No code, logs or long explanation. Name the file, PR, ticket or stack.

## 4. Decisions

Log with `decide` only if at least one is true:
- hard or costly to reverse (schema, data migration, public API, vendor, architecture, security model)
- it changes the task's direction or scope
- someone would later ask "why did we do it this way?"

Never for naming, formatting, small refactors or routine fixes. When unsure, do not log.

## 5. Follow-ups

Add one when something will need checking later. Put what to check in the text
(PR number, run id, URL, log path) so it can be checked unattended.

| Trigger | WHEN |
|---|---|
| Deploy or release about to run (add it before running) | `+30m` |
| Long test run, build or migration started | when it should finish, else `+30m` |
| Waiting on a review, reply or another team | `next-workday` (09:00) |
| Task set to blocked | `+1d` |
| Owner says "remind me" | their time, with `--remind` |

## 6. Due follow-ups

If the board marks one `DUE`: tell the owner in one line, check it if you can
(`gh run view`, `gh pr checks`, a status URL, a log), then `fdone ID "result"`.

## 7. Finish

Owner says a task is done: `done SLUG "final line"` (sets status, closes its follow-ups).

## 8. Recall

"What's on my board", "where was I on X", "what did we decide about Y": answer
briefly from `~/brain` (`board`, `show SLUG`, `grep -i` in `~/brain/decisions.md`,
`~/brain/archive/`).

## Never

- Store secrets, tokens, credentials or customer data in `~/brain`.
- Paste code or logs into task files.
- Talk about the bookkeeping beyond one short line.
