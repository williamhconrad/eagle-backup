#!/bin/bash
#
# run_three_sets.sh - dock train1, test and validation one after another.
#
# WHY SEQUENTIAL:
#   gen_joblist_production.py always writes the same three files into train1/:
#     E3L_6DO3_dock.joblist, sbatch_dock_arrayjobs.sh, submit_arrayjobs.sh
#   Every running subjob reads the joblist with `head -n $PBS_ARRAY_INDEX`, so
#   regenerating it while an array is live corrupts that run. PBS job
#   dependencies do NOT help here - they order the *jobs*, but the file
#   rewrite happens at submit time on the login node.
#
#   Running them concurrently would also exceed the workq limit of 10 running
#   jobs per project (3 arrays x %10 = 30), risking subjobs that never place.
#
# USAGE (run inside screen so it survives disconnection):
#   cd $VSROOT/OpenVS-main/experiments/E3L_6DO3/screening
#   screen -S dock
#   bash run_three_sets.sh 2>&1 | tee run_three_sets.log
#   # Ctrl-A then D to detach; screen -r dock to return
#
set -u

SCREENING_DIR="$(cd "$(dirname "$0")" && pwd)"
POLL_SECONDS=120
CONCURRENT=10          # workq allows 10 running jobs per project

log() { echo "[$(date '+%F %T')] $*"; }

wait_for_job() {
    local jid="$1"
    log "waiting on $jid (polling every ${POLL_SECONDS}s)"
    while true; do
        # qstat exits non-zero once the job has left the queue entirely
        if ! qstat "$jid" >/dev/null 2>&1; then
            log "  $jid no longer in queue"
            return 0
        fi
        local state
        state=$(qstat -f "$jid" 2>/dev/null | awk -F= '/job_state/{gsub(/ /,"",$2); print $2; exit}')
        if [ "$state" = "F" ]; then
            log "  $jid finished"
            return 0
        fi
        sleep "$POLL_SECONDS"
    done
}

for PREFIX in train1 test validation; do
    log "================ $PREFIX ================"
    cd "$SCREENING_DIR" || exit 1

    sed -i "s/prefix=\"[a-z0-9]*\"/prefix=\"$PREFIX\"/" gen_screening_inputs.py
    if ! grep -q "prefix=\"$PREFIX\"" gen_screening_inputs.py; then
        log "ERROR: prefix edit failed for $PREFIX"; exit 1
    fi
    log "prefix set to $PREFIX"

    python gen_screening_inputs.py || { log "ERROR: gen_screening_inputs failed"; exit 1; }

    cd train1 || exit 1
    python gen_joblist_production.py || { log "ERROR: gen_joblist_production failed"; exit 1; }

    N=$(wc -l < E3L_6DO3_dock.joblist)
    if [ "$N" -lt 1 ]; then log "ERROR: empty joblist for $PREFIX"; exit 1; fi
    log "$PREFIX -> $N array tasks"

    if [ "$N" -gt 1 ]; then
        SUBMIT="qsub -J 1-${N}%${CONCURRENT} sbatch_dock_arrayjobs.sh"
    else
        SUBMIT="qsub sbatch_dock_arrayjobs.sh"     # 1-element arrays are not portable
    fi
    echo "#!/bin/bash"      > submit_arrayjobs.sh
    echo "$SUBMIT"         >> submit_arrayjobs.sh
    log "submitting: $SUBMIT"

    JOBID=$($SUBMIT) || { log "ERROR: qsub failed"; exit 1; }
    log "job id: $JOBID"

    wait_for_job "$JOBID"

    NOUT=$(ls "../outputs/E3L_6DO3_${PREFIX}/E3L_6DO3_VSX/"*.score.sc 2>/dev/null | wc -l)
    log "$PREFIX complete: $NOUT score files written"
done

log "================ all three sets done ================"
