#!/bin/bash -l
#PBS -q workq-route
#PBS -A marP_TB_VLS
# Crux allocates whole nodes; ncpus/mem chunks from the SLURM original do not
# apply here (dual 64-core EPYC 7742 = 128 cores, 256 GB per node).
#PBS -l select=1:system=crux
#PBS -l place=scatter
#PBS -l filesystems=home:eagle
#PBS -l walltime=12:00:00
#PBS -N find_similar_main
#PBS -o output.find_similar.log
#PBS -j oe

# PBS Pro starts jobs in $HOME, not the submission directory.
cd "${PBS_O_WORKDIR:-$(pwd)}" || exit 1

# Crux defaults OMP_NUM_THREADS to 256 (logical); cap at 128 physical cores.
export OMP_NUM_THREADS=128

source ~/.bashrc
conda activate openvs
echo python -u find_similar_zinc22_mol2s.py
python -u find_similar_zinc22_mol2s.py
