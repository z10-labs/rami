#!/bin/bash
# Offline tests for install-brain.sh and the brain command.
# Runs in a throwaway HOME. A fake `claude` records whether a model was called.
# Usage: tests/test.sh            (needs bash, git, python3)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/brain-test.XXXXXX")"
export HOME="$WORK/home"
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
check "page assets served" "curl -sf ${URL}app.js >/dev/null && curl -sf ${URL}app.css >/dev/null"
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
