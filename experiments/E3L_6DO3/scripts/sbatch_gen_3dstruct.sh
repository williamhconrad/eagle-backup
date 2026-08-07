#!/bin/bash -l
#PBS -q workq-route
#PBS -A marP_TB_VLS
# Crux allocates whole nodes; ncpus/mem chunks from the SLURM original do not
# apply here (dual 64-core EPYC 7742 = 128 cores, 256 GB per node).
#PBS -l select=1:system=crux
#PBS -l place=scatter
#PBS -l filesystems=home:eagle
#PBS -l walltime=01:00:00
#PBS -N gen_3dstruct
#PBS -o output.gen_3dstruct.log
#PBS -j oe

# PBS Pro starts jobs in $HOME, not the submission directory.
cd "${PBS_O_WORKDIR:-$(pwd)}" || exit 1

# PBS Pro does not pass positional arguments to job scripts.
# Submit with:  qsub -v iter=<N> sbatch_gen_3dstruct.sh
iter="${iter:-$1}"

# Crux defaults OMP_NUM_THREADS to 256 (logical); cap at 128 physical cores.
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-128}

source ~/.bashrc
conda activate openvs
echo python prepare_smiles.py $iter
python prepare_smiles.py $iter
echo python gen_3dstruct_jobs.py $iter
python -u gen_3dstruct_jobs.py $iter
sh submit_arrayjobs.gen3d.sh
