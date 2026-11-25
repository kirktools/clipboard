#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import os, signal, subprocess, time
from pathlib import Path
executable = str(Path('dist/dev/Clipboard Dev.app/Contents/MacOS/Clipboard').resolve())
rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
for row in rows:
    fields = row.strip().split(None, 1)
    if len(fields) != 2 or fields[1] != executable:
        continue
    pid = int(fields[0])
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.1)
PY

./scripts/build.sh debug
open "dist/dev/Clipboard Dev.app"
