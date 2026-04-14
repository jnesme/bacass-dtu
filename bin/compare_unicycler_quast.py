#!/usr/bin/env python3
"""
Compare per-sample N50 and longest contig from Unicycler logs vs QUAST report.

Reads:
  - Last 20 lines of *.unicycler.log from two Unicycler result directories
    (rerun and original), extracts N50 and Longest segment from the assembly
    graph summary table.
  - QUAST report.tsv, extracts N50 and Largest contig per sample.

Writes TSV to stdout with columns:
  sample, unicycler_rerun_N50, unicycler_rerun_longest,
          unicycler_original_N50, unicycler_original_longest,
          quast_N50, quast_largest

Usage:
  python bin/compare_unicycler_quast.py > comparison.tsv
  python bin/compare_unicycler_quast.py \\
      --rerun-dir /path/to/Bacass_results/Unicycler \\
      --original-dir /path/to/bak.Bacass_results/Unicycler \\
      --quast-tsv /path/to/bak.Bacass_results/QUAST/report/report.tsv \\
      > comparison.tsv
"""

import argparse
import csv
import sys
from pathlib import Path

RERUN_DIR    = "/work3/josne/Projects/Vibrio_Galathea3/vibrio_seq/Bacass_results/Unicycler"
ORIGINAL_DIR = "/work3/josne/Projects/Vibrio_Galathea3/vibrio_seq/bak.Bacass_results/Unicycler"
QUAST_TSV    = "/work3/josne/Projects/Vibrio_Galathea3/vibrio_seq/bak.Bacass_results/QUAST/report/report.tsv"


def parse_unicycler_log(log_path):
    """Return (N50, longest) from the assembly graph summary table.

    The table looks like:
        Component   Segments   Links   Length      N50       Longest segment   Status
            total        606   1,004   4,503,989   37,490    161,727
                1        604   1,002   4,441,915   37,490    161,727           incomplete
                2          1       1      56,047   56,047     56,047            complete

    Fields (0-indexed): [0]=component/"total", [4]=N50, [5]=longest segment.
    Numbers use comma thousand-separators.

    For multi-component assemblies Unicycler appends a "Rotating completed replicons"
    section after the table, pushing the header well beyond the last 20 lines.
    We therefore scan the full file to find the LAST occurrence of the header,
    then prefer the "total" summary row; fall back to the first component row.
    Returns (None, None) if the table cannot be found.
    """
    with open(log_path) as fh:
        lines = fh.readlines()

    # Find the last line that looks like the assembly graph summary header
    header_idx = None
    for i in range(len(lines) - 1, -1, -1):
        if "Component" in lines[i] and "Segments" in lines[i] and "N50" in lines[i]:
            header_idx = i
            break

    if header_idx is None:
        return None, None

    total_row = None
    first_row = None
    for line in lines[header_idx + 1:]:
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split()
        if len(parts) < 6:
            break  # blank separator or unrelated section started
        try:
            n50     = int(parts[4].replace(",", ""))
            longest = int(parts[5].replace(",", ""))
        except ValueError:
            break
        if parts[0] == "total":
            total_row = (n50, longest)
        elif parts[0].isdigit():
            if first_row is None:
                first_row = (n50, longest)

    return total_row if total_row is not None else first_row


def load_unicycler_dir(directory):
    """Return dict {sample_id: (N50, longest)} for all *.unicycler.log files."""
    result = {}
    dirpath = Path(directory)
    for log in sorted(dirpath.glob("*.unicycler.log")):
        sample = log.name.replace(".unicycler.log", "")
        result[sample] = parse_unicycler_log(log)
    return result


def load_quast_tsv(tsv_path):
    """Return dict {sample_id: (N50, largest)} from QUAST report.tsv.

    Column headers look like 'S0204.scaffolds'; we strip the '.scaffolds' suffix.
    Rows of interest: 'N50' and 'Largest contig'.
    """
    n50_row     = {}
    largest_row = {}

    with open(tsv_path, newline="") as fh:
        reader = csv.reader(fh, delimiter="\t")
        headers = next(reader)
        # Strip known suffix from sample column names
        samples = [h.replace(".scaffolds", "").replace(".fa", "") for h in headers[1:]]

        for row in reader:
            if not row:
                continue
            metric = row[0]
            values = row[1:]
            if metric == "N50":
                for sample, val in zip(samples, values):
                    try:
                        n50_row[sample] = int(val)
                    except (ValueError, TypeError):
                        n50_row[sample] = None
            elif metric == "Largest contig":
                for sample, val in zip(samples, values):
                    try:
                        largest_row[sample] = int(val)
                    except (ValueError, TypeError):
                        largest_row[sample] = None

    all_samples = set(n50_row) | set(largest_row)
    return {s: (n50_row.get(s), largest_row.get(s)) for s in all_samples}


def fmt(val):
    return "NA" if val is None else str(val)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rerun-dir",    default=RERUN_DIR,    help="Unicycler results dir (rerun)")
    parser.add_argument("--original-dir", default=ORIGINAL_DIR, help="Unicycler results dir (original)")
    parser.add_argument("--quast-tsv",    default=QUAST_TSV,    help="QUAST report.tsv path")
    args = parser.parse_args()

    rerun    = load_unicycler_dir(args.rerun_dir)
    original = load_unicycler_dir(args.original_dir)
    quast    = load_quast_tsv(args.quast_tsv)

    all_samples = sorted(set(rerun) | set(original) | set(quast))

    writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    writer.writerow([
        "sample",
        "unicycler_rerun_N50", "unicycler_rerun_longest",
        "unicycler_original_N50", "unicycler_original_longest",
        "quast_N50", "quast_largest",
    ])

    for sample in all_samples:
        rerun_n50,    rerun_longest    = rerun.get(sample,    (None, None))
        orig_n50,     orig_longest     = original.get(sample, (None, None))
        quast_n50,    quast_largest    = quast.get(sample,    (None, None))
        writer.writerow([
            sample,
            fmt(rerun_n50), fmt(rerun_longest),
            fmt(orig_n50),  fmt(orig_longest),
            fmt(quast_n50), fmt(quast_largest),
        ])


if __name__ == "__main__":
    main()
