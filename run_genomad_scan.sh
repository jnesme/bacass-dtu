#!/bin/bash
### General options
### -- specify queue --
#BSUB -q hpc
### -- set the job Name --
#BSUB -J genomad_scan
### -- ask for number of cores --
#BSUB -n 8
### -- all cores on one host --
#BSUB -R "span[hosts=1] rusage[mem=16GB]"
### -- specify that we want the job to get killed if it exceeds 17 GB --
### (must stay within 5% of rusage[mem=16GB]=16384MB, i.e. <=17203MB, or this
### cluster's esub rejects the submission outright)
#BSUB -M 17200MB
### -- set walltime limit: hh:mm --
#BSUB -W 24:00
### -- set the email address --
#BSUB -u josne@dtu.dk
### -- send notification at start --
#BSUB -B
### -- send notification at completion --
#BSUB -N
### -- Specify the output and error file. %J is the job-id --
#BSUB -o genomad_scan_%J.out
#BSUB -e genomad_scan_%J.err

# ============================================================================
# Runs geNomad (plasmid/virus identification) on every Unicycler assembly in
# a bacass OUTDIR, then builds a cross-sample summary. Independent of
# Unicycler's own "closed/circular" completeness flag — that only catches
# elements that fully resolved into a single loop in the assembly graph
# (17 out of ~38 completed batch2 samples at time of writing). geNomad scores
# every contig by sequence composition + marker genes regardless of assembly
# topology, so it also catches plasmid-derived contigs that never closed.
#
# Demoed Aug 2026 on S1089 (Bacass_results_batch2): found 16 plasmids + 1
# provirus vs. Unicycler's single closed element, including a 224 kb
# conjugative megaplasmid (traI/traY/traN) carrying no AMR genes itself, plus
# 3 smaller plasmids each carrying a different aminoglycoside-resistance gene
# family (aac(2')-Ia x2, aac(3)-XI + ant(9)), and an 11.6 kb integrated
# provirus (Preplasmiviricota/Tectiliviricetes, PM2/Corticoviridae-like).
#
# Runtime: ~3.5 min/sample at 8 threads for a ~6 Mb, ~260-contig genome — runs
# serially here (simple, matches this project's single-bsub-job convention);
# parallelize across samples later if the full 83-sample batch2 needs it.
#
# Usage:
#   ./run_genomad_scan.sh <OUTDIR> [threads]
#   bsub < run_genomad_scan.sh  (edit OUTDIR below first)
# ============================================================================

set -euo pipefail

BACASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <OUTDIR> [threads]"
    echo "  OUTDIR   Bacass results directory containing Unicycler/*.scaffolds.fa.gz"
    echo "           (or, for the preassembled-genome entry point with no Unicycler/"
    echo "           dir, Bakta/<sample>/<sample>.fna is used as a fallback)"
    echo "  threads  Optional, passed to genomad end-to-end (default: 8)"
    exit 1
}

[ $# -ge 1 ] || usage
OUTDIR="$(cd "$1" 2>/dev/null && pwd)" || { echo "ERROR: OUTDIR '$1' does not exist or is not a directory"; exit 1; }
THREADS="${2:-8}"

GENOMAD_ENV="/work3/josne/miniconda3/envs/genomad"
GENOMAD_DB="/work3/josne/Databases/genomad_db"

[ -x "${GENOMAD_ENV}/bin/genomad" ] || { echo "ERROR: geNomad env not found at ${GENOMAD_ENV}"; exit 1; }
[ -d "${GENOMAD_DB}" ] || { echo "ERROR: geNomad database not found at ${GENOMAD_DB}"; exit 1; }

# genomad invokes mmseqs as a bare command internally, not via absolute path,
# so the env's bin/ must be on PATH — same class of fix as run_defensefinder_scan.sh's
# hmmsearch. Without this, "end-to-end" dies immediately with "missing dependencies: mmseqs".
export PATH="${GENOMAD_ENV}/bin:${PATH}"

# Preassembled-genome entry point (main_preassembled.nf) has no Unicycler/Dragonflye
# assembler dir — fall back to Bakta's own re-emitted nucleotide FASTA, same fallback
# already applied to bacass_to_funcscan.sh for this same entry point.
ASSEMBLY_FROM_BAKTA=false
if [ -d "${OUTDIR}/Unicycler" ]; then
    mapfile -t ASSEMBLIES < <(find "${OUTDIR}/Unicycler" -name "*.scaffolds.fa.gz" | sort)
else
    echo "No Unicycler/ output found — assuming preassembled-genome entry point (main_preassembled.nf); using each sample's Bakta-annotated .fna as the assembly FASTA"
    ASSEMBLY_FROM_BAKTA=true
    mapfile -t ASSEMBLIES < <(find "${OUTDIR}/Bakta" -mindepth 2 -maxdepth 2 -name "*.fna" | sort)
fi
echo "=========================================="
echo "geNomad scan"
echo "Job started on $(date)"
echo "OUTDIR: ${OUTDIR}"
echo "Assemblies found: ${#ASSEMBLIES[@]}"
echo "Threads: ${THREADS}"
echo "=========================================="
if [ "${#ASSEMBLIES[@]}" -eq 0 ]; then
    echo "ERROR: no assembly FASTAs found (looked for ${OUTDIR}/Unicycler/*.scaffolds.fa.gz and ${OUTDIR}/Bakta/*/*.fna)"
    exit 1
fi

GENOMAD_OUT="${OUTDIR}/genomad"
mkdir -p "${GENOMAD_OUT}"

STAGING=$(mktemp -d)
trap 'rm -rf "${STAGING}"' EXIT

i=0
for asm in "${ASSEMBLIES[@]}"; do
    i=$((i + 1))
    if [ "${ASSEMBLY_FROM_BAKTA}" = true ]; then
        sample="$(basename "${asm}" .fna)"
    else
        sample="$(basename "${asm}" .scaffolds.fa.gz)"
    fi
    echo ""
    echo "=== Sample ${i}/${#ASSEMBLIES[@]}: ${sample} ==="

    if [ -f "${GENOMAD_OUT}/${sample}/${sample}.scaffolds_summary/${sample}.scaffolds_plasmid_summary.tsv" ] || \
       [ -f "${GENOMAD_OUT}/${sample}/${sample}_summary/${sample}_plasmid_summary.tsv" ]; then
        echo "Already scanned, skipping"
        continue
    fi

    if [ "${ASSEMBLY_FROM_BAKTA}" = true ]; then
        fasta="${asm}"
    else
        fasta="${STAGING}/${sample}.scaffolds.fasta"
        zcat "${asm}" > "${fasta}"
    fi

    "${GENOMAD_ENV}/bin/genomad" end-to-end "${fasta}" "${GENOMAD_OUT}/${sample}" "${GENOMAD_DB}" \
        --threads "${THREADS}" --quiet

    [ "${ASSEMBLY_FROM_BAKTA}" = true ] || rm -f "${fasta}"
done

# ============================================================
# Build cross-sample summary
# ============================================================
echo ""
echo "=== Building cross-sample summary ==="

SUMMARY="${GENOMAD_OUT}/genomad_summary.tsv"
{
    printf "sample\tn_plasmids\tn_viruses\tlargest_plasmid_bp\thas_conjugation_genes\tamr_gene_families\n"
    for asm in "${ASSEMBLIES[@]}"; do
        if [ "${ASSEMBLY_FROM_BAKTA}" = true ]; then
            sample="$(basename "${asm}" .fna)"
            pl="${GENOMAD_OUT}/${sample}/${sample}_summary/${sample}_plasmid_summary.tsv"
            vi="${GENOMAD_OUT}/${sample}/${sample}_summary/${sample}_virus_summary.tsv"
        else
            sample="$(basename "${asm}" .scaffolds.fa.gz)"
            pl="${GENOMAD_OUT}/${sample}/${sample}.scaffolds_summary/${sample}.scaffolds_plasmid_summary.tsv"
            vi="${GENOMAD_OUT}/${sample}/${sample}.scaffolds_summary/${sample}.scaffolds_virus_summary.tsv"
        fi
        [ -f "${pl}" ] || continue

        n_plasmids=$(($(wc -l < "${pl}") - 1))
        n_viruses=0
        [ -f "${vi}" ] && n_viruses=$(($(wc -l < "${vi}") - 1))
        largest=$(tail -n +2 "${pl}" | cut -f2 | sort -rn | head -1)
        [ -z "${largest}" ] && largest="NA"
        # Note: this system's `grep` is ugrep, which mishandles combined -qv
        # (always exits 1 regardless of match) — use -vc (count) instead,
        # never -qv, for any invert-match boolean check on this HPC.
        has_conj="no"
        # grep -c always prints a count (0 on no match) but still exits 1 in that
        # case; under `set -e`, `var=$(... | grep -c ...)` alone would abort the
        # script on a legitimate zero-match sample. `|| echo 0` is the wrong fix —
        # it fires in ADDITION to grep's own printed "0", yielding "0\n0" and
        # breaking the -gt test below. Use `|| true` (no extra output) instead.
        n_conj=$(tail -n +2 "${pl}" | cut -f10 | { grep -vc '^NA$' || true; } 2>/dev/null)
        [ "${n_conj}" -gt 0 ] && has_conj="yes"
        # Same `pipefail` hazard as n_conj above: grep -v exits 1 when every row
        # is NA (no AMR genes), which would kill the whole pipeline under
        # pipefail even though "no matches" is a legitimate, common outcome here.
        amr=$(tail -n +2 "${pl}" | cut -f11 | { grep -v '^NA$' || true; } | tr '\n' ';' | sed 's/;$//')
        [ -z "${amr}" ] && amr="NA"

        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "${sample}" "${n_plasmids}" "${n_viruses}" "${largest}" "${has_conj}" "${amr}"
    done
} > "${SUMMARY}"

echo ""
echo "=========================================="
echo "Done on $(date)"
echo "Per-sample geNomad output: ${GENOMAD_OUT}/<sample>/"
echo "Cross-sample summary: ${SUMMARY}"
echo "=========================================="
