#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpc
### -- set the job Name --
#BSUB -J kmerfinder_scan
### -- ask for number of cores --
#BSUB -n 2
### -- all cores on one host --
#BSUB -R "span[hosts=1] rusage[mem=8GB]"
### -- specify that we want the job to get killed if it exceeds 8.4 GB --
### (must stay within 5% of rusage[mem=8GB]=8192MB, i.e. <=8601MB)
#BSUB -M 8400MB
### -- set walltime limit: hh:mm --
#BSUB -W 04:00
### -- set the email address --
#BSUB -u josne@dtu.dk
### -- send notification at start --
#BSUB -B
### -- send notification at completion --
#BSUB -N
### -- Specify the output and error file. %J is the job-id --
#BSUB -o kmerfinder_scan_%J.out
#BSUB -e kmerfinder_scan_%J.err

# ============================================================================
# Runs KmerFinder (species identification/purity QC) on every Bakta-annotated
# assembly FASTA in a bacass OUTDIR, then builds a cross-sample summary.
# Standalone equivalent of the live pipeline's KMERFINDER_KMERFINDER module
# (modules/local/kmerfinder/kmerfinder/main.nf) for projects whose bacass run
# predates the Sep 2026 addition of KmerFinder to the preassembled-genome
# entry point (main_preassembled.nf) — e.g. pseudoalteromonas_seq, whose
# 143-genome bacass run (job 29298421) completed before that addition existed.
#
# Motivation: Bakta's SOURCE/ORGANISM metadata is blank for every sample
# (conf/modules.config's BAKTA_BAKTA ext.args was '' until this same fix) —
# and for NCBI-downloaded preassembled genomes, the alternative organism
# source (NCBI's own submitter-provided Taxonomy column) is frequently
# genus-only ("Halomonas sp. S2151", confirmed on this exact project's real
# data), not a true binomial. KmerFinder's genome-scale k-mer match against a
# curated database is more trustworthy at scale — same rationale already
# applied to vibrio_seq via its own (reads-based) KmerFinder run, see
# kmerfinder_gbk_patch.py in that project.
#
# Uses this repo's own already-built conda env directly — no new external env
# needed, unlike DefenseFinder/PADLOC/geNomad. Mirrors
# modules/local/kmerfinder/kmerfinder/main.nf's exact CLI flags and its
# results.txt/data.json -> <sample>_results.txt/<sample>_data.json rename, so
# output is a drop-in match for kmerfinder_gbk_patch.py's
# parse_kmerfinder_sample_info() (which expects <sample>/<sample>_results.txt)
# and for the live pipeline's own Kmerfinder/<sample>/ publishDir layout.
#
# kmerfinder.py is single-threaded (conf/modules.config: "kmerfinder.py is
# single-threaded Python"), so this runs the same 1-CPU-per-sample workload as
# the live pipeline, just serially in one job (same convention as
# run_genomad_scan.sh/run_defensefinder_scan.sh/run_padloc_scan.sh).
#
# Usage:
#   ./run_kmerfinder_scan.sh <OUTDIR>
#   bsub -q hpc -n 2 -R "span[hosts=1] rusage[mem=8GB]" -M 8400MB -W 04:00 \
#     -o kmerfinder_scan_%J.out -e kmerfinder_scan_%J.err \
#     ./run_kmerfinder_scan.sh <OUTDIR>
#   (bsub < run_kmerfinder_scan.sh doesn't work here -- OUTDIR is a required
#   positional arg, and `bsub <` only parses the #BSUB header, it can't pass
#   one; see CLAUDE.md's "Submitting via bsub" note for the same caveat on
#   the other standalone scan/aggregation scripts)
# ============================================================================

set -euo pipefail

BACASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <OUTDIR>"
    echo "  OUTDIR   Bacass results directory containing Bakta/<sample>/<sample>.fna"
    exit 1
}

[ $# -ge 1 ] || usage
OUTDIR="$(cd "$1" 2>/dev/null && pwd)" || { echo "ERROR: OUTDIR '$1' does not exist or is not a directory"; exit 1; }

KMERFINDER_ENV="${BACASS_DIR}/.conda_envs/env-21843fa86453d47af56b2c980ee644d7"
KMERFINDER_DB="${BACASS_DIR}/assets/databases/kmerfinder_20190108_stable_dirs/bacteria"
DB_ATG="${KMERFINDER_DB}/bacteria.ATG"

[ -x "${KMERFINDER_ENV}/bin/kmerfinder.py" ] || { echo "ERROR: kmerfinder.py not found in ${KMERFINDER_ENV}"; exit 1; }
[ -x "${KMERFINDER_ENV}/bin/kma" ] || { echo "ERROR: kma not found in ${KMERFINDER_ENV}"; exit 1; }
[ -f "${DB_ATG}.name" ] || { echo "ERROR: Kmerfinder DB not found at ${DB_ATG}"; exit 1; }
[ -d "${OUTDIR}/Bakta" ] || { echo "ERROR: ${OUTDIR}/Bakta not found"; exit 1; }

# kmerfinder.py invokes kma as a bare command, not via absolute path -- same class of fix as
# run_defensefinder_scan.sh's hmmsearch and run_padloc_scan.sh's hmmsearch/Rscript. Without this,
# it dies immediately with "Error: No valid path to a kma program was provided."
export PATH="${KMERFINDER_ENV}/bin:${PATH}"

# Same tax-file fallback order as modules/local/kmerfinder/kmerfinder/main.nf
DB="${KMERFINDER_DB}/bacteria"
if [ -f "${DB}.tax" ]; then
    DB_TAX_FILE="${DB}.tax"
elif [ -f "${DB}.name" ]; then
    DB_TAX_FILE="${DB}.name"
else
    DB_TAX_FILE="${DB_ATG}.name"
fi

mapfile -t ASSEMBLIES < <(find "${OUTDIR}/Bakta" -mindepth 2 -maxdepth 2 -name "*.fna" | sort)
echo "=========================================="
echo "KmerFinder scan"
echo "Job started on $(date)"
echo "OUTDIR: ${OUTDIR}"
echo "Assemblies found: ${#ASSEMBLIES[@]}"
echo "Tax file: ${DB_TAX_FILE}"
echo "=========================================="
if [ "${#ASSEMBLIES[@]}" -eq 0 ]; then
    echo "ERROR: no assembly FASTAs found in ${OUTDIR}/Bakta/*/"
    exit 1
fi

KF_OUT="${OUTDIR}/Kmerfinder"
mkdir -p "${KF_OUT}"

i=0
for asm in "${ASSEMBLIES[@]}"; do
    i=$((i + 1))
    sample="$(basename "${asm}" .fna)"
    echo ""
    echo "=== Sample ${i}/${#ASSEMBLIES[@]}: ${sample} ==="

    if [ -f "${KF_OUT}/${sample}/${sample}_results.txt" ]; then
        echo "Already scanned, skipping"
        continue
    fi

    mkdir -p "${KF_OUT}/${sample}"
    "${KMERFINDER_ENV}/bin/kmerfinder.py" \
        --infile "${asm}" \
        --output_folder "${KF_OUT}/${sample}" \
        --db_path "${DB_ATG}" \
        -tax "${DB_TAX_FILE}" \
        -x

    mv "${KF_OUT}/${sample}/results.txt" "${KF_OUT}/${sample}/${sample}_results.txt"
    mv "${KF_OUT}/${sample}/data.json" "${KF_OUT}/${sample}/${sample}_data.json"
done

# ============================================================
# Build cross-sample summary (reuses the live pipeline's own summary script —
# pure stdlib, no conda env needed)
# ============================================================
echo ""
echo "=== Building cross-sample summary ==="

SUMMARY_STAGING=$(mktemp -d)
trap 'rm -rf "${SUMMARY_STAGING}"' EXIT
for asm in "${ASSEMBLIES[@]}"; do
    sample="$(basename "${asm}" .fna)"
    [ -f "${KF_OUT}/${sample}/${sample}_results.txt" ] && ln -s "${KF_OUT}/${sample}/${sample}_results.txt" "${SUMMARY_STAGING}/"
done

python3 "${BACASS_DIR}/bin/kmerfinder_summary.py" \
    --path "${SUMMARY_STAGING}/" \
    --output_bn "${KF_OUT}/kmerfinder.bn" \
    --output_csv "${KF_OUT}/kmerfinder_summary.csv"

echo ""
echo "=========================================="
echo "Done on $(date)"
echo "Per-sample KmerFinder output: ${KF_OUT}/<sample>/"
echo "Cross-sample summary: ${KF_OUT}/kmerfinder_summary.csv"
echo "=========================================="
