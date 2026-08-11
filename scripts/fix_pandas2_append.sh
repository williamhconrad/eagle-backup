#!/bin/bash
#
# fix_pandas2_append.sh
#
# `DataFrame.append()` was deprecated in pandas 1.4 and REMOVED in pandas 2.0.
# OpenVS still calls it, yet requirements.txt pins pandas=2.1.3 - so several
# scripts cannot run in the environment the project itself specifies. The
# symptom is:
#
#     AttributeError: 'DataFrame' object has no attribute 'append'
#
# This script rewrites the DataFrame calls to pd.concat(), which works
# identically on pandas 1.x and 2.x.
#
# It only touches the unambiguous pattern
#     X = X.append(Y, ignore_index=True)
# and rewrites it to
#     X = pd.concat([X, Y], ignore_index=True)
#
# It deliberately does NOT touch bare `something.append(...)` calls, because
# almost all of those are ordinary Python list appends and are perfectly valid.
# (e.g. augment_vs_results.py line 43 builds a list then calls pd.concat on it
# - already correct.)
#
# USAGE
#   cd /path/to/OpenVS-main
#   bash scripts/fix_pandas2_append.sh --check    # report only
#   bash scripts/fix_pandas2_append.sh            # apply
#
# UNDO
#   git checkout -- .
#
set -euo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

if [ ! -d openvs ] || [ ! -d experiments ]; then
    echo "ERROR: run this from the top of the OpenVS repository." >&2
    exit 1
fi

PATTERN='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*\1\.append\('

echo "DataFrame .append() calls found:"
grep -rnE "$PATTERN" --include='*.py' . | sed 's|^\./|  |' || true
n=$(grep -rlE "$PATTERN" --include='*.py' . 2>/dev/null | wc -l)
echo
echo "in $n file(s)."

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo
    echo "--check given: nothing modified."
    exit 0
fi

python3 - <<'PY'
import re
from pathlib import Path

# X = X.append(Y, ignore_index=True)  ->  X = pd.concat([X, Y], ignore_index=True)
pat = re.compile(
    r'^(?P<indent>\s*)(?P<var>[A-Za-z_]\w*)\s*=\s*(?P=var)\.append\('
    r'(?P<other>[^,)]+)'
    r'(?P<rest>.*?)\)[ \t]*$',
    re.MULTILINE)

def repl(m):
    rest = m.group('rest').strip()
    extra = (', ' + rest.lstrip(',').strip()) if rest.strip(', ') else ''
    return (f"{m.group('indent')}{m.group('var')} = pd.concat("
            f"[{m.group('var')}, {m.group('other').strip()}]{extra})")

changed = 0
for p in sorted(Path('.').rglob('*.py')):
    s = p.read_text(encoding='utf-8')
    new, n = pat.subn(repl, s)
    if n:
        if 'import pandas as pd' not in new:
            print(f"  SKIPPED (no 'import pandas as pd'): {p}")
            continue
        p.write_text(new, encoding='utf-8')
        print(f"  fixed {n} call(s) in {p}")
        changed += 1
print(f"\nModified {changed} file(s).")
PY

echo
echo "Review with:  git diff"
echo "Undo with:    git checkout -- ."
