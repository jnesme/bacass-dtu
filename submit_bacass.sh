#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpc
### -- set the job Name --
#BSUB -J bacass_pipeline
### -- ask for number of cores --
#BSUB -n 20
### -- all cores on one host, 6GB per core (20 x 6GB = 120GB < 128GB node limit) --
#BSUB -R "span[hosts=1] rusage[mem=6GB]"
### -- specify that we want the job to get killed if it exceeds 6.5GB per core/slot --
#BSUB -M 6500MB
### -- set walltime limit: hh:mm --
#BSUB -W 48:00
### -- set the email address --
#BSUB -u josne@dtu.dk
### -- send notification at start --
#BSUB -B
### -- send notification at completion --
#BSUB -N
### -- Specify the output and error file. %J is the job-id --
#BSUB -o bacass_%J.out
#BSUB -e bacass_%J.err

#==========================================================================
# EDIT THESE BEFORE SUBMITTING
#==========================================================================
INPUT="/work3/josne/Projects/Vibrio_Galathea3/vibrio_seq/test5.samplesheet.tsv"
OUTDIR="/work3/josne/github/bacass/results"
ASSEMBLY_TYPE="short"   # short, long, or hybrid
#==========================================================================

# Pipeline directory
BACASS_DIR="/work3/josne/github/bacass"

# Validate user-editable paths
if [ "${INPUT}" = "/path/to/samplesheet.tsv" ]; then
    echo "ERROR: Please edit INPUT in submit_bacass.sh before submitting."
    exit 1
fi
if [ "${OUTDIR}" = "/path/to/results" ]; then
    echo "ERROR: Please edit OUTDIR in submit_bacass.sh before submitting."
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
echo "Bacass Pipeline - Single Node"
echo "Job started on $(date)"
echo "Job ID: $LSB_JOBID"
echo "Running on node: $(hostname)"
echo "Total memory reserved: 120GB (20 cores x 6GB)"
echo "Input: ${INPUT}"
echo "Output: ${OUTDIR}"
echo "Assembly type: ${ASSEMBLY_TYPE}"
echo "Kraken2 DB: ${BACASS_KRAKEN2DB}"
echo "Kmerfinder DB: ${BACASS_KMERFINDERDB}"
echo "Bakta DB: ${BACASS_BAKTADB}"
echo "=========================================="

# Run Bacass
nextflow run "${BACASS_DIR}" \
    -resume \
    -profile conda \
    --input "${INPUT}" \
    --outdir "${OUTDIR}" \
    --assembly_type "${ASSEMBLY_TYPE}" \
    --kraken2db "${BACASS_KRAKEN2DB}" \
    --kmerfinderdb "${BACASS_KMERFINDERDB}" \
    --annotation_tool bakta \
    --baktadb "${BACASS_BAKTADB}"

EXIT_CODE=$?

# Print completion information
echo "=========================================="
echo "Job finished on $(date)"
echo "Exit code: ${EXIT_CODE}"
echo "=========================================="

exit ${EXIT_CODE}
