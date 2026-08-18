#!/bin/bash
#
# run_obabel.sh - SMILES -> 3D mol2, with verification and retry.
#
# The original sent all Open Babel output to /dev/null and never checked
# whether the .mol2 it produced had any content. When two protonated .smi
# inputs turned out to be empty, this wrote two empty .mol2 files and the
# pipeline continued ~2,000 molecules short with no error.
#
# This version:
#   * refuses to start if the input .smi is empty (the real upstream failure)
#   * skips work if the output .mol2 already has content (resumable)
#   * retries up to MAX_RETRIES on an empty result
#   * keeps a per-batch error log instead of discarding stderr
#   * exits non-zero on failure so the array task is visibly marked bad
#
smifn=$1
tempprefix=$2
mol2fn=$3
infer_H=$4

MAX_RETRIES=${MAX_RETRIES:-3}
errlog="${mol2fn}.err"

nlines() { [ -s "$1" ] && wc -l < "$1" || echo 0; }

# --- input gate -------------------------------------------------------------
n_in=$(nlines "$smifn")
if [ "$n_in" -eq 0 ]; then
    echo "ERROR: input $smifn is empty or missing - nothing to convert." | tee "$errlog"
    echo "       (protonation upstream produced no output for this batch)" | tee -a "$errlog"
    exit 1
fi

# --- already done? ----------------------------------------------------------
if [ -s "$mol2fn" ]; then
    echo "$(basename "$mol2fn") already has content, skip"
    exit 0
fi

echo "converting $(basename "$smifn"): $n_in molecules"

for attempt in $(seq 1 "$MAX_RETRIES"); do
    rm -f "$mol2fn" "$tempprefix".1.pdb "$tempprefix".1.mol2

    if [ "$infer_H" -eq 1 ]; then
        obabel "$smifn" -O "$tempprefix.1.mol2" -e -d --gen3d --conformer \
               -nconf 100 --score energy --partialcharge mmff94 -xl >>"$errlog" 2>&1
        obabel "$tempprefix.1.mol2" -O "$mol2fn" -e -p 7.0 --partialcharge mmff94 \
               -xl --minimize --steps 2000 --sd >>"$errlog" 2>&1
        rm -f "$tempprefix.1.mol2"
    else
        obabel "$smifn" -O "$tempprefix.1.pdb" -e --gen3d --conformer \
               -nconf 100 --score energy --partialcharge mmff94 -xl >>"$errlog" 2>&1
        obabel "$tempprefix.1.pdb" -O "$mol2fn" -e -h --minimize --steps 2000 \
               --sd --partialcharge mmff94 --title "" --append "COMPND" -xl >>"$errlog" 2>&1
        rm -f "$tempprefix.1.pdb"
    fi

    if [ -s "$mol2fn" ]; then
        echo "  wrote $(basename "$mol2fn") ($(du -h "$mol2fn" | cut -f1), attempt $attempt)"
        rm -f "$errlog"
        exit 0
    fi
    echo "  WARNING: empty output on attempt $attempt/$MAX_RETRIES"
    sleep $((5 * attempt))
done

echo "ERROR: $(basename "$mol2fn") still empty after $MAX_RETRIES attempts." | tee -a "$errlog"
echo "       see $errlog for Open Babel output" | tee -a "$errlog"
exit 1
