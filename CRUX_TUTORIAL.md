# Running OpenVS on Crux: the KLHDC2 screen

A step-by-step guide for setting up OpenVS on ALCF Crux and running the
KLHDC2 (PDB **6DO3**) docking example from Zhou, Rusnac, Park et al.,
*Nat Commun* **15**, 7761 (2024).

**Layout used by this guide:**

| What | Where | Why |
|---|---|---|
| Miniconda + the `openvs` environment | **`$HOME`** | small files and binaries; backed up |
| Rosetta, Dimorphite-DL | **Eagle** | large build tree, keeps home free |
| The OpenVS repo, molecule libraries, all output | **Eagle** | intensive job I/O, large files |

This follows ALCF's own guidance: home is for small files and binaries, while
the project filesystem is for intensive compute-node I/O and large files. Home
is also backed up to tape; **Eagle is not**.

> Both `/home` and `/eagle` are Lustre filesystems on Crux — home is
> `agile-home` at `/lus/agile/home`. Putting conda in home is not about
> escaping Lustre; it is about matching each filesystem to its documented
> purpose and getting backups for the part that is painful to rebuild.

The screen uses the drug-like **centroids** library. Enamine REAL is not needed
(see the note at the end of step 11 if you want to scale up later).

This guide assumes you have never used Crux before. It assumes you are
comfortable with basic BASH (`cd`, `ls`, `nano`) but nothing beyond that.

Project allocation: **`marP_TB_VLS`**

---

## Before you start: six things to know

Please read this section. It will save you days.

**1. The experiment is called `E3L_6DO3`, not "KLHDC2".**
The code names it after the E3 ligase and its PDB entry. You can confirm it is
the right target: `experiments/E3L_6DO3/screening/target/` contains
`KLHDC2_c8_lig.params`. Every time this guide says `E3L_6DO3`, that is KLHDC2.

**2. You need compiled Rosetta, NOT PyRosetta.**
These are different products. The pipeline calls a compiled binary,
`rosetta_scripts.linuxgccrelease` (see
`experiments/E3L_6DO3/screening/train1/run_dock.vsx.sh`). PyRosetta is the
Python-binding version and **will not work here**. Start the build first and let
it run while you do everything else.

**3. Crux has no GPUs.** Everything runs on CPU. This is fine — the code handles
it — but it changes how you install PyTorch (step 7).

**4. Eagle is not backed up.** Keep your code in a git remote (GitHub/GitLab).
Re-downloading a library is annoying; losing your edits is worse.

**5. Jobs need BOTH filesystems.** Conda lives in home, your data lives on
Eagle, and every job script runs `source ~/.bashrc`. That is why each job header
declares `#PBS -l filesystems=home:eagle`. **Do not** change that to `eagle`
alone — your jobs will fail.

**6. This repository has no `.gitignore`, by choice.**
The pipeline writes all its output *inside* the repository folder. So:

> **Never run `git add -A`, `git add .`, or `git commit -a` from the repo root.**
> Add files by name only. Committing generated data can silently double your
> disk usage and cannot be undone without rewriting history.

---

## What you are actually going to run

**Phase 1 — the working example (steps 1–13).** Dock a small random sample of
molecules from the centroids library against KLHDC2. This is the documented
working example from the OpenVS authors. **This is your goal. Get this working
first.**

**Phase 2 — the active-learning loop (step 14).** Train a model on the round-1
results, predict over the library, dock the best candidates, repeat. Upstream
this switches to Enamine REAL at iteration 2, so running it on centroids needs
source edits. Treat it as a stretch goal.

---

## Step 1 — Log in to Crux

```bash
ssh <your_alcf_username>@crux.alcf.anl.gov
```

You will be asked for a password from your **MobilePASS+** token, not a normal
password. If you have not set that up, do it first at
<https://accounts.alcf.anl.gov/>.

Confirm your project space exists:

```bash
whoami
ls /eagle/marP_TB_VLS/
```

If that fails with "Permission denied", stop and email `support@alcf.anl.gov`.

---

## Step 2 — Check your quotas

```bash
myquota
```

Two entries: **home** (50 GB, backed up) and your **Eagle project** directory
(1 TB by default, not backed up). Eagle's is a *directory* quota covering every
file in `/eagle/marP_TB_VLS/` regardless of owner — if you share the allocation
with labmates, you draw on the same pool.

---

## Step 3 — Set up your paths

```bash
mkdir -p /eagle/marP_TB_VLS/$USER
echo "export VSROOT=/eagle/marP_TB_VLS/$USER" >> ~/.bashrc
echo "export CONDA_BASE=$HOME/miniconda3" >> ~/.bashrc
source ~/.bashrc
echo $VSROOT
echo $CONDA_BASE
```

From here on:

- **`$VSROOT`** = `/eagle/marP_TB_VLS/<your_username>` — code, libraries, output
- **`$CONDA_BASE`** = `/home/<your_username>/miniconda3` — the conda install

`$CONDA_BASE` is used in step 6b to make conda work reliably inside batch jobs.

---

## Step 4 — Upload and extract the code

On **your laptop**:

```bash
scp OpenVS-crux-nogitignore.zip <your_alcf_username>@crux.alcf.anl.gov:/eagle/marP_TB_VLS/<your_username>/
```

Back on **Crux**:

```bash
cd $VSROOT
unzip OpenVS-crux-nogitignore.zip
cd OpenVS-main
ls
rm $VSROOT/OpenVS-crux-nogitignore.zip
```

You should see `openvs`, `experiments`, `databases`, `benchmarks`, `scripts`,
`setup.py`, and `PORTING_SLURM_TO_PBS.md`.

> If `scp` is slow or keeps dropping, use **Globus** — it resumes after failures.

---

## Step 5 — Turn the folder into a git repository

The code will not run until you do this. `init_config.py` calls
`git rev-parse --show-toplevel`, which fails outside a git repository. This is
also how OpenVS decides where to write its data — which is why the repo belongs
on Eagle.

```bash
cd $VSROOT/OpenVS-main
git init
git config user.name "Your Name"
git config user.email "you@example.edu"
```

Commit **the code only**, naming each path explicitly:

```bash
git add openvs benchmarks scripts setup.py requirements.txt README.md LICENSE
git add experiments/E3L_6DO3/scripts experiments/E3L_6DO3/screening
git add experiments/Nav_5EK0/scripts
git add PORTING_SLURM_TO_PBS.md CRUX_TUTORIAL.md
git commit -m "OpenVS, PBS Pro / Crux port"
```

Verify — this must print a path, not an error:

```bash
git rev-parse --show-toplevel
```

Expected: `/eagle/marP_TB_VLS/<your_username>/OpenVS-main`

Because Eagle is not backed up, push somewhere safe once you start editing:

```bash
# git remote add origin <your repo URL>
# git push -u origin main
```

---

## Step 6 — Install Miniconda in your home directory

```bash
cd ~
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
bash Miniconda3-latest-Linux-x86_64.sh -b -p $HOME/miniconda3
$HOME/miniconda3/bin/conda init bash
source ~/.bashrc
conda --version
rm ~/Miniconda3-latest-Linux-x86_64.sh
```

Confirm conda is running from home:

```bash
which conda      # should start with /home/
```

> Crux compute nodes reach the internet only through a proxy. If a download
> hangs *on a compute node*:
> ```bash
> export http_proxy=http://proxy.alcf.anl.gov:3128
> export https_proxy=http://proxy.alcf.anl.gov:3128
> ```
> On the login node you usually do not need this.

---

## Step 6b — Make conda work inside batch jobs

**Read this step even if everything seems fine.** It is the single most likely
cause of jobs that fail instantly for no obvious reason.

### The problem

`conda init` (step 6) added a block to your `~/.bashrc`. That works when *you*
type `conda activate openvs` at the prompt, because your login shell is
**interactive**.

A PBS job script is **not interactive**. Many `.bashrc` files begin with a guard
that exits early for non-interactive shells, something like:

```bash
case $- in
    *i*) ;;
      *) return;;
esac
```

If that guard is present, everything below it — including conda's block — never
runs inside your job. The job then dies immediately with
`conda: command not found` or `CommandNotFoundError: Your shell has not been
properly configured to use 'conda activate'`.

### Test whether it affects you

```bash
head -20 ~/.bashrc
```

Look for `case $- in` or `[ -z "$PS1" ] && return` near the top. Or just test it
directly, which is more reliable:

```bash
bash -c 'source ~/.bashrc; conda activate openvs && echo "ACTIVATION OK"'
```

- Prints `ACTIVATION OK` → you are fine, but read "when to use it" below anyway.
- Prints an error → you **must** apply the fix.

(You can run this test after step 7, once the `openvs` environment exists.)

### The fix: source conda's hook directly

This works in interactive *and* non-interactive shells, unconditionally:

```bash
source "${CONDA_BASE:-$HOME/miniconda3}/etc/profile.d/conda.sh"
conda activate "${OPENVS_ENV:-openvs}"
```

The `${VAR:-default}` syntax means "use `$CONDA_BASE` if it is set, otherwise
fall back to `$HOME/miniconda3`" — so it keeps working even if the variable is
not exported into the job, and you can relocate conda later without editing
every script.

### When to use it

| Situation | What to do |
|---|---|
| Typing commands at the Crux prompt | Nothing. `conda activate openvs` just works |
| Inside a `#PBS` job script you submit with `qsub` | **Use the two-line snippet** |
| Any script you run with `bash script.sh` | **Use the snippet** |
| Inside `screen` or `tmux` | Nothing — those are interactive |

Rule of thumb: **if a computer is running it rather than you, use the snippet.**

### Applying it to the OpenVS job scripts

If your test above failed, **do not do this by hand with `sed`.** The pattern
appears in three different places and one of them has a trap:

| Where | Count | Note |
|---|---|---|
| Job scripts (`*.sh`) | 22 | straightforward |
| Joblist generator templates (`*.py`) | 5 | **braces must be doubled** |
| dask `job_script_prologue` lists (`*.py`) | 2 | easy to miss entirely |

The trap: the generators build job scripts as Python `str.format()` templates,
so a literal `{` inside them must be written `{{`. A naive replacement puts
`${CONDA_BASE:-...}` into a template and the generator then dies with
`KeyError: 'CONDA_BASE'`. Fixing only the `.sh` files is also not enough —
running `gen_joblist_production.py` would immediately overwrite your fix with
the old pattern again.

A tested helper that handles all three cases correctly ships with this repo:

```bash
cd $VSROOT/OpenVS-main

bash scripts/fix_conda_activation.sh --check   # report only, changes nothing
bash scripts/fix_conda_activation.sh           # apply
```

Review before trusting it — this is exactly why you made it a git repository in
step 5:

```bash
git diff
```

If it looks wrong, undo completely:

```bash
git checkout -- .
```

Then confirm the generators still work:

```bash
cd experiments/E3L_6DO3/screening/train1
python gen_joblist_production.py
grep conda.sh sbatch_dock_arrayjobs.sh    # should show single braces: ${CONDA_BASE:-...}
```

> **Note:** the two benchmark scripts under `benchmarks/casf_2016/` activate an
> environment called `deepdock` rather than `openvs`. That environment is not
> part of this guide; the helper fixes their activation line but you would still
> need to create that environment to run the CASF benchmarks.

---

## Step 7 — Create the OpenVS environment

The environment lives in home alongside Miniconda (`~/miniconda3/envs/openvs`),
which is what you want — small files, backed up.

```bash
cd $VSROOT/OpenVS-main
conda create -n openvs python=3.9 -y
conda activate openvs
conda install -c conda-forge --file requirements.txt -y
```

> **If that fails to solve:** `requirements.txt` pins exact build strings
> (e.g. `orjson=3.9.10=py39h10b2342_0`) that may no longer exist. Strip them to
> plain version numbers and retry:
> ```bash
> sed 's/=[^=]*$//' requirements.txt > requirements.loose.txt
> conda install -c conda-forge --file requirements.loose.txt -y
> ```

**Install PyTorch — CPU build.** The project README gives a CUDA command.
**Do not use it.** Crux has no GPUs:

```bash
conda install pytorch torchvision torchaudio cpuonly -c pytorch -y
```

Install OpenVS itself:

```bash
pip install -e .
```

Verify:

```bash
python -c "import openvs, torch; print('openvs OK, torch', torch.__version__, 'cuda:', torch.cuda.is_available())"
```

Expect `cuda: False`. That is correct.

Now go back and run the step 6b activation test, which needs this environment to
exist:

```bash
bash -c 'source ~/.bashrc; conda activate openvs && echo "ACTIVATION OK"'
```

Check home usage — conda is the main thing living there:

```bash
myquota
```

---

## Step 8 — Install Dimorphite-DL on Eagle

```bash
cd $VSROOT
git clone https://github.com/durrantlab/dimorphite_dl.git
echo "export DIMORPHITE=$VSROOT/dimorphite_dl" >> ~/.bashrc
source ~/.bashrc
echo $DIMORPHITE
```

---

## Step 9 — Install Rosetta on Eagle (start this early)

Get a licence first — free for academics, at
<https://els2.comotion.uw.edu/product/rosetta>. You will receive download
credentials.

```bash
cd $VSROOT
# download the source bundle using the credentials from your licence email
tar -xzf rosetta_src_*.tgz
cd rosetta*/main/source
```

Build just the one binary the pipeline needs — much faster than a full build:

```bash
./scons.py -j 16 mode=release bin/rosetta_scripts.linuxgccrelease
```

This takes **several hours**. Run it inside `screen` so it survives a dropped
connection:

```bash
screen -S rosetta
# start the build, then press Ctrl-A then D to detach
# reattach later with:  screen -r rosetta
```

When it finishes:

```bash
echo "export ROSETTAHOME=$VSROOT/rosetta/main" >> ~/.bashrc
source ~/.bashrc
ls -lh $ROSETTAHOME/source/bin/rosetta_scripts.linuxgccrelease
```

That command **must** list the file. The pipeline calls it by that exact path
and fails if it is missing.

> If your extracted folder is named something like `rosetta.source.release-371`
> rather than plain `rosetta`, adjust the `ROSETTAHOME` line to match. Check
> with `ls $VSROOT`.

---

## Step 10 — CSD Python API (skip for now)

Only `geometry_analysis.py` needs this, at the very end of post-analysis. It
requires an institutional licence and its own conda environment. **Skip it until
Phase 1 is working.**

```bash
conda create -n csd python=3.9 -y
conda activate csd
# follow: https://downloads.ccdc.cam.ac.uk/documentation/API/installation_notes.html
conda activate openvs   # switch back
```

---

## Step 11 — Download the centroids library

```bash
cd $VSROOT/OpenVS-main/databases
wget https://files.ipd.uw.edu/pub/OpenVS/centroids.tgz
tar -xzf centroids.tgz
rm centroids.tgz
ls centroids/
myquota
```

You should see `fingerprints/`, `smiles/`, `index/`, and `CA/`.

> **You do not need Enamine REAL or ZINC22 for this guide.** Ignore the
> `databases/real/` and `databases/zinc/` folders — the small files in them are
> just layout examples.

### If you want to scale up to Enamine REAL later

Measured from the sample data shipped in this repo:

| Library | SMILES | Fingerprints | Total |
|---|---|---|---|
| REAL subset (402M, HAC 22–23) | ~70 GB | ~34 GB | **~104 GB** |
| Enamine REAL full (~6.75B) | ~1.17 TB | ~571 GB | **~1.74 TB** |

A single subset fits comfortably in 1 TB. **The full library does not** — 1.74 TB
exceeds the default quota before any docking output exists. Talk to your
supervisor first; it needs a quota increase.

---

## Step 12 — Generate the config files

```bash
conda activate openvs
cd $VSROOT/OpenVS-main/experiments/E3L_6DO3/scripts
nano init_config.py
```

Scroll to the very bottom. Change:

```python
if __name__ == "__main__":
    database = "real"
    main(database)
    database = "cluster"
    main(database)
```

to:

```python
if __name__ == "__main__":
    database = "cluster"
    main(database)
```

Save (Ctrl-O, Enter, Ctrl-X) and run it:

```bash
python init_config.py
ls ../config_clusterdb.json
```

Check that the paths inside point at Eagle:

```bash
grep -m3 path ../config_clusterdb.json
```

They should begin `/eagle/marP_TB_VLS/`. If they say `/home/...`, your repo is
in the wrong place — go back to step 4.

---

## Step 13 — Run the KLHDC2 docking round

Expect roughly **90–200 seconds per ligand**.

### 13a. Pick the starting molecules from centroids

```bash
cd $VSROOT/OpenVS-main/experiments/E3L_6DO3/scripts
python extract_starting_params.py
ls ../scratch/params/
```

### 13b. Tar the params

```bash
cd ../scratch/params
tar -cf train1_params_0.tar train1_params
mv train1_params_0.tar ../../screening/params/
```

### 13c. Generate the screening inputs

```bash
cd $VSROOT/OpenVS-main/experiments/E3L_6DO3/screening
nano gen_screening_inputs.py
```

Find line 56, `prefix="validation"`, and change it to:

```python
prefix="train1"
```

Save, then:

```bash
python gen_screening_inputs.py
ls inputs/train1set/
```

### 13d. Generate the job scripts

```bash
cd train1
python gen_joblist_production.py
```

**Look at what it produced before submitting anything:**

```bash
head -8 sbatch_dock_arrayjobs.sh
cat submit_arrayjobs.sh
wc -l E3L_6DO3_dock.joblist
```

The header should show `#PBS -q workq-route`, `#PBS -A marP_TB_VLS`, and
`#PBS -l filesystems=home:eagle`.

> If you ran the step 6b fix, the generator templates were patched too, so the
> scripts it writes here already use the safe pattern. Confirm with
> `grep conda.sh sbatch_dock_arrayjobs.sh`.

### 13e. Submit

```bash
sh submit_arrayjobs.sh
```

### 13f. Watch the jobs

```bash
qstat -u $USER          # your jobs
qstat -f <jobid>        # detail on one job
qdel <jobid>            # cancel
```

States: `Q` queued, `R` running, `E` exiting, `F` finished.

Results appear in
`$VSROOT/OpenVS-main/experiments/E3L_6DO3/screening/outputs/E3L_6DO3_train1/`.

### 13g. Check against the reference

```bash
cd $VSROOT/OpenVS-main/experiments/E3L_6DO3/screening/outputs/E3L_6DO3_train1
head -3 E3L_6DO3_VSX/E3L_6DO3_0_0.score.sc
```

**If your scores are in a comparable range, Phase 1 is done.**

---

## Step 14 — Phase 2: the active-learning loop (stretch goal)

Upstream OpenVS seeds with centroids at iteration 1 then switches to Enamine
REAL from iteration 2. That switch is hardcoded, so a centroids-only loop needs
source edits. **Do Phase 1 first, and talk to your supervisor before this.**

### What the hardcoding looks like

In `gather_vs_results.py` and `augment_vs_results.py`:

```python
if i_iter == 1:
    configfn = "../config_clusterdb.json"
    dbtype   = "cluster"
else:
    configfn = "../config_real_db.json"   # <-- switches to REAL
    dbtype   = "real"
```

And eight scripts open `config_real_db.json` directly:

| File | Line |
|---|---|
| `augment_vs_results.py` | 395 |
| `gather_vs_results.py` | 92 |
| `gen_3dstruct_jobs.py` | 122 |
| `gen_params.py` | 46 |
| `predict_db.py` | 266 |
| `prepare_smiles.py` | 171 |
| `save_top_predictions.py` | 283 |
| `train.py` | 350 |

Each must point at `config_clusterdb.json`, and the two `else` branches must
keep `dbtype="cluster"`.

### Two things that are not just config edits

**a) The 3D-structure steps become unnecessary.** `prepare_smiles.py` and
`gen_3dstruct_jobs.py` exist because Enamine REAL ships SMILES only. The
centroids library already ships params files, so on a centroids-only loop the
next round's params should be extracted from the centroids tarballs — the way
`extract_starting_params.py` already does. That is a real code change.

**b) A known trap in `predict_db.py`.** It contains `predict_clusterdb()`, which
looks like the right function for centroids, but line 249 hardcodes:

```python
pargs.run_platform = 'gpu'
```

On Crux this raises `gpu is requested but gpu is not available!`. Nothing calls
it today — `__main__` calls `predict_fulldb()`. **Do not switch to
`predict_clusterdb`.** The centroids config already sets
`"database_type": "full"`, so `predict_fulldb` pointed at
`config_clusterdb.json` is correct.

### Running the loop

```bash
cd $VSROOT/OpenVS-main/experiments/E3L_6DO3/screening/outputs
tar -cf E3L_6DO3_train1.tar E3L_6DO3_train1
mv E3L_6DO3_train1.tar ../../scratch/results/
cd ../../scripts
nano run_all.sh
```

Set `curr_iter=1` and uncomment the stages **one at a time**:

1. `sbatch_gather_vs_results.sh` — collect docking scores
2. `sbatch_augment_results.sh` — add fingerprints
3. `sbatch_train.sh` — train the model
4. `sbatch_predict_slurm.sh` — predict over the library
5. `sbatch_save_top_prediction.sh` — take the best candidates
6. `sbatch_gen_params.sh` — build params for the next round

> **Note on this port:** PBS cannot take positional arguments the way SLURM
> could, so the iteration number is passed as an environment variable:
> ```bash
> qsub -v iter=1 sbatch_train.sh
> ```
> **Not** `qsub sbatch_train.sh 1` — that silently does the wrong thing.

Then repeat 13b–13f with `prefix="train2"`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `conda: command not found` **in a job** | `.bashrc` non-interactive guard | Step 6b — use the conda.sh snippet |
| `CommandNotFoundError: ... 'conda activate'` **in a job** | Same as above | Step 6b |
| `conda activate` works at the prompt but jobs fail | Same as above | Step 6b — this is the classic signature |
| `fatal: not a git repository` | Step 5 skipped | `git init` in `OpenVS-main` |
| Config paths say `/home/...` | Repo in the wrong place | Move to `$VSROOT`, rerun `init_config.py` |
| `Error: env variable ROSETTAHOME is not set` | Rosetta not on PATH | Step 9; check the folder name matches |
| Job dies instantly, empty log | Filesystem not declared | Header needs `filesystems=home:eagle` — **both** |
| `qsub: Job has no project/account` | Missing `-A` | Already in scripts; `head sbatch_train.sh` |
| Jobs sit in `Q` forever | Queue limits | `workq` allows 10 running per project. Normal |
| `Disk quota exceeded` on home | conda env grew | `conda clean -a -y` |
| `Disk quota exceeded` on Eagle | Directory quota | `myquota` — shared across the whole project |
| `gpu is requested but gpu is not available!` | Called `predict_clusterdb` | Step 14b — use `predict_fulldb` |
| Training hits the walltime | CPU is slower than GPU | Raise `#PBS -l walltime=` (max 24h) |

**Reading a failed job:** look at `output.*.log` in the directory you submitted
from, and at `<jobname>.o<jobid>` / `.e<jobid>`.

---

## Quick reference

```bash
# interactive use — nothing special needed
conda activate openvs

# inside any job script or non-interactive script
source "${CONDA_BASE:-$HOME/miniconda3}/etc/profile.d/conda.sh"
conda activate "${OPENVS_ENV:-openvs}"

# environment
echo $VSROOT $CONDA_BASE $ROSETTAHOME $DIMORPHITE

# where things are
cd $VSROOT/OpenVS-main

# jobs
qstat -u $USER
qsub -v iter=1 sbatch_train.sh
qdel <jobid>

# space
myquota
```

**Things that will bite you:**

1. Conda works at the prompt but not in jobs → step 6b.
2. Never `git add -A` (no `.gitignore` in this build).
3. `qsub -v iter=N script.sh`, never `qsub script.sh N`.
4. Rosetta, not PyRosetta.
5. PyTorch CPU build, not CUDA.
6. Keep `filesystems=home:eagle` — jobs need both.
7. Eagle is not backed up. Push your code somewhere.

---

## Getting help

- ALCF support: `support@alcf.anl.gov`
- ALCF Crux docs: <https://docs.alcf.anl.gov/crux/>
- ALCF filesystems: <https://docs.alcf.anl.gov/data-management/filesystem-and-storage/>
- Port-specific notes: `PORTING_SLURM_TO_PBS.md` in this repo
- The paper: <https://doi.org/10.1038/s41467-024-52061-7>

When emailing ALCF support, include your job ID, the full command you ran, and
the contents of the error log.
