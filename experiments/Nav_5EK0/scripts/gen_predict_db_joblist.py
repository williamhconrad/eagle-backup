import os,sys
from glob import glob
import numpy as np
import orjson
from tap import Tap

def load_configfn(configfn):
    with open(configfn, 'rb') as f:
        config = orjson.loads(f.read())
    return config

class RunArgs(Tap):
    i_iter: int
    fplist: str

def write_sbatchfn(sbatchfn, submitfn, joblistfn, n_jobs, job_name="arrayjobs", queue='cpu'):
    if queue=='cpu':
        sbatch_content = """#!/bin/bash -l
#PBS -q workq-route
#PBS -A marP_TB_VLS
# Crux allocates whole nodes; ncpus/mem chunks from the SLURM original do not
# apply here (dual 64-core EPYC 7742 = 128 cores, 256 GB per node).
#PBS -l select=1:system=crux
#PBS -l place=scatter
#PBS -l filesystems=home:eagle
#PBS -l walltime=03:00:00
#PBS -N {jobname}
#PBS -o output.{jobname}.log
#PBS -j oe

# PBS Pro starts jobs in $HOME, not the submission directory.
cd "${{PBS_O_WORKDIR:-$(pwd)}}" || exit 1

# Crux defaults OMP_NUM_THREADS to 256. Each array task runs several
# independent processes via GNU parallel, so pin to 1.
export OMP_NUM_THREADS=1

source ~/.bashrc

# PBS Pro exposes the array index as $PBS_ARRAY_INDEX
# (SLURM: $SLURM_ARRAY_TASK_ID). Default to 1 so the script also works
# when submitted as a plain, non-array job.
TASK_ID="${{PBS_ARRAY_INDEX:-1}}"
CMD=$(head -n "$TASK_ID" {joblistfn} | tail -n 1)
exec ${{CMD}}
""".format(jobname=job_name, joblistfn=joblistfn)
        with open(sbatchfn, 'w') as outf:
            outf.write(sbatch_content)
        print("Wrote: %s"%sbatchfn)

        script_base = os.path.basename(sbatchfn)
        # SLURM job arrays (-a 1-N) become PBS Pro job arrays (-J 1-N).
        # SLURM's "%50" concurrency throttle maps to PBS Pro's
        # -W max_run_subjobs=8, which needs PBS Pro 2021.1 or newer;
        # on older versions drop it and use a queue-level max_run limit.
        if n_jobs > 1:
            submit_line = "qsub -J 1-{} -W max_run_subjobs=8 {}".format(n_jobs, script_base)
        else:
            # A single-element job array is not portable across PBS Pro
            # versions, so submit it as an ordinary job instead.
            submit_line = "qsub {}".format(script_base)
        submit_content = "#!/bin/bash\n# SLURM: sbatch -a 1-{}%50 {}\n{}\n".format(
                n_jobs, script_base, submit_line)
        with open(submitfn, 'w') as outf:
            outf.write(submit_content)
        print("Wrote: %s"%submitfn)

def save_listfns(inlist, outdir, prefix="fpfilelist", batchsize=100):
    os.makedirs(outdir, exist_ok=True)
    startIndex = np.arange(0, len(inlist), batchsize)
    content = []
    for i, startndx in enumerate(startIndex):
        outfn = os.path.join(outdir, f"{prefix}.{i}.txt")
        if os.path.exists(outfn):
            raise Exception(f"{outfn} exists.")
        sublist = inlist[startndx:startndx+batchsize]
        content = [f"{fpfn}\n" for fpfn in sublist]
        if len(content) == 0: continue
        with open(outfn, 'w') as outf:
            outf.writelines(content)
        print(f"Saved: {outfn}")

def gen_joblist(i_iter, listfiledir, joblistfn="predict_db.joblist"):
    
    patt = os.path.join(listfiledir, "*.txt")
    filelist = sorted( glob(patt) )
    app = "predict_db_arraytask.py"
    platform = 'cpu'
    joblist = []
    for infn in filelist:
        cmd = f"{app} --i_iter {i_iter} --fplist {infn} --run_platform {platform}\n"
        joblist.append(cmd)
    
    with open(joblistfn, 'w') as outf:
        outf.writelines(joblist)
    print(f"Saved: {joblistfn}")
    
    sbatchfn="sbatch_predict_db_array.sh"
    submitfn = "submit_predict_db_array.sh"
    n_jobs = len(joblist)
    write_sbatchfn(sbatchfn, submitfn, joblistfn, n_jobs, job_name="predict_db", queue='cpu')

def gen_joblist_zinc22(i_iter, config):
    fps_path = config["fps_path"]
    dbfn_pattern = os.path.join(fps_path, "zinc-22*", "*.feather")
    dbfns = sorted(glob(dbfn_pattern))
    fpfilelist_outpath = "./fpfilelist"
    save_listfns(dbfns, fpfilelist_outpath, prefix="fpfilelist", batchsize=100)
    gen_joblist(i_iter, fpfilelist_outpath, joblistfn="predict_db.joblist")

def main():
    if len(sys.argv) <2:
        print("Usage: python this.py iter")
        raise
    else:
        i_iter = int(sys.argv[1])
    
    configfn = os.path.join("../", "config_zinc22_db.json" )
    config = load_configfn(configfn)
    gen_joblist_zinc22(i_iter, config)

if __name__ == '__main__':
    main()
        
        
    