#!/bin/bash
# ============================================================================
# compare_assemblies_for_funcscan.sh
#
# After re-running bacass without -resume, compares new assemblies to old ones
# and generates a funcscan samplesheet that:
#   - Points to OLD paths for unchanged samples (preserves funcscan cache)
#   - Points to NEW paths for changed samples   (triggers funcscan re-run)
#
# Usage:
#   compare_assemblies_for_funcscan.sh \
#       <old_bacass_dir> <new_bacass_dir> \
#       <old_funcscan_samplesheet> [output_samplesheet]
#
# The output samplesheet is passed directly to submit_funcscan_distributed.sh.
# ============================================================================
set -euo pipefail

OLD_DIR="${1:-}"
NEW_DIR="${2:-}"
OLD_SHEET="${3:-}"
OUT_SHEET="${4:-funcscan_samplesheet_updated.csv}"

if [ -z "$OLD_DIR" ] || [ -z "$NEW_DIR" ] || [ -z "$OLD_SHEET" ]; then
    echo "Usage: $0 <old_bacass_dir> <new_bacass_dir> <old_funcscan_samplesheet> [output_samplesheet]"
    echo ""
    echo "Example:"
    echo "  $0 Bacass_results Bacass_results_v2 funcscan_samplesheet_full.csv funcscan_samplesheet_updated.csv"
    exit 1
fi

OLD_DIR="$(realpath "$OLD_DIR")"
NEW_DIR="$(realpath "$NEW_DIR")"
OLD_SHEET="$(realpath "$OLD_SHEET")"

[ -d "$OLD_DIR" ]  || { echo "ERROR: Directory not found: $OLD_DIR";  exit 1; }
[ -d "$NEW_DIR" ]  || { echo "ERROR: Directory not found: $NEW_DIR";  exit 1; }
[ -f "$OLD_SHEET" ] || { echo "ERROR: Samplesheet not found: $OLD_SHEET"; exit 1; }

echo "Old bacass results : $OLD_DIR"
echo "New bacass results : $NEW_DIR"
echo "Old funcscan sheet : $OLD_SHEET"
echo "Output sheet       : $OUT_SHEET"
echo ""

# Content hash of a (possibly gzipped) file — ignores gzip metadata differences
content_md5() {
    local f="$1"
    if [[ "$f" == *.gz ]]; then
        zcat "$f" | md5sum | cut -d' ' -f1
    else
        md5sum "$f" | cut -d' ' -f1
    fi
}

echo "sample,fasta,protein,gbk" > "$OUT_SHEET"

UNCHANGED=0
CHANGED=0
MISSING_NEW=0
CHANGED_SAMPLES=()

while IFS=',' read -r sample old_fasta old_protein old_gbk; do
    [ "$sample" = "sample" ] && continue  # skip header

    # Locate new assembly
    new_fasta="${NEW_DIR}/Unicycler/${sample}.scaffolds.fa.gz"
    if [ ! -f "$new_fasta" ]; then
        echo "WARN: $sample — new assembly not found, skipping"
        MISSING_NEW=$((MISSING_NEW + 1))
        continue
    fi

    # Compare assembly content (decompress before hashing to avoid gzip timestamp differences)
    old_md5=$(content_md5 "$old_fasta" 2>/dev/null || echo "MISSING")
    new_md5=$(content_md5 "$new_fasta")

    if [ "$old_md5" = "$new_md5" ]; then
        # Unchanged — keep old paths so funcscan -resume cache stays valid
        echo "${sample},${old_fasta},${old_protein},${old_gbk}" >> "$OUT_SHEET"
        UNCHANGED=$((UNCHANGED + 1))
    else
        # Changed — point to new assembly and new annotation
        new_protein=""
        new_gbk=""
        if [ -f "${NEW_DIR}/Bakta/${sample}/${sample}.faa" ]; then
            new_protein="${NEW_DIR}/Bakta/${sample}/${sample}.faa"
            new_gbk="${NEW_DIR}/Bakta/${sample}/${sample}.gbff"
        elif [ -f "${NEW_DIR}/Prokka/${sample}/${sample}.faa" ]; then
            new_protein="${NEW_DIR}/Prokka/${sample}/${sample}.faa"
            new_gbk="${NEW_DIR}/Prokka/${sample}/${sample}.gbk"
        fi

        if [ -z "$new_protein" ] || [ ! -f "$new_protein" ] || [ -z "$new_gbk" ] || [ ! -f "$new_gbk" ]; then
            echo "WARN: $sample — assembly changed but new annotation not found, skipping"
            MISSING_NEW=$((MISSING_NEW + 1))
            continue
        fi

        echo "${sample},${new_fasta},${new_protein},${new_gbk}" >> "$OUT_SHEET"
        CHANGED=$((CHANGED + 1))
        CHANGED_SAMPLES+=("$sample")
    fi

done < "$OLD_SHEET"

echo "Summary:"
echo "  Unchanged — funcscan cache valid : $UNCHANGED"
echo "  Changed   — funcscan will re-run : $CHANGED"
[ "$MISSING_NEW" -gt 0 ] && echo "  Missing in new results           : $MISSING_NEW"
echo ""
echo "Written: $OUT_SHEET"

if [ "${#CHANGED_SAMPLES[@]}" -gt 0 ]; then
    echo ""
    echo "Changed samples:"
    printf '  %s\n' "${CHANGED_SAMPLES[@]}"
fi
