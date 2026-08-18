#!/bin/bash
# SLURM: sbatch -a 1-18 sbatch_arrayjobs.gen3d.sh
qsub -r y -J 1-18 -W max_run_subjobs=8 sbatch_arrayjobs.gen3d.sh
