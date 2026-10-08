#!/bin/bash
# SessionStart hook: log the session, print the board into Claude's context.
# Headless runs started by the brain itself set BRAIN_AGENT=1 and are ignored.
if [ "${BRAIN_AGENT:-}" = "1" ]; then cat >/dev/null; exit 0; fi
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$here/../.state" 2>/dev/null
py="$(command -v python3 || echo /usr/bin/python3)"
"$py" "$here/brain.py" hook-start 2>>"$here/../.state/hook-errors.log"
exit 0
