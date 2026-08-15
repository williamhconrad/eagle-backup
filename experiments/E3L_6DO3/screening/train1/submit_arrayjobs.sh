#!/bin/bash
qsub -r y -J 1-5%10 sbatch_dock_arrayjobs.sh
