#!/usr/bin/env python3
"""
Backfill real, current organism metadata (SOURCE/ORGANISM in .gbff, OS/OC in .embl) into a bacass
OUTDIR's already-published Bakta output, using a GTDB-Tk classify_wf run (run_gtdbtk_scan.sh) as the
source -- patches Bakta's own files IN PLACE (backup taken first), correcting the true source data
rather than every downstream copy independently.

This is a standalone, one-off correction for genomes annotated before conf/modules.config's
BAKTA_BAKTA ext.args existed (or where the live pipeline's KmerFinder-based confidence gate declined
to pass --species) -- NOT part of the live Nextflow pipeline, matching the
DefenseFinder/PADLOC/geNomad/KmerFinder-scan/GTDB-Tk-scan convention (see CLAUDE.md / project memory).

Usage:
    python3 bin/patch_bakta_organism_gtdbtk.py <OUTDIR> [--dry-run]

<OUTDIR> must contain:
    Bakta/<sample>/<sample>.gbff, <sample>.embl
    gtdbtk/classify/gtdbtk.bac120.summary.tsv  (and/or gtdbtk.ar53.summary.tsv for archaea)
    (i.e. the output of run_gtdbtk_scan.sh already run against this same OUTDIR)
"""

import argparse
import glob
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gbk_organism_patch import parse_gtdbtk_classification, rewrite_gbff_source_organism, rewrite_embl_os_oc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("outdir", help="Bacass OUTDIR containing Bakta/ and gtdbtk/classify/")
    parser.add_argument("--dry-run", action="store_true", help="Report what would change without writing anything")
    args = parser.parse_args()

    bakta_dir = os.path.join(args.outdir, "Bakta")
    gtdbtk_classify_dir = os.path.join(args.outdir, "gtdbtk", "classify")
    backup_root = os.path.join(bakta_dir, ".pre_gtdbtk_organism_fix_backup")

    if not os.path.isdir(bakta_dir):
        sys.exit(f"ERROR: {bakta_dir} not found")

    summary_paths = sorted(glob.glob(os.path.join(gtdbtk_classify_dir, "gtdbtk.*.summary.tsv")))
    if not summary_paths:
        sys.exit(f"ERROR: no gtdbtk.*.summary.tsv found under {gtdbtk_classify_dir} "
                  f"-- run run_gtdbtk_scan.sh against this OUTDIR first")

    classification = {}
    for summary_path in summary_paths:
        classification.update(parse_gtdbtk_classification(summary_path))
    print(f"Parsed GTDB-Tk classification for {len(classification)} samples from {len(summary_paths)} summary file(s)")

    samples = sorted(
        s for s in os.listdir(bakta_dir)
        if os.path.isdir(os.path.join(bakta_dir, s)) and not s.startswith(".")
    )

    total_patched = 0
    total_already_ok = 0
    total_no_classification = 0
    total_genus_only = 0
    total_species = 0

    for sample in samples:
        if sample not in classification:
            total_no_classification += 1
            continue

        organism_label, taxonomy, genus, species = classification[sample]
        if species:
            total_species += 1
        elif genus:
            total_genus_only += 1

        for ext, rewrite_fn in (("gbff", rewrite_gbff_source_organism), ("embl", rewrite_embl_os_oc)):
            file_path = os.path.join(bakta_dir, sample, f"{sample}.{ext}")
            if not os.path.isfile(file_path):
                continue

            with open(file_path) as fh:
                lines = fh.readlines()

            patched_lines = rewrite_fn(lines, organism_label, taxonomy)

            if patched_lines == lines:
                total_already_ok += 1
                continue

            if not args.dry_run:
                backup_dir = os.path.join(backup_root, sample)
                os.makedirs(backup_dir, exist_ok=True)
                backup_path = os.path.join(backup_dir, f"{sample}.{ext}")
                if not os.path.exists(backup_path):
                    shutil.copy2(file_path, backup_path)

                with open(file_path, "w") as fh:
                    fh.writelines(patched_lines)

            total_patched += 1

    print(f"\n=== Summary{' (DRY RUN, nothing written)' if args.dry_run else ''} ===")
    print(f"Files patched:              {total_patched}")
    print(f"Files already correct:      {total_already_ok}")
    print(f"Samples with no GTDB-Tk hit: {total_no_classification}")
    print(f"Samples with real species:   {total_species}")
    print(f"Samples genus-only:          {total_genus_only}")
    if total_patched:
        print(f"Backups at: {backup_root}/<sample>/")


if __name__ == "__main__":
    main()
