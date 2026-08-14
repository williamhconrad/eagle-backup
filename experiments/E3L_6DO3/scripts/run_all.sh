#!/bin/bash
# wrapper for qsub (PBS Pro)
#
# SLURM -> PBS Pro notes:
#   * sbatch --dependency=afterok:<id>   ->  qsub -W depend=afterok:<id>
#   * sbatch prints "Submitted batch job <id>", which had to be stripped with
#     sed. qsub prints the job id on its own, so no post-processing is needed.
#   * PBS Pro cannot pass positional arguments to a job script, so the
#     iteration number is handed over through the environment via -v iter=<N>.
#
# Usage:  submit <script> <iter> [extra qsub options...]
submit() {
    local script=$1
    local iter=$2
    shift 2
    if [ -n "$prev_jobid" ]; then
        job_id=$(qsub -W depend=afterok:$prev_jobid -v iter=$iter "$@" $script)
    else
        job_id=$(qsub -v iter=$iter "$@" $script)
    fi
    echo $job_id # the "return" value
    echo $job_id >>/dev/stderr
}

# make the script stop when error (non-true exit code) is occured
set -e

curr_iter=1
#prev_jobid=$(submit sbatch_gather_vs_results.sh $curr_iter)
#echo sbatch_gather_vs_results.sh $prev_jobid

prev_jobid=$(submit sbatch_augment_results.sh $curr_iter)
echo sbatch_augment_results.sh $prev_jobid

#prev_jobid=$(submit sbatch_train.sh $curr_iter -o output.train.$curr_iter.log)
#echo sbatch_train.sh $prev_jobid

#prev_jobid=$(submit sbatch_predict_slurm.sh $curr_iter)
#echo sbatch_predict_slurm.sh $prev_jobid

#prev_jobid=$(submit sbatch_save_top_prediction.sh $curr_iter)
#echo sbatch_save_top_prediction.sh $prev_jobid

#prev_jobid=$(submit sbatch_gen_3dstruct.sh $curr_iter)
#echo sbatch_gen_3dstruct.sh $prev_jobid

#prev_jobid=$(submit sbatch_gen_params.sh $(($curr_iter+1)))
#echo sbatch_gen_params.sh $prev_jobid

