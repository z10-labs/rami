# Rami: second brain for Claude Code (source)

`install-brain.sh` is the single deliverable. It is generated, so do not edit it by hand.

| Path | What |
|---|---|
| `install-brain.sh` | generated installer (`--uninstall` to remove); copies itself to `~/brain/bin/` |
| `src/bin/brain.py` | all logic: board, hooks, tick, export, task edits, settings merge |
| `src/bin/brain_web.py`, `src/bin/web/` | `brain serve`: the local brain page (127.0.0.1 only): Inbox, Today, Ask, Graph, Projects, System, Meet, Cmd-K search |
| `src/bin/brain_captures.py`, `brain_search.py`, `brain_projects.py`, `brain_graph.py`, `brain_status.py`, `brain_ask.py` | captures, search, projects, graph, health/config, ask; each used by the CLI and the page |
| `src/bin/brain_meet.py`, `brain_meet_refs.py` | Meet: recording lifecycle, notes, library; live cards that point at tasks, work done and decisions |
| `src/bin/rami-rec.swift`, `rami-rec.plist` | the recorder (ScreenCaptureKit, mic, on-device SpeechTranscriber); compiled by the installer on macOS 26+ |
| `src/bin/brain`, `session-start.sh`, `session-end.sh` | thin wrappers |
| `src/bin/agent-prompt.md` | brain agent instructions (findings are appended per run) |
| `src/skill/SKILL.md` | the `brain` skill, installed to `~/.claude/skills/brain/` |
| `src/README.md` | the owner's README, installed to `~/brain/README.md` |
| `build.sh` | regenerates `install-brain.sh` from `src/` |
| `tests/test.sh` | offline tests in a throwaway HOME with a fake `claude` and a fake recorder (229 checks) |
| `tests/integration.sh` | real `claude` CLI and model, in a throwaway HOME |
| `REPORT.md` | what was built and verified, and known issues |

```
./build.sh && bash tests/test.sh
```
