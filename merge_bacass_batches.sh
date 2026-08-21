#!/bin/bash
# ============================================================================
# Merges published outputs from multiple bacass batch OUTDIRs into one union
# directory, so run_bacass_aggregation.sh can produce a single combined
# report (QUAST, Kmerfinder summary, MultiQC) spanning every batch.
#
# Read-only against the source batches: everything in TARGET is either a
# freshly-created real directory or a symlink to a file in a source batch —
# nothing is copied, nothing in the source batches is modified.
#
# Per-sample-subdirectory tools (Kmerfinder/<id>/, busco/<id>/, Bakta/<id>/):
# a real subdirectory is created in TARGET and each file inside it is
# symlinked individually — NOT the whole subdirectory symlinked as one unit,
# because `find -mindepth N -maxdepth N` (used by run_bacass_aggregation.sh)
# does not descend into symlinked directories by default, only symlinked
# files are transparently readable.
#
# Flat-per-sample-file tools (Unicycler/, FastQC/raw|trim/, Kraken2/,
# trimming/shortreads/...): each file is symlinked directly into TARGET.
#
# NOT merged (aggregate outputs, not per-sample — regenerated fresh by
# run_bacass_aggregation.sh against the merged OUTDIR instead):
# QUAST/, multiqc/, pipeline_info/.
#
# Usage:
#   ./merge_bacass_batches.sh <TARGET_DIR> <BATCH_DIR_1> <BATCH_DIR_2> [...]
# ============================================================================

set -euo pipefail

usage() {
    echo "Usage: $0 <TARGET_DIR> <BATCH_DIR_1> <BATCH_DIR_2> [BATCH_DIR_3 ...]"
    echo "  TARGET_DIR   New directory to create the merged view in (must not already exist)"
    echo "  BATCH_DIR_*  At least 2 existing bacass OUTDIRs to merge"
    exit 1
}

[ $# -ge 3 ] || usage

TARGET="$1"
shift
BATCH_DIRS=()
for d in "$@"; do
    resolved="$(cd "$d" 2>/dev/null && pwd)" || { echo "ERROR: batch dir '$d' does not exist or is not a directory"; exit 1; }
    BATCH_DIRS+=("$resolved")
done

if [ -e "${TARGET}" ]; then
    echo "ERROR: TARGET_DIR '${TARGET}' already exists — refusing to merge into an existing directory (avoid mixing a stale merge with a new one)"
    exit 1
fi

# Per-sample-subdirectory tool dirs (relative to each batch's OUTDIR)
SUBDIR_TOOLS=(Kmerfinder busco Bakta)
# Non-sample subdirectories that live alongside per-sample ones in the tools
# above and must not be merged as if they were a sample (e.g. busco's
# pre-downloaded lineage DB cache, published alongside per-sample results).
NON_SAMPLE_SUBDIRS=(busco_downloads)
# Flat-per-sample-file tool dirs (relative to each batch's OUTDIR)
FLAT_TOOLS=(Unicycler FastQC/raw FastQC/trim Kraken2 trimming/shortreads trimming/shortreads/json_html trimming/shortreads/log)

echo "=========================================="
echo "Bacass batch merge"
echo "Target: ${TARGET}"
echo "Batches:"
for d in "${BATCH_DIRS[@]}"; do echo "  - ${d}"; done
echo "=========================================="

# --- Step 1: sample-ID collision check, before touching anything ---
echo ""
echo "=== Step 1: Checking for sample-ID collisions across batches ==="

declare -A seen_sample_batch
collision=0
for batch in "${BATCH_DIRS[@]}"; do
    # Kmerfinder subdirs are the canonical per-sample ID source (present unless
    # --skip_kmerfinder was used); fall back to Unicycler filenames otherwise.
    if [ -d "${batch}/Kmerfinder" ]; then
        mapfile -t ids < <(find "${batch}/Kmerfinder" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
    elif [ -d "${batch}/Unicycler" ]; then
        mapfile -t ids < <(find "${batch}/Unicycler" -maxdepth 1 -name "*.scaffolds.fa.gz" -printf '%f\n' | sed 's/\.scaffolds\.fa\.gz$//' | sort)
    else
        echo "ERROR: neither Kmerfinder/ nor Unicycler/ found under ${batch} — cannot determine sample IDs"
        exit 1
    fi
    echo "${batch}: ${#ids[@]} samples"
    for id in "${ids[@]}"; do
        if [ -n "${seen_sample_batch[$id]:-}" ]; then
            echo "COLLISION: sample '${id}' present in both '${seen_sample_batch[$id]}' and '${batch}'"
            collision=1
        else
            seen_sample_batch[$id]="${batch}"
        fi
    done
done

if [ "${collision}" -eq 1 ]; then
    echo ""
    echo "ERROR: sample-ID collisions found (listed above) — refusing to merge. A naive"
    echo "       merge would silently pick whichever batch happens to be processed last."
    echo "       Resolve the collision (rename/exclude one batch's copy) before merging."
    exit 1
fi
echo "No collisions — ${#seen_sample_batch[@]} unique samples across ${#BATCH_DIRS[@]} batches"

# --- Step 2: merge per-sample-subdirectory tools ---
echo ""
echo "=== Step 2: Merging per-sample-subdirectory tool outputs ==="

for tool in "${SUBDIR_TOOLS[@]}"; do
    merged_count=0
    for batch in "${BATCH_DIRS[@]}"; do
        [ -d "${batch}/${tool}" ] || continue
        while IFS= read -r sample_dir; do
            sample="$(basename "${sample_dir}")"
            skip=0
            for non_sample in "${NON_SAMPLE_SUBDIRS[@]}"; do
                [ "${sample}" = "${non_sample}" ] && skip=1 && break
            done
            [ "${skip}" -eq 1 ] && continue
            mkdir -p "${TARGET}/${tool}/${sample}"
            for f in "${sample_dir}"/*; do
                [ -f "$f" ] && ln -s "$f" "${TARGET}/${tool}/${sample}/$(basename "$f")"
            done
            merged_count=$((merged_count + 1))
        done < <(find "${batch}/${tool}" -mindepth 1 -maxdepth 1 -type d)
    done
    echo "${tool}: ${merged_count} sample directories merged"
done

# --- Step 3: merge flat-per-sample-file tools ---
echo ""
echo "=== Step 3: Merging flat-per-sample-file tool outputs ==="

for tool in "${FLAT_TOOLS[@]}"; do
    merged_count=0
    for batch in "${BATCH_DIRS[@]}"; do
        [ -d "${batch}/${tool}" ] || continue
        mkdir -p "${TARGET}/${tool}"
        for f in "${batch}/${tool}"/*; do
            [ -f "$f" ] || continue
            ln -s "$f" "${TARGET}/${tool}/$(basename "$f")"
            merged_count=$((merged_count + 1))
        done
    done
    echo "${tool}: ${merged_count} files merged"
done

echo ""
echo "=========================================="
echo "Done on $(date)"
echo "Merged OUTDIR: ${TARGET}"
echo "Not merged (regenerate fresh against this OUTDIR instead): QUAST/, multiqc/, pipeline_info/"
echo "Next: ./run_bacass_aggregation.sh ${TARGET}"
echo "=========================================="
