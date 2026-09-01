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
# reports/combgc/*.tsv (top-level), multiqc/, pipeline_info/ (the noisy
# per-resume execution_report_*/execution_timeline_*/pipeline_dag_* files).
#
# Exception: pipeline_info/nf_core_funcscan_software_mqc_versions.yml (one
# small, non-timestamped file per batch) IS carried over, one per batch under
# a batch-prefixed name — it's the only pipeline_info file
# run_funcscan_aggregation.sh's MultiQC step actually consumes. Without it,
# the merged OUTDIR has nothing to feed MultiQC (no per-sample QC modules run
# either, since these are pre-annotated Bakta samplesheets — see that
# script's Step 4 comment), so MultiQC reports "No analysis results found"
# and produces no report.html at all.
#
# Bug found + fixed Sep 2026: SUBDIR_TOOLS was missing the raw AMP per-tool
# output dirs (amp/ampir, amp/amplify, amp/macrel) entirely -- unlike the ARG
# and BGC branches, which both merge their raw per-tool dirs AND their
# combined/aggregate output (arg/abricate etc. + arg/hamronization/*;
# bgc/deepbgc etc. + reports/combgc). AMP only had reports/ampcombi2 (the
# already-parsed/filtered per-sample summary) merged, so any already-built
# merged OUTDIR is missing the amp/<tool>/ raw predictions -- the final
# Ampcombi_summary.tsv itself was NOT affected (it's regenerated fresh by
# run_funcscan_aggregation.sh from reports/ampcombi2, which was always
# correctly merged), but per-sample raw ampir/amplify/macrel output was
# invisible in the merged view. Confirmed via the two real source batches on
# disk (funcscan_results: 218 samples, funcscan_results_batch2: 83 samples,
# each with exactly ampir/amplify/macrel under amp/, no stray non-sample
# dirs) -- no SUBDIR_EXCLUDE entry needed for these three.
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
    amp/ampir amp/amplify amp/macrel
    reports/ampcombi2 reports/combgc
    annotation/prokka annotation/bakta
)
# Flat-per-sample-file tool dirs (relative to each batch's OUTDIR)
FLAT_TOOLS=(
    arg/hamronization/abricate arg/hamronization/amrfinderplus
    arg/hamronization/deeparg arg/hamronization/rgi arg/hamronization/fargene
)
# Non-sample subdirectories that can appear alongside real per-sample dirs
# under reports/ampcombi2 (e.g. the AMPcombi reference DB published at the
# top level by an older run) — excluded so they aren't mistaken for samples.
SUBDIR_EXCLUDE=(amp_DRAMP_database)

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
    for excl in "${SUBDIR_EXCLUDE[@]}"; do
        ids=("${ids[@]/${excl}}")
    done
    for i in "${!ids[@]}"; do [ -z "${ids[$i]}" ] && unset 'ids[i]'; done
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
            for excl in "${SUBDIR_EXCLUDE[@]}"; do
                [ "${sample}" = "${excl}" ] && continue 2
            done
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

# --- Step 4: carry over the pipeline_info files MultiQC actually reads ---
# nf_core_funcscan_software_mqc_versions.yml is always published to pipeline_info/.
# workflow_summary_mqc.yaml / methods_description_mqc.yaml are NOT published by
# funcscan itself (they're transient MultiQC-module inputs living only in
# Nextflow's work dir) — they only end up here if someone copied them out of
# the work dir into pipeline_info/ before it was cleaned up (see CLAUDE.md /
# run_funcscan_aggregation.sh Step 4 comment for why this matters). Batch-
# prefixed to avoid collisions; custom_content matches by embedded id, not
# filename, so renaming doesn't break MultiQC's ability to read them.
echo ""
echo "=== Step 4: Merging pipeline_info files MultiQC reads ==="

MQC_INFO_FILES=(
    nf_core_funcscan_software_mqc_versions.yml
    workflow_summary_mqc.yaml
    methods_description_mqc.yaml
)
versions_count=0
for batch in "${BATCH_DIRS[@]}"; do
    for fname in "${MQC_INFO_FILES[@]}"; do
        src="${batch}/pipeline_info/${fname}"
        [ -f "${src}" ] || continue
        mkdir -p "${TARGET}/pipeline_info"
        ln -s "${src}" "${TARGET}/pipeline_info/$(basename "${batch}")_${fname}"
        versions_count=$((versions_count + 1))
    done
done
[ "${versions_count}" -gt 0 ] && echo "pipeline_info: ${versions_count} MultiQC info files merged"

echo ""
echo "=========================================="
echo "Done on $(date)"
echo "Merged OUTDIR: ${TARGET}"
echo "Not merged (regenerate fresh against this OUTDIR instead, except combgc — see"
echo "run_funcscan_aggregation.sh's own comments): reports/hamronization_summarize/,"
echo "reports/ampcombi2/*.tsv (top-level), reports/combgc/*.tsv (top-level), multiqc/,"
echo "pipeline_info/ (except software-versions ymls, merged above)"
echo "Next: ./run_funcscan_aggregation.sh ${TARGET}"
echo "=========================================="
