#!/bin/bash
#
# run_cycle.sh - one complete OpenVS active-learning cycle.
#
# ORDER (for iteration N):
#     dock round N        using train<N>_params from the previous cycle
#     stage 1  gather     iter=N
#     stage 2  augment    iter=N
#     stage 3  train      iter=N   -> model_N
#     stage 4  predict    iter=N   -> model_N_prediction  (4 single-process jobs)
#     stage 5  save_top   iter=N   -> candidates for round N+1
#     stage 6  gen_3dstruct iter=N -> smiles_iter<N+1>, mol2s_iter<N+1>
#     stage 7  gen_params iter=N+1 -> train<N+1>_params
#
# Ending on stage 7 means the next cycle can start straight at docking:
#     bash run_cycle.sh 2      # docks round 2, leaves train3_params ready
#     bash run_cycle.sh 3      # docks round 3, leaves train4_params ready
#
# EVERY STAGE IS GATED. On failure it names the gate and exits. Completed work
# is detected and skipped, so re-running after a fix resumes rather than
# restarting.
#
# USAGE
#   cd $VSROOT/OpenVS-main/experiments/E3L_6DO3/scripts
#   screen -S cycle2
#   bash run_cycle.sh 2 2>&1 | tee cycle2.log
#   # Ctrl-A then D to detach; screen -r cycle2 to return
#
set -u

ITER="${1:-2}"
NEXT=$((ITER+1))
PROJ="E3L_6DO3"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
EXP="$(cd "$SCRIPTS/.." && pwd)"
QUEUE="${OPENVS_QUEUE:-preemptable}"
WALL="${OPENVS_WALLTIME:-06:00:00}"
POLL=120

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo; log "GATE FAILED: $*"; log "fix the cause, then re-run: bash run_cycle.sh $ITER"; exit 1; }

wait_job() {
    local num="${1%%.*}"; num="${num%%[*}"
    log "  waiting on job $num"
    sleep 30
    while true; do
        n=$(qstat -u "$USER" 2>/dev/null | awk -v j="$num" \
            '{id=$1; sub(/[\[.].*$/,"",id); if(id==j) c++} END{print c+0}')
        [ "$n" -eq 0 ] && { log "  job $num finished"; return 0; }
        sleep "$POLL"
    done
}

# some stages submit a child array job and exit; wait for that too
wait_jobname() {
    local pat="$1"
    sleep 30
    if qstat -u "$USER" 2>/dev/null | grep -q "$pat"; then
        log "  waiting on child job(s) matching '$pat'"
        while qstat -u "$USER" 2>/dev/null | grep -q "$pat"; do sleep "$POLL"; done
        log "  child job(s) '$pat' finished"
    fi
}

submit_wait() {           # submit_wait <script> <logfile> <iter>
    local s="$1" lg="$2" it="$3"
    log "  qsub $s (iter=$it) -> $lg"
    local jid
    jid=$(qsub -v iter=$it,OPENVS_QUEUE=$QUEUE -q "$QUEUE" \
              -l walltime="$WALL" -r y -o "$lg" "$s") || die "qsub failed: $s"
    log "  job id: $jid"
    wait_job "$jid"
}

cd "$SCRIPTS" || die "cannot cd to $SCRIPTS"
log "=========== CYCLE $ITER  (dock round $ITER, leaves train${NEXT}_params) ==========="
log "queue=$QUEUE  walltime=$WALL"

# ============================================================ DOCK ROUND N
log "--- prechecks for docking round $ITER"
PDIR="$EXP/scratch/params/train${ITER}_params"
n_par=$(ls "$PDIR" 2>/dev/null | wc -l)
[ "$n_par" -gt 100 ] || die "only $n_par params in $PDIR - run cycle $((ITER-1)) first"
log "  GATE OK: $n_par params for round $ITER"

# Skip the whole docking block if this round is already docked and tarred.
DOCKED="$EXP/screening/outputs/${PROJ}_train${ITER}/${PROJ}_VSX"
n_done=$(grep -h '^SCORE:' "$DOCKED"/*.score.sc 2>/dev/null \
         | awk '$2!="total_score" && $(NF-1)!="LG1"{print $(NF-1)}' | sort -u | wc -l)
n_want=$(ls "$EXP/scratch/params/train${ITER}_params" 2>/dev/null | wc -l)
n_min=$(( n_want * 90 / 100 ))          # allow 10% attrition
if [ "$n_done" -ge "$n_min" ] && [ "$n_min" -gt 0 ] \
   && [ -f "$EXP/scratch/results/${PROJ}_train${ITER}.tar" ]; then
    log "--- docking round $ITER already done ($n_done of $n_want ligands), skipping to stage 1"
    SKIP_DOCK=1
else
    SKIP_DOCK=0
fi

if [ "$SKIP_DOCK" -eq 0 ]; then
log "--- packaging params"
cd "$EXP/scratch/params" || die "no scratch/params"
TARF="$EXP/screening/params/train${ITER}_params_0.tar"
if [ ! -f "$TARF" ]; then
    tar -cf "train${ITER}_params_0.tar" "train${ITER}_params" || die "tar failed"
    mv "train${ITER}_params_0.tar" "$EXP/screening/params/" || die "mv failed"
fi
m=$(tar -tf "$TARF" | wc -l)
[ "$m" -gt 100 ] || die "params tar has only $m members"
log "  GATE OK: tar has $m members"

# upstream ships only screening/train1
cd "$EXP/screening" || die
if [ ! -d "train${ITER}" ]; then
    log "  creating screening/train${ITER} from train1"
    mkdir -p "train${ITER}"
    cp train1/run_dock.vsx.sh train1/dock_vsx.xml train1/gen_joblist_production.py \
       "train${ITER}/" || die "cannot seed train${ITER}"
    chmod +x "train${ITER}/run_dock.vsx.sh"
fi
for f in run_dock.vsx.sh dock_vsx.xml gen_joblist_production.py; do
    [ -f "train${ITER}/$f" ] || die "train${ITER}/$f missing"
done
log "  GATE OK: screening/train${ITER} ready"

log "--- screening inputs (prefix=train${ITER})"
sed -i "s/prefix=\"[a-z0-9]*\"/prefix=\"train${ITER}\"/" gen_screening_inputs.py
grep -q "prefix=\"train${ITER}\"" gen_screening_inputs.py || die "prefix edit failed"
python gen_screening_inputs.py || die "gen_screening_inputs failed"
FLAGS=$(ls inputs/train${ITER}set/*/flags_params_train${ITER}_0_0.flags 2>/dev/null | head -1)
[ -n "$FLAGS" ] || die "no flags file produced"
# Rosetta 2026 silently ignores a .tar passed to -in:file:extra_res_fa
np=$(tr ' ' '\n' < "$FLAGS" | grep -c '\.params$')
[ "$np" -gt 1 ] || die "flags lists $np params - the .tar regression is back"
log "  GATE OK: flags file lists $np individual .params"

log "--- docking round $ITER"
cd "train${ITER}" || die
python gen_joblist_production.py "train${ITER}" || die "gen_joblist_production failed"
N=$(wc -l < "${PROJ}_dock.joblist")
[ "$N" -ge 1 ] || die "empty joblist"
grep -q '^#PBS -r y' sbatch_dock_arrayjobs.sh || die "sbatch_dock_arrayjobs.sh lacks -r y"
log "  $N array tasks"
if [ "$N" -gt 1 ]; then SUB="qsub -r y -q $QUEUE -J 1-${N}%10 sbatch_dock_arrayjobs.sh"
else                    SUB="qsub -r y -q $QUEUE sbatch_dock_arrayjobs.sh"; fi
log "  $SUB"
JID=$($SUB) || die "array submit failed"
wait_job "$JID"

OUT="$EXP/screening/outputs/${PROJ}_train${ITER}/${PROJ}_VSX"
nlig=$(grep -h '^SCORE:' "$OUT"/*.score.sc 2>/dev/null \
       | awk '$2!="total_score" && $(NF-1)!="LG1"{print $(NF-1)}' | sort -u | wc -l)
[ "$nlig" -gt 100 ] || die "only $nlig distinct ligands docked - check $OUT"
log "  GATE OK: $nlig distinct ligands docked"

cd "$EXP/screening/outputs" || die
if [ ! -f "$EXP/scratch/results/${PROJ}_train${ITER}.tar" ]; then
    tar -cf "${PROJ}_train${ITER}.tar" "${PROJ}_train${ITER}" || die "tar failed"
    mv "${PROJ}_train${ITER}.tar" "$EXP/scratch/results/" || die "mv failed"
fi
log "  GATE OK: results tarred"

# ============================================================ STAGES 1 - 5
cd "$SCRIPTS" || die

fi   # end SKIP_DOCK block

log "--- stage 1: gather (iter=$ITER)"
G="$EXP/screening/outputs/${PROJ}_train${ITER}_vs_results.feather"
# gather skips any set whose .feather already exists, so clear a stale one
[ -f "$G" ] && { log "  removing stale $(basename "$G")"; rm -f "$G"; }
submit_wait sbatch_gather_vs_results.sh "output.gather.iter${ITER}.log" "$ITER"
[ -f "$G" ] || die "gather produced no $(basename "$G")"
log "  GATE OK: $(basename "$G")"

log "--- stage 2: augment (iter=$ITER)"
A="$EXP/screening/outputs/${PROJ}_train${ITER}_vs_results.aug.feather"
submit_wait sbatch_augment_results.sh "output.augment.iter${ITER}.log" "$ITER"
[ -f "$A" ] || die "augment produced no $(basename "$A")"
log "  GATE OK: $(basename "$A")"

log "--- stage 3: train (iter=$ITER)"
submit_wait sbatch_train.sh "output.train.iter${ITER}.log" "$ITER"
M="$EXP/models/model_${ITER}/vanilla_model_best.pt"
[ -f "$M" ] || die "training produced no model_${ITER}"
grep -E 'roc_auc' "output.train.iter${ITER}.log" | tail -1 | sed 's/^/    /'
log "  GATE OK: model_${ITER} written"

log "--- stage 4: predict (iter=$ITER, 4 single-process jobs)"
PD="$EXP/scratch/predictions_real_db/model_${ITER}_prediction"
for i in 1 2 3 4; do
    qsub -v iter=$ITER -q "$QUEUE" -l walltime="$WALL" -r y \
         -o "output.predict.iter${ITER}.$i.log" run_predict_auto.sh \
        || die "predict submit $i failed"
    sleep 45
done
log "  submitted 4 predict jobs"
sleep 60
while qstat -u "$USER" 2>/dev/null | grep -q 'predict_a'; do sleep "$POLL"; done
NP=$(ls "$PD"/*/*.feather 2>/dev/null | wc -l)
[ "$NP" -gt 1000 ] || die "only $NP prediction files in $PD"
log "  GATE OK: $NP prediction files"

log "--- stage 5: save top (iter=$ITER)"
submit_wait sbatch_save_top_prediction.sh "output.savetop.iter${ITER}.log" "$ITER"
T="$PD/top_predictions"
[ -f "$T/all.top.feather" ]    || die "no all.top.feather"
[ -f "$T/all.random.feather" ] || die "no all.random.feather"
log "  GATE OK: candidates selected for round $NEXT"

# ======================================================== STAGE 6: 3D STRUCT
log "--- stage 6: gen_3dstruct (iter=$ITER -> smiles_iter${NEXT})"
MOL2="$EXP/scratch/mol2s/mmff94_mol2s_iter${NEXT}"
n_mol2=$(ls "$MOL2"/*.mol2 2>/dev/null | wc -l)
n_empty=$(ls -la "$MOL2" 2>/dev/null | awk 'NR>3 && $5==0{c++} END{print c+0}')
if [ "$n_mol2" -gt 0 ] && [ "$n_empty" -eq 0 ]; then
    log "  $MOL2 already has $n_mol2 good mol2 files, skipping"
else
    [ "$n_empty" -gt 0 ] && { log "  clearing $n_empty empty mol2 files"; rm -rf "$MOL2"; }
    submit_wait sbatch_gen_3dstruct.sh "output.gen3d.iter${ITER}.log" "$ITER"
    # the parent submits a gen3d array and exits; wait for the array too
    wait_jobname 'gen3d'
    n_mol2=$(ls "$MOL2"/*.mol2 2>/dev/null | wc -l)
    n_empty=$(ls -la "$MOL2" 2>/dev/null | awk 'NR>3 && $5==0{c++} END{print c+0}')
fi
[ "$n_mol2" -gt 0 ]  || die "no mol2 files in $MOL2"
[ "$n_empty" -eq 0 ] || die "$n_empty EMPTY mol2 files in $MOL2 (see *.err there)"
log "  GATE OK: $n_mol2 mol2 files, none empty"

# ========================================================= STAGE 7: PARAMS
log "--- stage 7: gen_params (iter=$NEXT -> train${NEXT}_params)"
NPDIR="$EXP/scratch/params/train${NEXT}_params"
n_next=$(ls "$NPDIR" 2>/dev/null | wc -l)
if [ "$n_next" -gt 1000 ]; then
    log "  $NPDIR already has $n_next params, skipping"
else
    # gen_params.py uses mode='multiprocessing'; the dask path returned exit
    # code 1 for every job and wrote nothing.
    submit_wait sbatch_gen_params.sh "output.genparams.iter${NEXT}.log" "$NEXT"
    n_next=$(ls "$NPDIR" 2>/dev/null | wc -l)
fi
[ "$n_next" -gt 100 ] || die "only $n_next params in $NPDIR"
log "  GATE OK: $n_next params ready for round $NEXT"

log "=========== CYCLE $ITER COMPLETE ==========="
log "next: bash run_cycle.sh $NEXT"
[ -f "$SCRIPTS/report_iteration.sh" ] && bash "$SCRIPTS/report_iteration.sh" "$ITER"
