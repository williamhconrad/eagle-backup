#!/bin/bash -l
#PBS -q preemptable
#PBS -A marP_TB_VLS
#PBS -l select=1:system=crux
#PBS -l place=scatter
#PBS -l filesystems=home:eagle
#PBS -l walltime=06:00:00
#PBS -N predict_auto
#PBS -j oe
#PBS -r y
#
# Single-process library-wide prediction.
#
# WHY NOT DASK: predict_db.py --run_platform pbs produced ZERO output files in
# 47 minutes (workers busy, nothing written). Four independent copies of this
# script finished all 5,458 chunks in ~70 minutes. predict_db.py skips chunks
# whose output already exists, so several copies racing over the same list
# partition the work naturally and a preemption costs only the in-flight chunk.
#
# USAGE (submit 3-4 copies, staggered):
#   for i in 1 2 3 4; do
#     qsub -v iter=1 -o output.predict.auto$i.log run_predict_auto.sh
#     sleep 45
#   done

cd "$PBS_O_WORKDIR" || exit 1
source "${CONDA_BASE:-$HOME/miniconda3}/etc/profile.d/conda.sh"
conda activate "${OPENVS_ENV:-openvs}"

# PBS cannot pass positional args; the iteration comes in via -v iter=N
iter="${iter:-1}"
echo "predict: iteration $iter on $(hostname) at $(date)"

python -u predict_db.py --i_iter "$iter" --run_platform auto
