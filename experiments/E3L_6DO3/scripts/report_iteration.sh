#!/bin/bash
#
# report_iteration.sh - evidence that an OpenVS iteration completed, plus the
# top-20 tables.
#
# READ-ONLY. Runs nothing, submits nothing, changes nothing. Safe at any time.
#
# USAGE
#   cd $VSROOT/OpenVS-main/experiments/E3L_6DO3/scripts
#   bash report_iteration.sh [ITER]        # ITER defaults to 1
#
set -u
ITER="${1:-1}"
EXP="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="E3L_6DO3"

hr()  { printf '%s\n' "------------------------------------------------------------"; }
ok()  { printf '  [ OK ] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; }
chk() { [ -e "$1" ] && ok "$2" || bad "$2  (missing: $1)"; }

echo "OpenVS iteration $ITER report - $(date)"
echo "experiment: $EXP"

hr; echo "1. CONFIG FILES"
for c in config_clusterdb.json config_real_db.json; do
    chk "$EXP/$c" "$c"
done
if [ -f "$EXP/config_real_db.json" ]; then
    python3 - "$EXP/config_real_db.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
for k in ("database_type","train_size","test_size","val_size","fps_path","prediction_path"):
    v=c.get(k,"<absent>")
    print(f"    {k:16s} {v}")
PY
fi

hr; echo "2. DOCKING OUTPUT"
for s in train1 test validation train${ITER}; do
    d="$EXP/screening/outputs/${PROJ}_${s}/${PROJ}_VSX"
    [ -d "$d" ] || continue
    n=$(ls "$d"/*.score.sc 2>/dev/null | wc -l)
    lig=$(grep -h '^SCORE:' "$d"/*.score.sc 2>/dev/null \
          | awk '$2!="total_score"{print $(NF-1)}' | sort -u | wc -l)
    printf "  %-12s %5s score files, %7s distinct ligands\n" "$s" "$n" "$lig"
done

hr; echo "3. GATHERED / AUGMENTED"
for s in train1 test validation; do
    for suf in _vs_results.feather _vs_results.aug.feather; do
        f="$EXP/screening/outputs/${PROJ}_${s}${suf}"
        [ -f "$f" ] && printf "  %-46s %s\n" "$(basename "$f")" \
            "$(python3 -c "import pandas as pd;print(len(pd.read_feather('$f')),'rows')" 2>/dev/null)"
    done
done

hr; echo "4. MODEL"
M="$EXP/models/model_${ITER}/vanilla_model_best.pt"
chk "$M" "model_${ITER}/vanilla_model_best.pt"
[ -f "$M" ] && printf "    size %s\n" "$(du -h "$M" | cut -f1)"
L="$(ls -t output.train*.log 2>/dev/null | head -1)"
if [ -n "$L" ]; then
    echo "    from $L:"
    grep -E 'roc_auc' "$L" | tail -2 | sed 's/^/      /'
    grep -E 'Early stopping|Best epoch' "$L" | tail -1 | sed 's/^/      /'
fi

hr; echo "5. LIBRARY-WIDE PREDICTION"
P="$EXP/scratch/predictions_real_db/model_${ITER}_prediction"
for sub in "$P"/*/; do
    [ -d "$sub" ] || continue
    case "$sub" in *top_predictions*) continue;; esac
    printf "  %-28s %5s prediction files\n" "$(basename "$sub")" "$(ls "$sub" | wc -l)"
done

hr; echo "6. SELECTED CANDIDATES"
T="$P/top_predictions"
for f in all.top all.random; do chk "$T/$f.feather" "$f.feather"; done

hr; echo "7. TOP 20 BY LIBRARY-WIDE PREDICTION (p_hits)"
python3 - "$T" <<'PY'
import os,sys
import pandas as pd
t=os.path.join(sys.argv[1],"all.top.feather")
if not os.path.exists(t): print("  all.top.feather not found"); raise SystemExit
d=pd.read_feather(t).nlargest(20,"p_hits")
print(f"  {'rank':>4}  {'p_hits':>7}  {'molecule_id':<40} smiles")
for i,(_,r) in enumerate(d.iterrows(),1):
    print(f"  {i:>4}  {r.p_hits:7.4f}  {str(r.molecule_id)[:40]:<40} {str(r.smiles)[:50]}")
PY

hr; echo "8. TOP 20 DOCKING HITS (by dG), with p_hits where available"
python3 - "$EXP" "$PROJ" "$ITER" <<'PY'
import glob,os,sys
import pandas as pd
exp,proj,it=sys.argv[1],sys.argv[2],sys.argv[3]

rows=[]
for s in ("train1","test","validation",f"train{it}"):
    for f in glob.glob(os.path.join(exp,"screening","outputs",f"{proj}_{s}",f"{proj}_VSX","*.score.sc")):
        hdr=None
        for line in open(f):
            if not line.startswith("SCORE:"): continue
            p=line.split()
            if hdr is None:
                hdr=p
                try: i_dg=hdr.index("dG"); i_lig=hdr.index("ligandname")
                except ValueError: hdr=None
                continue
            if len(p)<=max(i_dg,i_lig): continue
            lig=p[i_lig]
            if lig=="LG1": continue
            try: rows.append((lig,float(p[i_dg]),s))
            except ValueError: pass
if not rows:
    print("  no docking scores found"); raise SystemExit
df=pd.DataFrame(rows,columns=["ligandname","dG","set"]).drop_duplicates("ligandname")

# join predictions if the ids share a namespace
ph={}
top=os.path.join(exp,"scratch","predictions_real_db",f"model_{it}_prediction",
                 "top_predictions","all.top.feather")
if os.path.exists(top):
    p=pd.read_feather(top); ph=dict(zip(p.molecule_id,p.p_hits))

best=df.nsmallest(20,"dG")
print(f"  {'rank':>4}  {'dG':>9}  {'p_hits':>7}  {'set':<11} ligand")
for i,(_,r) in enumerate(best.iterrows(),1):
    v=ph.get(r.ligandname)
    v=f"{v:7.4f}" if v is not None else "      -"
    print(f"  {i:>4}  {r.dG:9.3f}  {v}  {r['set']:<11} {r.ligandname}")
print()
print(f"  (dG is Rosetta's estimate; more negative = tighter. n={len(df):,} unique ligands)")
print("  '-' in p_hits means the ligand is not in this iteration's top set --")
print("  expected for iteration 1, where docking used centroids and prediction used REAL.")
PY

hr; echo "report complete"
