#!/bin/bash
### General options
#BSUB -q hpc
#BSUB -J funcscan_deepbgc_test
#BSUB -n 1
#BSUB -R "rusage[mem=4GB]"
#BSUB -M 4500MB
#BSUB -W 72:00
#BSUB -u josne@dtu.dk
#BSUB -B
#BSUB -N
#BSUB -o funcscan_deepbgc_test_%J.out
#BSUB -e funcscan_deepbgc_test_%J.err

BACASS_DIR="/work3/josne/github/bacass"
INPUT="/work3/josne/Projects/Vibrio_Galathea3/vibrio_seq/funcscan_samplesheet_test.csv"
OUTDIR="/work3/josne/Projects/Vibrio_Galathea3/vibrio_seq/funcscan_results_deepbgc_test"
FUNCSCAN_WORK="/work3/josne/Projects/Vibrio_Galathea3/vibrio_seq/work_funcscan_deepbgc_test"
# Isolated launch dir — keeps .nextflow/cache separate from the full run
LAUNCH_DIR="/work3/josne/Projects/Vibrio_Galathea3/vibrio_seq/deepbgc_test_launch"

ANTISMASH_DB="${BACASS_DIR}/assets/databases/antismash_db"
DEEPBGC_DB="${BACASS_DIR}/assets/databases/deepbgc_db"

export BACASS_DIR
source "${BACASS_DIR}/setup.sh"

# Deploy patches
cp "${BACASS_DIR}/conf/funcscan_patches/comBGC.py" \
   "${NXF_HOME}/assets/nf-core/funcscan/bin/comBGC.py"
cp "${BACASS_DIR}/conf/funcscan_patches/combgc.nf" \
   "${NXF_HOME}/assets/nf-core/funcscan/modules/local/combgc.nf"
cp "${BACASS_DIR}/conf/funcscan_patches/deepbgc_pipeline_main.nf" \
   "${NXF_HOME}/assets/nf-core/funcscan/modules/nf-core/deepbgc/pipeline/main.nf"

echo "=========================================="
echo "DeepBGC /tmp patch test — BGC screening only"
echo "Job started on $(date)"
echo "Head job ID: $LSB_JOBID"
echo "Head node: $(hostname)"
echo "Input:      ${INPUT}"
echo "Output:     ${OUTDIR}"
echo "Work dir:   ${FUNCSCAN_WORK}"
echo "Launch dir: ${LAUNCH_DIR}"
echo "=========================================="

mkdir -p "${LAUNCH_DIR}"
cd "${LAUNCH_DIR}"

nextflow run nf-core/funcscan \
    -r 3.0.0 \
    -profile conda \
    -c "${BACASS_DIR}/conf/lsf.config" \
    -c "${BACASS_DIR}/conf/funcscan_overrides.config" \
    -w "${FUNCSCAN_WORK}" \
    --input "${INPUT}" \
    --outdir "${OUTDIR}" \
    --run_bgc_screening \
    --bgc_antismash_db "${ANTISMASH_DB}" \
    --bgc_antismash_taxon bacteria \
    --bgc_deepbgc_db "${DEEPBGC_DB}"

EXIT_CODE=$?
cd "${BACASS_DIR}"
echo "=========================================="
echo "Job finished on $(date)"
echo "Exit code: ${EXIT_CODE}"
echo "=========================================="
exit ${EXIT_CODE}
