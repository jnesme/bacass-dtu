#!/usr/bin/env bash
# ============================================================================
# Bacass portable environment setup
# Source this file to configure your shell for running the bacass pipeline.
#
# Usage:
#   source /work3/josne/github/bacass/setup.sh
#
# Then run the pipeline:
#   nextflow run /work3/josne/github/bacass -profile conda [options]
#
# First run will build conda environments (~30-60 min). Subsequent runs
# reuse the cached environments instantly.
# ============================================================================

# Resolve the directory where this script lives (works even if sourced)
BACASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Conda + Nextflow ---
# Source conda init, then activate the bacass env (provides nextflow)
source /work3/josne/miniconda3/etc/profile.d/conda.sh
conda activate /work3/josne/miniconda3/envs/bacass

# --- Conda cache directory (shared, inside the project) ---
export NXF_CONDA_CACHEDIR="${BACASS_DIR}/.conda_envs"
mkdir -p "${NXF_CONDA_CACHEDIR}"

# --- Databases ---
export BACASS_KRAKEN2DB="${BACASS_DIR}/assets/databases/minikraken2_v2_8GB_201904_UPDATE"
export BACASS_KMERFINDERDB="${BACASS_DIR}/assets/databases/kmerfinder_20190108_stable_dirs/bacteria"
export BACASS_BAKTADB="${BACASS_DIR}/assets/databases/bakta_db"

# --- LSF shadow config ---
# Nextflow 25.x auto-detects LSB_JOB_MEMLIMIT=Y from the system lsf.conf and
# internally overrides perJobMemLimit=false, causing rusage[mem=X] to not be
# divided by CPUs (e.g. 16 CPUs × 40 GB = 640 GB reservation instead of 40 GB).
# Fix: generate a shadow lsf.conf identical to the system one except
# LSB_JOB_MEMLIMIT=N, then point LSF_ENVDIR at it so Nextflow sees N.
# bsub/bjobs still work correctly because all other paths in the shadow
# lsf.conf (LSF_CONFDIR, LSB_CONFDIR, etc.) still point to the real system dirs.
mkdir -p "${BACASS_DIR}/conf/lsf_shadow"
sed 's/LSB_JOB_MEMLIMIT=Y/LSB_JOB_MEMLIMIT=N/' /lsf/conf/lsf.conf \
    > "${BACASS_DIR}/conf/lsf_shadow/lsf.conf"
export LSF_ENVDIR="${BACASS_DIR}/conf/lsf_shadow"

# --- Nextflow settings ---
# Keep Nextflow home (pulled pipelines, plugins) inside the project
export NXF_HOME="${BACASS_DIR}/.nextflow_home"
mkdir -p "${NXF_HOME}"
# Keep work directory inside the project for portability
export NXF_WORK="${NXF_WORK:-${BACASS_DIR}/work}"

# Offline mode: uncomment to prevent Nextflow from fetching remote configs
# export NXF_OFFLINE=true

# --- Summary ---
echo "============================================"
echo " Bacass pipeline environment loaded"
echo "============================================"
echo " NXF_HOME      : ${NXF_HOME}"
echo " Pipeline dir  : ${BACASS_DIR}"
echo " Conda cache   : ${NXF_CONDA_CACHEDIR}"
echo " Work dir      : ${NXF_WORK}"
echo " Kraken2 DB    : ${BACASS_KRAKEN2DB}"
echo " Kmerfinder DB : ${BACASS_KMERFINDERDB}"
echo " Bakta DB      : ${BACASS_BAKTADB}"
echo " Nextflow      : $(nextflow -version 2>&1 | grep 'version' | head -1)"
echo " Conda         : $(conda --version 2>&1)"
echo "============================================"
echo ""
echo " Run example:"
echo "   nextflow run ${BACASS_DIR} -profile conda --input samplesheet.csv --outdir results \\"
echo "     --kraken2db \${BACASS_KRAKEN2DB} --kmerfinderdb \${BACASS_KMERFINDERDB} \\"
echo "     --annotation_tool bakta --baktadb \${BACASS_BAKTADB}"
echo ""
