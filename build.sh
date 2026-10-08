#!/bin/bash
# Generate install-brain.sh from src/install.tmpl.sh, embedding the files in src/.
set -eu
cd "$(dirname "$0")"
python3 - <<'PY'
import re
src = "src/"
tmpl = open(src + "install.tmpl.sh").read()
DELIM = "__BRAIN_EOF__"

def body(path):
    text = open(src + path).read()
    assert DELIM not in text, path
    return text if text.endswith("\n") else text + "\n"

def put(m):
    dest, mode = m.group(1), m.group(2)
    dest, _, srcp = dest.partition("=")
    return 'put_file "$BRAIN/%s" %s <<\'%s\'\n%s%s' % (dest, mode, DELIM, body(srcp or dest), DELIM)

def keep(m):
    dest = m.group(1)
    name = dest.split("/")[-1]
    return 'keep_file "$BRAIN/%s" <<\'%s\'\n%s%s' % (dest, DELIM, body(name), DELIM)

out = re.sub(r"@@PUT (\S+) (\d+)@@", put, tmpl)
out = re.sub(r"@@KEEP (\S+)@@", keep, out)
out = re.sub(r"@@RAW (\S+)@@\n", lambda m: body(m.group(1)), out)
assert "@@" not in out
open("install-brain.sh", "w").write(out)
PY
chmod +x install-brain.sh
bash -n install-brain.sh
echo "built install-brain.sh ($(wc -l < install-brain.sh) lines)"
