#!/bin/bash
# ============================================================================
# Generate a funcscan samplesheet from bacass results
#
# Usage:
#   ./bacass_to_funcscan.sh <bacass_results_dir> [output_csv]
#
# Auto-detects Bakta (.gbff/.faa) or Prokka (.gbk/.faa) annotation output
# and pairs each sample with its assembly FASTA from Unicycler/Dragonflye.
#
# Output: 4-column CSV (sample,fasta,protein,gbk) ready for nf-core/funcscan
# ============================================================================

set -euo pipefail

RESULTS_DIR="${1:-}"
OUTPUT_CSV="${2:-funcscan_samplesheet.csv}"

if [ -z "${RESULTS_DIR}" ]; then
    echo "Usage: $0 <bacass_results_dir> [output_csv]"
    echo ""
    echo "Example:"
    echo "  $0 /path/to/Bacass_results"
    echo "  $0 /path/to/Bacass_results my_samplesheet.csv"
    exit 1
fi

if [ ! -d "${RESULTS_DIR}" ]; then
    echo "ERROR: Results directory not found: ${RESULTS_DIR}"
    exit 1
fi

# Resolve to absolute path
RESULTS_DIR="$(realpath "${RESULTS_DIR}")"

# Detect assembler output directory
ASSEMBLY_DIR=""
for assembler in Unicycler Dragonflye; do
    if [ -d "${RESULTS_DIR}/${assembler}" ]; then
        ASSEMBLY_DIR="${RESULTS_DIR}/${assembler}"
        echo "Found assembler output: ${assembler}"
        break
    fi
done

if [ -z "${ASSEMBLY_DIR}" ]; then
    echo "ERROR: No assembly output found (looked for Unicycler/ and Dragonflye/ in ${RESULTS_DIR})"
    exit 1
fi

# Detect annotation tool (Bakta or Prokka)
ANNO_TOOL=""
ANNO_DIR=""
GBK_EXT=""
if [ -d "${RESULTS_DIR}/Bakta" ]; then
    ANNO_TOOL="Bakta"
    ANNO_DIR="${RESULTS_DIR}/Bakta"
    GBK_EXT="gbff"
elif [ -d "${RESULTS_DIR}/Prokka" ]; then
    ANNO_TOOL="Prokka"
    ANNO_DIR="${RESULTS_DIR}/Prokka"
    GBK_EXT="gbk"
else
    echo "ERROR: No annotation output found (looked for Bakta/ and Prokka/ in ${RESULTS_DIR})"
    exit 1
fi
echo "Found annotation tool: ${ANNO_TOOL} (${GBK_EXT})"

# Write CSV header
echo "sample,fasta,protein,gbk" > "${OUTPUT_CSV}"

# Iterate over annotated samples
SAMPLE_COUNT=0
SKIP_COUNT=0

for sample_dir in "${ANNO_DIR}"/*/; do
    [ -d "${sample_dir}" ] || continue
    sample=$(basename "${sample_dir}")

    # Find assembly FASTA (gzipped or plain)
    fasta=""
    for pattern in "${sample}.scaffolds.fa.gz" "${sample}.scaffolds.fa" "${sample}.fa.gz" "${sample}.fa"; do
        if [ -f "${ASSEMBLY_DIR}/${pattern}" ]; then
            fasta="${ASSEMBLY_DIR}/${pattern}"
            break
        fi
    done

    # Find protein FASTA
    protein=""
    if [ -f "${sample_dir}${sample}.faa" ]; then
        protein="${sample_dir}${sample}.faa"
    fi

    # Find GenBank file
    gbk=""
    if [ -f "${sample_dir}${sample}.${GBK_EXT}" ]; then
        gbk="${sample_dir}${sample}.${GBK_EXT}"
    fi

    # Validate all three files exist
    if [ -z "${fasta}" ] || [ -z "${protein}" ] || [ -z "${gbk}" ]; then
        echo "WARN: Skipping ${sample} — missing files (fasta=${fasta:-MISSING}, protein=${protein:-MISSING}, gbk=${gbk:-MISSING})"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    echo "${sample},${fasta},${protein},${gbk}" >> "${OUTPUT_CSV}"
    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
done

echo ""
echo "Wrote ${OUTPUT_CSV}: ${SAMPLE_COUNT} samples"
[ ${SKIP_COUNT} -gt 0 ] && echo "Skipped ${SKIP_COUNT} samples (missing files)"
echo ""
echo "Next steps:"
echo "  1. Edit submit_funcscan.sh — set INPUT to: $(realpath "${OUTPUT_CSV}")"
echo "  2. bsub < submit_funcscan.sh"
