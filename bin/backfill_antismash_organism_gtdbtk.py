#!/usr/bin/env python3
"""
Backfill GTDB-Tk-derived organism metadata into a funcscan OUTDIR's antiSMASH region GBKs
(bgc/antismash/ and bgc/antismash_merged/, whichever exist), patching them IN PLACE (backup taken
first), using a completed run_gtdbtk_scan.sh run against the corresponding bacass OUTDIR as the
source. Mirrors the same fix already applied to Bakta's own output via
patch_bakta_organism_gtdbtk.py -- antiSMASH's region GBKs are generated from the *original*,
unpatched Bakta .gbff, so they stay blank even after Bakta's own record is corrected, exactly the
same situation this project already hit and fixed once for vibrio_seq (KmerFinder-based instead of
GTDB-Tk-based; see vibrio_seq/backfill_antismash_organism.py, project-local, same structure).

Usage:
    python3 bin/backfill_antismash_organism_gtdbtk.py <bacass_outdir> <funcscan_outdir> [--dry-run]

<bacass_outdir> must contain gtdbtk/classify/gtdbtk.*.summary.tsv (i.e. run_gtdbtk_scan.sh already
run against it). <funcscan_outdir> must contain bgc/antismash/ and/or bgc/antismash_merged/.
"""

import argparse
import glob
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gbk_organism_patch import parse_gtdbtk_classification, rewrite_gbff_source_organism

TREES = ["antismash", "antismash_merged"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bacass_outdir", help="Bacass OUTDIR containing gtdbtk/classify/")
    parser.add_argument("funcscan_outdir", help="Funcscan OUTDIR containing bgc/antismash{,_merged}/")
    parser.add_argument("--dry-run", action="store_true", help="Report what would change without writing anything")
    args = parser.parse_args()

    gtdbtk_classify_dir = os.path.join(args.bacass_outdir, "gtdbtk", "classify")
    summary_paths = sorted(glob.glob(os.path.join(gtdbtk_classify_dir, "gtdbtk.*.summary.tsv")))
    if not summary_paths:
        sys.exit(f"ERROR: no gtdbtk.*.summary.tsv found under {gtdbtk_classify_dir} "
                  f"-- run run_gtdbtk_scan.sh against {args.bacass_outdir} first")

    classification = {}
    for summary_path in summary_paths:
        classification.update(parse_gtdbtk_classification(summary_path))
    print(f"Parsed GTDB-Tk classification for {len(classification)} samples from {len(summary_paths)} summary file(s)")

    bgc_dir = os.path.join(args.funcscan_outdir, "bgc")
    backup_root = os.path.join(bgc_dir, ".pre_gtdbtk_organism_fix_backup")

    total_patched = 0
    total_already_ok = 0
    total_no_classification = 0
    missing_samples = set()

    for tree in TREES:
        tree_dir = os.path.join(bgc_dir, tree)
        if not os.path.isdir(tree_dir):
            print(f"NOTE: {tree_dir} not found, skipping (expected for pipelines that merge BGC "
                  f"sideload data inline, e.g. no separate antismash_merged/ tree)")
            continue

        gbk_paths = sorted(glob.glob(os.path.join(tree_dir, "*", "*.region*.gbk")))
        print(f"\n=== {tree}: {len(gbk_paths)} region GBK files ===")

        tree_patched = 0
        for gbk_path in gbk_paths:
            sample = os.path.basename(os.path.dirname(gbk_path))

            if sample not in classification:
                missing_samples.add(sample)
                total_no_classification += 1
                continue

            organism_label, taxonomy, genus, species = classification[sample]

            with open(gbk_path) as fh:
                lines = fh.readlines()

            patched_lines = rewrite_gbff_source_organism(lines, organism_label, taxonomy)

            if patched_lines == lines:
                total_already_ok += 1
                continue

            if not args.dry_run:
                rel_path = os.path.relpath(gbk_path, bgc_dir)
                backup_path = os.path.join(backup_root, rel_path)
                os.makedirs(os.path.dirname(backup_path), exist_ok=True)
                if not os.path.exists(backup_path):
                    shutil.copy2(gbk_path, backup_path)

                with open(gbk_path, "w") as fh:
                    fh.writelines(patched_lines)

            tree_patched += 1
            total_patched += 1

        print(f"{tree}: {tree_patched} patched (backed up first to {backup_root}/{tree}/)")

    print(f"\n=== Summary{' (DRY RUN, nothing written)' if args.dry_run else ''} ===")
    print(f"Patched:              {total_patched}")
    print(f"Already correct:      {total_already_ok}")
    print(f"No GTDB-Tk hit:       {total_no_classification}")
    if missing_samples:
        print(f"Samples with no GTDB-Tk data: {sorted(missing_samples)}")


if __name__ == "__main__":
    main()
