#!/bin/bash
# SLURM original: sbatch -a 1-1%50 sbatch_dock_arrayjobs.sh
#
# On Crux the concurrency cap is set by policy, not preference: the `workq`
# execution queue allows only 10 running jobs per project, so subjob
# concurrency is throttled to 8 to leave headroom for the driver job.
# -W max_run_subjobs requires PBS Pro 2021.1 or newer.
qsub -J 1-1 -W max_run_subjobs=8 sbatch_dock_arrayjobs.sh
