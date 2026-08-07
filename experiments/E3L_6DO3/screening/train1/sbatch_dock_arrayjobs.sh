#!/bin/bash -l
#PBS -q workq-route
#PBS -A marP_TB_VLS
# Crux allocates whole nodes; ncpus/mem chunks from the SLURM original do not
# apply here (dual 64-core EPYC 7742 = 128 cores, 256 GB per node).
#PBS -l select=1:system=crux
#PBS -l place=scatter
#PBS -l filesystems=home:eagle
#PBS -l walltime=05:30:00
#PBS -N VSX_E3L_6DO3
#PBS -o output.VSX_E3L_6DO3.log
#PBS -j oe

# PBS Pro starts jobs in $HOME, not the submission directory.
cd "${PBS_O_WORKDIR:-$(pwd)}" || exit 1

# Crux defaults OMP_NUM_THREADS to 256. These array tasks run
# several independent processes via GNU parallel, so pin to 1.
export OMP_NUM_THREADS=1

source ~/.bashrc

# PBS Pro exposes the array index as $PBS_ARRAY_INDEX (SLURM: $SLURM_ARRAY_TASK_ID).
# Default to 1 so the script still works if run as a plain (non-array) job.
TASK_ID="${PBS_ARRAY_INDEX:-1}"
CMD=$(head -n "$TASK_ID" E3L_6DO3_dock.joblist | tail -n 1)
exec ${CMD}
