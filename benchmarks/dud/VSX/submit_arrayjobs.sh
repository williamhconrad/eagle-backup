#!/bin/bash
# SLURM: sbatch -a 1-6 sbatch_dock_arrayjobs.sh
qsub -J 1-6 -W max_run_subjobs=8 sbatch_dock_arrayjobs.sh
