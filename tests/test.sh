#!/bin/bash
# Offline tests for install-brain.sh and the brain command.
# Runs in a throwaway HOME. A fake `claude` records whether a model was called.
# Usage: tests/test.sh            (needs bash, git, python3)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/brain-test.XXXXXX")"
export HOME="$WORK/home"
# The launchd label is per user, not per HOME: never touch the owner's real job.
export BRAIN_NO_LAUNCHD=1
mkdir -p "$HOME/.claude" "$WORK/bin"
unset CLAUDE_CONFIG_DIR BRAIN_HOME BRAIN_AGENT BRAIN_RUN_ID CLAUDE_CODE_SESSION_ID
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
B="$HOME/brain/bin/brain"

# Fake claude: logs its args and stdin, answers "ok".
cat > "$WORK/bin/claude" <<EOF
#!/bin/bash
{ echo "ARGS: \$*"; echo "ENV BRAIN_AGENT=\${BRAIN_AGENT:-} RUN=\${BRAIN_RUN_ID:-}"; cat; echo; echo "----"; } >> "$WORK/claude-calls.log"
echo "agent summary: ok"
EOF
chmod +x "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

echo "== install"
cat > "$HOME/.claude/settings.json" <<'EOF'
{"model":"opus","env":{"X":"1"},"permissions":{"allow":["Bash(npm test)"]},
 "hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo mine"}]},{"hooks":[{"type":"command","command":"~/brain/bin/board.sh"}]}],
          "SessionEnd":[{"hooks":[{"type":"command","command":"$HOME/brain/bin/session-end.sh"}]}],
          "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"true"}]}]}}
EOF
bash "$ROOT/install-brain.sh" > "$WORK/install1.log" 2>&1
check "first install exits 0" "[ $? -eq 0 ]"
check "store layout" "[ -d $HOME/brain/tasks -a -d $HOME/brain/archive -a -f $HOME/brain/decisions.md -a -f $HOME/brain/followups.md -a -f $HOME/brain/inbox.md -a -f $HOME/brain/sessions.log -a -f $HOME/brain/config -a -f $HOME/brain/README.md ]"
check "skill installed" "[ -f $HOME/.claude/skills/brain/SKILL.md ]"
check "settings backup made" "ls $HOME/.claude/settings.json.bak-* >/dev/null 2>&1"
check "existing settings kept" "python3 -c \"
import json;d=json.load(open('$HOME/.claude/settings.json'))
assert d['model']=='opus' and d['env']=={'X':'1'}
assert 'Bash(npm test)' in d['permissions']['allow']
cmds=[h['command'] for g in d['hooks']['SessionStart'] for h in g['hooks']]
assert 'echo mine' in cmds and any('session-start.sh' in c for c in cmds)
assert d['hooks']['PreToolUse'][0]['matcher']=='Bash'
assert any('session-end.sh' in h['command'] for g in d['hooks']['SessionEnd'] for h in g['hooks'])
\""
check "git repo with a commit" "git -C $HOME/brain log --oneline | grep -q install"
check "v1 hook entries replaced, not duplicated" "! grep -q board.sh $HOME/.claude/settings.json && [ \$(grep -c 'session-end.sh' $HOME/.claude/settings.json) -eq 1 ]"
check "installer copy kept for uninstall" "[ -x $HOME/brain/bin/install-brain.sh ]"
check "tests never touch the real launchd job" "grep -q 'launchd: skipped (BRAIN_NO_LAUNCHD=1)' $WORK/install1.log"
check "CLAUDE_BIN recorded" "grep -q '^CLAUDE_BIN=$WORK/bin/claude' $HOME/brain/config"

echo "== owner data survives re-install"
"$B" new api-rate-limits "Add API rate limits" --goal "Limit per-key requests" --direction "Token bucket in the gateway" --next "Write the middleware" --ticket ENG-12 >/dev/null
"$B" decide api-rate-limits "Use token bucket" --decision "Token bucket at the gateway" --why "Bursty clients" --rejected "Fixed window" >/dev/null
"$B" followup +2h api-rate-limits "Check gateway deploy" >/dev/null
printf 'WORK_HOURS=07:00-19:00 Mon-Sat\n' >> "$HOME/brain/config"
sed -i.bak 's/^NOTIFY=on/NOTIFY=off/' "$HOME/brain/config" && rm -f "$HOME/brain/config.bak"
echo "my note" >> "$HOME/brain/tasks/_template.md"
echo "secret-local/" >> "$HOME/brain/.gitignore"
snap() { (cd "$HOME/brain" && cat tasks/*.md decisions.md followups.md inbox.md sessions.log config .gitignore | cksum); cksum < "$HOME/.claude/settings.json"; }
before="$(snap)"
bash "$ROOT/install-brain.sh" > "$WORK/install2.log" 2>&1
check "second install exits 0" "[ $? -eq 0 ]"
check "second install changes no owner file or settings" "[ \"\$(snap)\" = \"$before\" ]"
check "skill installed with content" "grep -q '^name: brain' $HOME/.claude/skills/brain/SKILL.md"
check "second install writes no files" "! grep -q '^wrote\|^created\|backed up' $WORK/install2.log"
check "owner config values kept" "grep -q '^NOTIFY=off' $HOME/brain/config"
check "settings hooks not duplicated" "[ \$(grep -c session-start.sh $HOME/.claude/settings.json) -eq 1 ]"

echo "== config merge adds only missing keys"
grep -v '^AGENT_MODEL=' "$HOME/brain/config" > "$WORK/c" && cp "$WORK/c" "$HOME/brain/config"
bash "$ROOT/install-brain.sh" > "$WORK/install3.log" 2>&1
check "missing key re-added" "grep -q '^AGENT_MODEL=haiku' $HOME/brain/config"
check "config backed up before change" "ls $HOME/brain/config.bak-* >/dev/null 2>&1"
check "owner value still kept" "grep -q '^NOTIFY=off' $HOME/brain/config"

echo "== invalid settings.json is left alone"
cp "$HOME/.claude/settings.json" "$WORK/good.json"
echo '{ not json' > "$HOME/.claude/settings.json"
bash "$ROOT/install-brain.sh" > "$WORK/install4.log" 2>&1
check "installer fails on invalid settings" "[ $? -ne 0 ]"
check "invalid settings untouched" "[ \"\$(cat $HOME/.claude/settings.json)\" = '{ not json' ]"
cp "$WORK/good.json" "$HOME/.claude/settings.json"

echo "== hooks"
SID=11111111-aaaa-bbbb-cccc-000000000001
TP="$HOME/.claude/projects/-w/$SID.jsonl"; mkdir -p "$(dirname "$TP")"
echo '{"type":"user","message":{"role":"user","content":"hi"}}' > "$TP"
"$B" notify --task api-rate-limits --key t1 "Deploy check failed" >/dev/null
out="$(printf '{"session_id":"%s","cwd":"/w","transcript_path":"%s","hook_event_name":"SessionStart","source":"startup"}' "$SID" "$TP" | "$HOME/brain/bin/session-start.sh")"
check "start hook logs a start line" "grep -q \"| start | $SID | /w | $TP\" $HOME/brain/sessions.log"
check "board shows session id, task, follow-up and inbox" "echo \"\$out\" | grep -q $SID && echo \"\$out\" | grep -q api-rate-limits && echo \"\$out\" | grep -q 'Check gateway deploy' && echo \"\$out\" | grep -q 'Deploy check failed'"
check "board asks to record work as soon as it starts" "echo \"\$out\" | grep -q 'As soon as' && echo \"\$out\" | grep -q 'brain log'"
check "inbox cleared after being shown" "! grep -q 'Deploy check failed' $HOME/brain/inbox.md"
out2="$(printf '{"session_id":"x2"}' | "$HOME/brain/bin/session-start.sh")"
check "inbox not shown twice" "! echo \"\$out2\" | grep -q 'Deploy check failed'"
check "agent runs are ignored by start hook" "[ -z \"\$(printf '{\"session_id\":\"agent1\"}' | BRAIN_AGENT=1 $HOME/brain/bin/session-start.sh)\" ] && ! grep -q agent1 $HOME/brain/sessions.log"
t0=$(python3 -c 'import time;print(time.time())')
printf '{"session_id":"%s","cwd":"/w","transcript_path":"%s","hook_event_name":"SessionEnd","reason":"other"}' "$SID" "$TP" | "$HOME/brain/bin/session-end.sh"
t1=$(python3 -c 'import time;print(time.time())')
check "end hook returns in under 1s" "python3 -c 'import sys; sys.exit(0 if $t1-$t0 < 1.0 else 1)'"
check "end hook logs an end line" "grep -q \"| end | $SID\" $HOME/brain/sessions.log"
sleep 2
check "end hook committed in background" "git -C $HOME/brain log -1 --format=%s | grep -q 'session end'"
check "end hook survives garbage stdin" "echo 'garbage' | $HOME/brain/bin/session-end.sh; [ \$? -eq 0 ]"
check "end hook survives missing store" "mv $HOME/brain $HOME/brain.x; echo '{}' | $HOME/brain.x/bin/session-end.sh; r=\$?; mv $HOME/brain.x $HOME/brain; [ \$r -eq 0 ]"

echo "== board size"
for i in $(seq 1 45); do "$B" new "bulk-task-$i" "Bulk task number $i with a fairly long title to test width" --next "Do the thing number $i which has quite a long description that should be cut" >/dev/null; done
for i in $(seq 1 15); do "$B" followup +${i}h bulk-task-1 "check $i" >/dev/null; done
for i in $(seq 1 12); do "$B" notify "note $i" >/dev/null; done
lines=$("$B" board | wc -l); chars=$("$B" board | wc -c)
check "board under 60 lines with 46 tasks ($lines)" "[ $lines -lt 60 ]"
check "board under 10000 chars ($chars)" "[ $chars -lt 10000 ]"
for i in $(seq 1 45); do rm "$HOME/brain/tasks/bulk-task-$i.md"; done
grep -v 'bulk-task-1' "$HOME/brain/followups.md" > "$WORK/f" && cp "$WORK/f" "$HOME/brain/followups.md"
printf '# Inbox\n\n' > "$HOME/brain/inbox.md"

echo "== task log keeps the history"
for i in $(seq 1 20); do "$B" log api-rate-limits "Milestone $i shipped" >/dev/null; done
"$B" progress api-rate-limits "Old progress command still logs" >/dev/null
"$B" set api-rate-limits direction "$(printf 'l1\nl2\nl3\nl4\nl5\nl6')" >/dev/null
"$B" set api-rate-limits next "Ship the middleware" >/dev/null
"$B" set api-rate-limits status blocked >/dev/null
"$B" set api-rate-limits status active >/dev/null
"$B" set api-rate-limits ticket "https://github.com/o/r/pull/7#issuecomment-1" >/dev/null
"$B" link api-rate-limits "$SID" >/dev/null; "$B" link api-rate-limits "$SID" >/dev/null
CLAUDE_CODE_SESSION_ID="$SID" "$B" log api-rate-limits "Found the gateway already buffers bursts" >/dev/null
f="$HOME/brain/tasks/api-rate-limits.md"
check "all 20 log lines kept, oldest first" "[ \$(grep -c '^- [0-9:]* Milestone' $f) -eq 20 ] && grep 'Milestone' $f | head -1 | grep -q 'Milestone 1 shipped'"
check "progress is an alias for log" "grep -q 'Old progress command still logs' $f"
check "no Progress section in new tasks" "! grep -q '^## Progress' $f"
check "direction capped at 4 lines" "! sed -n '/^## Direction/,/^## /p' $f | grep -q '^l5'"
check "direction change logged with the old value" "grep -q 'Direction changed to: .*l1.*(was: Token bucket in the gateway)' $f"
check "next change logged with the old value" "grep -q 'Next: Ship the middleware (was: Write the middleware)' $f"
check "status changes logged" "grep -q 'Status: active -> blocked' $f && grep -q 'Status: blocked -> active' $f"
check "ticket addition logged" "grep -q 'Ticket added: https://github.com/o/r/pull/7' $f"
check "two tickets kept, URL with # intact" "grep -q '^ticket: \[ENG-12, https://github.com/o/r/pull/7#issuecomment-1\]' $f"
check "session linked once" "[ \$(grep '^sessions:' $f | grep -o $SID | wc -l) -eq 1 ]"
check "link logged once under that session's heading" "[ \$(grep -c 'Session linked' $f) -eq 1 ] && grep -q '^### .* | session 11111111 (w)' $f"
check "entry from a session is filed under its heading" "awk '/^### /{h=\$0} /buffers bursts/{print h}' $f | grep -q 'session 11111111'"
check "entries without a session are filed as background" "grep -q '^### .* | background' $f"
check "lint passes" "$B lint >/dev/null"
# a summary written later goes where the work happened, not at the bottom
"$B" new backdate-test "Backdate test" >/dev/null
"$B" log backdate-test "written now" >/dev/null
TODAY="$(date '+%Y-%m-%d')"
"$B" log backdate-test "early work" --session early-sess --at "$TODAY 00:02" >/dev/null
"$B" log backdate-test "earlier work" --session early-sess --at "$TODAY 00:01" >/dev/null
bf="$HOME/brain/tasks/backdate-test.md"
check "--at entry filed under its session, in time order, before later blocks" "[ \"\$(grep -E '^(### |- )' $bf | sed 's/ (.*)//' | tr '\n' '/' | cut -d/ -f1-3)\" = \"### $TODAY | session early-se/- 00:01 earlier work/- 00:02 early work\" ]"
check "--at does not backdate the task's updated time" "! grep -q '^updated: $TODAY 00:0' $bf"
check "--at rejects a bad time" "! $B log backdate-test x --at 'yesterday-ish' 2>/dev/null"
check "--at rejects a future time" "! $B log backdate-test x --at '2099-01-01 10:00' 2>/dev/null"
rm -f "$bf"
# an old-format task with a Progress section is migrated into the log, nothing lost
cat > "$HOME/brain/tasks/old-format-task.md" <<'EOF'
---
title: Old format
status: active
ticket:
created: 2026-01-01
updated: 2026-01-02 10:00
sessions: []
---
## Goal
Old goal

## Direction
Old direction

## Progress
- 2026-01-02 10:00 second thing
- 2026-01-01 09:00 first thing

## Next
Old next
EOF
of="$HOME/brain/tasks/old-format-task.md"
check "lint flags an unmigrated Progress section" "! $B lint >/dev/null"
"$B" tick --no-agent >/dev/null
check "tick migrates Progress into the log" "! grep -q '^## Progress' $of && grep -q '^## Log' $of"
check "migrated lines kept, oldest first, by date" "[ \"\$(grep -E '^(### |- )' $of | tr '\n' '/')\" = '### 2026-01-01 | earlier/- 09:00 first thing/### 2026-01-02 | earlier/- 10:00 second thing/' ]"
check "migration keeps Goal, Direction and Next" "grep -q 'Old goal' $of && grep -q 'Old direction' $of && grep -q 'Old next' $of"
rm -f "$of"
check "bad slug rejected" "! $B new Bad_Slug x 2>/dev/null && ! $B new one x 2>/dev/null && ! $B new a-b-c-d-e x 2>/dev/null"

echo "== follow-up times"
fu() { "$B" followup "$1" api-rate-limits "probe $1" | sed 's/.* set for //'; }
check "+30m" "[ \"\$(fu +30m)\" = \"\$(python3 -c 'import datetime as d;print((d.datetime.now().replace(second=0,microsecond=0)+d.timedelta(minutes=30)).strftime(\"%Y-%m-%d %H:%M\"))')\" ]"
nwd="$(fu next-workday)"
check "next-workday lands 09:00 on a work day ($nwd)" "python3 -c \"
import datetime as d,sys
t=d.datetime.strptime('$nwd','%Y-%m-%d %H:%M'); n=d.datetime.now()
sys.exit(0 if t.hour==9 and t.minute==0 and t.weekday()<6 and t.date()>n.date() else 1)\""
check "bad time rejected" "! $B followup 'whenever' api-rate-limits x 2>/dev/null"
grep -v 'probe' "$HOME/brain/followups.md" > "$WORK/f" && cp "$WORK/f" "$HOME/brain/followups.md"

echo "== tick: nothing to do calls no model"
git -C "$HOME/brain" add -A >/dev/null; git -C "$HOME/brain" commit -qm wip >/dev/null
"$B" set api-rate-limits next "Write the middleware" >/dev/null
: > "$WORK/claude-calls.log"
# a weekday inside working hours, with nothing due
python3 - "$HOME/brain/followups.md" <<'EOF'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=re.sub(r"- \[ \] \S+ \S+ \| api-rate-limits \| Check gateway deploy", "- [ ] 2099-01-01 10:00 | api-rate-limits | Check gateway deploy", s)
open(p,"w").write(s)
EOF
NOW="$(date '+%Y-%m-%d') 10:00"
dow=$(date +%u); if [ "$dow" -ge 6 ]; then NOW="$(python3 -c 'import datetime as d;t=d.date.today();t+=d.timedelta(days=(7-t.weekday()));print(t)') 10:00"; fi
# mark the ended session as handled so only "nothing" remains
"$B" tick --at "$NOW" >/dev/null
: > "$WORK/claude-calls.log"
"$B" tick --at "$NOW" >/dev/null
check "quiet tick did not call claude" "[ ! -s $WORK/claude-calls.log ]"
check "quiet tick logged" "tail -1 $HOME/brain/.state/tick.log | grep -q 'nothing to do'"

echo "== tick: due follow-up calls the agent, with limits and env"
"$B" followup "2020-01-01 10:00" api-rate-limits "Check deploy run 123 (gh run view 123)" >/dev/null
"$B" tick --at "$NOW" >/dev/null
check "agent called once" "[ \$(grep -c '^ARGS:' $WORK/claude-calls.log) -eq 1 ]"
check "agent run marked BRAIN_AGENT=1 with run id" "grep -q 'ENV BRAIN_AGENT=1 RUN=2' $WORK/claude-calls.log"
check "agent gets dontAsk and restricted tools" "grep -q -- '--permission-mode dontAsk' $WORK/claude-calls.log && grep -q 'Bash(gh run view \*)' $WORK/claude-calls.log && ! grep -q 'Bash(gh pr merge' $WORK/claude-calls.log"
check "findings passed in the prompt" "grep -q '\"kind\": \"due_followup\"' $WORK/claude-calls.log"
check "outside hours: follow-up not sent to agent" "$B tick --dry-run --at '2026-10-10 23:00' | grep -q '\"findings\": \[\]'"
: > "$WORK/claude-calls.log"
"$B" tick --at "$NOW" >/dev/null   # fake agent did not tick it: second try
"$B" tick --at "$NOW" >/dev/null   # third time: give up and tell the owner
check "agent tried twice then gave up" "[ \$(grep -c '^ARGS:' $WORK/claude-calls.log) -eq 1 ]"
check "give-up ticked the follow-up and told the owner" "grep -q '\[x\] 2020-01-01 10:00' $HOME/brain/followups.md && grep -q 'Could not check follow-up' $HOME/brain/inbox.md"

echo "== reminders fire at any hour without a model"
: > "$WORK/claude-calls.log"
"$B" followup "2020-01-01 22:00" api-rate-limits "call the bank" --remind >/dev/null
"$B" tick --at "2026-10-10 23:30" >/dev/null
check "reminder notified at night" "grep -q 'Remind: call the bank' $HOME/brain/inbox.md"
check "reminder ticked" "grep -q '\[x\] 2020-01-01 22:00 | api-rate-limits | Remind: call the bank' $HOME/brain/followups.md"
check "no model for reminders" "[ ! -s $WORK/claude-calls.log ]"

echo "== notifications de-duplicated"
"$B" notify --key same "once" >/dev/null; "$B" notify --key same "once" >/dev/null
check "one inbox line per key" "[ \$(grep -c '| once' $HOME/brain/inbox.md) -eq 1 ]"

echo "== session findings"
# Every time in this block is relative to AT, the simulated clock the tick
# runs with, so the checks do not depend on the real time of day.
AT="$(date '+%Y-%m-%d') 10:00"
at_minus() { python3 -c "import datetime as d,sys;print((d.datetime.strptime(sys.argv[1],'%Y-%m-%d %H:%M')-d.timedelta(minutes=int(sys.argv[2]))).strftime(sys.argv[3]))" "$AT" "$1" "${2:-%Y-%m-%d %H:%M}"; }
mk_transcript() { # sid prompts tools mtime_minutes_before_AT
  p="$HOME/.claude/projects/-w/$1.jsonl"
  : > "$p"
  for i in $(seq 1 "$2"); do echo "{\"type\":\"user\",\"timestamp\":\"2026-10-08T09:0$i:00Z\",\"message\":{\"role\":\"user\",\"content\":\"please do step $i\"}}" >> "$p"; done
  for i in $(seq 1 "$3"); do echo "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"working $i\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"make $i\"}}]}}" >> "$p"; done
  python3 -c "import os,sys;t=float(sys.argv[2]);os.utime(sys.argv[1],(t,t))" "$p" "$(at_minus "$4" %s)"
  echo "$p"
}
T="$(at_minus 5)"
TS="$(at_minus 200)"
p1=$(mk_transcript triv-1 1 0 5);  printf '%s | start | triv-1 | /w | %s\n%s | end | triv-1 | /w | %s\n' "$TS" "$p1" "$T" "$p1" >> "$HOME/brain/sessions.log"
p2=$(mk_transcript real-2 4 6 5);  printf '%s | start | real-2 | /w | %s\n%s | end | real-2 | /w | %s\n' "$TS" "$p2" "$T" "$p2" >> "$HOME/brain/sessions.log"
p3=$(mk_transcript upd-3 4 6 5);   printf '%s | start | upd-3 | /w | %s\n%s | end | upd-3 | /w | %s\n' "$TS" "$p3" "$T" "$p3" >> "$HOME/brain/sessions.log"
p4=$(mk_transcript stall-4 3 3 90); printf '%s | start | stall-4 | /w | %s\n' "$TS" "$p4" >> "$HOME/brain/sessions.log"
p5="$HOME/.claude/projects/-w/edit-5.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"write fizz.py"}}' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/w/fizz.py"}}]}}' > "$p5"
printf '%s | start | edit-5 | /w | %s\n%s | end | edit-5 | /w | %s\n' "$TS" "$p5" "$T" "$p5" >> "$HOME/brain/sessions.log"
p6=$(mk_transcript noend-6 3 4 90); printf '%s | start | noend-6 | /w | %s\n' "$TS" "$p6" >> "$HOME/brain/sessions.log"
"$B" new upd-target-task "Session update target" >/dev/null; "$B" link upd-target-task upd-3 >/dev/null
"$B" new stall-target-task "Stall target" >/dev/null; "$B" link stall-target-task stall-4 >/dev/null
p7=$(mk_transcript cov-7 4 6 5);   printf '%s | start | cov-7 | /w | %s\n%s | end | cov-7 | /w | %s\n' "$TS" "$p7" "$T" "$p7" >> "$HOME/brain/sessions.log"
"$B" new covered-task "Covered" >/dev/null; "$B" link covered-task cov-7 >/dev/null
printf '\n### %s | session cov-7 (w)\n- %s Deployed and verified\n' "$(at_minus 3 %Y-%m-%d)" "$(at_minus 3 %H:%M)" >> "$HOME/brain/tasks/covered-task.md"
python3 - "$HOME/brain/tasks/upd-target-task.md" "$(at_minus 180)" <<'EOF'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=re.sub(r"updated: .*", "updated: "+sys.argv[2], s)
open(p,"w").write(s)
EOF
dry="$("$B" tick --dry-run --at "$AT")"
if [ "$(date +%u)" -le 5 ]; then
  check "trivial unlinked session filtered without a model" "! echo \"\$dry\" | grep -q triv-1"
  check "one-prompt session that edited a file is not trivial" "echo \"\$dry\" | grep -q '\"session\": \"edit-5\"'"
  check "unlinked session with no end line, idle 90 min, treated as ended" "echo \"\$dry\" | grep -q '\"session\": \"noend-6\"'"
  check "real unlinked session found" "echo \"\$dry\" | grep -q '\"session\": \"real-2\"' && echo \"\$dry\" | grep -q unlinked_session"
  check "ended session with stale task found" "echo \"\$dry\" | grep -q session_update && echo \"\$dry\" | grep -q upd-target-task"
  check "linked session with nothing in the log gets a summary pass" "echo \"\$dry\" | grep -q '\"key\": \"update:upd-3'"
  check "linked session already covered by the log is skipped" "! echo \"\$dry\" | grep -q '\"session\": \"cov-7\"'"
  check "stalled linked session found" "echo \"\$dry\" | grep -q stalled_session && echo \"\$dry\" | grep -q stall-4"
else
  echo "  skip session-finding checks (weekend: outside working hours)"
fi

echo "== transcript reader"
big="$HOME/.claude/projects/-w/big-5.jsonl"
python3 - "$big" <<'EOF'
import json,sys
with open(sys.argv[1],"w") as f:
    for i in range(5000):
        f.write(json.dumps({"type":"attachment","attachment":{"x":"y"*500}})+"\n")
        f.write(json.dumps({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"line %d"%i}]}})+"\n")
EOF
out="$(BRAIN_RUN_ID=r1 "$B" transcript big-5)"
utc_t="$HOME/.claude/projects/-w/utc-9.jsonl"
echo '{"type":"user","timestamp":"2026-07-01T09:30:00.000Z","message":{"role":"user","content":"utc check"}}' > "$utc_t"
want="$(python3 -c 'import datetime as d;print(d.datetime(2026,7,1,9,30,tzinfo=d.timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M"))')"
check "transcript times are shown in local time" "$B transcript utc-9 | grep -q \"^$want OWNER: utc check\""
check "transcript returns only the tail" "echo \"\$out\" | grep -q 'line 4999' && ! echo \"\$out\" | grep -q 'line 4800:'"
for i in 2 3 4 5; do BRAIN_RUN_ID=r1 "$B" transcript big-5 >/dev/null; done
check "6th transcript read in one run refused" "! BRAIN_RUN_ID=r1 $B transcript big-5 >/dev/null 2>&1"
check "ask refuses a live session" "touch $p2; ! BRAIN_RUN_ID=r2 $B ask real-2 'status?' 2>/dev/null"

echo "== concurrent session ends lose nothing"
for i in $(seq 1 20); do
  printf '{"session_id":"conc-%s","cwd":"/w","transcript_path":""}' "$i" | "$HOME/brain/bin/session-end.sh" &
done
for i in $(seq 1 10); do "$B" log api-rate-limits "parallel $i" >/dev/null & done
wait; sleep 4
check "all 20 end lines present" "[ \$(grep -c '| end | conc-' $HOME/brain/sessions.log) -eq 20 ]"
check "all 10 parallel log writes applied" "[ \$(grep -c 'parallel' $HOME/brain/tasks/api-rate-limits.md) -eq 10 ]"
check "working tree committed, no index.lock" "[ -z \"\$(git -C $HOME/brain status --porcelain)\" ] && [ ! -e $HOME/brain/.git/index.lock ]"
check "end lines are in git" "git -C $HOME/brain show HEAD:sessions.log | grep -c 'conc-' | grep -q 20"

echo "== done and archive"
"$B" followup +1d stall-target-task "check something" >/dev/null
"$B" done stall-target-task "Shipped" >/dev/null
check "done sets status, closes follow-ups" "grep -q '^status: done' $HOME/brain/tasks/stall-target-task.md && ! grep -q '\[ \] .*stall-target-task' $HOME/brain/followups.md"
python3 - "$HOME/brain/tasks/stall-target-task.md" <<'EOF'
import sys,re
p=sys.argv[1]; s=open(p).read(); s=re.sub(r"updated: .*","updated: 2025-01-02 10:00",s); open(p,"w").write(s)
EOF
"$B" tick --no-agent --at "2026-10-10 23:00" >/dev/null
check "old done task archived by year" "[ -f $HOME/brain/archive/2025/stall-target-task.md ] && [ ! -f $HOME/brain/tasks/stall-target-task.md ]"

echo "== export"
"$B" export "$WORK/export.json" >/dev/null
check "export is valid JSON with all parts" "python3 - <<EOF
import json
d=json.load(open('$WORK/export.json'))
slugs={t['slug'] for t in d['tasks']}
assert {'api-rate-limits','upd-target-task','stall-target-task'} <= slugs, slugs
assert any(t['archived'] for t in d['tasks'])
assert d['decisions'][0]['decision']=='Token bucket at the gateway'
import re
n=len([l for l in open('$HOME/brain/followups.md') if re.match(r'- \\[[ x]\\] ', l)])
assert n > 0 and len(d['followups']) == n, (n, len(d['followups']))
assert any(s['session_id']=='$SID' and 'api-rate-limits' in s['tasks'] for s in d['sessions'])
EOF"
check "export to stdout" "$B export - | python3 -c 'import json,sys; json.load(sys.stdin)'"

echo "== captures (inbox)"
cj() { "$B" captures --json | python3 -c "import json,sys;d=json.load(sys.stdin);c=[x for x in d if '$1' in x['text']];print(c[0]['$2'] if c else 'MISSING')"; }
check "installer creates captures.md" "[ -f $HOME/brain/captures.md ]"
"$B" capture "gateway rate limits: bursts look fine on staging" >/dev/null
"$B" capture "remind me to call the bank tomorrow" >/dev/null
"$B" capture "buy batteries and gaffer tape" --src voice >/dev/null
check "capture is stored as an open line" "grep -q '^- \[ \] .* | TEXT | gateway rate limits' $HOME/brain/captures.md"
check "source is kept" "grep -q '| VOICE | buy batteries' $HOME/brain/captures.md"
check "text matching a task is suggested as a log entry on it" "[ \"\$(cj 'gateway rate' kind)\" = log ] && [ \"\$(cj 'gateway rate' dest)\" = api-rate-limits ]"
check "reminder phrasing is suggested as a reminder" "[ \"\$(cj 'call the bank' kind)\" = remind ]"
check "anything else is suggested as a new task with a slug" "[ \"\$(cj 'buy batteries' kind)\" = task ] && [ \"\$(cj 'buy batteries' dest)\" = buy-batteries-gaffer ]"
check "empty capture rejected" "! $B capture '   ' 2>/dev/null"
"$B" capture "pipes | are | flattened" >/dev/null
check "pipes in text cannot break the line format" "grep -q 'pipes / are / flattened' $HOME/brain/captures.md"
bo="$("$B" board)"
check "board lists unsorted captures" "echo \"\$bo\" | grep -q '## Captures' && echo \"\$bo\" | grep -q 'buy batteries'"
id_log="$(cj 'gateway rate' id)"; id_rem="$(cj 'call the bank' id)"; id_task="$(cj 'buy batteries' id)"; id_pipe="$(cj 'pipes' id)"
"$B" capture-accept "$id_log" >/dev/null
check "accepting a log suggestion logs it on the task as you" "awk '/^### /{h=\$0} /bursts look fine on staging/{print h}' $HOME/brain/tasks/api-rate-limits.md | grep -q '| you\$'"
check "accepted capture is closed with where it went" "grep -q '^- \[x\] .*gateway rate limits.* -> log api-rate-limits' $HOME/brain/captures.md"
"$B" capture-accept "$id_task" >/dev/null
check "accepting a task suggestion creates the task" "grep -q '^title: buy batteries and gaffer tape' $HOME/brain/tasks/buy-batteries-gaffer.md && grep -q 'Task created from capture' $HOME/brain/tasks/buy-batteries-gaffer.md"
"$B" capture-accept "$id_rem" >/dev/null
check "accepting a reminder adds an owner reminder" "grep -q '^- \[ \] .* | [Rr]emind.*call the bank tomorrow' $HOME/brain/followups.md"
"$B" capture "second batteries note" >/dev/null
id_ovr="$(cj 'second batteries' id)"
"$B" capture-accept "$id_ovr" --kind log --dest buy-batteries-gaffer >/dev/null
check "kind and destination can be overridden" "grep -q 'second batteries note' $HOME/brain/tasks/buy-batteries-gaffer.md"
check "accepting into a missing task fails" "\"$B\" capture 'orphan note' >/dev/null; ! $B capture-accept \$(cj 'orphan note' id) --kind log --dest no-such-task 2>/dev/null"
"$B" capture-dismiss "$id_pipe" >/dev/null
check "dismissed capture is closed and leaves the open list" "grep -q '^- \[x\] .*pipes / are / flattened -> dismissed' $HOME/brain/captures.md && [ \"\$(cj 'pipes' id)\" = MISSING ]"
check "a closed capture cannot be accepted again" "! $B capture-accept $id_log 2>/dev/null"
"$B" capture-dismiss "$(cj 'orphan note' id)" >/dev/null
"$B" capture "twin text" >/dev/null; "$B" capture "twin text" >/dev/null
twins="$("$B" captures --json | python3 -c "import json,sys;print(' '.join(c['id'] for c in json.load(sys.stdin) if c['text']=='twin text'))")"
check "identical captures in the same minute get different ids" "[ \$(echo $twins | wc -w) -eq 2 ] && [ \$(echo $twins | tr ' ' '\\n' | sort -u | wc -l) -eq 2 ]"
for t in $twins; do "$B" capture-dismiss "$t" >/dev/null; done
twin_ids() { "$B" captures --json | python3 -c "import json,sys;print(' '.join(c['id'] for c in json.load(sys.stdin) if c['text']=='twin text'))"; }
check "both twins can be closed" "[ -z \"\$(twin_ids)\" ]"
capid() { "$B" captures --json | python3 -c "import json,sys;print([c['id'] for c in json.load(sys.stdin) if sys.argv[1] in c['text']][0])" "$1"; }
wq() { "$B" captures --json | python3 -c "
import json,sys,datetime as d
c=[x for x in json.load(sys.stdin) if sys.argv[1] in x['text']][0]
w=d.datetime.strptime(c['when'],'%Y-%m-%d %H:%M')
print(w.strftime('%a %H:%M'), (w.date()-d.date.today()).days)" "$1"; }
"$B" capture "remind me to rotate the key on Friday" >/dev/null
"$B" capture "remind me to call mum tomorrow at 4pm" >/dev/null
"$B" capture "remind me to stretch at 23:59" >/dev/null
"$B" capture "remind me about the plants" >/dev/null
fri="$(wq 'rotate the key')"
tom="$(python3 -c 'import datetime as d;print((d.date.today()+d.timedelta(1)).strftime("%a"))') 16:00 1"
next_fri="$(python3 -c 'import datetime as d;t=d.date.today();n=(4-t.weekday())%7 or 7;print((t+d.timedelta(n)).isoformat())')"
check "weekday in the text sets the reminder day, 09:00 ($fri)" "echo '$fri' | grep -q '^Fri 09:00 [1-7]$'"
check "tomorrow at 4pm" "[ \"\$(wq 'call mum')\" = '$tom' ]"
check "a time alone means today if still ahead" "wq stretch | grep -q ' 23:59 [01]$'"
check "no time in the text means next workday 09:00" "wq 'the plants' | grep -q ' 09:00 '"
"$B" capture "remind me to check the monitoring dashboard at 23:58" >/dev/null
check "words that start like a day name are not days" "wq 'monitoring dashboard' | grep -q ' 23:58 [01]$'"
"$B" capture-dismiss "$(capid 'monitoring dashboard')" >/dev/null
"$B" capture-accept "$(capid 'rotate the key')" --kind remind >/dev/null
check "accepting uses the time from the text" "grep -q '^- \[ \] $next_fri 09:00 | .*rotate the key' $HOME/brain/followups.md"
for t in 'call mum' stretch 'the plants'; do "$B" capture-dismiss "$(capid "$t")" >/dev/null; done
"$B" capture "remind me to water the plants" >/dev/null
"$B" capture-accept "$(cj 'water the plants' id)" >/dev/null
check "a reminder with no task is kept as an unattached reminder" "grep -q '| inbox | .*water the plants' $HOME/brain/followups.md"
rm -f "$HOME/brain/tasks/buy-batteries-gaffer.md"

echo "== search"
sj() { "$B" search "$1" --json | python3 -c "import json,sys;r=json.load(sys.stdin);print(' '.join('%s:%s' % (x['type'], x['slug']) for x in r))"; }
check "finds a task by its title" "sj 'rate limits' | grep -q 'task:api-rate-limits'"
check "finds a log entry by its text" "sj 'gateway already buffers' | grep -q 'log:api-rate-limits'"
check "finds a decision" "sj 'token bucket' | grep -q 'decision:api-rate-limits'"
check "all words must match, in any order" "sj 'bursts gateway' | grep -q 'log:api-rate-limits' && [ -z \"\$(sj 'gateway zebra')\" ]"
check "case-insensitive" "sj 'RATE LIMITS' | grep -q 'task:api-rate-limits'"
check "title match ranks above log matches" "sj 'rate limits' | awk '{print \$1}' | grep -q '^task:api-rate-limits'"
check "finds archived tasks" "sj 'stall target' | grep -q 'archived:stall-target-task'"
check "empty query returns nothing" "[ -z \"\$(sj '  ')\" ]"
check "results are capped" "[ \$(\"$B\" search a --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))') -le 30 ]"
check "plain output for people" "$B search 'rate limits' | grep -q 'api-rate-limits'"

echo "== projects"
P1=22222222-aaaa-bbbb-cccc-000000000001; P2=22222222-aaaa-bbbb-cccc-000000000002
NOWTS="$(date '+%Y-%m-%d %H:%M')"
printf '%s | start | %s | /code/alpha | \n%s | start | %s | /code/beta | \n%s | end | %s | /code/beta/src | \n' "$NOWTS" "$P1" "$NOWTS" "$P2" "$NOWTS" "$P2" >> "$HOME/brain/sessions.log"
"$B" new alpha-one "Alpha one" --session "$P1" >/dev/null
"$B" new alpha-two "Alpha two" --session "$P1" >/dev/null
"$B" new beta-one "Beta one" --session "$P2" >/dev/null
"$B" new loose-task "No session" >/dev/null
"$B" set alpha-two status blocked >/dev/null
"$B" set beta-one status done >/dev/null
pj() { "$B" projects --json | python3 -c "import json,sys;d={p['name']:p for p in json.load(sys.stdin)};p=d.get('$1');print(p['$2'] if p else 'MISSING')"; }
check "tasks are grouped by the folder their sessions ran in" "[ \"\$(pj alpha total)\" = 2 ]"
check "a session's start folder names the project, not a subfolder" "[ \"\$(pj beta total)\" = 1 ]"
check "tasks without sessions are grouped as unfiled" "[ \"\$(pj unfiled total)\" -ge 1 ]"
check "project state is its most urgent open task" "[ \"\$(pj alpha state)\" = blocked ]"
check "a project with nothing open is quiet" "[ \"\$(pj beta state)\" = quiet ] && [ \"\$(pj beta done)\" = 1 ]"
check "counts by status" "[ \"\$(pj alpha blocked)\" = 1 ] && [ \"\$(pj alpha active)\" = 1 ]"
check "plain output for people" "$B projects | grep -q '^alpha'"
for t in alpha-one alpha-two beta-one loose-task; do rm -f "$HOME/brain/tasks/$t.md"; done

echo "== system status"
sx() { "$B" status --json | python3 -c "import json,sys;d=json.load(sys.stdin);exec(sys.argv[1])" "$1"; }
check "status reports the last tick" "sx \"assert d['tick']['last'] and d['tick']['last_result'], d['tick']\""
check "status counts agent runs and failures from the tick log" "sx \"assert d['agent']['runs'] >= 1 and d['agent']['failed'] >= 0 and d['agent']['model']=='haiku', d['agent']\""
check "status lists health checks with ok/warn/bad" "sx \"c={x['id']:x for x in d['checks']}; assert {'hooks','tick','claude','git'} <= set(c), c; assert all(x['level'] in ('ok','warn','bad') for x in c.values())\""
check "hooks check sees the installed hooks" "sx \"c={x['id']:x for x in d['checks']}; assert c['hooks']['level']=='ok', c['hooks']\""
check "status counts the store" "sx \"s=d['store']; assert s['tasks'] >= 1 and s['decisions'] >= 1 and 'captures' in s and s['archived'] >= 1, s\""
check "status shows hourly activity for the last 24h" "sx \"a=d['activity']; assert len(a['sessions'])==24 and len(a['log'])==24, a\""
check "status shows config values" "sx \"assert d['config']['AGENT_MODEL']=='haiku'\""
check "plain status for people" "$B status | grep -qi 'tick'"
"$B" config NOTIFY off >/dev/null
check "config can switch a known on/off key" "grep -q '^NOTIFY=off' $HOME/brain/config"
check "config refuses unknown keys" "! $B config NOPE 1 2>/dev/null"
check "config refuses bad values" "! $B config NOTIFY maybe 2>/dev/null && ! $B config TICK_MINUTES abc 2>/dev/null"
"$B" config NOTIFY on >/dev/null

echo "== ask (questions over the brain)"
cat > "$WORK/bin/claude-ask" <<EOF
#!/bin/bash
{ echo "ARGS: \$*"; echo "PWD: \$PWD"; echo "ENV BRAIN_AGENT=\${BRAIN_AGENT:-}"; cat; echo; echo "----"; } >> "$WORK/ask-calls.log"
[ -f "$WORK/ask-fail" ] && { echo "boom" >&2; exit 3; }
printf 'The rate limit work is active; the token bucket was chosen.\nREFS: api-rate-limits, no-such-task\n'
EOF
chmod +x "$WORK/bin/claude-ask"
"$B" config CLAUDE_BIN "$WORK/bin/claude-ask" >/dev/null
out="$("$B" query 'where are we on rate limits?' --json)"
check "query returns the model's answer" "echo \"\$out\" | python3 -c \"import json,sys;d=json.load(sys.stdin);assert d['answer'].startswith('The rate limit work is active'), d\""
check "refs keep only real tasks" "echo \"\$out\" | python3 -c \"import json,sys;d=json.load(sys.stdin);assert d['refs']==['api-rate-limits'], d\""
check "the answer has no REFS line" "! echo \"\$out\" | grep -q 'REFS:'"
check "query runs read-only, as an agent run, in ~/brain" "grep -q -- '--permission-mode dontAsk' $WORK/ask-calls.log && grep -q 'ENV BRAIN_AGENT=1' $WORK/ask-calls.log && grep -q 'PWD: .*/home/brain\$' $WORK/ask-calls.log && ! grep -q 'Bash(gh' $WORK/ask-calls.log && ! grep -q 'Write\|Edit' <(grep '^ARGS' $WORK/ask-calls.log)"
check "the question and the board go in the prompt" "grep -q 'where are we on rate limits?' $WORK/ask-calls.log && grep -q 'Brain board' $WORK/ask-calls.log"
check "questions and answers are kept as history" "$B query --history --json | python3 -c \"import json,sys;h=json.load(sys.stdin);assert h[-1]['question']=='where are we on rate limits?' and h[-1]['refs']==['api-rate-limits'], h\""
check "empty question rejected" "! $B query '  ' 2>/dev/null"
check "overlong question rejected" "! $B query \"\$(python3 -c 'print(\"x\"*600)')\" 2>/dev/null"
touch "$WORK/ask-fail"
check "a failing model call is an error, not a crash" "! $B query 'anything' 2>$WORK/ask.err && grep -q 'claude' $WORK/ask.err && ! grep -q Traceback $WORK/ask.err"
rm -f "$WORK/ask-fail"

echo "== graph"
G1=33333333-aaaa-bbbb-cccc-000000000001
printf '%s | start | %s | /code/gamma | \n' "$(date '+%Y-%m-%d %H:%M')" "$G1" >> "$HOME/brain/sessions.log"
"$B" new gamma-one "Gamma one" --session "$G1" >/dev/null
"$B" new gamma-two "Gamma two" --session "$G1" >/dev/null
"$B" decide gamma-one "Use a queue" --decision "SQS" --why "retries" >/dev/null
gq() { "$B" graph --json | python3 -c "import json,sys;g=json.load(sys.stdin);exec(sys.argv[1])" "$1"; }
check "graph has project, task and decision nodes" "gq \"k={n['id']:n['kind'] for n in g['nodes']}; assert k.get('project:gamma')=='project' and k.get('task:gamma-one')=='task' and any(v=='decision' for v in k.values()), k\""
check "tasks link to their project" "gq \"e={(x['a'],x['b'],x['kind']) for x in g['edges']}; assert ('task:gamma-one','project:gamma','project') in e, e\""
check "tasks that shared a session are linked" "gq \"e={(x['a'],x['b'],x['kind']) for x in g['edges']}; assert ('task:gamma-one','task:gamma-two','session') in e or ('task:gamma-two','task:gamma-one','session') in e, e\""
check "decisions link to their task" "gq \"assert any(x['kind']=='decision' and x['b']=='task:gamma-one' for x in g['edges'])\""
check "every edge points at existing nodes" "gq \"ids={n['id'] for n in g['nodes']}; assert all(x['a'] in ids and x['b'] in ids for x in g['edges'])\""
check "done tasks are left out unless asked" "\"$B\" set gamma-two status done >/dev/null; gq \"assert 'task:gamma-two' not in {n['id'] for n in g['nodes']}\" && \"$B\" graph --all --json | grep -q 'task:gamma-two'"
for t in gamma-one gamma-two; do rm -f "$HOME/brain/tasks/$t.md"; done

echo "== web: brain serve"
"$B" new web-task-one "Web task one" --goal "Show it on the page" --next "Check the page" >/dev/null
"$B" followup +1h web-task-one "Check the web page" >/dev/null
"$B" serve --port 0 > "$WORK/serve.out" 2>&1 & srv=$!
for i in $(seq 1 50); do grep -q '^brain serve: http' "$WORK/serve.out" 2>/dev/null && break; sleep 0.1; done
URL="$(sed -n 's/^brain serve: \(http[^ ]*\).*/\1/p' "$WORK/serve.out" | head -1)"
PORT="$(echo "$URL" | sed 's/.*:\([0-9]*\)\/.*/\1/')"
check "serve prints a 127.0.0.1 URL" "echo \"$URL\" | grep -q '^http://127.0.0.1:[0-9]*/$'"
page="$(curl -s "$URL")"
TOKEN="$(echo "$page" | sed -n 's/.*name="brain-token" content="\([0-9a-f]*\)".*/\1/p' | head -1)"
check "page served with a per-run token" "[ \${#TOKEN} -ge 32 ]"
check "page assets served" "(for f in app.js app.css core.js today.js inbox.js palette.js ask.js projects.js system.js graph.js look.js; do curl -sf ${URL}\$f >/dev/null || exit 1; done)"
check "unknown path is 404" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' ${URL}../config)\" = 404 ] && [ \"\$(curl -s -o /dev/null -w '%{http_code}' ${URL}nope)\" = 404 ]"
api() { curl -s -o "$WORK/api.out" -w '%{http_code}' -H "X-Brain-Token: $TOKEN" -H 'Content-Type: application/json' "$@"; }
check "state needs the token" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' ${URL}api/state)\" = 403 ]"
check "state lists the task with goal, next, log and follow-ups" "[ \"\$(api ${URL}api/state)\" = 200 ] && python3 -c \"
import json;d=json.load(open('$WORK/api.out'))
t=[x for x in d['tasks'] if x['slug']=='web-task-one'][0]
assert t['goal']=='Show it on the page' and t['next']=='Check the page', t
assert any(e['text']=='Task created' for e in t['log']), t['log']
assert t['followups'][0]['what']=='Check the web page' and not t['followups'][0]['done']
assert 'now' in d
\""
check "a foreign Host header is refused (DNS rebinding)" "[ \"\$(api -H 'Host: evil.example:$PORT' ${URL}api/state)\" = 403 ]"
check "a cross-site Origin is refused" "[ \"\$(api -X POST -H 'Origin: https://evil.example' -d '{\"status\":\"blocked\"}' ${URL}api/tasks/web-task-one/status)\" = 403 ]"
check "POST without the token is refused" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{\"status\":\"blocked\"}' ${URL}api/tasks/web-task-one/status)\" = 403 ]"
check "POST needs a JSON body" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -X POST -H \"X-Brain-Token: $TOKEN\" -H 'Content-Type: text/plain' -d 'x' ${URL}api/tasks/web-task-one/status)\" = 415 ]"
wf="$HOME/brain/tasks/web-task-one.md"
check "status change from the page is saved and logged as you" "[ \"\$(api -X POST -d '{\"status\":\"blocked\"}' ${URL}api/tasks/web-task-one/status)\" = 200 ] && grep -q '^status: blocked' $wf && awk '/^### /{h=\$0} /Status: active -> blocked/{print h}' $wf | grep -q '| you\$'"
check "bad status rejected" "[ \"\$(api -X POST -d '{\"status\":\"nope\"}' ${URL}api/tasks/web-task-one/status)\" = 400 ]"
check "unknown task is 404" "[ \"\$(api -X POST -d '{\"status\":\"done\"}' ${URL}api/tasks/no-such-task/status)\" = 404 ]"
check "update posted from the page lands in the log" "[ \"\$(api -X POST -d '{\"text\":\"Checked from the page\"}' ${URL}api/tasks/web-task-one/log)\" = 200 ] && grep -q 'Checked from the page' $wf"
check "empty update rejected" "[ \"\$(api -X POST -d '{\"text\":\"  \"}' ${URL}api/tasks/web-task-one/log)\" = 400 ]"
fid="$(api ${URL}api/state >/dev/null; python3 -c "import json;print([x for x in json.load(open('$WORK/api.out'))['tasks'] if x['slug']=='web-task-one'][0]['followups'][0]['id'])")"
check "follow-up ticked from the page" "[ \"\$(api -X POST -d '{\"result\":\"looked fine\"}' ${URL}api/followups/$fid/done)\" = 200 ] && grep -q '\[x\] .*Check the web page' $HOME/brain/followups.md && grep -q 'looked fine' $wf"
check "oversized body rejected" "[ \"\$(api -X POST --data-binary @<(python3 -c 'print(\"{\\\"text\\\":\\\"\" + \"x\"*70000 + \"\\\"}\")') ${URL}api/tasks/web-task-one/log)\" = 413 ]"
check "server listens on 127.0.0.1 only" "! curl -s -m 2 http://\$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print \$1}'):$PORT/ >/dev/null 2>&1"
check "capture from the page" "[ \"\$(api -X POST -d '{\"text\":\"web capture about the web page\"}' ${URL}api/captures)\" = 200 ] && grep -q '| WEB | web capture about the web page' $HOME/brain/captures.md"
cid="$(python3 -c "import json;d=json.load(open('$WORK/api.out'));print([c for c in d['state']['captures'] if 'web capture' in c['text']][0]['id'])")"
check "state carries captures with a suggestion" "python3 -c \"
import json;d=json.load(open('$WORK/api.out'))['state']
c=[c for c in d['captures'] if 'web capture' in c['text']][0]
assert c['kind']=='log' and c['dest']=='web-task-one', c
assert isinstance(d['notes'], list)
assert isinstance(d['reminders'], list) and any('water the plants' in r['what'] for r in d['reminders']), d['reminders']
\""
check "accept from the page" "[ \"\$(api -X POST -d '{}' ${URL}api/captures/$cid/accept)\" = 200 ] && grep -q 'web capture about the web page' $wf"
"$B" capture "web dismiss me" >/dev/null
did="$("$B" captures --json | python3 -c "import json,sys;print([c for c in json.load(sys.stdin) if 'dismiss me' in c['text']][0]['id'])")"
check "dismiss from the page" "[ \"\$(api -X POST -d '{}' ${URL}api/captures/$did/dismiss)\" = 200 ] && grep -q 'web dismiss me -> dismissed' $HOME/brain/captures.md"
check "bad capture kind rejected" "\"$B\" capture 'kind test' >/dev/null; k=\$(\"$B\" captures --json | python3 -c \"import json,sys;print([c for c in json.load(sys.stdin) if 'kind test' in c['text']][0]['id'])\"); [ \"\$(api -X POST -d '{\\\"kind\\\":\\\"nope\\\"}' ${URL}api/captures/\$k/accept)\" = 400 ]"
"$B" notify --key webnote "A note from the brain" >/dev/null
nid="$(api ${URL}api/state >/dev/null; python3 -c "import json;print([n for n in json.load(open('$WORK/api.out'))['notes'] if 'note from the brain' in n['text']][0]['id'])")"
check "brain notes can be cleared from the page" "[ \"\$(api -X POST -d '{}' ${URL}api/notes/$nid/dismiss)\" = 200 ] && ! grep -q 'A note from the brain' $HOME/brain/inbox.md"
check "search from the page" "[ \"\$(api ${URL}'api/search?q=web%20task')\" = 200 ] && python3 -c \"
import json;r=json.load(open('$WORK/api.out'))['results']
assert r and r[0]['type']=='task' and r[0]['slug']=='web-task-one', r
\""
check "search needs the token" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' ${URL}'api/search?q=web')\" = 403 ]"
check "state carries projects" "api ${URL}api/state >/dev/null; python3 -c \"
import json;d=json.load(open('$WORK/api.out'))
assert isinstance(d['projects'], list) and all('name' in p and 'state' in p for p in d['projects']), d['projects']
\""
check "system status from the page" "[ \"\$(api ${URL}api/status)\" = 200 ] && python3 -c \"
import json;d=json.load(open('$WORK/api.out')); assert d['checks'] and d['tick'], d
\""
check "config switch from the page" "[ \"\$(api -X POST -d '{\"key\":\"NOTIFY\",\"value\":\"off\"}' ${URL}api/config)\" = 200 ] && grep -q '^NOTIFY=off' $HOME/brain/config"
check "page cannot set arbitrary config" "[ \"\$(api -X POST -d '{\"key\":\"CLAUDE_BIN\",\"value\":\"/tmp/evil\"}' ${URL}api/config)\" = 400 ] && ! grep -q '/tmp/evil' $HOME/brain/config"
api -X POST -d '{"key":"NOTIFY","value":"on"}' ${URL}api/config >/dev/null
check "ask from the page" "[ \"\$(api -X POST -d '{\"question\":\"what is open?\"}' ${URL}api/ask)\" = 200 ] && python3 -c \"
import json;d=json.load(open('$WORK/api.out')); assert d['answer'] and d['refs']==['api-rate-limits'], d
\""
check "ask history from the page" "[ \"\$(api ${URL}api/ask)\" = 200 ] && python3 -c \"
import json;h=json.load(open('$WORK/api.out'))['history']; assert h[-1]['question']=='what is open?', h
\""
check "empty question from the page rejected" "[ \"\$(api -X POST -d '{\"question\":\" \"}' ${URL}api/ask)\" = 400 ]"
check "graph from the page" "[ \"\$(api ${URL}api/graph)\" = 200 ] && python3 -c \"
import json;g=json.load(open('$WORK/api.out')); assert g['nodes'] and isinstance(g['edges'], list), g
\""
kill $srv 2>/dev/null; wait $srv 2>/dev/null
rm -f "$wf"

echo "== tick lock"
mkdir -p "$HOME/brain/.state/tick.lock"; sleep 300 & echo $! > "$HOME/brain/.state/tick.lock/pid"; holder=$!
check "second tick refuses while locked" "$B tick --no-agent | grep -q 'another tick'"
kill $holder 2>/dev/null; wait $holder 2>/dev/null
check "stale lock (dead pid) is taken over" "! $B tick --no-agent --at '2026-10-10 23:00' | grep -q 'another tick'"

echo "== uninstall"
bash "$HOME/brain/bin/install-brain.sh" --uninstall > "$WORK/uninstall.log" 2>&1
check "uninstall removes skill" "[ ! -d $HOME/.claude/skills/brain ]"
check "uninstall removes brain hooks and permissions only" "python3 -c \"
import json;d=json.load(open('$HOME/.claude/settings.json'))
s=json.dumps(d); assert '/brain/bin/' not in s and '~/brain' not in s, s
assert d['model']=='opus' and 'Bash(npm test)' in d['permissions']['allow']
assert d['hooks']['SessionStart'][0]['hooks'][0]['command']=='echo mine'
assert 'SessionEnd' not in d['hooks']
\""
check "uninstall keeps ~/brain" "[ -f $HOME/brain/tasks/api-rate-limits.md -a -f $HOME/brain/decisions.md ]"

echo
echo "passed $PASS, failed $FAIL   (work dir: $WORK)"
[ "$FAIL" -eq 0 ]
