#!/bin/bash
#
# fix_conda_activation.sh
#
# Replaces the fragile `source ~/.bashrc` pattern with a direct source of
# conda's activation hook, which works in NON-INTERACTIVE shells (PBS job
# scripts, `bash script.sh`, dask workers).
#
# WHY THIS IS NEEDED
#   `conda init` appends a block to ~/.bashrc. Many .bashrc files begin with a
#   guard that returns early for non-interactive shells:
#       case $- in *i*) ;; *) return;; esac
#   When that guard is present, conda's block never runs inside a batch job and
#   every job dies with "conda: command not found".
#
# WHAT IT CHANGES
#   1. Job scripts (*.sh)            - plain `source ~/.bashrc` lines
#   2. Joblist generators (*.py)     - the same line embedded in job-script
#                                      templates. These pass through
#                                      str.format(), so literal braces MUST be
#                                      doubled ({{ }}) or the generator raises
#                                      KeyError. This script handles that.
#   3. dask job_script_prologue      - ['source ~/.bashrc', 'conda activate X']
#
# USAGE
#   cd /path/to/OpenVS-main
#   bash scripts/fix_conda_activation.sh          # apply
#   bash scripts/fix_conda_activation.sh --check  # report only, change nothing
#
# UNDO
#   This repo is a git repository, so:  git checkout -- .
#
set -euo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

if [ ! -d openvs ] || [ ! -d experiments ]; then
    echo "ERROR: run this from the top of the OpenVS repository." >&2
    exit 1
fi

HOOK_SH='source "${CONDA_BASE:-$HOME/miniconda3}/etc/profile.d/conda.sh"'
# same line, but with braces doubled for use inside str.format() templates
HOOK_PY='source "${{CONDA_BASE:-$HOME/miniconda3}}/etc/profile.d/conda.sh"'

n_sh=$(grep -rl '^source ~/\.bashrc$' --include='*.sh' . 2>/dev/null | wc -l)
n_py=$(grep -rl '^source ~/\.bashrc$' --include='*.py' . 2>/dev/null | wc -l)
n_dask=$(grep -rl "job_script_prologue=\['source ~/\.bashrc'" --include='*.py' . 2>/dev/null | wc -l)

echo "Found:"
echo "  $n_sh  job script(s) (*.sh)"
echo "  $n_py  generator template(s) (*.py)"
echo "  $n_dask  dask prologue(s) (*.py)"

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo
    echo "--check given: nothing modified."
    exit 0
fi

# 1. shell scripts
while IFS= read -r f; do
    [ -n "$f" ] || continue
    python3 - "$f" "$HOOK_SH" <<'PY'
import sys
path, hook = sys.argv[1], sys.argv[2]
s = open(path).read()
open(path, 'w').write(s.replace('source ~/.bashrc', hook))
PY
done < <(grep -rl '^source ~/\.bashrc$' --include='*.sh' . 2>/dev/null || true)

# 2. generator templates (braces doubled for str.format)
while IFS= read -r f; do
    [ -n "$f" ] || continue
    python3 - "$f" "$HOOK_PY" <<'PY'
import re, sys
path, hook = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r'^source ~/\.bashrc$', hook.replace('\\', '\\\\'), s, flags=re.M)
open(path, 'w').write(s)
PY
done < <(grep -rl '^source ~/\.bashrc$' --include='*.py' . 2>/dev/null || true)

# 3. dask job_script_prologue lists (plain strings, single braces)
while IFS= read -r f; do
    [ -n "$f" ] || continue
    python3 - "$f" "$HOOK_SH" <<'PY'
import sys
path, hook = sys.argv[1], sys.argv[2]
s = open(path).read()
s = s.replace("'source ~/.bashrc'", '"%s"' % hook.replace('"', '\\"'))
open(path, 'w').write(s)
PY
done < <(grep -rl "job_script_prologue=\['source ~/\.bashrc'" --include='*.py' . 2>/dev/null || true)

echo
echo "Done. Review with:   git diff"
echo "Undo with:           git checkout -- ."
