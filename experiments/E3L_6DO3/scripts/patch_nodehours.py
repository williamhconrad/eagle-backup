#!/usr/bin/env python3
"""
patch_nodehours.py - wire nodehours.sh into run_cycle.sh.

Adds an nh_mark call at every stage boundary so each cycle produces
nodehours_iter<N>.csv with per-stage node-hour costs.

USAGE
  cd $VSROOT/OpenVS-main/experiments/E3L_6DO3/scripts
  python patch_nodehours.py
  bash -n run_cycle.sh && echo "syntax OK"
"""
from pathlib import Path
import sys

p = Path("run_cycle.sh")
s = p.read_text()

if "nh_mark" in s:
    sys.exit("already patched - nothing to do")

# 1. source the helper and initialise, right after the opening banner
anchor = 'log "queue=$QUEUE  walltime=$WALL"'
assert anchor in s, "banner line not found"
s = s.replace(anchor, anchor + '''

# --- node-hour accounting -------------------------------------------------
if [ -f "$SCRIPTS/nodehours.sh" ]; then
    . "$SCRIPTS/nodehours.sh"
    nh_init "$ITER"
    nh_mark "cycle_start"
else
    nh_init()    { :; }
    nh_mark()    { :; }
    nh_summary() { :; }
    log "  nodehours.sh not found - node-hour tracking disabled"
fi''', 1)

# 2. a mark after each stage boundary
marks = [
    ('log "  GATE OK: $nlig distinct ligands docked"',            "docking"),
    ('log "  GATE OK: $(basename "$G") has $n_gat rows"',         "stage1_gather"),
    ('log "  GATE OK: $(basename "$A") has $n_aug rows"',         "stage2_augment"),
    ('log "  GATE OK: model_${ITER} written"',                    "stage3_train"),
    ('log "  GATE OK: $NP prediction files"',                     "stage4_predict"),
    ('log "  GATE OK: candidates selected for round $NEXT"',      "stage5_savetop"),
    ('log "  GATE OK: $n_mol2 mol2 files, none empty"',           "stage6_gen3d"),
    ('log "  GATE OK: $n_next params ready for round $NEXT"',     "stage7_genparams"),
]
n = 0
for anchor, label in marks:
    if anchor in s:
        s = s.replace(anchor, anchor + f'\nnh_mark "{label}"', 1)
        n += 1
        print(f"  marked: {label}")
    else:
        print(f"  ANCHOR NOT FOUND, skipped: {label}")

# 3. summary at the end
tail = 'log "=========== CYCLE $ITER COMPLETE ==========="'
assert tail in s, "completion banner not found"
s = s.replace(tail, tail + '\nnh_summary', 1)

p.write_text(s)
print(f"\npatched {n}/8 stage boundaries + init + summary")
