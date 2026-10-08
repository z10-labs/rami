#!/bin/bash
# SessionEnd hook: log the end, commit and push in the background. Returns at once.
if [ "${BRAIN_AGENT:-}" = "1" ]; then cat >/dev/null; exit 0; fi
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$here/../.state" 2>/dev/null
py="$(command -v python3 || echo /usr/bin/python3)"
"$py" "$here/brain.py" hook-end 2>>"$here/../.state/hook-errors.log"
exit 0
