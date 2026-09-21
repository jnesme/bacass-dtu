#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpc
### -- set the job Name --
#BSUB -J gtdbtk_scan
### -- ask for number of cores --
#BSUB -n 20
### -- all cores on one host --
#BSUB -R "span[hosts=1] rusage[mem=6GB]"
### -- specify that we want the job to get killed if it exceeds 6.3 GB per core/slot --
### (must stay within 5% of rusage[mem=6GB]=6144MB, i.e. <=6451MB; 20 cores x 6GB = 120GB total,
### this cluster's documented per-node ceiling, see CLAUDE.md)
#BSUB -M 6300MB
### -- set walltime limit: hh:mm --
#BSUB -W 24:00
### -- set the email address --
#BSUB -u josne@dtu.dk
### -- send notification at start --
#BSUB -B
### -- send notification at completion --
#BSUB -N
### -- Specify the output and error file. %J is the job-id --
#BSUB -o gtdbtk_scan_%J.out
#BSUB -e gtdbtk_scan_%J.err

# ============================================================================
# Runs GTDB-Tk (current, actively-maintained taxonomy -- GTDB release 232 as of
# Sep 2026) classify_wf on every Bakta-annotated assembly FASTA in a bacass
# OUTDIR, as a standalone step between Bakta and funcscan. Explicitly NOT
# wired into the Nextflow pipeline (matches the DefenseFinder/PADLOC/geNomad/
# KmerFinder-scan convention) -- see CLAUDE.md / project memory for the full
# rationale.
#
# Motivation: the live pipeline's KmerFinder-based --genus/--species wiring
# (conf/modules.config's BAKTA_BAKTA ext.args) stays as the zero-cost default,
# but its local database (Jan 2019 vintage) is old and narrow for
# under-characterized environmental isolates -- confirmed concretely on real
# project data: one sample's local KmerFinder DB match was essentially a
# single, weakly-related genome filed under a taxonomically superseded name
# (Loktanella -> Yoonia). GTDB-Tk's current, actively-curated taxonomy fixes
# exactly this class of problem. Its own classification is meant to patch
# Bakta's own SOURCE/ORGANISM fields afterward (see
# bin/patch_bakta_organism_gtdbtk.py), correcting the true source data rather
# than every downstream copy independently.
#
# GTDB-Tk shells out to ~8 external tools (prodigal, fastANI, skani, pplacer,
# hmmalign, fasttree, pfam_search, tigrfam_search) as bare commands -- rather
# than hand-enumerate/PATH-prepend each one, this script properly `conda
# activate`s the env it was built for. Do NOT source bacass's setup.sh here:
# its `conda info --json` short-circuit (a BeeGFS ENOENT mitigation for
# Nextflow's own internal use of that call) breaks `conda activate` for any
# second env activated afterward (falls through to `command conda "$@"`,
# which bypasses the shell-function integration `activate` requires to
# modify the current shell's environment) -- confirmed hitting exactly this
# during development (`CondaError: Run 'conda init' before 'conda activate'`).
# Sourcing conda's own profile script directly avoids both problems and needs
# none of setup.sh's bacass-specific env vars anyway.
#
# GTDBTK_DATA_PATH is NOT set manually here -- properly activating the env
# supplies its own correct, pre-configured value automatically (confirmed via
# `conda-meta/state`'s env_vars key, conda's official per-env env-var
# mechanism), overriding anything set beforehand.
#
# classify_wf operates on a whole directory of genomes in ONE batch call
# (shared alignment/placement across all inputs) -- structurally different
# from this project's usual per-sample serial loop
# (run_defensefinder_scan.sh/run_padloc_scan.sh/run_genomad_scan.sh/
# run_kmerfinder_scan.sh).
#
# --scratch_dir is used as a safety margin: no test so far has exercised the
# heavy identify/align/pplacer path (small sizing tests on 2 genomes both
# resolved via the cheap ANI-screening fast path, ~1-2GB peak) so the real
# peak memory for a 143-genome batch where some samples need the full
# pipeline is unmeasured. --scratch_dir trades some speed for a much lower
# pplacer memory footprint (writes to disk instead of RAM), reducing OOM risk
# for this first real attempt at this scale.
#
# Usage:
#   ./run_gtdbtk_scan.sh <OUTDIR> [cpus]
#   bsub -q hpc -n 20 -R "span[hosts=1] rusage[mem=6GB]" -M 6300MB -W 24:00 \
#     -o gtdbtk_scan_%J.out -e gtdbtk_scan_%J.err \
#     ./run_gtdbtk_scan.sh <OUTDIR>
#   (bsub < run_gtdbtk_scan.sh doesn't work here -- OUTDIR is a required
#   positional arg, and `bsub <` only parses the #BSUB header, it can't pass
#   one; see CLAUDE.md's "Submitting via bsub" note for the same caveat on
#   the other standalone scan/aggregation scripts)
# ============================================================================

set -euo pipefail

usage() {
    echo "Usage: $0 <OUTDIR> [cpus]"
    echo "  OUTDIR   Bacass results directory containing Bakta/<sample>/<sample>.fna"
    echo "  cpus     Optional, passed to gtdbtk --cpus/--pplacer_cpus (default: 20)"
    exit 1
}

[ $# -ge 1 ] || usage
OUTDIR="$(cd "$1" 2>/dev/null && pwd)" || { echo "ERROR: OUTDIR '$1' does not exist or is not a directory"; exit 1; }
CPUS="${2:-20}"

GTDBTK_ENV="/work3/josne/miniconda3/envs/gtdbtk"
[ -d "${GTDBTK_ENV}" ] || { echo "ERROR: gtdbtk conda env not found at ${GTDBTK_ENV}"; exit 1; }
[ -d "${OUTDIR}/Bakta" ] || { echo "ERROR: ${OUTDIR}/Bakta not found"; exit 1; }

source /work3/josne/miniconda3/etc/profile.d/conda.sh
conda activate "${GTDBTK_ENV}"

mapfile -t ASSEMBLIES < <(find "${OUTDIR}/Bakta" -mindepth 2 -maxdepth 2 -name "*.fna" | sort)
echo "=========================================="
echo "GTDB-Tk scan"
echo "Job started on $(date)"
echo "OUTDIR: ${OUTDIR}"
echo "Assemblies found: ${#ASSEMBLIES[@]}"
echo "GTDBTK_DATA_PATH: ${GTDBTK_DATA_PATH:-<not set -- env activation should have set this>}"
echo "CPUs: ${CPUS}"
echo "=========================================="
if [ "${#ASSEMBLIES[@]}" -eq 0 ]; then
    echo "ERROR: no assembly FASTAs found in ${OUTDIR}/Bakta/*/"
    exit 1
fi

GTDBTK_OUT="${OUTDIR}/gtdbtk"
STAGING="${GTDBTK_OUT}/.genome_staging"

if [ -f "${GTDBTK_OUT}/classify/gtdbtk.bac120.summary.tsv" ] || [ -f "${GTDBTK_OUT}/gtdbtk.bac120.summary.tsv" ]; then
    echo "GTDB-Tk summary already exists under ${GTDBTK_OUT} -- skipping (remove it to force a rerun)"
    exit 0
fi

mkdir -p "${STAGING}"
for asm in "${ASSEMBLIES[@]}"; do
    sample="$(basename "${asm}" .fna)"
    ln -sf "${asm}" "${STAGING}/${sample}.fna"
done
echo "Staged ${#ASSEMBLIES[@]} genomes into ${STAGING}"

gtdbtk classify_wf \
    --genome_dir "${STAGING}" \
    --out_dir "${GTDBTK_OUT}" \
    --cpus "${CPUS}" \
    --pplacer_cpus "${CPUS}" \
    --scratch_dir "${GTDBTK_OUT}/.pplacer_scratch"

rm -rf "${STAGING}" "${GTDBTK_OUT}/.pplacer_scratch"

echo ""
echo "=========================================="
echo "Done on $(date)"
echo "GTDB-Tk output: ${GTDBTK_OUT}/"
echo "=========================================="
