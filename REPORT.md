# Second brain: build report

## What was built

The spec's starting point, `install-brain.sh` v1, was not in this workspace. I rebuilt everything from the spec. Upgrading over a v1 install is handled by the rule "any hook command containing `/brain/bin/` is ours": v1 hook entries are replaced, not duplicated. That rule is tested with v1-style entries, not with the real v1 script.

- **Installer** `install-brain.sh`: one self-contained bash script, safe to re-run.
  - It replaces code (`bin/*`, the skill and README) only when the content differs. The skill is backed up first.
  - It creates the owner's files (tasks, decisions, follow-ups, inbox, sessions.log, template) only if they are missing.
  - `config` gets missing keys only, with a backup when it changes.
  - `settings.json` is merged after a timestamped backup. Invalid JSON aborts the install and leaves the file untouched.
  - It writes the `launchd` plist with `plistlib`, recording the install-time `PATH`, and prints the `gh repo create` command.
  - `--uninstall` removes the hooks, permissions, skill and `launchd` job, and leaves `~/brain` alone.
- **`brain` command** (python3, standard library only, 3.6+ syntax for macOS's 3.9):
  - Reading and maintenance: `board`, `show`, `tick`, `export`, `lint`, `commit`.
  - Writes used by the skill and the agent: `new`, `link`, `set`, `progress`, `done`, `decide`, `followup`, `fdone`, `notify`.
  - Agent-only, with enforced limits: `transcript` and `ask`.
  - All writes go through it, so formats and size rules are enforced in code: Progress keeps the 8 newest lines, Direction ≤4 lines, Goal ≤2, slugs validated, `updated` bumped.
  - Store writes take a `mkdir` lock. Commits take their own lock and retry once.
- **Hooks**:
  - SessionStart logs a `start` line and prints the board. The board is capped at about 55 lines and stays under the 10,000-character hook limit; it shows due follow-ups and unread inbox notes, then clears the inbox.
  - SessionEnd logs an `end` line and spawns a detached commit and push. It returns in about 60 ms; SessionEnd's default budget is 1.5 s and I set 10 s.
  - Both exit 0 on any error. Both skip runs that set `BRAIN_AGENT=1`.
- **Tick** (no model) looks for:
  - due follow-ups
  - active tasks stale for more than N working days
  - stalled linked sessions
  - ended sessions with no task. A cheap transcript check skips trivial ones; a file edit or a ticket mention counts as real work.
  - ended linked sessions whose transcript ran past the task's `updated` time by more than 30 min (the trigger for "session update")
  - done tasks to archive

  Owner reminders (`--remind`) fire at any hour without a model. Outside working hours the tick only archives and fires reminders. If the agent leaves a follow-up unticked twice, the tick ticks it and tells the owner. Each finding is handled once (by key and fingerprint).
- **Brain agent**: `claude -p --permission-mode dontAsk` with an explicit tool list: Read/Grep/Glob, the `brain` command, and read-only `gh run|pr|release view/list/checks` and `curl -s`. It runs in `~/brain` with `BRAIN_AGENT=1` and a run id. The limits (5 transcript reads, 2 resumes per run) are enforced by `brain transcript` and `brain ask`, not left to the model. `ask` refuses sessions whose transcript changed in the last 10 minutes, and resumes with `--resume ID --fork-session`.
- **Notifications**: `osascript` plus a dated `inbox.md` line, de-duplicated per key.
- **Owner README** (`~/brain/README.md`): daily use, config, backup, uninstall.

Two settings choices go beyond the spec. They are disclosed in the README and removed by uninstall:
- **Permission rules added to the user-level settings**: `Bash(<abs>/brain/bin/brain *)`, `Bash(~/brain/bin/brain *)` and `Read(~/brain/**)`. Without them every bookkeeping step would show a permission prompt, which breaks "background".
- **Extra config keys**: `SESSION_UPDATE_GAP_MINUTES`, `IDLE_ASK_MINUTES`, the agent limits and timeout, and `CLAUDE_BIN`.

## How it was verified

All results are from **Linux** (bash 5.2, GNU tools, Python 3.13, Claude Code 2.1.294). Nothing ran on macOS.

1. **`tests/test.sh`**: 79 offline checks in a throwaway HOME, with a fake `claude` that records whether it was called. They cover:
   - Install, then re-install with a checksum of every owner file and of `settings.json`: unchanged, and nothing written.
   - Config merge, invalid settings, v1 hook replacement, and uninstall keeping both `~/brain` and unrelated settings.
   - Both hooks: input, timing, garbage input, missing store, inbox clearing, and agent-run skipping.
   - Board size with 46 tasks, 15 follow-ups and 12 notes: 55 lines, 5.4 KB.
   - Size rules after 20 progress writes, and trimming of hand-made overflow.
   - Follow-up time parsing.
   - Quiet tick: no model called.
   - Agent call: arguments, env, findings in the prompt, retry then give up.
   - Night-time reminders and quiet hours.
   - Notification de-duplication.
   - Each finding type, including the trivial filter and no-end sessions.
   - Transcript tail on a 10,000-line file, the per-run read limit, and `ask` refusing a live session.
   - 20 simultaneous SessionEnds plus 10 parallel progress writes: no lost lines, clean tree, all in git.
   - Archive, export JSON contents, and the tick lock with stale-lock takeover.
2. **`tests/integration.sh`** with the real CLI and model (work sessions on `sonnet`, agent on `haiku`), throwaway HOME. I ran it 7 times while fixing (the first had a test-script bug), plus 4 extra runs of session 1 and the trivial question alone. The final full run passed every step.
3. **shellcheck** on all scripts: the installer is clean.

### Done-means checklist (section 13)

| # | Result | Evidence |
|---|---|---|
| 1 | **Met (Linux)** | Fresh install works. Re-run changes no owner file (checksums equal) and writes nothing. |
| 2 | **Met in headless tests, after two fixes** | Final wording: a small ticketed coding task was created and linked in 5 of 5 runs, a deploy session in 5 of 5. Each mentioned it in one line. Earlier wording missed the small task in 3 of 5 runs, and once explained the skip in a sentence. That led to the board's explicit triggers ("changes files, names a ticket, or starts something … even for small work"). The tick backup also covers misses: it created and linked the task from the transcript within one tick in both runs where it was needed. |
| 3 | **Met in tests** | "What does HTTP 418 mean" made no task in all runs. The agent did log "keep fizz.py dependency-free" as a decision; my prompt labelled it "Decision:", but it is borderline under 5.2. |
| 4 | **Met (Linux, simulated clock)** | Session added `+30m` "Check Actions run 9999 (gh run view 9999 -R …)". Tick at +31 min ran the agent, which ran `gh run view` (403 here), ticked the follow-up, noted it on the task, and wrote one inbox line. The notification banner is untested (no `osascript` on Linux). |
| 5 | **Met** | A session that never touched its task: the agent read the transcript tail, added the milestone, rewrote Direction, and logged the decision. |
| 6 | **Met** | The tick log says "nothing to do" and the fake `claude` was never invoked. The real run took 0.07 s. |
| 7 | **Met** | 20 concurrent session ends plus 10 concurrent writes: all lines present, committed, no `index.lock`. |
| 8 | **Met** | 20 progress writes give 8 lines and the file stays ≤40 lines. The tick trims hand-made overflow. `lint` reports breaks. |
| 9 | **Met** | `brain export` emits valid JSON with every task (including archived), decision, follow-up, session and link. |
| 10 | **Met** | README steps plus `~/brain/bin/install-brain.sh --uninstall`, tested. |

### Section 13 assumptions

| Assumption | Verdict | How checked / design change |
|---|---|---|
| SessionStart output reaches Claude's context | **Holds** | Hook printed a secret word and `claude -p` repeated it. Docs: plain stdout is added, capped at 10,000 chars, so the board is capped well below. |
| Hooks get `session_id`, `cwd`, `transcript_path` on stdin | **Holds** | Captured the JSON. It also has `hook_event_name`, `source`/`reason`, `prompt_id`. |
| SessionEnd fires for desktop, terminal and headless | **Headless holds** (`reason: other`, even when the run errored). **Interactive terminal and desktop app: not verified**; the docs don't say. | SessionEnd has a **1.5 s default timeout**, so the hook sets `timeout: 10` and returns in about 60 ms. If SessionEnd is missed, an idle session with no end line is still treated as ended (unlinked) or stalled (linked). |
| Skills in `~/.claude/skills/` work in the app and the CLI | **CLI holds**: the model invoked the `brain` skill headlessly. **Desktop: not verified.** | Docs say personal skills are not loaded in Cowork or cloud sessions. The board's two-line instruction carries the key triggers even if the skill doesn't load. |
| Transcripts are local `.jsonl` at `transcript_path` | **Holds** | Under `~/.claude/projects/<cwd-encoded>/<id>.jsonl`. Docs call the format internal and subject to change, so the reader skips unknown entries. Most lines are not messages; a 2-turn session was 26 lines and about 190 KB. |
| A session can be resumed headlessly by id and forked | **Holds** | `claude -p --resume ID --fork-session` answered from the original's context. The original's checksum was unchanged. A new transcript appears in that project (side effect, below). **Must run in the session's original cwd**, so `ask` uses the cwd from `sessions.log`. |
| Headless runs trigger hooks; an env var lets hooks skip them | **Holds** | Hooks fired for `claude -p`, and `BRAIN_AGENT=1` reached the hook's env. Agent and fork runs left no `sessions.log` lines. **Found:** a nested `claude` inherits `CLAUDE_CODE_SESSION_ID` and reused the parent's session id. The brain strips that and related variables before every `claude` call. |
| `launchd` can run `claude` with the owner's login and `PATH` | **Not verified** (no macOS) | The plist records the install-time `PATH` and `HOME`, and config stores `CLAUDE_BIN` as an absolute path. Untested risk: `claude` reads its login from the Keychain, which a LaunchAgent in the user's GUI session should be able to reach. |

Also found: `--allowedTools` takes several values, so a prompt passed after it is swallowed as another tool name. The brain passes prompts on stdin. Under `dontAsk`, a Bash call built from shell variables (`B=…; $B show`) matches no rule and is denied. The first real agent run failed this way, so the prompt and skill now require one literal `~/brain/bin/brain …` call per Bash call.

## Not verified

- Anything on macOS: bash 3.2 and BSD tools (the scripts avoid GNU-only flags and bash 4 features, and shellcheck is clean, but I could not run bash 3.2; the network blocked the source), `launchd` loading and firing, `osascript` banners, and Keychain auth from `launchd`.
- Interactive sessions: the terminal UI and the desktop app. Every real session here was `claude -p`.
- A real passing or failing deploy check. Here `gh` got a 403, which exercised the "could not check, tell the owner" path only.
- Push to a GitHub remote: the code path exists, but no remote was configured.
- Multi-day behaviour (stale tasks, archive) on a real clock. These ran with a simulated clock (`tick --at`) and backdated files.

## Known issues, most severe first

1. **In-session matching is model judgment.** With the final wording it went 5 of 5 here, but all of those were one-shot `claude -p` runs. Long interactive sessions may drift. The tick backup catches misses within about 15 minutes during working hours, at the cost of one model call per missed session.
2. **macOS path entirely untested** (see above). The most likely failure is `launchd`: a wrong `PATH` or no Keychain access means the agent never runs. Check `~/brain/.state/tick.log` and `launchd.log` after the first day.
3. **SessionEnd in the desktop app unknown.** If it doesn't fire, there are no end-of-session commits; ticks still commit. Unlinked sessions are only picked up after 60 idle minutes.
4. **The agent may over-log decisions.** It logged one borderline decision. Tune the wording in `bin/agent-prompt.md` and the skill after seeing real entries (spec 15).
5. **Forked resumes leave an extra session** in that project's `/resume` list. Capped at 2 per run.
6. **Agent tool allowlist includes `curl -s`**, which could in principle send writes. The prompt forbids acting on results, and only read-only `gh` subcommands are allowed.
7. **Global permission rules**: the installer pre-approves the `brain` command and reads of `~/brain` in user settings. This is disclosed and removed by uninstall.
8. **Non-reminder follow-ups due after hours wait for the next working morning** (spec default). A deploy started at 17:45 is reported at 08:00.
9. **The session-update trigger is a heuristic**: the transcript ran ≥30 min past the task's `updated`. Short unrecorded sessions are missed, and long recorded ones may get a redundant agent pass (seen once: the agent correctly changed nothing).
10. **Inbox lines are deleted once shown**, including when the session is a headless script the owner runs. They stay in git history.

## Update 2026-10-08: macOS install and task log

Installed and run on macOS (Darwin 25.5, bash 3.2, Python 3.14, Claude Code 2.1.294).

**Now verified on macOS**
- `tests/test.sh`: 97/97. Two session-finding checks used to depend on the real time of day (fixture times came from the real clock, the tick used a simulated 10:00); all times in that block are now relative to the simulated clock.
- `tests/integration.sh` against the real model: every step behaved as intended (task created and linked, trivial question ignored, deploy follow-up added and checked by the agent, session summary written, forked `ask` left the original transcript untouched, idle tick used no model, export and lint clean). On macOS the login lives in the Keychain, which is found through `HOME`, so the script links the real `~/Library/Keychains` into its throwaway HOME. It also sets `NOTIFY=off` so test findings never reach the owner's screen.
- `launchd` loads the job and fires `brain tick` (exit 0); `claude` authenticates from a LaunchAgent (Keychain reachable); a real agent run from `launchd` ticked a follow-up, logged it and showed an `osascript` banner.
- SessionStart and SessionEnd fire in interactive terminal sessions, and the end hook commits.

**Changed after first use**
- **Tasks are journals.** Progress (newest 8, trimmed) is replaced by a Log that is never trimmed, oldest first, grouped under `### date | session abcd1234 (folder)` or `| background`. `set` logs every Goal/Direction/Next/status/title change with the old value; `new`, `link`, `decide`, `fdone` and `done` also log. Entries pick up `CLAUDE_CODE_SESSION_ID` automatically. `brain log` is the command (`progress` is an alias). Old tasks are migrated by the installer and the tick.
- **Session summaries.** A linked session that ended with activity its log does not cover gets an agent pass that writes 1 to 5 lines of what happened, at the time it happened (`log --at`, filed in time order). Transcript times are converted from UTC to local first.
- **Record at the start.** The board and skill now say to link or create the task before the first file edit, deploy or migration, and to add a deploy follow-up before running it. Before, "before your final reply" meant a long deploy session recorded nothing until the deploy had finished.

**Still not verified**: SessionEnd in the desktop app; push to a GitHub remote; multi-day behaviour (stale, stalled, archive) on a real clock.
