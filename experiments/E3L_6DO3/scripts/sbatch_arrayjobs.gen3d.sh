#!/bin/bash -l
#PBS -q preemptable
#PBS -A marP_TB_VLS
# Crux allocates whole nodes; ncpus/mem chunks from the SLURM original do not
# apply here (dual 64-core EPYC 7742 = 128 cores, 256 GB per node).
#PBS -l select=1:system=crux
#PBS -l place=scatter
#PBS -l filesystems=home:eagle
#PBS -l walltime=06:30:00
# PBS Pro requires array jobs to be rerunnable; Crux defaults to -r n.
#PBS -r y
#PBS -N gen3d
#PBS -o output.gen3d.log
#PBS -j oe

# PBS Pro starts jobs in $HOME, not the submission directory.
cd "${PBS_O_WORKDIR:-$(pwd)}" || exit 1

# Crux defaults OMP_NUM_THREADS to 256. Each array task runs several
# independent processes via GNU parallel, so pin to 1.
export OMP_NUM_THREADS=1

source ~/.bashrc
conda activate openvs

# PBS Pro exposes the array index as $PBS_ARRAY_INDEX
# (SLURM: $SLURM_ARRAY_TASK_ID). Default to 1 so the script also works
# when submitted as a plain, non-array job.
TASK_ID="${PBS_ARRAY_INDEX:-1}"
CMD=$(head -n "$TASK_ID" ./gen3d.joblist | tail -n 1)
exec ${CMD}
