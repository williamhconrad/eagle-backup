#!/bin/bash -l
#PBS -q workq-route
#PBS -A marP_TB_VLS
# Crux allocates whole nodes; ncpus/mem chunks from the SLURM original do not
# apply here (dual 64-core EPYC 7742 = 128 cores, 256 GB per node).
#PBS -l select=1:system=crux
#PBS -l place=scatter
#PBS -l filesystems=home:eagle
#PBS -l walltime=10:00:00
#PBS -N extract_mol2
#PBS -o output.extract_mol2.log
#PBS -j oe

# PBS Pro starts jobs in $HOME, not the submission directory.
cd "${PBS_O_WORKDIR:-$(pwd)}" || exit 1

# PBS Pro does not pass positional arguments to job scripts.
# Submit with:  qsub -v iter=<N> sbatch_extract_mol2s.sh
iter="${iter:-$1}"

# Crux defaults OMP_NUM_THREADS to 256 (logical); cap at 128 physical cores.
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-128}

source ~/.bashrc
conda activate openvs
echo python -u extract_zinc22_raw_mol2s.py $iter
python -u extract_zinc22_raw_mol2s.py $iter
