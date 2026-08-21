#!/bin/bash
# ============================================================================
# Merges published outputs from multiple funcscan batch OUTDIRs into one
# union directory, so run_funcscan_aggregation.sh can produce a single
# combined report (hamronize summarize, ampcombi complete, MultiQC) spanning
# every batch.
#
# Read-only against the source batches: everything in TARGET is either a
# freshly-created real directory or a symlink to a file in a source batch —
# nothing is copied, nothing in the source batches is modified.
#
# Per-sample-subdirectory tools: a real subdirectory is created in TARGET and
# each file inside it is symlinked individually — NOT the whole subdirectory
# symlinked as one unit, because `find -mindepth N -maxdepth N` (used by
# run_funcscan_aggregation.sh) does not descend into symlinked directories by
# default, only symlinked files are transparently readable. This also
# correctly handles reports/ampcombi2 and reports/combgc, which mix
# per-sample subdirs with top-level aggregate files in the same parent dir —
# only the subdirs get merged, the top-level aggregate files are left alone.
#
# Flat-per-sample-file tools (arg/hamronization/<tool>/): each file is
# symlinked directly into TARGET.
#
# NOT merged (aggregate outputs, not per-sample — regenerated fresh by
# run_funcscan_aggregation.sh against the merged OUTDIR instead, except
# combgc which that script deliberately never regenerates — see its own
# comments for why):
# reports/hamronization_summarize/, reports/ampcombi2/*.tsv (top-level),
# reports/combgc/*.tsv (top-level), multiqc/, pipeline_info/.
#
# Usage:
#   ./merge_funcscan_batches.sh <TARGET_DIR> <BATCH_DIR_1> <BATCH_DIR_2> [...]
# ============================================================================

set -euo pipefail

usage() {
    echo "Usage: $0 <TARGET_DIR> <BATCH_DIR_1> <BATCH_DIR_2> [BATCH_DIR_3 ...]"
    echo "  TARGET_DIR   New directory to create the merged view in (must not already exist)"
    echo "  BATCH_DIR_*  At least 2 existing funcscan OUTDIRs to merge"
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
SUBDIR_TOOLS=(
    arg/abricate arg/amrfinderplus arg/deeparg arg/fargene arg/rgi
    bgc/deepbgc bgc/gecco bgc/antismash
    reports/ampcombi2 reports/combgc
    annotation/prokka annotation/bakta
)
# Flat-per-sample-file tool dirs (relative to each batch's OUTDIR)
FLAT_TOOLS=(
    arg/hamronization/abricate arg/hamronization/amrfinderplus
    arg/hamronization/deeparg arg/hamronization/rgi arg/hamronization/fargene
)

echo "=========================================="
echo "Funcscan batch merge"
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
    ids_source=""
    for candidate in reports/combgc reports/ampcombi2 arg/rgi arg/abricate; do
        if [ -d "${batch}/${candidate}" ]; then
            ids_source="${batch}/${candidate}"
            break
        fi
    done
    if [ -z "${ids_source}" ]; then
        echo "ERROR: could not find any known per-sample tool directory under ${batch} to determine sample IDs"
        exit 1
    fi
    mapfile -t ids < <(find "${ids_source}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
    echo "${batch} (IDs from ${ids_source#${batch}/}): ${#ids[@]} samples"
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
            mkdir -p "${TARGET}/${tool}/${sample}"
            for f in "${sample_dir}"/*; do
                [ -f "$f" ] && ln -s "$f" "${TARGET}/${tool}/${sample}/$(basename "$f")"
            done
            merged_count=$((merged_count + 1))
        done < <(find "${batch}/${tool}" -mindepth 1 -maxdepth 1 -type d)
    done
    [ "${merged_count}" -gt 0 ] && echo "${tool}: ${merged_count} sample directories merged"
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
    [ "${merged_count}" -gt 0 ] && echo "${tool}: ${merged_count} files merged"
done

echo ""
echo "=========================================="
echo "Done on $(date)"
echo "Merged OUTDIR: ${TARGET}"
echo "Not merged (regenerate fresh against this OUTDIR instead, except combgc — see"
echo "run_funcscan_aggregation.sh's own comments): reports/hamronization_summarize/,"
echo "reports/ampcombi2/*.tsv (top-level), reports/combgc/*.tsv (top-level), multiqc/,"
echo "pipeline_info/"
echo "Next: ./run_funcscan_aggregation.sh ${TARGET}"
echo "=========================================="
