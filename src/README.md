# Brain

A local second brain for work done in Claude Code. Each task has one short
markdown file. Every session is linked to the task it worked on. Big decisions
and timed follow-ups are recorded. Everything is plain text in this git repo,
so the repo is also the export.

You rarely need to touch it. Sessions keep it current through the `brain`
skill. A background tick runs every 15 minutes during working hours and fills
in what sessions missed.

## Layout

| Path | What |
|---|---|
| `tasks/<slug>.md` | one file per task: Goal, Direction, Next (the current state), then a Log of everything that happened, grouped by session and never trimmed |
| `archive/<yyyy>/` | done tasks, moved here 14 days after they finish |
| `decisions.md` | big decisions, newest first |
| `followups.md` | `- [ ] YYYY-MM-DD HH:MM \| slug \| what to check` |
| `inbox.md` | notes from the brain agent, shown at the next session start and then cleared |
| `sessions.log` | `time \| start\|end \| session_id \| cwd \| transcript` |
| `config` | settings (below) |
| `bin/` | scripts (replaced by the installer on upgrade) |
| `.state/` | tick bookkeeping and logs (not committed) |

## Daily use

Work normally in Claude Code (desktop app or CLI). At session start Claude sees
the board. As soon as real work starts it links the session to a task or
creates one, then logs what happens, big decisions and follow-ups, saying one
line at most about it. After a linked session ends, the background agent adds
a short summary of anything that session did that the log does not cover yet.

Ask things such as "what's on my board", "where was I on X", "what did we
decide about Y", "remind me at 16:00 to …", or "X is done".

From a terminal:

```
~/brain/bin/brain board            # open tasks, follow-ups, inbox
~/brain/bin/brain serve --open     # today's tasks in the browser (127.0.0.1:7477, Ctrl-C to stop)
~/brain/bin/brain show SLUG
~/brain/bin/brain tick --dry-run   # what the next tick would do, without doing it
~/brain/bin/brain tick             # run a tick now
~/brain/bin/brain export out.json  # everything as one JSON file
~/brain/bin/brain lint             # check task files against the size rules
~/brain/bin/brain help
```

You can edit any file by hand. Keep the formats shown above.

## What runs in the background

- **SessionStart hook:** logs the session and prints the board for Claude.
- **SessionEnd hook:** logs the end, then commits and pushes in the background.
- **Tick** (`launchd`, every `TICK_MINUTES`): a shell-only check with no model.
  It looks for due follow-ups, active tasks with no update for more than 2
  working days, stalled sessions, and ended sessions with no task or with a
  stale task. It archives done tasks. If it finds work, it starts a headless
  `claude -p` run (the brain agent) with your settings. Otherwise it calls no
  model. Outside working hours it only archives and fires reminders you set.
- **Notifications:** a macOS notification plus a line in `inbox.md`. You get
  one for a failed or uncheckable follow-up, a reminder you set, a session
  stalled waiting on you, or a task stale for more than 2 working days. Each
  item notifies you at most once.

Logs: `.state/tick.log`, `.state/hook-errors.log`, `.state/push.log`.

## Config

`~/brain/config` holds `KEY=value` lines. The installer only adds missing
keys and never changes your values.

| Key | Default | Meaning |
|---|---|---|
| `TICK_MINUTES` | 15 | tick interval (re-run the installer after changing it) |
| `WORK_HOURS` | `08:00-18:00 Mon-Fri` | local time; outside it the tick only archives and fires reminders |
| `STALE_TASK_DAYS` | 2 | working days without an update before an active task counts as stale |
| `STALLED_SESSION_MINUTES` | 60 | a linked session with no end and an idle transcript counts as stalled after this |
| `ARCHIVE_AFTER_DAYS` | 14 | done tasks move to `archive/` after this |
| `AGENT_MODEL` | `haiku` | model for the brain agent and session questions |
| `NOTIFY` | `on` | `off` writes inbox lines only |
| `SESSION_UPDATE_GAP_MINUTES` | 30 | an ended session counts as unrecorded if it ran this long after its task was last updated |
| `IDLE_ASK_MINUTES` | 10 | a session is only asked a question if idle this long |
| `AGENT_MAX_TRANSCRIPTS` / `AGENT_MAX_RESUMES` | 5 / 2 | limits per agent run |
| `AGENT_TIMEOUT_MINUTES` | 15 | the agent run is killed after this |
| `CLAUDE_BIN` | found at install | full path to `claude` (`launchd` has a minimal `PATH`) |

## Backup

Every session end and every tick that changes something makes a commit. To
also push to a private GitHub repo, create one once:

```
cd ~/brain && gh repo create brain --private --source . --push
```

Pushes then happen in the background.

## Uninstall

Run `~/brain/bin/install-brain.sh --uninstall`, or do these steps by hand:

1. Remove the brain hooks and permissions from `~/.claude/settings.json`: the
   `SessionStart` and `SessionEnd` entries whose command contains
   `/brain/bin/`, and the `permissions.allow` entries mentioning `~/brain`.
   The installer saved backups as `settings.json.bak-*`.
2. `rm -r ~/.claude/skills/brain`
3. `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.brain.tick.plist; rm ~/Library/LaunchAgents/com.brain.tick.plist`

`~/brain` stays as it is. Delete it yourself only if you want the data gone.

Nothing secret belongs here: no tokens, credentials or customer data.

## Web page

`~/brain/bin/brain serve --open` starts a small server on this machine only
(127.0.0.1:7477) and opens the Today page: open tasks and tasks finished
today, each with its Goal, Direction, Next, follow-ups, links and the full
log. From the page you can change a task's status, post an update and tick a
follow-up; those entries are logged as "you". The page refreshes every 10
seconds, so work recorded by Claude sessions and the agent shows up on its
own. It keeps running until you press Ctrl-C in its terminal. Each run uses
a new secret key embedded in the page, so other websites cannot read or
change your brain through it.
