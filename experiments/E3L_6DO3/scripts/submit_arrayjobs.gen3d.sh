#!/bin/bash
# SLURM: sbatch -a 1-2 sbatch_arrayjobs.gen3d.sh
qsub -J 1-2 -W max_run_subjobs=8 sbatch_arrayjobs.gen3d.sh
