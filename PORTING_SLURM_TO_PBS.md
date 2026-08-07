# Porting notes: SLURM → PBS Pro

This tree was converted from SLURM to PBS Pro. Everything below describes what
changed and, more importantly, **what you still need to check against your own
cluster** before running production jobs.

## 1. Directive mapping

| SLURM | PBS Pro | Notes |
|---|---|---|
| `#SBATCH -p cpu` | `#PBS -q cpu` | partition → queue |
| `#SBATCH -n 1` + `#SBATCH -c 5` | `#PBS -l select=1:ncpus=5` | tasks/cpus-per-task → chunk model |
| `#SBATCH --mem=20g` | `...:mem=20gb` | folded into the `select` statement |
| `#SBATCH --gres=gpu:1` | `...:ngpus=1` | folded into `select`; **site-specific**, see §5 |
| `#SBATCH --time 5:30:00` | `#PBS -l walltime=05:30:00` | zero-padded |
| `#SBATCH --time 1-00:00:00` | `#PBS -l walltime=24:00:00` | PBS has no `D-HH:MM:SS` form |
| `#SBATCH --job-name=X` | `#PBS -N X` | |
| `#SBATCH -o file.log` | `#PBS -o file.log` + `#PBS -j oe` | SLURM's `-o` merges stderr; PBS needs `-j oe` |
| `$SLURM_ARRAY_TASK_ID` | `$PBS_ARRAY_INDEX` | |
| `sbatch -a 1-N script.sh` | `qsub -J 1-N script.sh` | |
| `sbatch -a 1-N%50 script.sh` | `qsub -J 1-N -W max_run_subjobs=50 script.sh` | needs PBS Pro ≥ 2021.1, see §5 |
| `sbatch --dependency=afterok:ID` | `qsub -W depend=afterok:ID` | |
| `sbatch script.sh 3` | `qsub -v iter=3 script.sh` | see §3 |

## 2. Working directory

SLURM starts a job in the submission directory; **PBS Pro starts it in
`$HOME`**. Every job script now begins with:

```bash
cd "${PBS_O_WORKDIR:-$(pwd)}" || exit 1
```

This was not a cosmetic change — without it every relative path in the pipeline
(`gen3d.joblist`, `*_dock.joblist`, `run_dock.sh`, config files) would break.

## 3. Passing the iteration number

**This is the change most likely to bite you.** `sbatch script.sh 3` passes `3`
as `$1`; `qsub script.sh 3` does not pass arguments at all. The pipeline scripts
that took an iteration number now read it from the environment:

```bash
iter="${iter:-$1}"
```

so they accept **either** form:

```bash
qsub -v iter=3 sbatch_train.sh     # cluster submission
./sbatch_train.sh 3                # still works when run directly
```

`scripts/run_all.sh` was rewritten around this. Its `submit` helper is now
`submit <script> <iter> [extra qsub options...]`, e.g.

```bash
prev_jobid=$(submit sbatch_train.sh $curr_iter -o output.train.$curr_iter.log)
```

Note the argument order changed: the script name now comes first, and extra
`qsub` flags go last.

## 4. Job-id handling in `run_all.sh`

`sbatch` prints `Submitted batch job 12345`, which the old wrapper stripped with
`sed`. `qsub` prints the job id on its own (e.g. `12345.pbsserver`), so the
`sed` is gone. The **full** id including the server suffix is passed to
`-W depend=afterok:`, which is what PBS expects.

## 5. Things you must verify for your site

> **This tree is now configured for ALCF Crux** (project `marP_TB_VLS`).
> See §10 for what that entailed. The generic items below are kept for
> reference if you ever move to another cluster; most are already resolved.

These are genuinely site-dependent and cannot be determined from the source:

1. **Queue names.** Five distinct names were carried over verbatim from the
   original SLURM partitions: `cpu` (58 occurrences), `short` (3), `ckpt` (3),
   `gpu-bf` (2), and `dimaio` (2). They almost certainly need to be changed to
   your local queue names — in the `#PBS -q` lines, in the `queue=` arguments
   to `PBSCluster(...)`, and in the `queue=` default parameter values.
   Note `ckpt` appears only as a function default that every current call site
   overrides with `cpu`, and `dimaio` looks like a lab-private queue.
2. **GPU requests: removed (CPU-only target cluster).** The two
   `sbatch_train.sh` scripts originally requested `-p gpu-bf --gres=gpu:1`.
   Both now request `-q cpu` with no `ngpus`. See §9 for what this means in
   practice.
3. **`-W max_run_subjobs=50`** (the SLURM `%50` array throttle) requires
   PBS Pro 2021.1 or newer. On older versions, remove the flag and throttle
   with a queue-level `max_run` limit instead.
4. **Single-element arrays.** The joblist generators now emit a plain `qsub`
   instead of `qsub -J 1-1` when there is only one job, because one-element
   arrays are not portable across PBS Pro versions. The job scripts default
   `PBS_ARRAY_INDEX` to `1` so they work either way.
5. **Memory units.** `mem=20gb` is interpreted as binary (GiB) by PBS. If your
   site enforces hard memory limits, sanity-check the converted values.

## 6. Python / dask-jobqueue layer

`dask_jobqueue.SLURMCluster` was replaced with `dask_jobqueue.PBSCluster`
throughout. All constructor arguments in use (`cores`, `processes`, `memory`,
`queue`, `job_name`, `walltime`, `extra`, `worker_extra_args`,
`job_script_prologue`) are shared between the two classes, so the calls did not
otherwise change.

The corresponding mode/platform string was renamed **`"slurm"` → `"pbs"`**.
This affects:

- `mode="pbs"` arguments throughout `openvs/` and `experiments/*/scripts/`
- `--run_platform pbs` on `predict_db.py` / `predict_db_arraytask.py`
- `use_slurm` → `use_pbs` in `find_similar_zinc22_mol2s.py`

If you have saved configs or shell history passing `--run_platform slurm`, they
need updating; the string is no longer recognised.

## 7. File naming

Script filenames were **not** renamed — `sbatch_train.sh` still contains PBS
directives, and `sbatch_predict_slurm.sh` keeps its name. This was deliberate:
renaming would break the cross-references in `run_all.sh`, `sbatch_gen_3dstruct.sh`,
`experiments/README`, and the joblist generators. If you want to rename them,
do it as a separate mechanical pass and update those references together.

## 8. Unrelated pre-existing issue

`experiments/{E3L_6DO3,Nav_5EK0}/scripts/report_mol_properties.py` has a
syntax error at line 32 (`elif infn.endswith(".feather")` is missing its
colon). This predates the port and was left untouched, but it means those two
files will not import as-is.

## 9. Running on a CPU-only cluster

This tree is configured for a cluster with **no GPUs**. Nothing in the pipeline
strictly requires CUDA, but three points are worth knowing.

**What already handles CPU automatically.** `train.py`, `cluster_top.py` and
the prediction paths all select their device with
`torch.device("cuda" if torch.cuda.is_available() else "cpu")`, so they degrade
to CPU with no change. Checkpoint loading is also CPU-safe: `predict_db.py`
and `predict_db_arraytask.py` pass `map_location=torch.device('cpu')` when CUDA
is absent, so models trained elsewhere on a GPU still load.

**The database-scoring step was already CPU-based.** `--run_platform pbs`
(formerly `slurm`) explicitly sets `device = torch.device("cpu")` and fans the
work out across many single-core dask workers. That is the design's intended
large-scale path, and it is unaffected by the absence of GPUs.

**Model size.** `VanillaNet2` is a 4-layer MLP: `nBits=1024` in, three hidden
layers of `nnodes=3000`, one output. That is ~21.1M parameters (~84 MB fp32)
and ~42 MFLOP per sample forward. This is small, and CPU training is entirely
feasible — but it is not free, and it will be meaningfully slower than the GPU
run the walltimes were originally chosen for.

**The one thing to watch: training walltime.** `sbatch_train.sh` still requests
5h (E3L_6DO3) and 6h (Nav_5EK0), values chosen when the job had a GPU. Watch
the first CPU training run; if it is killed at the walltime limit, raise
`#PBS -l walltime=` and consider raising `ncpus` above 4 (PyTorch CPU matmuls
thread well, and this model is dense-matmul bound). Also check that
`OMP_NUM_THREADS` is not pinned to 1 by your site profile, which would leave
those cores idle.

**Latent trap (currently dead code).** `predict_clusterdb()` in both
`predict_db.py` files hardcodes `pargs.run_platform = 'gpu'`, which raises
`Exception("gpu is requested but gpu is not available!")` on a CPU-only host.
Nothing calls this function today — the `__main__` entry point calls
`predict_fulldb()` instead — so it will not bite you as shipped. If you ever
wire it up, change that line to `'auto'` or `'pbs'` first.

## 10. Crux (ALCF) specific pass

Configured for **project `marP_TB_VLS`** against
<https://docs.alcf.anl.gov/crux/queueing-and-running-jobs/running-jobs/>.

### Job script headers (22 scripts + 5 generator templates)

Every job script now carries:

```bash
#!/bin/bash -l
#PBS -q workq-route
#PBS -A marP_TB_VLS
#PBS -l select=1:system=crux
#PBS -l place=scatter
#PBS -l filesystems=home:eagle
#PBS -l walltime=HH:MM:SS
```

`-A` and `-l filesystems` are required by ALCF and were absent from all 22
scripts — jobs would have been rejected outright without them.

### Node-exclusive resource model

Crux allocates **whole nodes** (dual 64-core AMD EPYC 7742 = 128 physical
cores, 256 logical threads, 256 GB DDR4), and its queue
limits are denominated in nodes. The chunk requests translated from SLURM
(`select=1:ncpus=5:mem=20gb` and friends) do not apply and have been replaced
with `select=1:system=crux`. The old `ncpus`/`mem` values are preserved only
as the `memory_per_worker` hint described below.

### Walltime

`workq-route` caps at 24 h. `benchmarks/casf_2016/eval_screening_cpp/sbatch_run_eval.sh`
requested 48 h and was clamped to 24 h — **check whether that job actually
completes in 24 h**, since it was originally given two days. Four other
scripts sit exactly at the 24 h ceiling with no headroom.

### Concurrency limits (the significant behavioural change)

`workq` allows 20 jobs queued-or-running and only **10 running per project**;
`workq-route` allows 100 jobs per project. Consequences:

- All array submissions are throttled with `-W max_run_subjobs=8`, leaving
  headroom for the driver job. Previously `submit_arrayjobs.sh` fired
  `-J 1-51` with no cap at all.
- **Confirm with ALCF whether array subjobs count individually against the
  10-running limit.** If they do, large arrays will trickle rather than fail,
  which is survivable but slow.

### dask-jobqueue restructuring

This was the deepest change. The original code requested up to **300-500
single-core worker jobs** (`adapt(minimum=0, maximum=500)`). On a
node-exclusive machine each of those would consume a whole 64-core node, and
the 10-job limit meant it could never reach that number anyway.

All 24 `PBSCluster(...)` sites across 21 files now call
`openvs.utils.crux.make_pbs_cluster()`, which packs many workers onto each
node and scales out in nodes rather than workers:

| memory per worker | workers packed per node | with 8 node-jobs | bound by |
|---|---|---|---|
| 1 GB | 128 | 1024 workers | cores |
| 2 GB | 128 | 1024 workers | cores |
| 3 GB | 85 | 680 workers | memory |
| 5 GB | 51 | 408 workers | memory |
| 10 GB | 25 | 200 workers | memory |
| 30 GB | 8 | 64 workers | memory |

So the effective worker count **matches or exceeds** the original intent while
using 8 jobs instead of 500. `adapt_cluster()` replaces the old `.adapt()`
calls and scales in whole nodes via `maximum_jobs`.

The per-site `queue=` arguments (`cpu`, `short`, `dimaio`, `ckpt`) are gone —
the helper supplies `workq-route` centrally.

### OMP_NUM_THREADS

Crux defaults this to **256** (the logical thread count). Now set explicitly:
`1` in array tasks (they fan out via GNU parallel) and in dask workers (one
core each), `128` in driver and training scripts - one thread per *physical*
core, since this workload is compute-bound and gains little from hyperthreads.

### Node utilisation

`cmd_size` in the joblist generators was `1*5`, matching the old SLURM
`-c 5`. On a node-exclusive machine that would use 5 of 64 cores — about 8%.
Raised to `1*64` so each array task fills its node. This changes the number of
array tasks generated; revert to `1*5` if you need the original job layout.

### VERIFY before first production run

1. **`CRUX_NODE_MEMORY_GB = 256` in `openvs/utils/crux.py` is an assumption.**
   The ALCF running-jobs page does not state per-node memory. Confirm with
   `pbsnodes -a` (look at `resources_available.mem`) and correct it — every
   worker-packing number above depends on it.
2. Whether array subjobs count individually against the 10-running limit.
3. That the clamped 24 h `eval_screening_cpp` job still completes.
4. `--no-bokeh` is passed via `worker_extra_args` in several scripts. That
   flag was removed from dask years ago and may cause worker startup to fail.
   It predates this port; left as-is, but worth deleting.
5. Compute nodes reach the internet only through a proxy
   (`http_proxy=http://proxy.alcf.anl.gov:3128`). Set it if any job fetches
   at runtime.

## 11. No .gitignore in this build

This build deliberately ships **without** a `.gitignore`. `init_config.py`
derives every path from `git rev-parse --show-toplevel`, so the pipeline
writes its bulk data inside the repository. With no ignore rules, treat git as
a tool for the *code only*:

* run `git add` on named paths (`git add openvs experiments/*/scripts`),
* never run `git add -A` or `git add .` from the repo root,
* never run `git commit -a`.

Committing generated data duplicates it into `.git/objects` at roughly 1:1 for
incompressible formats (feather, tar), so a 200 GB screen becomes 400 GB on
disk and cannot be removed without rewriting history.
