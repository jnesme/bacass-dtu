#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpc
### -- set the job Name --
#BSUB -J bgc_sideload_merge
### -- ask for number of cores --
#BSUB -n 8
### -- all cores on one host --
#BSUB -R "span[hosts=1] rusage[mem=8GB]"
### -- specify that we want the job to get killed if it exceeds 8.5 GB --
#BSUB -M 8500MB
### -- set walltime limit: hh:mm --
#BSUB -W 12:00
### -- set the email address --
#BSUB -u josne@dtu.dk
### -- send notification at start --
#BSUB -B
### -- send notification at completion --
#BSUB -N
### -- Specify the output and error file. %J is the job-id --
#BSUB -o bgc_sideload_merge_%J.out
#BSUB -e bgc_sideload_merge_%J.err

# ============================================================================
# Fixes nf-core/funcscan's fragile BGC merge (COMBGC parses antiSMASH's
# GenBank + a separate clusterblast text file, instead of antiSMASH's own
# native JSON or the antiSMASH-sideload format DeepBGC/GECCO both provide —
# see CLAUDE.md's "Known caveat" under Standalone Aggregation Scripts).
#
# Uses the method an antiSMASH core developer recommended: feed DeepBGC's and
# GECCO's antiSMASH-sideload JSON into antiSMASH itself via
# `--reuse-results` (reuses the already-computed antiSMASH JSON, skipping
# re-detection) + `--sideload` (merges in the other tools' calls), producing
# one authoritative, self-consistent antiSMASH output per sample.
#
# Per sample:
#   Step 1 — GECCO rerun with --antismash-sideload (funcscan never passed
#            this flag, so no GECCO sideload JSON exists yet). Uses the same
#            Bakta .gbff input and pinned conda env funcscan itself used.
#            Writes to <funcscan-outdir>/bgc/gecco_sideload/<sample>/ — the
#            original bgc/gecco/ output is untouched.
#   Step 2 — antismash --reuse-results <original antismash json> --sideload
#            <deepbgc.json>,<gecco sideload json>. Writes to
#            <funcscan-outdir>/bgc/antismash_merged/<sample>/ — the original
#            bgc/antismash/ output is untouched.
#
# Smoke-tested Aug 2026 on S0204 (88-contig genome): GECCO rerun 37s, antiSMASH
# reuse-results+sideload merge 37s (vs. a full run) — region count went from
# 8 (antiSMASH-only) to 18 (with GECCO/DeepBGC calls antiSMASH's own detectors
# missed merged in). Provenance per region is recoverable from
# <sample>.json's modules['antismash.detection.sideloader']['subregions']
# (each tagged tool.name: DeepBGC/GECCO) — see bin/antismash_merged_summary.py.
#
# Usage:
#   ./run_bgc_sideload_merge.sh <bacass-outdir> <funcscan-outdir> [cpus]
#   bsub < run_bgc_sideload_merge.sh   (edit BACASS_OUTDIR/FUNCSCAN_OUTDIR below first)
# ============================================================================

set -euo pipefail

BACASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <bacass-outdir> <funcscan-outdir> [cpus]"
    echo "  bacass-outdir     Bacass results dir containing Bakta/<sample>/<sample>.gbff"
    echo "  funcscan-outdir   Funcscan results dir containing bgc/{antismash,deepbgc,gecco}/<sample>/"
    echo "  cpus              Optional, passed to gecco -j and antismash -c (default: 4)"
    exit 1
}

[ $# -ge 2 ] || usage
BACASS_OUTDIR="$(cd "$1" 2>/dev/null && pwd)" || { echo "ERROR: bacass-outdir '$1' does not exist"; exit 1; }
FUNCSCAN_OUTDIR="$(cd "$2" 2>/dev/null && pwd)" || { echo "ERROR: funcscan-outdir '$2' does not exist"; exit 1; }
CPUS="${3:-4}"

GECCO_ENV="/work3/josne/github/bacass/.conda_envs/env-686caaf6ce281d76ea8c8f40b5186ae6"
ANTISMASH_ENV="/work3/josne/github/bacass/.conda_envs/env-3afb2e6d352a088017e79a544d2d4222"
ANTISMASH_DB="${BACASS_DIR}/assets/databases/antismash_db"

[ -x "${GECCO_ENV}/bin/gecco" ] || { echo "ERROR: gecco not found at ${GECCO_ENV} (must match conf/gecco_environment.yml's pyhmmer<0.12 pin)"; exit 1; }
[ -x "${ANTISMASH_ENV}/bin/antismash" ] || { echo "ERROR: antismash not found at ${ANTISMASH_ENV}"; exit 1; }
[ -d "${ANTISMASH_DB}" ] || { echo "ERROR: antiSMASH database not found at ${ANTISMASH_DB}"; exit 1; }
[ -d "${BACASS_OUTDIR}/Bakta" ] || { echo "ERROR: ${BACASS_OUTDIR}/Bakta not found"; exit 1; }
[ -d "${FUNCSCAN_OUTDIR}/bgc/antismash" ] || { echo "ERROR: ${FUNCSCAN_OUTDIR}/bgc/antismash not found"; exit 1; }

# antiSMASH needs its own conda env's bin/ (hmmsearch, blastp, ...) on PATH and
# the RPATH-fix activate.d script sourced — `conda activate`, not a bare
# absolute-path invocation (confirmed during smoke test: without this,
# antismash fails "Failed to locate executable for 'hmmsearch'" etc).
source /work3/josne/miniconda3/etc/profile.d/conda.sh
conda activate "${ANTISMASH_ENV}"

mapfile -t GBFFS < <(find "${BACASS_OUTDIR}/Bakta" -mindepth 2 -maxdepth 2 -name "*.gbff" | sort)
echo "=========================================="
echo "BGC sideload merge (GECCO rerun + antiSMASH reuse-results/sideload)"
echo "Job started on $(date)"
echo "Bacass outdir:   ${BACASS_OUTDIR}"
echo "Funcscan outdir: ${FUNCSCAN_OUTDIR}"
echo "Samples found:   ${#GBFFS[@]}"
echo "CPUs per tool:   ${CPUS}"
echo "=========================================="
if [ "${#GBFFS[@]}" -eq 0 ]; then
    echo "ERROR: no *.gbff files found in ${BACASS_OUTDIR}/Bakta/*/"
    exit 1
fi

GECCO_OUT="${FUNCSCAN_OUTDIR}/bgc/gecco_sideload"
MERGED_OUT="${FUNCSCAN_OUTDIR}/bgc/antismash_merged"
mkdir -p "${GECCO_OUT}" "${MERGED_OUT}"

i=0
for gbff in "${GBFFS[@]}"; do
    i=$((i + 1))
    sample="$(basename "${gbff}" .gbff)"
    echo ""
    echo "=== Sample ${i}/${#GBFFS[@]}: ${sample} ==="

    antismash_json="${FUNCSCAN_OUTDIR}/bgc/antismash/${sample}/${sample}.json"
    if [ ! -f "${antismash_json}" ]; then
        echo "WARNING: no antiSMASH json for ${sample} (no BGC hits originally) — skipping"
        continue
    fi

    # --- Step 1: GECCO rerun with --antismash-sideload ---
    gecco_sideload="${GECCO_OUT}/${sample}/${sample}.sideload.json"
    if [ -f "${gecco_sideload}" ]; then
        echo "GECCO sideload already exists, skipping Step 1"
    else
        mkdir -p "${GECCO_OUT}/${sample}"
        "${GECCO_ENV}/bin/gecco" run -j "${CPUS}" -o "${GECCO_OUT}/${sample}" -g "${gbff}" --antismash-sideload \
            || echo "WARNING: GECCO found nothing / failed for ${sample} (continuing without its sideload input)"
    fi

    # --- Step 2: antiSMASH reuse-results + sideload merge ---
    merged_json="${MERGED_OUT}/${sample}/${sample}.json"
    if [ -f "${merged_json}" ]; then
        echo "Merged antiSMASH output already exists, skipping Step 2"
        continue
    fi

    sideload_files=""
    deepbgc_json="${FUNCSCAN_OUTDIR}/bgc/deepbgc/${sample}/${sample}.antismash.json"
    [ -f "${deepbgc_json}" ] && sideload_files="${deepbgc_json}"
    if [ -f "${gecco_sideload}" ]; then
        [ -n "${sideload_files}" ] && sideload_files="${sideload_files},${gecco_sideload}" || sideload_files="${gecco_sideload}"
    fi

    if [ -z "${sideload_files}" ]; then
        echo "No DeepBGC/GECCO sideload data for ${sample} — nothing to merge, skipping"
        continue
    fi

    mkdir -p "${MERGED_OUT}/${sample}"
    # antiSMASH's sideload validation is strict per-sample (e.g. rejects a sideloaded area
    # that contains no complete CDS, which can happen for a call sitting right at a contig
    # edge) and exits 1 on rejection. Don't let one sample's rejection kill the whole batch —
    # log it and move on; the merged_json skip-check above makes this safely re-runnable.
    if ! antismash \
        --reuse-results "${antismash_json}" \
        --sideload "${sideload_files}" \
        --databases "${ANTISMASH_DB}" \
        -c "${CPUS}" \
        --output-dir "${MERGED_OUT}/${sample}" \
        --output-basename "${sample}" \
        --logfile "${MERGED_OUT}/${sample}/${sample}.log"; then
        echo "WARNING: antiSMASH sideload merge failed for ${sample} (see ${MERGED_OUT}/${sample}/${sample}.log) — skipping"
        echo "${sample}" >> "${MERGED_OUT}/FAILED_SAMPLES.txt"
    fi
done

echo ""
echo "=========================================="
echo "Done on $(date)"
echo "GECCO sideload output:    ${GECCO_OUT}/<sample>/"
echo "Merged antiSMASH output:  ${MERGED_OUT}/<sample>/"
if [ -f "${MERGED_OUT}/FAILED_SAMPLES.txt" ]; then
    echo "Samples that failed the merge: $(wc -l < "${MERGED_OUT}/FAILED_SAMPLES.txt") (see ${MERGED_OUT}/FAILED_SAMPLES.txt)"
fi
echo "Next: bin/antismash_merged_summary.py to build a corrected summary table"
echo "=========================================="
