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

cd "$PBS_O_WORKDIR" || exit 1
source "${CONDA_BASE:-$HOME/miniconda3}/etc/profile.d/conda.sh"
conda activate openvs
python -u predict_db.py --i_iter 1 --run_platform auto
