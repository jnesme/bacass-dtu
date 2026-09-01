#!/usr/bin/env python3
"""
Cross-sample summary for PADLOC anti-phage defense-system scan output
(run_padloc_scan.sh).

A sample with zero defense systems is a real, successfully-scanned "0"
result, not a missing/failed sample -- PADLOC's own R code (padloc.R,
~line 868) only writes "<sample>_padloc.csv" when nrow(padloc_out) > 0, but
its bash wrapper always writes "<sample>.domtblout" (the hmmsearch step)
regardless of hit count. This script uses domtblout presence, not csv
presence, to tell "scanned, zero hits" apart from "not scanned yet" --
matching run_padloc_scan.sh's own skip-if-scanned check.

PADLOC's CSV is one row per protein hit, not one row per system instance
(unlike DefenseFinder's *_defense_finder_systems.tsv) -- e.g. a 3-gene system
is 3 rows. Distinct system instances are deduplicated here by the
(seqid, system.number) pair PADLOC itself assigns, to match DefenseFinder's
one-row-per-system summary granularity.

Usage:
    python bin/padloc_summary.py --padloc-outdir <bacass-outdir>/padloc -o padloc_summary.tsv
"""

import argparse
import csv
import os
import sys
from collections import Counter


def summarize_sample(csv_path):
    """Return (n_systems, Counter of system-type -> instance count)."""
    if not os.path.isfile(csv_path):
        return 0, Counter()
    seen = set()
    types = Counter()
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            key = (row["seqid"], row["system.number"])
            if key in seen:
                continue
            seen.add(key)
            types[row["system"]] += 1
    return len(seen), types


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--padloc-outdir", required=True, help="<bacass-outdir>/padloc, containing <sample>/ subdirs")
    ap.add_argument("-o", "--output", required=True, help="Output TSV path")
    args = ap.parse_args()

    if not os.path.isdir(args.padloc_outdir):
        sys.exit(f"ERROR: {args.padloc_outdir} not found")

    samples = sorted(
        d for d in os.listdir(args.padloc_outdir)
        if os.path.isdir(os.path.join(args.padloc_outdir, d))
    )
    if not samples:
        sys.exit(f"ERROR: no sample subdirectories found under {args.padloc_outdir}")

    n_scanned = 0
    with open(args.output, "w", newline="") as out_f:
        writer = csv.writer(out_f, delimiter="\t")
        writer.writerow(["sample", "n_systems", "system_types"])
        for sample in samples:
            sample_dir = os.path.join(args.padloc_outdir, sample)
            domtbl = os.path.join(sample_dir, f"{sample}.domtblout")
            if not os.path.isfile(domtbl):
                print(f"WARNING: {sample} has no .domtblout -- scan incomplete/failed, skipping", file=sys.stderr)
                continue
            n_scanned += 1
            csv_path = os.path.join(sample_dir, f"{sample}_padloc.csv")
            n_systems, types = summarize_sample(csv_path)
            types_str = ";".join(f"{t}:{c}" for t, c in types.most_common()) or "NA"
            writer.writerow([sample, n_systems, types_str])

    print(f"Done. {n_scanned}/{len(samples)} samples scanned, summary written to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
