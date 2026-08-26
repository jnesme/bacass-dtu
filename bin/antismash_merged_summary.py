#!/usr/bin/env python3
"""
antismash_merged_summary.py
============================
Builds a corrected BGC summary table directly from antiSMASH's own native
JSON output, replacing nf-core/funcscan's COMBGC (which parses antiSMASH's
GenBank output + a separately-parsed clusterblast text file instead of using
antiSMASH's stable JSON schema — see CLAUDE.md's "Known caveat").

Input is the *merged* antiSMASH output produced by run_bgc_sideload_merge.sh
(<funcscan-outdir>/bgc/antismash_merged/<sample>/<sample>.json), i.e. each
sample's original antiSMASH detection reused (--reuse-results) with DeepBGC's
and GECCO's antiSMASH-sideload calls merged in (--sideload) — one row per
final BGC region ("area"), with per-region tool provenance recovered by
overlapping each region against
record['modules']['antismash.detection.sideloader']['subregions']
(each tagged tool.name: DeepBGC/GECCO). A region with its own antiSMASH
rule-based candidate(s) (n_candidates > 0) is antiSMASH-native; overlapping
sideloader subregions add DeepBGC/GECCO to that region's source_tools.

Usage:
    python bin/antismash_merged_summary.py --funcscan-outdir <dir> -o <output.tsv>
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path


def _overlaps(a_start: int, a_end: int, b_start: int, b_end: int) -> bool:
    return a_start < b_end and b_start < a_end


def summarize_sample(sample: str, json_path: Path) -> list[dict]:
    with json_path.open() as fh:
        data = json.load(fh)

    rows = []
    for rec in data.get("records", []):
        contig = rec.get("name", "NA")
        sideloader = rec.get("modules", {}).get("antismash.detection.sideloader") or {}
        subregions = sideloader.get("subregions", [])

        for idx, area in enumerate(rec.get("areas", []), start=1):
            start = area.get("start")
            end = area.get("end")
            products = area.get("products", [])
            n_candidates = len(area.get("candidates", []))

            source_tools = set()
            if n_candidates > 0:
                source_tools.add("antiSMASH")
            for sub in subregions:
                if _overlaps(start, end, sub.get("start", -1), sub.get("end", -1)):
                    tool_name = sub.get("tool", {}).get("name")
                    if tool_name:
                        source_tools.add(tool_name)

            rows.append(
                {
                    "sample": sample,
                    "contig": contig,
                    "region_index": idx,
                    "start": start,
                    "end": end,
                    "length_bp": (end - start) if (start is not None and end is not None) else "NA",
                    "products": ";".join(products) if products else "NA",
                    "n_candidates": n_candidates,
                    "source_tools": ";".join(sorted(source_tools)) if source_tools else "NA",
                }
            )
    return rows


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--funcscan-outdir", required=True, help="Funcscan results dir")
    p.add_argument(
        "--antismash-subdir",
        default="bgc/antismash_merged",
        help=(
            "Subdir under --funcscan-outdir holding <sample>/<sample>.json, relative to "
            "--funcscan-outdir. Default 'bgc/antismash_merged' is run_bgc_sideload_merge.sh's "
            "output tree (fixing an already-published, pre-patch OUTDIR). For a funcscan OUTDIR "
            "produced by the live pipeline *with* the antiSMASH-sideload patch applied "
            "(conf/funcscan_patches/bgc.nf), the merge already happened inline — pass 'bgc/antismash' "
            "instead, since COMBGC's own summary can't see sideloaded regions (it only reads "
            "antiSMASH's native `protocluster` features, which sideloaded areas never have — "
            "confirmed by cross-checking a live pipeline run's combgc_complete_summary.tsv, which "
            "was byte-identical to the pre-sideload run despite antiSMASH's own region count jumping "
            "up to 8x)."
        ),
    )
    p.add_argument("-o", "--output", required=True, help="Output TSV path")
    args = p.parse_args(argv)

    merged_dir = Path(args.funcscan_outdir) / args.antismash_subdir
    if not merged_dir.is_dir():
        print(f"ERROR: {merged_dir} not found — run run_bgc_sideload_merge.sh first, or check --antismash-subdir", file=sys.stderr)
        return 1

    all_rows = []
    sample_dirs = sorted(d for d in merged_dir.iterdir() if d.is_dir())
    for sample_dir in sample_dirs:
        sample = sample_dir.name
        json_path = sample_dir / f"{sample}.json"
        if not json_path.exists():
            print(f"WARNING: {json_path} missing — skipping {sample}", file=sys.stderr)
            continue
        all_rows.extend(summarize_sample(sample, json_path))

    fieldnames = [
        "sample",
        "contig",
        "region_index",
        "start",
        "end",
        "length_bp",
        "products",
        "n_candidates",
        "source_tools",
    ]
    out_path = Path(args.output)
    with out_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames, delimiter="\t")
        writer.writeheader()
        writer.writerows(all_rows)

    n_samples = len(sample_dirs)
    n_regions = len(all_rows)
    print(f"[INFO] {n_samples} samples, {n_regions} BGC regions written to {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
