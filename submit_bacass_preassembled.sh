#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpc
### -- set the job Name --
#BSUB -J bacass_preassembled
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
#BSUB -o bacass_preassembled_%J.out
#BSUB -e bacass_preassembled_%J.err

#==========================================================================
# EDIT THESE BEFORE SUBMITTING
#==========================================================================
INPUT="/work3/josne/Projects/Vibrio_Galathea3/pseudoalteromonas_seq/samplesheet_preassembled.csv"
OUTDIR="/work3/josne/Projects/Vibrio_Galathea3/pseudoalteromonas_seq/bacass_results"
#==========================================================================

# Pipeline directory
BACASS_DIR="/work3/josne/github/bacass"

# Validate user-editable paths
if [ ! -f "${INPUT}" ]; then
    echo "ERROR: Samplesheet not found: ${INPUT}"
    echo "Generate it first with: bin/download_ncbi_assemblies.py -f <assembly_details.txt> -o <out_dir>"
    exit 1
fi

# Always run from BACASS_DIR so .nextflow/ cache is in a consistent location
# (enables -resume to work regardless of where bsub was called from)
cd "${BACASS_DIR}" || exit 1

# Load environment (conda, nextflow, database paths)
source "${BACASS_DIR}/setup.sh"

# Print job information
echo "=========================================="
echo "Bacass Pipeline - Preassembled genomes, single node"
echo "Job started on $(date)"
echo "Job ID: $LSB_JOBID"
echo "Running on node: $(hostname)"
echo "Total memory reserved: 120GB (20 cores x 6GB)"
echo "Input: ${INPUT}"
echo "Output: ${OUTDIR}"
echo "Bakta DB: ${BACASS_BAKTADB}"
echo "=========================================="

# Run Bacass — preassembled-genome entry point (skips assembly, starts from FASTA)
nextflow run "${BACASS_DIR}/main_preassembled.nf" \
    -resume \
    -profile conda \
    --input "${INPUT}" \
    --outdir "${OUTDIR}" \
    --annotation_tool bakta \
    --baktadb "${BACASS_BAKTADB}" \
    --busco_db_path "${BACASS_BUSCODB}"

EXIT_CODE=$?

# Print completion information
echo "=========================================="
echo "Job finished on $(date)"
echo "Exit code: ${EXIT_CODE}"
echo "=========================================="

exit ${EXIT_CODE}
