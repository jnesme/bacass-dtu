#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpc
### -- set the job Name --
#BSUB -J bacass_aggregation
### -- ask for number of cores (8 for QUAST parallelism) --
#BSUB -n 8
### -- all cores on one host, 6 GB per core (8 x 6 GB = 48 GB) --
#BSUB -R "span[hosts=1] rusage[mem=6GB]"
### -- specify that we want the job to get killed if it exceeds 6.5 GB per core/slot --
#BSUB -M 6500MB
### -- set walltime limit: hh:mm --
#BSUB -W 02:00
### -- set the email address --
#BSUB -u josne@dtu.dk
### -- send notification at start --
#BSUB -B
### -- send notification at completion --
#BSUB -N
### -- Specify the output and error file. %J is the job-id --
#BSUB -o bacass_aggregation_%J.out
#BSUB -e bacass_aggregation_%J.err

# ============================================================================
# Regenerates bacass's two aggregation results — Kmerfinder summary and
# MultiQC report — directly from a results OUTDIR, outside Nextflow. QUAST is
# included too since the pipeline always runs it across every assembly at
# once (same collect-everything pattern). Needed because a batch's raw reads
# and work dir can be deleted after the fact, at which point Nextflow can
# never resume/regenerate these for it again — this script reads only
# published outputs, so it still works.
#
# Usage:
#   ./run_bacass_aggregation.sh <OUTDIR> [assembly_type]
#   bsub < run_bacass_aggregation.sh  (edit OUTDIR below first)
# ============================================================================

set -euo pipefail

BACASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <OUTDIR> [assembly_type]"
    echo "  OUTDIR         Bacass results directory (e.g. Bacass_results)"
    echo "  assembly_type  Optional, passed to multiqc_to_custom_csv.py (default: short)"
    exit 1
}

[ $# -ge 1 ] || usage
OUTDIR="$(cd "$1" 2>/dev/null && pwd)" || { echo "ERROR: OUTDIR '$1' does not exist or is not a directory"; exit 1; }
ASSEMBLY_TYPE="${2:-short}"

# --- Resolve conda envs (before sourcing setup.sh, so failures are cheap) ---
QUAST_ENV="${BACASS_DIR}/.conda_envs/env-64b03f4592c4fb360664f065698df4dd"
[ -x "${QUAST_ENV}/bin/quast.py" ] || { echo "ERROR: QUAST env not found at ${QUAST_ENV}"; exit 1; }

MULTIQC_ENV=""
for env_hash in env-55e377717f27765e46a811a08ed80f85 env-9226b7757fc400d6e95dcf4e13d34338; do
    env_path="${BACASS_DIR}/.conda_envs/${env_hash}"
    if "${env_path}/bin/multiqc" --version 2>&1 | grep -q "1\.19"; then
        MULTIQC_ENV="${env_path}"
        break
    fi
done
if [ -z "${MULTIQC_ENV}" ]; then
    echo "ERROR: Could not find MultiQC 1.19 conda env in .conda_envs/"
    exit 1
fi
# kmerfinder_summary.py and csv_to_yaml.py are stdlib-only, and
# modules/local/kmerfinder/summary/environment.yml is byte-identical to
# modules/local/custom/multiqc/environment.yml (verified via diff) — same
# conda cache hash, so MULTIQC_ENV/bin/python is reused for both.

# --- Validate inputs ---
if [ ! -d "${OUTDIR}/Unicycler" ]; then
    echo "ERROR: ${OUTDIR}/Unicycler not found"
    exit 1
fi
if [ ! -d "${OUTDIR}/Kmerfinder" ]; then
    echo "ERROR: ${OUTDIR}/Kmerfinder not found"
    exit 1
fi

# Load base environment (conda, database paths)
source "${BACASS_DIR}/setup.sh"

echo "=========================================="
echo "Bacass aggregation re-run"
echo "Job started on $(date)"
echo "Job ID: ${LSB_JOBID:-N/A}"
echo "Running on node: $(hostname)"
echo "OUTDIR: ${OUTDIR}"
echo "=========================================="
echo "QUAST env   : ${QUAST_ENV}"
echo "MultiQC env : ${MULTIQC_ENV}"

# ============================================================
# Step 1: QUAST — one run across every assembly found
# ============================================================
echo ""
echo "=== Step 1: Running QUAST ==="

QUAST_OUT="${OUTDIR}/QUAST/report"
mkdir -p "${QUAST_OUT}"

mapfile -t FASTAS < <(find "${OUTDIR}/Unicycler" -name "*.scaffolds.fa.gz" | sort)
echo "Found ${#FASTAS[@]} assemblies"
if [ "${#FASTAS[@]}" -eq 0 ]; then
    echo "ERROR: No *.scaffolds.fa.gz files found in ${OUTDIR}/Unicycler/"
    exit 1
fi

"${QUAST_ENV}/bin/quast.py" \
    "${FASTAS[@]}" \
    -t "${LSB_MAX_NUM_PROCESSORS:-8}" \
    -o "${QUAST_OUT}"

echo "QUAST done → ${QUAST_OUT}/report.html"

# ============================================================
# Step 2: Regenerate Kmerfinder summary from raw per-sample files
# Always regenerated from scratch (not reusing any pre-existing CSV) so a
# combined report over a merged multi-batch OUTDIR reflects every sample
# actually present, not just whichever batch produced an existing CSV first.
# ============================================================
echo ""
echo "=== Step 2: Regenerating Kmerfinder summary ==="

KF_STAGING=$(mktemp -d)
MQ_STAGING=""
cleanup() { rm -rf "${KF_STAGING}" "${MQ_STAGING}"; }
trap cleanup EXIT

mkdir -p "${KF_STAGING}/reports"

mapfile -t KF_RESULTS < <(find "${OUTDIR}/Kmerfinder" -mindepth 2 -maxdepth 2 -name "*_results.txt" | sort)
echo "Found ${#KF_RESULTS[@]} Kmerfinder result files"
if [ "${#KF_RESULTS[@]}" -eq 0 ]; then
    echo "ERROR: No <sample>_results.txt files found under ${OUTDIR}/Kmerfinder/<sample>/"
    exit 1
fi

for f in "${KF_RESULTS[@]}"; do
    ln -s "${f}" "${KF_STAGING}/reports/$(basename "${f}")"
done

"${MULTIQC_ENV}/bin/python" "${BACASS_DIR}/bin/kmerfinder_summary.py" \
    --path "${KF_STAGING}/reports/" \
    --output_bn "${KF_STAGING}/kmerfinder.bn" \
    --output_csv "${KF_STAGING}/kmerfinder_summary.csv"

cp "${KF_STAGING}/kmerfinder_summary.csv" "${KF_STAGING}/kmerfinder.bn" "${OUTDIR}/Kmerfinder/"
echo "Kmerfinder summary regenerated → ${OUTDIR}/Kmerfinder/kmerfinder_summary.csv"

# ============================================================
# Step 3: MultiQC staging
# Mirrors the directory layout that CUSTOM_MULTIQC creates in its
# Nextflow work dir, so path_filters in multiqc_config_short.yml match.
# ============================================================
echo ""
echo "=== Step 3: Setting up MultiQC staging ==="

MQ_STAGING=$(mktemp -d)
echo "Staging dir: ${MQ_STAGING}"

mkdir -p "${MQ_STAGING}/quast"
ln -s "${QUAST_OUT}" "${MQ_STAGING}/quast/report"

[ -d "${OUTDIR}/FastQC/raw" ]  && ln -s "${OUTDIR}/FastQC/raw"  "${MQ_STAGING}/fastqc"
[ -d "${OUTDIR}/FastQC/trim" ] && ln -s "${OUTDIR}/FastQC/trim" "${MQ_STAGING}/fastqc_trim"
[ -d "${OUTDIR}/trimming" ]    && ln -s "${OUTDIR}/trimming"    "${MQ_STAGING}/fastp"
[ -d "${OUTDIR}/Kraken2" ]     && ln -s "${OUTDIR}/Kraken2"     "${MQ_STAGING}/kraken2_short"
[ -d "${OUTDIR}/busco" ]       && ln -s "${OUTDIR}/busco"       "${MQ_STAGING}/busco"
[ -d "${OUTDIR}/Bakta" ]       && ln -s "${OUTDIR}/Bakta"       "${MQ_STAGING}/bakta"

cp "${BACASS_DIR}/assets/multiqc_config_short.yml" "${MQ_STAGING}/multiqc_config.yaml"

# ============================================================
# Step 4: Kmerfinder YAML for MultiQC (from the regenerated CSV)
# ============================================================
echo ""
echo "=== Step 4: Generating kmerfinder MultiQC YAML ==="

mkdir -p "${MQ_STAGING}/extra"
(
    cd "${MQ_STAGING}/extra"
    "${MULTIQC_ENV}/bin/python" "${BACASS_DIR}/bin/csv_to_yaml.py" \
        -i "${OUTDIR}/Kmerfinder/kmerfinder_summary.csv" \
        -k 'sample_name' \
        -op multiqc_kmerfinder
)
echo "kmerfinder YAML: ${MQ_STAGING}/extra/multiqc_kmerfinder.yaml"

# ============================================================
# Step 5: Two-pass MultiQC (replicates CUSTOM_MULTIQC's script block)
# ============================================================
cd "${MQ_STAGING}"

echo ""
echo "=== Step 5: MultiQC pass 1 ==="
"${MULTIQC_ENV}/bin/multiqc" -f -k yaml -c multiqc_config.yaml .

if [ -d extra/ ]; then
    cp extra/* multiqc_data/
fi

echo ""
echo "=== Step 6: Generating assembly metrics CSV ==="
"${MULTIQC_ENV}/bin/python" "${BACASS_DIR}/bin/multiqc_to_custom_csv.py" \
    --assembly_type "${ASSEMBLY_TYPE}"

echo ""
echo "=== Step 7: MultiQC pass 2 ==="
"${MULTIQC_ENV}/bin/multiqc" -f -k yaml -c multiqc_config.yaml .

# ============================================================
# Step 8: Publish
# ============================================================
echo ""
echo "=== Step 8: Publishing results ==="

MULTIQC_OUT="${OUTDIR}/multiqc"
mkdir -p "${MULTIQC_OUT}"

cp -r "${MQ_STAGING}/"*multiqc_report.html       "${MULTIQC_OUT}/"
cp -r "${MQ_STAGING}/"*_data                     "${MULTIQC_OUT}/"
cp -r "${MQ_STAGING}/"*_plots                    "${MULTIQC_OUT}/" 2>/dev/null || true
cp    "${MQ_STAGING}/"*_assembly_metrics_mqc.csv "${MULTIQC_OUT}/" 2>/dev/null || true

echo ""
echo "=========================================="
echo "Done on $(date)"
echo "QUAST report      : ${QUAST_OUT}/report.html"
echo "Kmerfinder summary: ${OUTDIR}/Kmerfinder/kmerfinder_summary.csv"
echo "MultiQC report    : ${MULTIQC_OUT}/multiqc_report.html"
echo "=========================================="
