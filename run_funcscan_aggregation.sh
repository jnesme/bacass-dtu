#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpc
### -- set the job Name --
#BSUB -J funcscan_aggregation
### -- ask for number of cores --
#BSUB -n 1
#BSUB -R "rusage[mem=8GB]"
### -- specify that we want the job to get killed if it exceeds 8.5 GB --
#BSUB -M 8500MB
### -- set walltime limit: hh:mm --
#BSUB -W 02:00
### -- set the email address --
#BSUB -u josne@dtu.dk
### -- send notification at start --
#BSUB -B
### -- send notification at completion --
#BSUB -N
### -- Specify the output and error file. %J is the job-id --
#BSUB -o funcscan_aggregation_%J.out
#BSUB -e funcscan_aggregation_%J.err

# ============================================================================
# Regenerates funcscan's cross-sample aggregation results — hAMRonization
# ARG summary, AMPcombi AMP summary, COMBGC BGC summary, and the top-level
# MultiQC report — directly from a results OUTDIR, outside Nextflow.
#
# Scope: only the 4 aggregation tasks actually exercised in this project.
# funcscan also has taxonomy-merge variants of the ARG/AMP/BGC summaries
# (MERGE_TAXONOMY_*) and an AMPcombi clustering step, but all of those are
# gated behind --run_taxa_classification, which submit_funcscan_distributed.sh
# never enables (confirmed: params.run_taxa_classification defaults false and
# is never overridden) — so they're skipped here, not just forgotten.
#
# Usage:
#   ./run_funcscan_aggregation.sh <OUTDIR>
#   bsub < run_funcscan_aggregation.sh  (edit OUTDIR below first)
# ============================================================================

set -euo pipefail

BACASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCSCAN_SRC="${BACASS_DIR}/.nextflow_home/assets/nf-core/funcscan"

usage() {
    echo "Usage: $0 <OUTDIR>"
    echo "  OUTDIR  Funcscan results directory (e.g. funcscan_results)"
    exit 1
}

[ $# -ge 1 ] || usage
OUTDIR="$(cd "$1" 2>/dev/null && pwd)" || { echo "ERROR: OUTDIR '$1' does not exist or is not a directory"; exit 1; }

# --- Resolve conda envs and config (before sourcing setup.sh) ---
HAMRONIZE_ENV="${BACASS_DIR}/.conda_envs/env-3fac51c11f6137ab3d0d18920305e955"
AMPCOMBI_ENV="${BACASS_DIR}/.conda_envs/env-a9e8ec1556d51be57f9eecb3ab4462f5"
FS_MULTIQC_ENV="${BACASS_DIR}/.conda_envs/env-55e377717f27765e46a811a08ed80f85"

"${HAMRONIZE_ENV}/bin/hamronize" --version 2>&1 | grep -q "1\.1\.9" \
    || { echo "ERROR: hamronization 1.1.9 not found at ${HAMRONIZE_ENV}"; exit 1; }
"${AMPCOMBI_ENV}/bin/ampcombi" --version 2>&1 | grep -q "2\.0\.1" \
    || { echo "ERROR: ampcombi 2.0.1 not found at ${AMPCOMBI_ENV}"; exit 1; }
"${FS_MULTIQC_ENV}/bin/multiqc" --version 2>&1 | grep -q "1\.29" \
    || { echo "ERROR: funcscan MultiQC 1.29 not found at ${FS_MULTIQC_ENV} (do not reuse bacass's 1.19 env)"; exit 1; }

FS_MULTIQC_CONFIG="${FUNCSCAN_SRC}/assets/multiqc_config.yml"
if [ ! -f "${FS_MULTIQC_CONFIG}" ]; then
    echo "ERROR: funcscan multiqc_config.yml not found at ${FS_MULTIQC_CONFIG}"
    echo "Contents of .nextflow_home/assets/nf-core/:"
    ls "${BACASS_DIR}/.nextflow_home/assets/nf-core/" 2>&1
    exit 1
fi

source "${BACASS_DIR}/setup.sh"

echo "=========================================="
echo "Funcscan aggregation re-run"
echo "Job started on $(date)"
echo "Job ID: ${LSB_JOBID:-N/A}"
echo "Running on node: $(hostname)"
echo "OUTDIR: ${OUTDIR}"
echo "=========================================="
echo "hAMRonization env : ${HAMRONIZE_ENV}"
echo "AMPcombi env       : ${AMPCOMBI_ENV}"
echo "MultiQC env         : ${FS_MULTIQC_ENV}"

# ============================================================
# Step 1: HAMRONIZATION_SUMMARIZE
# ============================================================
echo ""
echo "=== Step 1: hamronize summarize ==="

if [ -d "${OUTDIR}/arg/hamronization" ]; then
    mapfile -t HAM_TSVS < <(find "${OUTDIR}/arg/hamronization" -mindepth 2 -maxdepth 2 -name "*.tsv" | sort)
    echo "Found ${#HAM_TSVS[@]} hamronization TSVs"
    if [ "${#HAM_TSVS[@]}" -gt 0 ]; then
        mkdir -p "${OUTDIR}/reports/hamronization_summarize"
        "${HAMRONIZE_ENV}/bin/hamronize" summarize "${HAM_TSVS[@]}" -t tsv \
            -o "${OUTDIR}/reports/hamronization_summarize/hamronization_combined_report.tsv"
        echo "hamronization report → ${OUTDIR}/reports/hamronization_summarize/hamronization_combined_report.tsv"
    else
        echo "WARNING: no *.tsv found under ${OUTDIR}/arg/hamronization — skipping (ARG screening likely not run)"
    fi
else
    echo "WARNING: ${OUTDIR}/arg/hamronization not found — skipping HAMRONIZATION_SUMMARIZE"
fi

# ============================================================
# Step 2: AMPCOMBI2_COMPLETE
# ============================================================
echo ""
echo "=== Step 2: ampcombi complete ==="

if [ -d "${OUTDIR}/reports/ampcombi2" ]; then
    mapfile -t AMP_TSVS < <(find "${OUTDIR}/reports/ampcombi2" -mindepth 2 -maxdepth 2 -name "*_ampcombi.tsv" | sort)
    echo "Found ${#AMP_TSVS[@]} ampcombi per-sample summaries"
    if [ "${#AMP_TSVS[@]}" -ge 2 ]; then
        (
            cd "${OUTDIR}/reports/ampcombi2"
            "${AMPCOMBI_ENV}/bin/ampcombi" complete --summaries_files "${AMP_TSVS[@]}" --log TRUE
        )
        echo "ampcombi summary → ${OUTDIR}/reports/ampcombi2/Ampcombi_summary.tsv"
    elif [ "${#AMP_TSVS[@]}" -eq 1 ]; then
        echo "ERROR: only 1 ampcombi summary file found — 'ampcombi complete' requires >=2. Not running."
        exit 1
    else
        echo "WARNING: no *_ampcombi.tsv found under ${OUTDIR}/reports/ampcombi2 — skipping"
    fi
else
    echo "WARNING: ${OUTDIR}/reports/ampcombi2 not found — skipping AMPCOMBI2_COMPLETE"
fi

# ============================================================
# Step 3: COMBGC — INTENTIONALLY NOT REGENERATED.
# Investigated Aug 2026: per-sample reports/combgc/<id>/combgc_summary.tsv
# files on disk contain only antiSMASH rows, while the existing
# reports/combgc/combgc_complete_summary.tsv aggregate also has DeepBGC and
# GECCO rows for the same samples — confirmed systemic (checked 20+ samples,
# 100% mismatch), and confirmed DeepBGC/GECCO raw output existed on disk
# *before* COMBGC ran (so it's not a "hadn't finished yet" issue). Could not
# determine the exact mechanism — funcscan's own work dir (work_funcscan) and
# the contemporaneous .nextflow.log are both gone, so there's no surviving
# trace of what COMBGC actually received as input that run. The aggregate is
# richer and internally consistent with data that was genuinely available;
# regenerating from today's per-sample files would silently downgrade
# already-published results. Until this is understood, leave
# combgc_complete_summary.tsv untouched rather than risk overwriting good
# data with bad — see project memory for the investigation writeup.
# ============================================================
echo ""
echo "=== Step 3: combgc — SKIPPED (see script comment above) ==="
if [ -f "${OUTDIR}/reports/combgc/combgc_complete_summary.tsv" ]; then
    echo "Existing aggregate found, left untouched: ${OUTDIR}/reports/combgc/combgc_complete_summary.tsv"
else
    echo "WARNING: ${OUTDIR}/reports/combgc/combgc_complete_summary.tsv not found — BGC screening likely not run, nothing to preserve"
fi

# ============================================================
# Step 4: funcscan top-level MultiQC
# NOTE: this project's funcscan runs always use preannotated (Bakta-from-
# bacass) samplesheets, so funcscan's own ANNOTATION subworkflow never runs
# and there is no Prokka/Bakta QC panel to recover here — this report will
# mainly contain software-versions/general info, not per-tool QC, matching
# funcscan's own multiqc_config.yml (run_modules: [prokka, custom_content]).
# ============================================================
echo ""
echo "=== Step 4: funcscan MultiQC ==="

MQ_STAGING=$(mktemp -d)
trap 'rm -rf "${MQ_STAGING}"' EXIT

[ -d "${OUTDIR}/pipeline_info" ]      && ln -s "${OUTDIR}/pipeline_info" "${MQ_STAGING}/pipeline_info"
[ -d "${OUTDIR}/annotation/prokka" ]  && ln -s "${OUTDIR}/annotation/prokka" "${MQ_STAGING}/prokka"

(
    cd "${MQ_STAGING}"
    "${FS_MULTIQC_ENV}/bin/multiqc" --force --config "${FS_MULTIQC_CONFIG}" .
)

mkdir -p "${OUTDIR}/multiqc"
cp -r "${MQ_STAGING}/"*multiqc_report.html "${OUTDIR}/multiqc/" 2>/dev/null || echo "WARNING: MultiQC produced no report.html"
cp -r "${MQ_STAGING}/"*_data              "${OUTDIR}/multiqc/" 2>/dev/null || true

echo ""
echo "=========================================="
echo "Done on $(date)"
echo "hAMRonization report : ${OUTDIR}/reports/hamronization_summarize/hamronization_combined_report.tsv"
echo "AMPcombi summary      : ${OUTDIR}/reports/ampcombi2/Ampcombi_summary.tsv"
echo "COMBGC summary        : ${OUTDIR}/reports/combgc/combgc_complete_summary.tsv (untouched — not regenerated, see Step 3 comment)"
echo "MultiQC report        : ${OUTDIR}/multiqc/multiqc_report.html"
echo "(any of the above may be missing if that screening type wasn't run — check the step log above)"
echo "=========================================="
