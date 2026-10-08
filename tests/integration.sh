#!/bin/bash
# Integration test with the REAL claude CLI and model, in a throwaway HOME.
# Costs a few cents of model usage. Prints evidence for the report.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$(mktemp -d "${TMPDIR:-/tmp}/brain-int.XXXXXX")}"
export HOME="$WORK/home"
mkdir -p "$HOME/.claude" "$WORK/proj"
# Do not inherit an outer Claude Code session's identity.
unset CLAUDE_CODE_SESSION_ID CLAUDE_CODE_REMOTE_SESSION_ID CLAUDECODE CLAUDE_CODE_CHILD_SESSION BRAIN_AGENT
B="$HOME/brain/bin/brain"
hr() { printf '\n==== %s\n' "$*"; }
run() { # prompt -> runs a headless work session in $WORK/proj
  (cd "$WORK/proj" && timeout 600 claude -p --model "${MODEL:-sonnet}" --permission-mode acceptEdits \
     --allowedTools "Bash(python3 *)" <<<"$1" 2>&1)
}

hr install
bash "$ROOT/install-brain.sh" | tail -3
sed -i.bak 's/^WORK_HOURS=.*/WORK_HOURS=00:00-23:59 Mon-Sun/' "$HOME/brain/config"; rm -f "$HOME/brain/config.bak"

hr "1. real work session (should create + link a task quietly)"
run "Write fizz.py in this directory that prints FizzBuzz for 1 to 15, then run it with python3. This is ticket ENG-42." | tee "$WORK/s1.out"
ls "$HOME/brain/tasks"; cat "$HOME/brain/tasks/"[!_]*.md 2>/dev/null
tail -2 "$HOME/brain/sessions.log"

hr "2. trivial question (should create no task)"
n_before=$(ls "$HOME/brain/tasks" | wc -l)
run "In one sentence: what does HTTP status 418 mean?" | tee "$WORK/s2.out"
n_after=$(ls "$HOME/brain/tasks" | wc -l)
echo "tasks before=$n_before after=$n_after"

hr "3. deploy started (should add a +30m follow-up)"
run "I've just started the production deploy of fizz: GitHub Actions run 9999 in repo example-org/fizz. Nothing else to do now." | tee "$WORK/s3.out"
cat "$HOME/brain/followups.md"; cat "$HOME/brain/decisions.md" | tail -5

hr "3b. tick 31 minutes later: agent checks the deploy and tells the owner"
AT="$(python3 -c 'import datetime as d;print((d.datetime.now()+d.timedelta(minutes=31)).strftime("%Y-%m-%d %H:%M"))')"
"$B" tick --dry-run --at "$AT"
time "$B" tick --at "$AT"
tail -30 "$HOME/brain/.state/tick.log"
echo "-- followups"; cat "$HOME/brain/followups.md"
echo "-- inbox"; cat "$HOME/brain/inbox.md"
echo "-- task"; cat "$HOME/brain/tasks/"[!_]*.md
echo "-- sessions.log (agent runs must not appear)"; cat "$HOME/brain/sessions.log"

hr "4. session that ends without updating its task"
SLUG="$(grep -l 'ENG-42' "$HOME/brain/tasks/"*.md 2>/dev/null | head -1)"; SLUG="$(basename "${SLUG:-none}" .md)"
if [ "$SLUG" = none ]; then echo "(session 1 left no ENG-42 task; creating one for this step)"; SLUG=fizzbuzz-eng-42; "$B" new "$SLUG" "FizzBuzz script" --ticket ENG-42 >/dev/null; fi
(cd "$WORK/proj" && BRAIN_AGENT=1 timeout 600 claude -p --model "${MODEL:-sonnet}" --permission-mode acceptEdits \
   --allowedTools "Bash(python3 *)" \
   <<<"Extend fizz.py so it takes N from argv (default 15), run it with 20, and tell me it works. Decision: we keep it dependency-free (no click/argparse) because it ships as a single file." 2>&1) | tee "$WORK/s4.out"
S4="$(ls -t "$HOME/.claude/projects/"*proj*/*.jsonl | head -1)"; SID4="$(basename "$S4" .jsonl)"
OLD="$(python3 -c 'import datetime as d;print((d.datetime.now()-d.timedelta(minutes=90)).strftime("%Y-%m-%d %H:%M"))')"
NOW="$(date '+%Y-%m-%d %H:%M')"
printf '%s | start | %s | %s | %s\n%s | end | %s | %s | %s\n' "$OLD" "$SID4" "$WORK/proj" "$S4" "$NOW" "$SID4" "$WORK/proj" "$S4" >> "$HOME/brain/sessions.log"
"$B" link "$SLUG" "$SID4" >/dev/null
python3 - "$HOME/brain/tasks/$SLUG.md" "$OLD" <<'EOF'
import sys,re
p,old=sys.argv[1:3]; s=open(p).read(); s=re.sub(r"updated: .*","updated: "+old,s); open(p,"w").write(s)
EOF
echo "-- before"; cat "$HOME/brain/tasks/$SLUG.md"
"$B" tick --dry-run
"$B" tick
tail -15 "$HOME/brain/.state/tick.log"
echo "-- after"; cat "$HOME/brain/tasks/$SLUG.md"; echo "-- decisions"; cat "$HOME/brain/decisions.md"

hr "5. ask an idle session through a forked resume"
S1="$(grep '| start |' "$HOME/brain/sessions.log" | head -1 | awk -F' [|] ' '{print $3}')"
T1="$(grep "| start | $S1" "$HOME/brain/sessions.log" | head -1 | awk -F' [|] ' '{print $5}')"
python3 -c "import os,time;t=time.time()-1200;os.utime('$T1',(t,t))"
sum_before="$(cksum < "$T1")"
nfiles_before=$(ls "$(dirname "$T1")" | wc -l)
BRAIN_RUN_ID=int1 "$B" ask "$S1" "In 3 lines: what is done, what is left, what is blocking?"
echo "original transcript unchanged: $([ "$(cksum < "$T1")" = "$sum_before" ] && echo yes || echo NO)"
echo "transcripts in project dir before=$nfiles_before after=$(ls "$(dirname "$T1")" | wc -l) (fork adds one)"
echo "sessions.log lines for the fork (should be 0): $(grep -c "$(ls -t "$(dirname "$T1")" | head -1 | sed 's/.jsonl//')" "$HOME/brain/sessions.log")"

hr "6. idle tick: no model"
"$B" tick; tail -1 "$HOME/brain/.state/tick.log"

hr "7. export"
"$B" export "$WORK/export.json" && python3 -c "import json;d=json.load(open('$WORK/export.json'));print({k:len(v) for k,v in d.items() if isinstance(v,list)})"
"$B" lint
git -C "$HOME/brain" log --oneline | head -20
echo "work dir: $WORK"
