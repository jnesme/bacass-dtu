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

# Screening modules — set to "true" or "false"
RUN_BGC="true"   # BGC: antiSMASH, DeepBGC, GECCO
RUN_AMP="true"   # AMP: ampir, amplify, macrel, AMPcombi2
RUN_ARG="true"   # ARG: ABRicate, AMRFinderPlus, DeepARG, fARGene, RGI
#==========================================================================

# Project directory — reuses setup.sh for conda/nextflow
# Exported so funcscan_overrides.config can resolve environment YAML paths
export BACASS_DIR="/work3/josne/github/bacass"

#==========================================================================
# DATABASE PATHS
# antiSMASH is required when RUN_BGC=true and must be pre-downloaded.
# All others: leave empty to auto-download on first run (needs internet on
# compute nodes), or pre-download to assets/databases/ and set the path here.
# With -resume, downloaded DBs are cached in work_funcscan/ and reused.
#
#   DeepBGC:       deepbgc download                   (~100 MB)
#   CARD (RGI):    https://card.mcmaster.ca/latest/data (~200 MB)
#   AMRFinderPlus: amrfinder_update                   (~30 MB)
#   DeepARG:       deeparg download_data              (~300 MB)
#   AMPcombi2:     DRAMP database                     (~100 MB)
#==========================================================================
ANTISMASH_DB="${BACASS_DIR}/assets/databases/antismash_db"
DEEPBGC_DB=""        # empty = auto-download via deepbgc download
CARD_DB=""           # empty = auto-download from card.mcmaster.ca (for RGI)
AMRFINDER_DB=""      # empty = auto-update from NCBI
DEEPARG_DB=""        # empty = auto-download via deeparg download_data
AMPCOMBI_DB=""       # empty = auto-download DRAMP database

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
if [ "${RUN_BGC}" = "true" ] && [ ! -d "${ANTISMASH_DB}" ]; then
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

# Build screening flags
NF_SCREENING=""
[ "${RUN_BGC}" = "true" ] && NF_SCREENING="${NF_SCREENING} --run_bgc_screening --bgc_antismash_db ${ANTISMASH_DB} --bgc_antismash_taxon bacteria"
[ "${RUN_AMP}" = "true" ] && NF_SCREENING="${NF_SCREENING} --run_amp_screening"
[ "${RUN_ARG}" = "true" ] && NF_SCREENING="${NF_SCREENING} --run_arg_screening"

# Pass pre-downloaded DB paths if set; otherwise funcscan auto-downloads at runtime
NF_DBS=""
[ -n "${DEEPBGC_DB}" ]   && NF_DBS="${NF_DBS} --bgc_deepbgc_db ${DEEPBGC_DB}"
[ -n "${CARD_DB}" ]      && NF_DBS="${NF_DBS} --arg_rgi_db ${CARD_DB}"
[ -n "${AMRFINDER_DB}" ] && NF_DBS="${NF_DBS} --arg_amrfinderplus_db ${AMRFINDER_DB}"
[ -n "${DEEPARG_DB}" ]   && NF_DBS="${NF_DBS} --arg_deeparg_db ${DEEPARG_DB}"
[ -n "${AMPCOMBI_DB}" ]  && NF_DBS="${NF_DBS} --amp_ampcombi_db ${AMPCOMBI_DB}"

# Print job information
echo "=========================================="
echo "Funcscan Pipeline — Distributed (LSF executor)"
echo "Job started on $(date)"
echo "Head job ID: $LSB_JOBID"
echo "Head node: $(hostname)"
echo "Each process is submitted as a separate LSF job"
echo "Input:      ${INPUT}"
echo "Output:     ${OUTDIR}"
echo "Work dir:   ${FUNCSCAN_WORK}"
echo "Conda cache: ${NXF_CONDA_CACHEDIR}"
echo "BGC screening: ${RUN_BGC}"
echo "AMP screening: ${RUN_AMP}"
echo "ARG screening: ${RUN_ARG}"
echo "=========================================="

# Run nf-core/funcscan v3.0.0 — LSF executor submits each process as its own bsub job
#
# Portability notes:
#   - Pipeline code: cached in $NXF_HOME/assets/nf-core/funcscan/ (pinned by -r)
#   - Conda envs: shared cache in $NXF_CONDA_CACHEDIR (.conda_envs/), built once
#   - Databases: antiSMASH pre-downloaded; others auto-download on first run
#                (cached in work_funcscan/ and reused via -resume)
#   - Work dir: separate from bacass, supports -resume across runs
#
# Pre-annotated input (Bakta .gbff + .faa) → funcscan skips annotation
#
# Launch from a temp directory to avoid bacass's nextflow.config
# interfering with funcscan's samplesheet validation
LAUNCH_DIR=$(mktemp -d)
cd "${LAUNCH_DIR}"

# shellcheck disable=SC2086
nextflow run nf-core/funcscan \
    -r 3.0.0 \
    -profile conda \
    -c "${BACASS_DIR}/conf/lsf.config" \
    -c "${BACASS_DIR}/conf/funcscan_overrides.config" \
    -w "${FUNCSCAN_WORK}" \
    -resume \
    --input "${INPUT}" \
    --outdir "${OUTDIR}" \
    ${NF_SCREENING} \
    ${NF_DBS}

EXIT_CODE=$?

cd "${BACASS_DIR}"
rm -rf "${LAUNCH_DIR}"

echo "=========================================="
echo "Job finished on $(date)"
echo "Exit code: ${EXIT_CODE}"
echo "=========================================="

exit ${EXIT_CODE}
