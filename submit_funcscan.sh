#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpc
### -- set the job Name --
#BSUB -J funcscan_head
### -- head process only needs minimal resources --
#BSUB -n 1
#BSUB -R "rusage[mem=4GB]"
#BSUB -M 4500MB
### -- set walltime limit: hh:mm --
#BSUB -W 72:00
### -- set the email address --
#BSUB -u josne@dtu.dk
### -- send notification at start --
#BSUB -B
### -- send notification at completion --
#BSUB -N
### -- Specify the output and error file. %J is the job-id --
#BSUB -o funcscan_head_%J.out
#BSUB -e funcscan_head_%J.err

#==========================================================================
# EDIT THESE BEFORE SUBMITTING
#==========================================================================
INPUT="funcscan_samplesheet.csv"           # <-- from bacass_to_funcscan.sh
OUTDIR="/path/to/results_funcscan"
#==========================================================================

# Project directory — reuses setup.sh for conda/nextflow
# Exported so funcscan_overrides.config can resolve environment YAML paths
export BACASS_DIR="/work3/josne/github/bacass"

# Database paths (downloaded once, reused across runs)
ANTISMASH_DB="${BACASS_DIR}/assets/databases/antismash_db"

# Separate work directory so funcscan doesn't collide with bacass
FUNCSCAN_WORK="${BACASS_DIR}/work_funcscan"

# Resolve INPUT to absolute path (we cd to a temp dir before launching)
INPUT="$(realpath "${INPUT}")"

# Validate inputs
if [ "${OUTDIR}" = "/path/to/results_funcscan" ]; then
    echo "ERROR: Please edit OUTDIR in submit_funcscan.sh before submitting."
    exit 1
fi
if [ ! -f "${INPUT}" ]; then
    echo "ERROR: Samplesheet not found: ${INPUT}"
    echo "Generate it first: ./bacass_to_funcscan.sh <bacass_results_dir>"
    exit 1
fi
if [ ! -d "${ANTISMASH_DB}" ]; then
    echo "ERROR: antiSMASH database not found: ${ANTISMASH_DB}"
    echo "Download it once with:"
    echo "  source ${BACASS_DIR}/setup.sh"
    echo "  conda create -p ${BACASS_DIR}/.conda_envs/antismash_setup antismash"
    echo "  conda activate ${BACASS_DIR}/.conda_envs/antismash_setup"
    echo "  download-antismash-databases --database-dir ${ANTISMASH_DB}"
    echo "  conda deactivate"
    exit 1
fi

# Load environment (conda, nextflow, NXF_CONDA_CACHEDIR)
source "${BACASS_DIR}/setup.sh"

# Print job information
echo "=========================================="
echo "Funcscan Pipeline — Distributed (LSF executor)"
echo "BGC + AMP + ARG screening"
echo "Job started on $(date)"
echo "Head job ID: $LSB_JOBID"
echo "Head node: $(hostname)"
echo "Each process is submitted as a separate LSF job"
echo "Input: ${INPUT}"
echo "Output: ${OUTDIR}"
echo "antiSMASH DB: ${ANTISMASH_DB}"
echo "Work dir: ${FUNCSCAN_WORK}"
echo "Conda cache: ${NXF_CONDA_CACHEDIR}"
echo "=========================================="

# Run nf-core/funcscan v3.0.0 — LSF executor submits each process as its own bsub job
#
# Portability notes:
#   - Pipeline code: cached in $NXF_HOME/assets/nf-core/funcscan/ (pinned by -r)
#   - Conda envs: shared cache in $NXF_CONDA_CACHEDIR (.conda_envs/), built once
#   - Databases: local in assets/databases/, passed by path, never re-downloaded
#   - Work dir: separate from bacass, supports -resume across runs
#
# Pre-annotated input (Bakta .gbff + .faa) → funcscan skips annotation
#
# Screening modules:
#   --run_bgc_screening : antiSMASH, DeepBGC, GECCO
#   --run_amp_screening : ampir, amplify, macrel, hmmsearch
#   --run_arg_screening : ABRicate, AMRFinderPlus, DeepARG, fARGene, RGI
#
# Launch from a temp directory to avoid bacass's nextflow.config
# interfering with funcscan's samplesheet validation
LAUNCH_DIR=$(mktemp -d)
cd "${LAUNCH_DIR}"

nextflow run nf-core/funcscan \
    -r 3.0.0 \
    -profile conda \
    -c "${BACASS_DIR}/conf/lsf.config" \
    -c "${BACASS_DIR}/conf/funcscan_overrides.config" \
    -w "${FUNCSCAN_WORK}" \
    -resume \
    --input "${INPUT}" \
    --outdir "${OUTDIR}" \
    --run_bgc_screening \
    --bgc_antismash_db "${ANTISMASH_DB}" \
    --bgc_antismash_taxon 'bacteria' \
    --run_amp_screening \
    --run_arg_screening

EXIT_CODE=$?

cd "${BACASS_DIR}"
rm -rf "${LAUNCH_DIR}"

echo "=========================================="
echo "Job finished on $(date)"
echo "Exit code: ${EXIT_CODE}"
echo "=========================================="

exit ${EXIT_CODE}
