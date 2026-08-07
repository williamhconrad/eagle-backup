#!/bin/bash
# SLURM: sbatch -a 1-51 sbatch_dock_arrayjobs.sh
qsub -J 1-51 -W max_run_subjobs=8 sbatch_dock_arrayjobs.sh
