from __future__ import print_function

import os,sys
from time import time
from glob import glob

# import scientific py
import numpy as np
import pandas as pd
# rdkit stuff
from rdkit import Chem
from rdkit.Chem import AllChem

from dask import compute, delayed
import dask.multiprocessing
from distributed import Client, as_completed, wait
from openvs.utils.crux import make_pbs_cluster, adapt_cluster


def valid_molid(molid):
    # Enamine catalogue IDs start Z/P; the REAL Samples files use s_/m_
    # synthon-style IDs instead. Note the '|' guard: ~8% of rows carry a
    # CXSMILES extension block (e.g. "CC(N)C |&1:1|") whose embedded space
    # shifts columns under str.split(), which is what the fields[2]
    # fallback below recovers from.
    if molid.startswith('|'):
        return False
    return molid.startswith(('Z', 'P', 's_', 'm_'))

def convert_enamine_smifn_to_fpfn_wrapper(inargs):
    return convert_enamine_smifn_to_fpfn(*inargs)

def convert_enamine_smifn_to_fpfn(smifn, fpfn, nBits=1024, radius=2, useFeature=True, useChirality=True, overwrite=True):
    if os.path.exists(fpfn) and not overwrite:
        print(f"{fpfn} exists, skip")
        return 0
    smis = []
    molids = []
    with open(smifn, 'r') as infh:
        for l in infh:
            if l.startswith("smiles"): continue
            fields = l.split()
            smi = fields[0]
            molid = fields[1]
            if not valid_molid(molid):
                molid = fields[2]
            if not valid_molid(molid):
                raise Exception(f"Cannot find valid molecule id, current molecule id {molid}")
            smis.append(smi)
            molids.append(molid)
    data = []
    for i, smi in enumerate(smis):
        m = Chem.MolFromSmiles(smi)
        fp = AllChem.GetMorganFingerprintAsBitVect(m, radius=radius, nBits=nBits, useFeatures=useFeature, useChirality=useChirality)
        data.append([molids[i], smi, fp.ToBinary()])
    df = pd.DataFrame(data, columns=['molecule_id', 'smiles', 'fp_binary']) 
    df.to_feather(fpfn)
    print(f"Saved: {fpfn}")
    return 0

def convert_enamine_real_db_smifns(inbasedir, outbasedir, mode="pbs"):
    if mode=="pbs":
        cluster_obj = make_pbs_cluster(memory_per_worker="10GB",
                                       walltime="12:00:00",
                                       job_name="gen_fp",
                                       worker_extra_args=["--no-nanny", "--no-bokeh"])
        adapt_cluster(cluster_obj, wait_count=400)
        client = Client(cluster_obj)
        print("Using PBS clusters:")
        print(client.scheduler_info())
    elif mode == "multiprocess":
        print("Using multiprocessing.")
    elif mode == "debug":
        pass
    else:
        raise Exception("Invalid running mode.")

    subdirs = next(os.walk(inbasedir))[1]
    print(subdirs)
    
    
    argslist = []
    oformat = "feather"
    delimiter = " "
    nBits = 1024
    radius = 2
    useFeature=True
    useChirality=True
    overwrite = False
    for subdir in subdirs:
        indir = os.path.join(inbasedir, subdir)
        if not os.path.exists(indir):
            print(f"{indir} doesn't exsit")
            continue
        pattern = os.path.join(indir, "cxsmiles.*")
        smifns = sorted(glob(pattern))
        if len(smifns) == 0:
            continue
        outdir = os.path.join(outbasedir, subdir)
        if not os.path.exists(outdir):
            os.makedirs(outdir)
        for smilefn in smifns:
            smifname = os.path.basename(smilefn)
            outfname = ".".join( [smifname] + [f"fp.{oformat}"] )
            outfn = os.path.join(outdir, outfname)
            argslist.append((smilefn, outfn, nBits, radius, useFeature, useChirality, overwrite))

    results = []
    print("Number of jobs:",len(argslist))
    for in_args in argslist:
        #print( cmd )
        if mode == "pbs":
            results.append( client.submit(convert_enamine_smifn_to_fpfn_wrapper, in_args) )
        elif mode == "multiprocess":
            results.append(delayed(convert_enamine_smifn_to_fpfn_wrapper)(in_args))
        elif mode == "debug":
            convert_enamine_smifn_to_fpfn_wrapper(in_args)
            sys.exit()
    if mode=="pbs":
        print(client.gather(results))
    elif mode == "multiprocess":
        retvals = compute(*results, scheduler='processes')



if __name__ == "__main__":
    mode = "multiprocess"
    db_root = os.environ.get("OPENVS_DB_PATH", "../databases")
    inbasedir = os.path.join(db_root, "real", "smiles", "split")
    outbasedir = os.path.join(db_root, "real", "fingerprints", "split")
    convert_enamine_real_db_smifns(inbasedir, outbasedir, mode)
