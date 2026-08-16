"""
Crux (ALCF) specific configuration for dask-jobqueue PBSCluster.

Crux allocates **whole nodes**, so the original one-core-per-PBS-job pattern
inherited from the SLURM version is a poor fit: it would burn an entire
128-core node per single-core dask worker, and the per-project limit of 10
running jobs in `workq` means it could never reach the 300-500 workers the
code asks for anyway.

This module instead packs many dask workers onto each node and scales out in
*nodes* rather than in workers.

Reference: https://docs.alcf.anl.gov/crux/queueing-and-running-jobs/running-jobs/
"""

import os
import re

# ---------------------------------------------------------------------------
# Site constants, from https://docs.alcf.anl.gov/crux/ (machine overview):
#   "Each compute node has dual AMD EPYC 7742 64-Core Processors... Each CPU
#    has 128 GB of DDR4 memory for a total of 256 GB per node."
#
# NOTE: the Crux running-jobs page states "two 32-core CPUs on each node".
# That is incorrect - the EPYC 7742 is a 64-core part, and the NUMA map on the
# overview page enumerates 128 physical cores (0-127) plus 128 hyperthread
# siblings (128-255), which also explains the documented OMP_NUM_THREADS
# default of 256. We size against the 128 *physical* cores, since this
# workload is compute-bound and gains little from hyperthreads.
# ---------------------------------------------------------------------------
CRUX_PROJECT = "marP_TB_VLS"
# Workers inherit the queue from the environment so a parent submitted to
# `preemptable` puts its workers there too. Set OPENVS_QUEUE to override.
CRUX_QUEUE = os.environ.get("OPENVS_QUEUE", "workq-route")          # routing queue -> executes in `workq`
CRUX_FILESYSTEMS = "home:eagle"     # required by ALCF; adjust if you use others
CRUX_CORES_PER_NODE = 128           # dual 64-core EPYC 7742 (256 logical)
CRUX_NODE_MEMORY_GB = 256           # confirmed: 2 x 128 GB DDR4
CRUX_MAX_WALLTIME = "24:00:00"      # workq-route ceiling

# `workq` allows 10 running jobs per project. The parent/driver script occupies
# one of those slots itself, so cap worker jobs below 10.
CRUX_MAX_WORKER_JOBS = 8


def _parse_memory_gb(memory):
    """'10GB' / '500MB' / '2 GB' -> float GB."""
    if isinstance(memory, (int, float)):
        return float(memory)
    m = re.fullmatch(r'\s*([\d.]+)\s*([KMGT]?)B?\s*', str(memory), re.IGNORECASE)
    if not m:
        raise ValueError(f"Cannot parse memory string: {memory!r}")
    value = float(m.group(1))
    scale = {'': 1e-9, 'K': 1e-6, 'M': 1e-3, 'G': 1.0, 'T': 1024.0}
    return value * scale[m.group(2).upper()]


def workers_per_node(memory_per_worker):
    """
    How many dask workers fit on one Crux node, bounded by both cores and RAM.

    A worker that wanted 30GB on the old one-core-per-job scheme gets 8 workers
    per node here (256/30); a 1GB worker gets the full 128.
    """
    per_worker_gb = _parse_memory_gb(memory_per_worker)
    if per_worker_gb <= 0:
        return CRUX_CORES_PER_NODE
    by_memory = int(CRUX_NODE_MEMORY_GB // per_worker_gb)
    return max(1, min(CRUX_CORES_PER_NODE, by_memory))


def make_pbs_cluster(memory_per_worker="4GB",
                     walltime="03:00:00",
                     job_name="dask-worker",
                     worker_extra_args=None,
                     job_script_prologue=None,
                     queue=None,
                     **kwargs):
    """
    Build a PBSCluster configured for Crux.

    `memory_per_worker` keeps the meaning the original code intended (how much
    memory one task needs); the number of workers packed onto each node is
    derived from it.
    """
    from dask_jobqueue import PBSCluster

    nprocs = workers_per_node(memory_per_worker)

    walltime = _clamp_walltime(walltime)

    prologue = ["export OMP_NUM_THREADS=1",
                "export MKL_NUM_THREADS=1"]
    if job_script_prologue:
        prologue = list(job_script_prologue) + prologue

    extra_directives = [
        f"-l filesystems={CRUX_FILESYSTEMS}",
        "-l place=scatter",
    ]
    if "job_extra_directives" in kwargs:
        extra_directives += list(kwargs.pop("job_extra_directives"))

    return PBSCluster(
        cores=nprocs,
        processes=nprocs,
        memory=f"{CRUX_NODE_MEMORY_GB}GB",
        queue=queue or CRUX_QUEUE,
        account=CRUX_PROJECT,
        walltime=walltime,
        job_name=job_name,
        resource_spec="select=1:system=crux",
        job_extra_directives=extra_directives,
        job_script_prologue=prologue,
        worker_extra_args=worker_extra_args or [],
        **kwargs,
    )


def _clamp_walltime(walltime):
    """workq-route caps at 24h; clamp rather than let qsub reject the job."""
    def to_seconds(t):
        parts = [int(p) for p in str(t).split(':')]
        while len(parts) < 3:
            parts.append(0)
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    if to_seconds(walltime) > to_seconds(CRUX_MAX_WALLTIME):
        return CRUX_MAX_WALLTIME
    return walltime


def adapt_cluster(cluster, max_jobs=None, wait_count=400):
    """
    Scale in whole nodes, respecting the per-project running-job limit.

    Replaces the original `cluster.adapt(minimum=0, maximum=300)`, which
    counted single-core worker *jobs* and exceeded what Crux permits.
    """
    if max_jobs is None:
        max_jobs = CRUX_MAX_WORKER_JOBS
    max_jobs = max(1, min(int(max_jobs), CRUX_MAX_WORKER_JOBS))
    return cluster.adapt(minimum_jobs=0, maximum_jobs=max_jobs,
                         wait_count=wait_count)
