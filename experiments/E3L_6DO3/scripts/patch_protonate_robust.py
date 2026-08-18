#!/usr/bin/env python3
"""
patch_protonate_robust.py - make protonation verify its own output.

WHY
  Batches gen3d_random.0 and .1 produced empty .prot.smi files. Nothing
  noticed: Open Babel then wrote empty .mol2 files, and the pipeline carried
  on ~2,000 molecules short with no error anywhere. The failure only became
  visible three stages later.

WHAT THIS CHANGES
  * skip batches whose output already exists and is non-empty  (resumable)
  * after each batch, CHECK the output file has content
  * retry a failed batch up to MAX_RETRIES times
  * raise at the end listing any batch that never succeeded
  * drop the blanket `rm {outdir}/*.smi`; each output is removed immediately
    before it is rewritten instead

USAGE
  cd $VSROOT/OpenVS-main/experiments/E3L_6DO3/scripts
  python patch_protonate_robust.py
  python -c "import ast;ast.parse(open('prepare_smiles.py').read());print('OK')"
"""
from pathlib import Path

import sys
if "MAX_PROTONATE_RETRIES" in open("prepare_smiles.py").read():
    sys.exit("already patched - nothing to do")
p = Path("prepare_smiles.py")
s = p.read_text()

OLD_PROT = '''def protonate_smiles(inargs):
    smifn, outdir = inargs
    smifname = os.path.basename(smifn)
    protname = smifname.replace(".smi", ".prot.smi")
    os.makedirs(outdir, exist_ok=True)
    outfn = os.path.join(outdir, protname)
    dimorphite_home = os.environ.get('DIMORPHITE')
    app = f"{dimorphite_home}/dimorphite_dl.py"
    if not os.path.exists(app):
        raise ValueError(f"Cannot find {app}, please set the correct path.")
    cmd = f"python {app} --smiles_file {smifn} --min_ph 7.4 --max_ph 7.4 --output_file {outfn} --pka_precision 0.1"
    return run_cmd(cmd)'''

NEW_PROT = '''MAX_PROTONATE_RETRIES = 3

def _nlines(fn):
    """Number of lines in fn, or 0 if it is missing/unreadable."""
    try:
        with open(fn) as fh:
            return sum(1 for _ in fh)
    except OSError:
        return 0

def protonate_smiles(inargs):
    smifn, outdir = inargs
    smifname = os.path.basename(smifn)
    protname = smifname.replace(".smi", ".prot.smi")
    os.makedirs(outdir, exist_ok=True)
    outfn = os.path.join(outdir, protname)
    dimorphite_home = os.environ.get('DIMORPHITE')
    app = f"{dimorphite_home}/dimorphite_dl.py"
    if not os.path.exists(app):
        raise ValueError(f"Cannot find {app}, please set the correct path.")

    # Already done? Nothing to do - makes the whole stage resumable.
    if _nlines(outfn) > 0:
        print(f"protonate: {os.path.basename(outfn)} already has "
              f"{_nlines(outfn)} lines, skip")
        return outfn

    n_in = _nlines(smifn)
    cmd = (f"python {app} --smiles_file {smifn} --min_ph 7.4 --max_ph 7.4 "
           f"--output_file {outfn} --pka_precision 0.1")

    for attempt in range(1, MAX_PROTONATE_RETRIES + 1):
        if os.path.exists(outfn):
            os.remove(outfn)          # remove only what we are about to write
        run_cmd(cmd)
        n_out = _nlines(outfn)
        if n_out > 0:
            print(f"protonate: {os.path.basename(smifn)} "
                  f"{n_in} -> {n_out} lines (attempt {attempt})")
            return outfn
        print(f"protonate: WARNING {os.path.basename(smifn)} produced an empty "
              f"output on attempt {attempt}/{MAX_PROTONATE_RETRIES}")
        time.sleep(5 * attempt)

    print(f"protonate: FAILED {smifn} after {MAX_PROTONATE_RETRIES} attempts")
    return None'''

OLD_DIR = '''    os.makedirs(outdir, exist_ok=True)
    cmd = f"rm {outdir}/*.smi"
    p = sp.Popen(cmd, shell=True)
    p.communicate()'''

NEW_DIR = '''    os.makedirs(outdir, exist_ok=True)
    # NOTE: the blanket "rm {outdir}/*.smi" that used to be here has been
    # removed. Each output file is deleted immediately before it is rewritten
    # (see protonate_smiles), which keeps the stage resumable and avoids
    # wiping good output if this is re-run after a partial failure.'''

OLD_TAIL = '''    if mode == 'pbs':
        print("Number jobs:", len(joblist))
        print( client.gather(joblist) )
        client.close()'''

NEW_TAIL = '''    if mode == 'pbs':
        print("Number jobs:", len(joblist))
        results = client.gather(joblist)
        client.close()
    else:
        results = None

    # Verify every input produced a non-empty output; fail loudly if not.
    missing = []
    for smifn in smifns:
        protname = os.path.basename(smifn).replace(".smi", ".prot.smi")
        outfn = os.path.join(outdir, protname)
        if _nlines(outfn) == 0:
            missing.append(outfn)
    if missing:
        print(f"protonate: {len(missing)} of {len(smifns)} batches are EMPTY:")
        for m in missing:
            print(f"    {m}")
        raise RuntimeError(
            f"protonation produced {len(missing)} empty file(s); "
            "re-run this stage (completed batches are skipped)")
    print(f"protonate: all {len(smifns)} batches produced output")'''

changed = 0
for old, new, label in ((OLD_PROT, NEW_PROT, "protonate_smiles"),
                        (OLD_DIR, NEW_DIR, "blanket rm"),
                        (OLD_TAIL, NEW_TAIL, "verification tail")):
    if old in s:
        s = s.replace(old, new, 1); changed += 1
        print(f"patched: {label}")
    else:
        print(f"NOT FOUND (skipped): {label}")

if "import time" not in s:
    s = s.replace("import os", "import os\nimport time", 1)
    print("added: import time")

if changed:
    Path("prepare_smiles.py.prepatch").write_text(p.read_text())
    p.write_text(s)
    print(f"\n{changed}/3 sections patched. Backup: prepare_smiles.py.prepatch")
else:
    print("\nnothing changed - the file may already be patched")
