import os,sys
import glob
import subprocess as sp
from pathlib import Path

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
#PBS -l walltime=05:30:00
#PBS -N {jobname}
#PBS -o output.{jobname}.log
#PBS -j oe

# PBS Pro starts jobs in $HOME, not the submission directory.
cd "${{PBS_O_WORKDIR:-$(pwd)}}" || exit 1

# Crux defaults OMP_NUM_THREADS to 256. Each array task runs several
# independent processes via GNU parallel, so pin to 1.
export OMP_NUM_THREADS=1

source "${{CONDA_BASE:-$HOME/miniconda3}}/etc/profile.d/conda.sh"
conda activate openvs

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

def gen_cmdlist_for_multiprocess(project_name, extra, batch_size=100, cmd_size = 5*16, skip_finished = False):

    basedir = Path(__file__).parents[1]
    print(basedir)
    
    inputdir = os.path.join(basedir,
            "inputs", f"{extra}set", f"{project_name}_{extra}_chunk{batch_size}")
    in_dir = inputdir
    results_dir = os.path.join(basedir, "outputs", f"{project_name}_{extra}")
    print("input dir:", inputdir)
    print("result dir:", results_dir)
            
    pattern = os.path.join(inputdir, "*.flags")
    outdir = os.path.abspath("./")

    flags_list = sorted(glob.glob(pattern))
    if not skip_finished:
        outdir_cmdlistfn = os.path.join(outdir, "%s_cmdlistfn"%(project_name) )
    else:
        outdir_cmdlistfn = os.path.join(outdir, "%s_cmdlistfn_rerun"%(project_name) )

    if not os.path.exists(outdir_cmdlistfn):
        os.makedirs(outdir_cmdlistfn)
        print("Made directory: %s"%outdir_cmdlistfn)
    else:
        pattern = os.path.join(outdir_cmdlistfn, "*.cmdlist")
        cmd = "rm %s"%pattern
        print(cmd)
        p = sp.Popen(cmd, shell=True)
        p.communicate()

    counter = 0
    contents = []
    cmdlistfns = []
    rosetta_scripts = "./run_dock.vsx.sh"
    outdirname = "%s_VSX"%project_name
    outpath = os.path.join(results_dir, outdirname)
    if not os.path.exists(outpath):
        os.makedirs(outpath)
        print("Make new directory", outpath)
    
    for flagfn in flags_list:
        flagfn_name = os.path.basename(flagfn)
        fields = flagfn_name.split(".")[0].split('_')
        ndx1 = fields[-2]
        ndx2 = fields[-1]
        if skip_finished:
            outfn = os.path.join( outpath, "{}_{}_{}.out".format(project_name, ndx1, ndx2) )
            if os.path.exists(outfn):
                print("%s exists, skip..."%outfn)
                continue

        ligand_list_name = f"ligands_list_{extra}_{ndx1}_{ndx2}.txt"
        ligand_list_fn = os.path.join(in_dir, ligand_list_name)
        prefix = "{}_{}_{}.".format(project_name, ndx1, ndx2)
        if not os.path.exists(ligand_list_fn):
            print("Cannot find {}, skip..".format(ligand_list_fn))
            continue
        cmd = "{} {} {} {} {}\n".format(rosetta_scripts, outpath, prefix, flagfn, ligand_list_fn)
        #print(cmd.strip())
        contents.append(cmd)
        if len(contents) == cmd_size:
            outfn_ndx = counter/cmd_size
            cmdlistfn = "%s_%d.cmdlist"%(project_name, outfn_ndx)
            outfn_cmdlist = os.path.join(outdir_cmdlistfn, cmdlistfn)
            with open(outfn_cmdlist, "w") as outf:
                outf.writelines(contents)
            contents = []
            print("Wrote: %s"%outfn_cmdlist)
            cmdlistfns.append(outfn_cmdlist)
        counter += 1

    if len(contents) != 0:
        outfn_ndx = counter/cmd_size
        cmdlistfn = "%s_%d.cmdlist"%(project_name, outfn_ndx)
        outfn_cmdlist = os.path.join(outdir_cmdlistfn, cmdlistfn)
        with open(outfn_cmdlist, "w") as outf:
            outf.writelines(contents)
        contents = []
        print("Wrote: %s"%outfn_cmdlist)
        cmdlistfns.append(outfn_cmdlist)
    return cmdlistfns

def gen_joblist_production(project_name, extra, batch_size = 100, cmd_size=1*16, queue='ckpt', skip_finished = True):

    cmdlistfns = gen_cmdlist_for_multiprocess(project_name, extra, batch_size, cmd_size, skip_finished)
    outdir = "./"
    if not os.path.exists(outdir):
        os.makedirs(outdir)
        print("Make new directory", outdir)
    if skip_finished:
        joblist_fn = os.path.join(outdir, "{}_dock.joblist.rerun".format(project_name) )
    else:
        joblist_fn = os.path.join(outdir, "{}_dock.joblist".format(project_name) )

    joblist_lines = []
    exec_scripts = os.path.join('parallel :::: ')

    for cmdlistfn in cmdlistfns:
        cmd = "%s %s\n"%(exec_scripts, cmdlistfn)
        print(cmd.strip())
        joblist_lines.append(cmd)

    with open(joblist_fn, 'w') as outf:
        outf.writelines(joblist_lines)
    print("Wrote: %s"%joblist_fn)
    n_jobs = len(joblist_lines)

    if skip_finished:
        sbatchfn = os.path.join( outdir, "sbatch_dock_arrayjobs.rerun.sh" )
        submitfn = os.path.join( outdir, "submit_arrayjobs.rerun.sh" )
        jobname = "VSX_%s_rerun"%project_name
        joblistfn = os.path.basename(joblist_fn)
        write_sbatchfn(sbatchfn, submitfn, joblistfn, n_jobs, jobname, queue)

    else:
        sbatchfn = os.path.join( outdir, "sbatch_dock_arrayjobs.sh" )
        submitfn = os.path.join( outdir, "submit_arrayjobs.sh" )
        jobname = "VSX_%s"%project_name
        joblistfn = os.path.basename(joblist_fn)
        write_sbatchfn(sbatchfn, submitfn, joblistfn, n_jobs, jobname, queue)

if __name__ == '__main__':
    project_name = 'E3L_6DO3'
    currfolder="train1"
    batch_size=50
    cmd_size = 1*64  # 64 concurrent docks/node: memory-bound
                     # (SLURM asked 20g for 5 procs = ~4GB each; 256GB/4 = 64),
                     # not core-bound (128 cores available)
    queue = 'cpu'
    skip_finished = 0
    gen_joblist_production(project_name, currfolder, batch_size , cmd_size, queue, skip_finished)

