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

# --- Short-circuit `conda info --json` (BeeGFS ENOENT mitigation) ---
# Nextflow runs `conda info --json` during conda-profile activation to discover
# the conda base prefix. That call imports ~50 conda Python modules — under
# BeeGFS metadata pressure, any spurious ENOENT during those imports crashes
# conda silently → Nextflow's awk extracts nothing → activation line becomes
# `source /bin/activate /env`, which fails with "/bin/activate: No such file
# or directory". This bash function returns hardcoded JSON without invoking
# Python. All other `conda` invocations fall through to the real binary via
# `command conda`. Lives in setup.sh (not in /work3/josne/miniconda3/bin/conda
# as previous patches did) so a `conda update` cannot revert it.
conda() {
    if [ "$1" = "info" ] && [ "$2" = "--json" ]; then
        printf '{"conda_prefix": "/work3/josne/miniconda3", "root_prefix": "/work3/josne/miniconda3"}\n'
        return 0
    fi
    command conda "$@"
}
export -f conda

# --- Conda cache directory (shared, inside the project) ---
export NXF_CONDA_CACHEDIR="${BACASS_DIR}/.conda_envs"
mkdir -p "${NXF_CONDA_CACHEDIR}"

# --- Databases ---
export BACASS_KRAKEN2DB="${BACASS_DIR}/assets/databases/minikraken2_v2_8GB_201904_UPDATE"
export BACASS_KMERFINDERDB="${BACASS_DIR}/assets/databases/kmerfinder_20190108_stable_dirs/bacteria"
export BACASS_BAKTADB="${BACASS_DIR}/assets/databases/bakta_db"
export BACASS_BUSCODB="${BACASS_DIR}/assets/databases/busco_db"

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

# --- UNCHECKED_HASH bytecode self-heal (BeeGFS ENOENT mitigation) ---
# Python's default .pyc validation calls stat() on the .py source at every
# import — a small operation that becomes problematic on BeeGFS at scale (80+
# concurrent jobs each doing dozens of imports). UNCHECKED_HASH-flagged .pyc
# files skip the source check entirely. recompile_pyc.sh applies this to all
# conda envs; per-env marker files make repeat invocations cheap. New envs
# (e.g. after a conda env rebuild) are recompiled automatically.
if [ -x "${BACASS_DIR}/bin/recompile_pyc.sh" ]; then
    needs_recompile=0
    [ -f /work3/josne/miniconda3/.unchecked_hash_applied ] || needs_recompile=1
    if [ "${needs_recompile}" = "0" ]; then
        for env_dir in "${BACASS_DIR}"/.conda_envs/env-*; do
            [ -d "${env_dir}" ] || continue
            # Only count envs that have a python3.X interpreter (otherwise the
            # recompile script will skip them — no marker expected).
            ls "${env_dir}/bin/" 2>/dev/null | grep -qE '^python3\.[0-9]+$' || continue
            [ -f "${env_dir}/.unchecked_hash_applied" ] || { needs_recompile=1; break; }
        done
    fi
    if [ "${needs_recompile}" = "1" ]; then
        echo "Recompiling .pyc bytecaches with UNCHECKED_HASH (one-time per env)..."
        "${BACASS_DIR}/bin/recompile_pyc.sh"
    fi
fi

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
echo " BUSCO DB      : ${BACASS_BUSCODB}"
echo " Nextflow      : $(nextflow -version 2>&1 | grep 'version' | head -1)"
echo " Conda         : $(conda --version 2>&1)"
echo "============================================"
echo ""
echo " Run example:"
echo "   nextflow run ${BACASS_DIR} -profile conda --input samplesheet.csv --outdir results \\"
echo "     --kraken2db \${BACASS_KRAKEN2DB} --kmerfinderdb \${BACASS_KMERFINDERDB} \\"
echo "     --annotation_tool bakta --baktadb \${BACASS_BAKTADB}"
echo ""
