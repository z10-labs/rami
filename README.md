# Rami: second brain for Claude Code (source)

`install-brain.sh` is the single deliverable. It is generated, so do not edit it by hand.

| Path | What |
|---|---|
| `install-brain.sh` | generated installer (`--uninstall` to remove); copies itself to `~/brain/bin/` |
| `src/bin/brain.py` | all logic: board, hooks, tick, export, task edits, settings merge |
| `src/bin/brain`, `session-start.sh`, `session-end.sh` | thin wrappers |
| `src/bin/agent-prompt.md` | brain agent instructions (findings are appended per run) |
| `src/skill/SKILL.md` | the `brain` skill, installed to `~/.claude/skills/brain/` |
| `src/README.md` | the owner's README, installed to `~/brain/README.md` |
| `build.sh` | regenerates `install-brain.sh` from `src/` |
| `tests/test.sh` | offline tests in a throwaway HOME with a fake `claude` (79 checks) |
| `tests/integration.sh` | real `claude` CLI and model, in a throwaway HOME |
| `REPORT.md` | what was built and verified, and known issues |

```
./build.sh && bash tests/test.sh
```
