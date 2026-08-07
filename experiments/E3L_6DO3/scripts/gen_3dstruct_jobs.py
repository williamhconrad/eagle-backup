import os,sys
import orjson
from glob import glob

def load_configfn(configfn):
    with open(configfn, 'rb') as f:
        config = orjson.loads(f.read())
    return config

def write_sbatchfn(sbatchfn, submitfn, joblistfn, n_jobs, cwd="./", job_name="arrayjobs", queue='cpu'):

    if queue == 'cpu':   
        sbatch_content = """#!/bin/bash -l
#PBS -q workq-route
#PBS -A marP_TB_VLS
# Crux allocates whole nodes; ncpus/mem chunks from the SLURM original do not
# apply here (dual 64-core EPYC 7742 = 128 cores, 256 GB per node).
#PBS -l select=1:system=crux
#PBS -l place=scatter
#PBS -l filesystems=home:eagle
#PBS -l walltime=06:30:00
#PBS -N {jobname}
#PBS -o output.{jobname}.log
#PBS -j oe

# PBS Pro starts jobs in $HOME, not the submission directory.
cd "${{PBS_O_WORKDIR:-$(pwd)}}" || exit 1

# Crux defaults OMP_NUM_THREADS to 256. Each array task runs several
# independent processes via GNU parallel, so pin to 1.
export OMP_NUM_THREADS=1

source ~/.bashrc
conda activate openvs

# PBS Pro exposes the array index as $PBS_ARRAY_INDEX
# (SLURM: $SLURM_ARRAY_TASK_ID). Default to 1 so the script also works
# when submitted as a plain, non-array job.
TASK_ID="${{PBS_ARRAY_INDEX:-1}}"
CMD=$(head -n "$TASK_ID" {joblistfn} | tail -n 1)
exec ${{CMD}}
""".format(jobname=job_name, joblistfn=joblistfn, cwd=cwd)
 
    with open(sbatchfn, 'w') as outf:
        outf.write(sbatch_content)
    print("Wrote: %s"%sbatchfn)

    script_base = os.path.basename(sbatchfn)
    # SLURM job arrays (-a 1-N) become PBS Pro job arrays (-J 1-N).
    if n_jobs > 1:
        submit_line = "qsub -J 1-{} -W max_run_subjobs=8 {}".format(n_jobs, script_base)
    else:
        # A single-element job array is not portable across PBS Pro
        # versions, so submit it as an ordinary job instead.
        submit_line = "qsub {}".format(script_base)
    submit_content = "#!/bin/bash\n# SLURM: sbatch -a 1-{} {}\n{}\n".format(
            n_jobs, script_base, submit_line)
    with open(submitfn, 'w') as outf:
        outf.write(submit_content)
    print("Wrote: %s"%submitfn)

def gen_joblist(smipath, outdir):
    joblist = []
    obabel_app = os.path.join(os.getcwd(), "run_obabel.sh")
    pattern = os.path.join(smipath, "prot", "*.smi")
    smifns = sorted(glob(pattern))
    for smifn in smifns:
        prefix = os.path.basename(smifn).replace(".smi", "")
        tempprefix = os.path.join(outdir, prefix+".temp")
        outmol2fn = os.path.join(outdir, f"{prefix}.mol2")
        cmd = f"{obabel_app} {smifn} {tempprefix} {outmol2fn} 0\n"
        joblist.append(cmd)
    pattern = os.path.join(smipath, "obabel", "*.smi")
    smifns = sorted(glob(pattern))
    for smifn in smifns:
        prefix = os.path.basename(smifn).replace(".smi", "")
        tempprefix = os.path.join(outdir, prefix)
        outmol2fn = os.path.join(outdir, f"{prefix}.mol2")
        cmd = f"{obabel_app} {smifn} {tempprefix} {outmol2fn} 1\n"
        joblist.append(cmd)

    return joblist

def gen3d_joblist_from_smipath(smipath, mol2outdir, jobname="gen3d", overwrite=False):
    queue="cpu"
    joblist_lines = gen_joblist(smipath, mol2outdir)
    
    joblist_fn = os.path.join("./", f"{jobname}.joblist" )

    with open(joblist_fn, 'w') as outf:
        outf.writelines(joblist_lines)
    print("Wrote: %s"%joblist_fn)
    n_jobs = len(joblist_lines)

    sbatchfn = os.path.join( "./", f"sbatch_arrayjobs.{jobname}.sh" )
    submitfn = os.path.join( "./", f"submit_arrayjobs.{jobname}.sh" )
    joblistfn = joblist_fn
    
    write_sbatchfn(sbatchfn, submitfn, joblistfn, n_jobs, mol2outdir, jobname, queue)


def gen3d_real_db(i_iter, configfn, debug=False):
    config = load_configfn(configfn)
    if debug:
        outdir = "debug_gen3d"
        os.makedirs(outdir, exist_ok=True)
    if not debug:
        outdir = os.path.join(config['mol2_path'], f"mmff94_mol2s_iter{i_iter+1}")
        os.makedirs(outdir, exist_ok=True)
    smipath = os.path.join(os.getcwd(), f"smiles_iter{i_iter+1}")
    jobname = "gen3d"
    
    gen3d_joblist_from_smipath(smipath, outdir, jobname)


if __name__ == "__main__":
    if len(sys.argv) <2:
        print("Usage: python this.py iter")
        raise
    else:
        i_iter = int(sys.argv[1])
    configfn = os.path.join("../", "config_real_db.json" )
    debug=False

    gen3d_real_db(i_iter, configfn, debug)
