#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpc
### -- set the job Name --
#BSUB -J padloc_scan
### -- ask for number of cores --
#BSUB -n 4
### -- all cores on one host --
#BSUB -R "span[hosts=1] rusage[mem=2GB]"
### -- specify that we want the job to get killed if it exceeds 2.2 GB --
#BSUB -M 2200MB
### -- set walltime limit: hh:mm --
#BSUB -W 48:00
### -- set the email address --
#BSUB -u josne@dtu.dk
### -- send notification at start --
#BSUB -B
### -- send notification at completion --
#BSUB -N
### -- Specify the output and error file. %J is the job-id --
#BSUB -o padloc_scan_%J.out
#BSUB -e padloc_scan_%J.err

# ============================================================================
# Runs PADLOC (anti-phage defense system detection, padlocbio) on every Bakta
# protein FASTA in a bacass OUTDIR, then builds a cross-sample summary.
# Second, mostly-independent defense-system caller alongside DefenseFinder
# (run_defensefinder_scan.sh) -- different HMM/model catalog (PADLOC-DB vs
# MacSyFinder models), so the two corroborate or complement each other rather
# than duplicating. bin/bgc_defense_proximity.py merges both into one
# per-system tool-provenance view, the same way bin/antismash_merged_summary.py
# already does for BGC-calling tools.
#
# Bakta pseudogene incompatibility (found + fixed Sep 2026): PADLOC's own GFF
# parser (padloc.R, ~line 750) does `ID <- ifelse(is.na(pseudo), ID, Name)`
# for any CDS carrying a "pseudo" attribute -- fine for tools where Name is a
# locus-tag-like string, but Bakta's Name is the (non-unique) product
# description ("hypothetical protein" etc.), so this silently corrupts the
# merge key for every pseudogene. PADLOC hard-exits ("N protein sequence IDs
# are missing from GFF file") whenever one of those pseudogenes happens to
# get an HMM hit -- hit exactly this on S0204 (2/12 pseudogenes had hits).
# Fixed here by stripping the "pseudo=..." attribute from a throwaway copy of
# each sample's GFF3 before handing it to PADLOC -- Bakta's own GFF3 is never
# touched, and PADLOC doesn't otherwise use the "pseudo" flag for anything
# (pseudogenes still get scanned normally once the attribute is gone, they're
# just no longer eligible for the broken ID-swap).
#
# --cpu benchmarked on S0204 (Sep 2026): --cpu 4 took ~4m16s wall for the
# hmmsearch step after hmmpress-indexing the DB (see below), ~5m17s before --
# either way this is the whole runtime, system-calling itself is under a
# minute. --cpu 8 gave no real speedup (hmmsearch's threading plateaus well
# under 8 for this profile-DB size, confirmed via `ps` CPU%: ~230% used
# regardless of --cpu 4 vs --cpu 8) so 4 is the right per-sample core count,
# not a compute budget compromise. Threads never exceed the declared CPU
# count and the systems-calling R step is confirmed single-threaded (<1%
# CPU) -- no CS-storm risk of the kind that hit FastQC (CLAUDE.md), and this
# script is a single serial-loop job regardless (no concurrent-job
# bin-packing scenario to begin with, unlike Nextflow's parallel fan-out).
#
# Memory: measured peaks (VmHWM, Sep 2026) are ~128MB for hmmsearch and
# ~303MB for the R step (never concurrent, so true peak is ~303MB, not the
# sum) -- rusage[mem=2GB]/-M 2200MB above is already >6x that, no need to
# reserve more. A first-batch guess (based on DefenseFinder's own 8GB
# reservation, itself apparently never profiled) had this at 6GB/6.5GB --
# corrected before ever running for real, since over-reserving blocks other
# users' access to shared node RAM (see CLAUDE.md's memory right-sizing
# section on FASTP/BUSCO for the same class of fix).
#
# PADLOC-DB was not hmmpress-indexed on install (no .h3f/.h3i/.h3m/.h3p next
# to padlocdb.hmm) -- every hmmsearch call was re-parsing the full 945MB text
# HMM file from scratch instead of memory-mapping a compact binary index.
# `hmmpress`ed once (Sep 2026, ~31s, lossless/idempotent) -- this is what
# dropped hmmsearch's peak memory to ~128MB and cut runtime ~20%. This
# script checks for the pressed index and presses it automatically if
# missing (e.g. after a PADLOC-DB reinstall/upgrade), so this fix survives.
#
# PADLOC's own bash wrapper caches <sample>.domtblout (the hmmsearch step)
# and skips re-running it if the file already exists -- this script relies on
# that for its own idempotency (skip-if-scanned check below), same as
# padloc.R's own internal behavior. Note padloc.R (~line 868) only writes
# "<sample>_padloc.csv" when at least one system was found -- a sample with
# zero defense systems legitimately has no csv file. bin/padloc_summary.py
# (called at the end of this script) accounts for this already -- see its
# own docstring.
#
# Runs serially here (simple, matches this project's single-bsub-job
# convention -- same choice already made for run_defensefinder_scan.sh and
# run_genomad_scan.sh) rather than as an LSF job array. Considered
# parallelizing given ~4m16s/sample only uses ~4 of a node's 20 cores for the
# whole ~21h (301 samples), but decided against it for this first run:
# (1) this is a brand-new script whose only real timing data point before
# this run was S0204 -- running the full batch once, serially, gives the
# actual per-sample runtime distribution across genuinely varied assembly
# sizes, which is what you'd want before deciding how aggressively to shard
# a rerun (same "measure before optimizing" pattern as this project's
# resource-tuning workflow); (2) a single serial job is far simpler to
# babysit and resume (one bhist entry, one log, the skip-if-scanned check
# above just works) than reconciling partial failures across N array tasks;
# (3) nothing is blocking on same-day results here, and this queue already
# tolerates much longer jobs elsewhere in this project (72h). If a future
# rerun's timeline needs it, an LSF job array (`bsub -J "padloc[1-N]%K"`,
# one sample per array task) is the natural mechanism -- the now-hmmpress'd
# DB (see above) makes concurrent reads cheap (same-node array tasks share
# the OS page cache for the mmap'd index), so parallelizing later is low-risk
# whenever it's actually warranted.
#
# Usage:
#   ./run_padloc_scan.sh <OUTDIR> [cpus]
#   bsub -q hpc -n 4 -R "span[hosts=1] rusage[mem=2GB]" -M 2200MB -W 48:00 \
#     -o padloc_scan_%J.out -e padloc_scan_%J.err \
#     ./run_padloc_scan.sh <OUTDIR>
#   (bsub < run_padloc_scan.sh doesn't work here -- OUTDIR is a required
#   positional arg, and `bsub <` only parses the #BSUB header, it can't pass
#   one; see CLAUDE.md's "Submitting via bsub" note for the same caveat on
#   the other standalone scan/aggregation scripts)
# ============================================================================

set -euo pipefail

BACASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <OUTDIR> [cpus]"
    echo "  OUTDIR   Bacass results directory containing Bakta/<sample>/<sample>.faa + .gff3"
    echo "  cpus     Optional, passed to padloc --cpu (default: 4)"
    exit 1
}

[ $# -ge 1 ] || usage
OUTDIR="$(cd "$1" 2>/dev/null && pwd)" || { echo "ERROR: OUTDIR '$1' does not exist or is not a directory"; exit 1; }
CPUS="${2:-4}"

PADLOC_ENV="/work3/josne/miniconda3/envs/defensefinder"

[ -x "${PADLOC_ENV}/bin/padloc" ] || { echo "ERROR: padloc not found in ${PADLOC_ENV}"; exit 1; }
[ -d "${PADLOC_ENV}/data/hmm" ] || { echo "ERROR: PADLOC-DB not installed -- run: ${PADLOC_ENV}/bin/padloc --db-install v2.0.0 (must be the tag, e.g. v2.0.0, not a bare number -- padloc's own --help example is misleading here)"; exit 1; }
[ -d "${OUTDIR}/Bakta" ] || { echo "ERROR: ${OUTDIR}/Bakta not found"; exit 1; }

PADLOC_HMM="${PADLOC_ENV}/data/hmm/padlocdb.hmm"
if [ -f "${PADLOC_HMM}" ] && [ ! -f "${PADLOC_HMM}.h3i" ]; then
    echo "PADLOC-DB is not hmmpress-indexed yet -- pressing once now (~30s, one-time, benefits every future run)"
    "${PADLOC_ENV}/bin/hmmpress" "${PADLOC_HMM}"
fi

# padloc's own bash wrapper invokes hmmsearch and Rscript as bare commands,
# not via absolute path -- same class of fix as run_defensefinder_scan.sh's
# hmmsearch. Without this, it dies with "hmmsearch: command not found".
export PATH="${PADLOC_ENV}/bin:${PATH}"

mapfile -t PROTEOMES < <(find "${OUTDIR}/Bakta" -mindepth 2 -maxdepth 2 -name "*.faa" ! -name "*.hypotheticals.faa" | sort)
echo "=========================================="
echo "PADLOC scan"
echo "Job started on $(date)"
echo "OUTDIR: ${OUTDIR}"
echo "Proteomes found: ${#PROTEOMES[@]}"
echo "CPUs per sample: ${CPUS}"
echo "=========================================="
if [ "${#PROTEOMES[@]}" -eq 0 ]; then
    echo "ERROR: no *.faa files found in ${OUTDIR}/Bakta/*/"
    exit 1
fi

PADLOC_OUT="${OUTDIR}/padloc"
mkdir -p "${PADLOC_OUT}"

STAGING=$(mktemp -d)
trap 'rm -rf "${STAGING}"' EXIT

i=0
for faa in "${PROTEOMES[@]}"; do
    i=$((i + 1))
    sample="$(basename "${faa}" .faa)"
    gff="${OUTDIR}/Bakta/${sample}/${sample}.gff3"
    echo ""
    echo "=== Sample ${i}/${#PROTEOMES[@]}: ${sample} ==="

    if [ -f "${PADLOC_OUT}/${sample}/${sample}.domtblout" ]; then
        echo "Already scanned, skipping"
        continue
    fi
    if [ ! -f "${gff}" ]; then
        echo "WARNING: no gff3 for ${sample} at ${gff} -- skipping"
        continue
    fi

    fixed_gff="${STAGING}/${sample}_nopseudo.gff3"
    sed -E 's/;pseudo=[^;]*//' "${gff}" > "${fixed_gff}"

    # padloc requires --outdir to already exist ("Valid output directory required")
    mkdir -p "${PADLOC_OUT}/${sample}"

    "${PADLOC_ENV}/bin/padloc" \
        --faa "${faa}" \
        --gff "${fixed_gff}" \
        --outdir "${PADLOC_OUT}/${sample}" \
        --cpu "${CPUS}"

    rm -f "${fixed_gff}"
done

# ============================================================
# Build cross-sample summary
# ============================================================
echo ""
echo "=== Building cross-sample summary ==="

SUMMARY="${PADLOC_OUT}/padloc_summary.tsv"
python3 "${BACASS_DIR}/bin/padloc_summary.py" --padloc-outdir "${PADLOC_OUT}" -o "${SUMMARY}"

echo ""
echo "=========================================="
echo "Done on $(date)"
echo "Per-sample PADLOC output: ${PADLOC_OUT}/<sample>/"
echo "Cross-sample summary: ${SUMMARY}"
echo "=========================================="
