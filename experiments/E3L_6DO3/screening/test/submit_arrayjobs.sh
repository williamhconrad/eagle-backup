#!/bin/bash
qsub -r y -J 1-10%10 sbatch_dock_arrayjobs.sh
