#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpc
### -- set the job Name --
#BSUB -J defensefinder_scan
### -- ask for number of cores --
#BSUB -n 8
### -- all cores on one host --
#BSUB -R "span[hosts=1] rusage[mem=8GB]"
### -- specify that we want the job to get killed if it exceeds 8.5 GB --
#BSUB -M 8500MB
### -- set walltime limit: hh:mm --
#BSUB -W 06:00
### -- set the email address --
#BSUB -u josne@dtu.dk
### -- send notification at start --
#BSUB -B
### -- send notification at completion --
#BSUB -N
### -- Specify the output and error file. %J is the job-id --
#BSUB -o defensefinder_scan_%J.out
#BSUB -e defensefinder_scan_%J.err

# ============================================================================
# Runs DefenseFinder (anti-phage defense system detection, MDM Labs/Institut
# Pasteur) on every Bakta protein FASTA in a bacass OUTDIR, then builds a
# cross-sample summary. Protein-mode (--db-type ordered_replicon against
# Bakta's already-called, already-ordered CDS set), so no re-assembly or
# re-calling — this is what makes it fast enough to run serially in one job.
#
# Motivation: Shomar et al. 2026 (Cell Host & Microbe, "A family of
# lanthipeptides with anti-phage function") found that a clade of class I
# lanthipeptide BGCs in Actinobacteria is strongly enriched near known
# anti-phage defense systems. This script produces the defense-system half of
# the same style of analysis for our own genome collection — see
# bin/bgc_defense_proximity.py for the BGC <-> defense-system proximity join
# against antiSMASH output.
#
# Smoke-tested Aug 2026 on S0204 (Bacass_results_merged): 12 defense systems
# found (Shango, GAPS2, Olokun, PD-T7-2, Septu, RM_Type_I x2, Belisama,
# dGTPase, Reve, Gabija, DRT_4, Aristaios) in 48s wall at -w 4. DefenseFinder's
# own hit_pos column in *_defense_finder_genes.tsv is already a genome-wide
# sequential gene index (not just per-contig), which bin/bgc_defense_proximity.py
# relies on directly instead of re-deriving gene order from Bakta's GFF.
#
# Usage:
#   ./run_defensefinder_scan.sh <OUTDIR> [workers]
#   bsub < run_defensefinder_scan.sh  (edit OUTDIR below first)
# ============================================================================

set -euo pipefail

BACASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <OUTDIR> [workers]"
    echo "  OUTDIR   Bacass results directory containing Bakta/<sample>/<sample>.faa"
    echo "  workers  Optional, passed to defense-finder run -w (default: 4)"
    exit 1
}

[ $# -ge 1 ] || usage
OUTDIR="$(cd "$1" 2>/dev/null && pwd)" || { echo "ERROR: OUTDIR '$1' does not exist or is not a directory"; exit 1; }
WORKERS="${2:-4}"

DEFENSEFINDER_ENV="/work3/josne/miniconda3/envs/defensefinder"
DEFENSEFINDER_MODELS="/work3/josne/Databases/defensefinder_models"

[ -x "${DEFENSEFINDER_ENV}/bin/defense-finder" ] || { echo "ERROR: defense-finder env not found at ${DEFENSEFINDER_ENV}"; exit 1; }
[ -x "${DEFENSEFINDER_ENV}/bin/hmmsearch" ] || { echo "ERROR: hmmsearch not found in ${DEFENSEFINDER_ENV} — defense-finder needs it on PATH"; exit 1; }
[ -d "${DEFENSEFINDER_MODELS}" ] || { echo "ERROR: DefenseFinder models not found at ${DEFENSEFINDER_MODELS} — run: ${DEFENSEFINDER_ENV}/bin/defense-finder update --models-dir ${DEFENSEFINDER_MODELS}"; exit 1; }
[ -d "${OUTDIR}/Bakta" ] || { echo "ERROR: ${OUTDIR}/Bakta not found"; exit 1; }

# defense-finder invokes hmmsearch as a bare command, not via absolute path,
# so it must be on PATH — prepend rather than fully replacing PATH.
export PATH="${DEFENSEFINDER_ENV}/bin:${PATH}"

mapfile -t PROTEOMES < <(find "${OUTDIR}/Bakta" -mindepth 2 -maxdepth 2 -name "*.faa" ! -name "*.hypotheticals.faa" | sort)
echo "=========================================="
echo "DefenseFinder scan"
echo "Job started on $(date)"
echo "OUTDIR: ${OUTDIR}"
echo "Proteomes found: ${#PROTEOMES[@]}"
echo "Workers per sample: ${WORKERS}"
echo "=========================================="
if [ "${#PROTEOMES[@]}" -eq 0 ]; then
    echo "ERROR: no *.faa files found in ${OUTDIR}/Bakta/*/"
    exit 1
fi

DF_OUT="${OUTDIR}/defensefinder"
mkdir -p "${DF_OUT}"

i=0
for faa in "${PROTEOMES[@]}"; do
    i=$((i + 1))
    sample="$(basename "${faa}" .faa)"
    echo ""
    echo "=== Sample ${i}/${#PROTEOMES[@]}: ${sample} ==="

    if [ -f "${DF_OUT}/${sample}/${sample}_defense_finder_systems.tsv" ]; then
        echo "Already scanned, skipping"
        continue
    fi

    "${DEFENSEFINDER_ENV}/bin/defense-finder" run \
        -o "${DF_OUT}/${sample}" \
        --models-dir "${DEFENSEFINDER_MODELS}" \
        -w "${WORKERS}" \
        "${faa}"
done

# ============================================================
# Build cross-sample summary
# ============================================================
echo ""
echo "=== Building cross-sample summary ==="

SUMMARY="${DF_OUT}/defensefinder_summary.tsv"
{
    printf "sample\tn_systems\tsystem_types\n"
    for faa in "${PROTEOMES[@]}"; do
        sample="$(basename "${faa}" .faa)"
        sys_tsv="${DF_OUT}/${sample}/${sample}_defense_finder_systems.tsv"
        [ -f "${sys_tsv}" ] || continue

        n_systems=$(($(wc -l < "${sys_tsv}") - 1))
        types=$(tail -n +2 "${sys_tsv}" | cut -f2 | sort | uniq -c | sort -rn | awk '{printf "%s:%s;", $2, $1}' | sed 's/;$//')
        [ -z "${types}" ] && types="NA"

        printf "%s\t%s\t%s\n" "${sample}" "${n_systems}" "${types}"
    done
} > "${SUMMARY}"

echo ""
echo "=========================================="
echo "Done on $(date)"
echo "Per-sample DefenseFinder output: ${DF_OUT}/<sample>/"
echo "Cross-sample summary: ${SUMMARY}"
echo "=========================================="
