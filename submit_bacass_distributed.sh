#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpc
### -- set the job Name --
#BSUB -J bacass_head
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
#BSUB -o bacass_head_%J.out
#BSUB -e bacass_head_%J.err

#==========================================================================
# EDIT THESE BEFORE SUBMITTING
#==========================================================================
INPUT="/path/to/samplesheet.tsv"
OUTDIR="/path/to/results"
ASSEMBLY_TYPE="short"   # short, long, or hybrid
#==========================================================================

# Pipeline directory
BACASS_DIR="/work3/josne/github/bacass"

# Validate user-editable paths
if [ "${INPUT}" = "/path/to/samplesheet.tsv" ]; then
    echo "ERROR: Please edit INPUT in submit_bacass_distributed.sh before submitting."
    exit 1
fi
if [ "${OUTDIR}" = "/path/to/results" ]; then
    echo "ERROR: Please edit OUTDIR in submit_bacass_distributed.sh before submitting."
    exit 1
fi
if [ ! -f "${INPUT}" ]; then
    echo "ERROR: Samplesheet not found: ${INPUT}"
    exit 1
fi

# Always run from BACASS_DIR so .nextflow/ cache is in a consistent location
# (enables -resume to work regardless of where bsub was called from)
cd "${BACASS_DIR}" || exit 1

# Load environment (conda, nextflow, database paths)
source "${BACASS_DIR}/setup.sh"

# Print job information
echo "=========================================="
echo "Bacass Pipeline - Distributed (LSF executor)"
echo "Job started on $(date)"
echo "Head job ID: $LSB_JOBID"
echo "Head node: $(hostname)"
echo "Each process is submitted as a separate LSF job"
echo "Input: ${INPUT}"
echo "Output: ${OUTDIR}"
echo "Assembly type: ${ASSEMBLY_TYPE}"
echo "Kraken2 DB: ${BACASS_KRAKEN2DB}"
echo "Kmerfinder DB: ${BACASS_KMERFINDERDB}"
echo "Bakta DB: ${BACASS_BAKTADB}"
echo "=========================================="

# Run Bacass — LSF executor submits each process as its own bsub job
nextflow run "${BACASS_DIR}" \
    -profile conda \
    -c "${BACASS_DIR}/conf/lsf.config" \
    --input "${INPUT}" \
    --outdir "${OUTDIR}" \
    --assembly_type "${ASSEMBLY_TYPE}" \
    --kraken2db "${BACASS_KRAKEN2DB}" \
    --kmerfinderdb "${BACASS_KMERFINDERDB}" \
    --unicycler_args "--mode bold --no_correct" \
    --annotation_tool bakta \
    --baktadb "${BACASS_BAKTADB}" \
    -resume

EXIT_CODE=$?

# Print completion information
echo "=========================================="
echo "Job finished on $(date)"
echo "Exit code: ${EXIT_CODE}"
echo "=========================================="

exit ${EXIT_CODE}
