#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpcspecial
### -- set the job Name --
#BSUB -J quast_multiqc
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
#BSUB -o quast_multiqc_%J.out
#BSUB -e quast_multiqc_%J.err

#==========================================================================
# EDIT THESE BEFORE SUBMITTING
#==========================================================================
RESULTS_DIR="/work3/josne/Projects/Vibrio_Galathea3/vibrio_seq/bak.Bacass_results"
#==========================================================================

BACASS_DIR="/work3/josne/github/bacass"
QUAST_ENV="${BACASS_DIR}/.conda_envs/env-64b03f4592c4fb360664f065698df4dd"
ASSEMBLY_TYPE="short"

# Load base environment (conda, database paths)
source "${BACASS_DIR}/setup.sh"

echo "=========================================="
echo "QUAST + MultiQC re-run"
echo "Job started on $(date)"
echo "Job ID: ${LSB_JOBID}"
echo "Running on node: $(hostname)"
echo "Results dir: ${RESULTS_DIR}"
echo "=========================================="

# Validate
if [ ! -d "${RESULTS_DIR}/Unicycler" ]; then
    echo "ERROR: ${RESULTS_DIR}/Unicycler not found"
    exit 1
fi
if [ ! -f "${RESULTS_DIR}/Kmerfinder/kmerfinder_summary.csv" ]; then
    echo "ERROR: ${RESULTS_DIR}/Kmerfinder/kmerfinder_summary.csv not found"
    exit 1
fi

# --- Locate MultiQC 1.19 conda env ---
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
echo "MultiQC env : ${MULTIQC_ENV}"
echo "QUAST env   : ${QUAST_ENV}"

# ============================================================
# Step 1: QUAST
# ============================================================
echo ""
echo "=== Step 1: Running QUAST ==="

QUAST_OUT="${RESULTS_DIR}/QUAST/report"
mkdir -p "${QUAST_OUT}"

mapfile -t FASTAS < <(find "${RESULTS_DIR}/Unicycler" -name "*.scaffolds.fa.gz" | sort)
echo "Found ${#FASTAS[@]} assemblies"
if [ "${#FASTAS[@]}" -eq 0 ]; then
    echo "ERROR: No *.scaffolds.fa.gz files found in ${RESULTS_DIR}/Unicycler/"
    exit 1
fi

"${QUAST_ENV}/bin/quast.py" \
    "${FASTAS[@]}" \
    -t "${LSB_MAX_NUM_PROCESSORS:-8}" \
    -o "${QUAST_OUT}"

echo "QUAST done → ${QUAST_OUT}/report.html"

# ============================================================
# Step 2: MultiQC staging
# Mirrors the directory layout that CUSTOM_MULTIQC creates in its
# Nextflow work dir, so path_filters in multiqc_config_short.yml match.
# ============================================================
echo ""
echo "=== Step 2: Setting up MultiQC staging ==="

STAGING=$(mktemp -d)
echo "Staging dir: ${STAGING}"
trap 'rm -rf "${STAGING}"' EXIT

# QUAST — path_filter: ./quast/*/report.tsv
mkdir -p "${STAGING}/quast"
ln -s "${QUAST_OUT}" "${STAGING}/quast/report"

# FastQC raw — path_filter: ./fastqc/*.zip
[ -d "${RESULTS_DIR}/FastQC/raw" ]  && ln -s "${RESULTS_DIR}/FastQC/raw"  "${STAGING}/fastqc"

# FastQC trimmed — path_filter: ./fastqc_trim/*.zip
[ -d "${RESULTS_DIR}/FastQC/trim" ] && ln -s "${RESULTS_DIR}/FastQC/trim" "${STAGING}/fastqc_trim"

# FASTP — sp override: fn: *.fastp.json
[ -d "${RESULTS_DIR}/trimming" ]    && ln -s "${RESULTS_DIR}/trimming"    "${STAGING}/fastp"

# Kraken2 — path_filter: .*kraken2_*/*report.txt
[ -d "${RESULTS_DIR}/Kraken2" ]     && ln -s "${RESULTS_DIR}/Kraken2"     "${STAGING}/kraken2_short"

# BUSCO and Bakta
[ -d "${RESULTS_DIR}/busco" ]       && ln -s "${RESULTS_DIR}/busco"       "${STAGING}/busco"
[ -d "${RESULTS_DIR}/Bakta" ]       && ln -s "${RESULTS_DIR}/Bakta"       "${STAGING}/bakta"

# MultiQC config (must be named multiqc_config.yaml as CUSTOM_MULTIQC expects)
cp "${BACASS_DIR}/assets/multiqc_config_short.yml" "${STAGING}/multiqc_config.yaml"

# ============================================================
# Step 3: Generate kmerfinder YAML for MultiQC
# kmerfinder_summary.csv is published; regenerate the YAML from it
# using csv_to_yaml.py (same tool as KMERFINDER_SUMMARY process).
# The YAML is staged in extra/ so CUSTOM_MULTIQC logic copies it to
# multiqc_data/ for multiqc_to_custom_csv.py to read.
# ============================================================
echo ""
echo "=== Step 3: Generating kmerfinder MultiQC YAML ==="

mkdir -p "${STAGING}/extra"
cd "${STAGING}/extra" || exit 1
"${MULTIQC_ENV}/bin/python" "${BACASS_DIR}/bin/csv_to_yaml.py" \
    -i "${RESULTS_DIR}/Kmerfinder/kmerfinder_summary.csv" \
    -k 'sample_name' \
    -op multiqc_kmerfinder
echo "kmerfinder YAML: ${STAGING}/extra/multiqc_kmerfinder.yaml"

# ============================================================
# Step 4: Two-pass MultiQC  (replicates CUSTOM_MULTIQC script block)
# ============================================================
cd "${STAGING}" || exit 1

echo ""
echo "=== Step 4: MultiQC pass 1 ==="
"${MULTIQC_ENV}/bin/multiqc" -f -k yaml -c multiqc_config.yaml .

# Copy extra files to multiqc_data/ (replicates CUSTOM_MULTIQC logic)
if [ -d extra/ ]; then
    cp extra/* multiqc_data/
fi

echo ""
echo "=== Step 5: Generating assembly metrics CSV ==="
# Reads multiqc_data/multiqc_quast.yaml and multiqc_data/multiqc_kmerfinder.yaml
"${MULTIQC_ENV}/bin/python" "${BACASS_DIR}/bin/multiqc_to_custom_csv.py" \
    --assembly_type "${ASSEMBLY_TYPE}"

# kmerfinder WAS run: do NOT delete the CSV.
# (The CUSTOM_MULTIQC grep check on workflow_summary_mqc.yaml is skipped here
#  since we have no workflow summary; the CSV is always kept in standalone mode.)

echo ""
echo "=== Step 6: MultiQC pass 2 ==="
"${MULTIQC_ENV}/bin/multiqc" -f -k yaml -c multiqc_config.yaml .

# ============================================================
# Step 5: Publish to Bacass_results/multiqc/
# ============================================================
echo ""
echo "=== Step 7: Publishing results ==="

MULTIQC_OUT="${RESULTS_DIR}/multiqc"
mkdir -p "${MULTIQC_OUT}"

cp -r "${STAGING}/"*multiqc_report.html       "${MULTIQC_OUT}/"
cp -r "${STAGING}/"*_data                     "${MULTIQC_OUT}/"
cp -r "${STAGING}/"*_plots                    "${MULTIQC_OUT}/" 2>/dev/null || true
cp    "${STAGING}/"*_assembly_metrics_mqc.csv "${MULTIQC_OUT}/" 2>/dev/null || true

echo ""
echo "=========================================="
echo "Done on $(date)"
echo "QUAST report  : ${QUAST_OUT}/report.html"
echo "MultiQC report: ${MULTIQC_OUT}/multiqc_report.html"
echo "=========================================="
