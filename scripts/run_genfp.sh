#!/bin/bash -l
#PBS -q workq-route
#PBS -A marP_TB_VLS
#PBS -l select=1:system=crux
#PBS -l place=scatter
#PBS -l filesystems=home:eagle
#PBS -l walltime=01:00:00
#PBS -N genfp
#PBS -o output.genfp.log
#PBS -j oe

cd "$PBS_O_WORKDIR" || exit 1

# Crux defaults OMP_NUM_THREADS to 256. multiprocess mode forks many workers,
# each of which would then try to spawn 256 BLAS threads -> pthread_create
# fails and numpy fails to import. Each worker is single-threaded RDKit work,
# so pin to 1 and let process count provide the parallelism.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1

source "${CONDA_BASE:-$HOME/miniconda3}/etc/profile.d/conda.sh"
conda activate openvs
python gen_fp_enamine_real.py
