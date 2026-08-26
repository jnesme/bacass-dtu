#!/usr/bin/env python3
"""
bgc_defense_proximity.py

For each antiSMASH-predicted BGC region, find the nearest DefenseFinder
anti-phage defense system on the same contig, in both gene-index distance
(matching Shomar et al. 2026, Cell Host & Microbe, "A family of
lanthipeptides with anti-phage function" — that paper's window is +/-23
genes) and bp distance.

Gene-index numbering is derived from each sample's Bakta .tsv, filtered to
type=="cds" and taken in file order. This has been verified to exactly
reproduce DefenseFinder's own hit_pos column (checked against S0204: Bakta
CDS-only file-order rank 43/44/45 for DMALBP_00215/00220/00225, and rank 486
for DMALBP_02485 — both match hit_pos exactly), so a BGC's gene-index range
is computed the same way for consistency, rather than trusting antiSMASH's
own embedded locus tags (which include synthetic "allorf_START_END" ORFs
that don't exist in Bakta's/DefenseFinder's locus-tag space).

Inputs (per sample <id>):
  - Bakta:          <bacass-outdir>/Bakta/<id>/<id>.tsv
  - DefenseFinder:  <bacass-outdir>/defensefinder/<id>/<id>_defense_finder_systems.tsv
  - antiSMASH BGCs: <funcscan-outdir>/bgc/antismash/<id>/*.region*.gbk

Output: one TSV row per BGC region, keyed by the same Record ID format used
in BiG-SCAPE's record_annotations.tsv (e.g.
"S1190_contig_53.region001.gbk_region_1"), so it joins directly against
existing BiG-SCAPE output without a separate ID scheme.

Usage:
  python bin/bgc_defense_proximity.py \\
      --bacass-outdir /path/to/Bacass_results_merged \\
      --funcscan-outdir /path/to/funcscan_results_merged \\
      --window-genes 23 \\
      -o bgc_defense_proximity.tsv
"""

import argparse
import csv
import glob
import os
import re
import sys

REGION_RE = re.compile(r"region(\d+)\.gbk$")
ORIG_START_RE = re.compile(r"Orig\.\s*start\s*::\s*(\d+)")
ORIG_END_RE = re.compile(r"Orig\.\s*end\s*::\s*(\d+)")
LOCUS_RE = re.compile(r"^LOCUS\s+(\S+)")
CORE_LOCATION_RE = re.compile(r'core_location="\[(\d+):(\d+)\]')


def load_bakta_genes(bakta_tsv):
    """Return (contig -> ordered list of (start, stop, locus_tag, gene_index)),
    (locus_tag -> (contig, gene_index, start, stop)). gene_index is 1-based,
    file-order rank among type=="cds" rows only (matches DefenseFinder hit_pos)."""
    by_contig = {}
    by_locus_tag = {}
    idx = 0
    with open(bakta_tsv) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 6 or fields[1] != "cds":
                continue
            contig, _, start, stop, _, locus_tag = fields[0], fields[1], int(fields[2]), int(fields[3]), fields[4], fields[5]
            idx += 1
            by_contig.setdefault(contig, []).append((start, stop, locus_tag, idx))
            by_locus_tag[locus_tag] = (contig, idx, start, stop)
    return by_contig, by_locus_tag


def load_defense_systems(systems_tsv, by_locus_tag):
    """Return list of dicts: sys_id, type, subtype, contig, gene_idx_min/max, bp_min/max."""
    systems = []
    if not os.path.isfile(systems_tsv):
        return systems
    with open(systems_tsv) as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            protein_ids = [p for p in row["protein_in_syst"].split(",") if p]
            gene_idxs, starts, stops, contigs = [], [], [], set()
            for lt in protein_ids:
                hit = by_locus_tag.get(lt)
                if hit is None:
                    continue
                contig, gi, start, stop = hit
                gene_idxs.append(gi)
                starts.append(start)
                stops.append(stop)
                contigs.add(contig)
            if not gene_idxs or len(contigs) != 1:
                continue
            systems.append({
                "sys_id": row["sys_id"],
                "type": row["type"],
                "subtype": row["subtype"],
                "contig": contigs.pop(),
                "gene_idx_min": min(gene_idxs),
                "gene_idx_max": max(gene_idxs),
                "bp_min": min(starts),
                "bp_max": max(stops),
            })
    return systems


def bgc_gene_range(contig_genes, orig_start, orig_end):
    """Find the gene-index range of Bakta CDS genes overlapping [orig_start, orig_end]
    (1-based inclusive). Falls back to the nearest single flanking gene if none
    overlap (e.g. a short intergenic/allorf-only BGC)."""
    overlapping = [gi for (start, stop, _lt, gi) in contig_genes if start <= orig_end and stop >= orig_start]
    if overlapping:
        return min(overlapping), max(overlapping)
    # fallback: nearest gene by midpoint distance to the BGC's own midpoint
    if not contig_genes:
        return None, None
    bgc_mid = (orig_start + orig_end) / 2
    nearest = min(contig_genes, key=lambda g: abs(((g[0] + g[1]) / 2) - bgc_mid))
    return nearest[3], nearest[3]


def nearest_defense_system(contig, gene_idx_min, gene_idx_max, bp_min, bp_max, systems):
    best = None
    for sys_ in systems:
        if sys_["contig"] != contig:
            continue
        if gene_idx_max < sys_["gene_idx_min"]:
            gdist = sys_["gene_idx_min"] - gene_idx_max
        elif sys_["gene_idx_max"] < gene_idx_min:
            gdist = gene_idx_min - sys_["gene_idx_max"]
        else:
            gdist = 0
        if bp_max < sys_["bp_min"]:
            bdist = sys_["bp_min"] - bp_max
        elif sys_["bp_max"] < bp_min:
            bdist = bp_min - sys_["bp_max"]
        else:
            bdist = 0
        if best is None or gdist < best[0]:
            best = (gdist, bdist, sys_)
    return best


def parse_bgc_gbk(gbk_path):
    """Return (contig, region_start_1based, region_end_1based, core_start_1based, core_end_1based)
    or None if not parseable.

    antiSMASH's "region" boundary (Orig. start/end) is padded well beyond the
    actual biosynthetic genes (e.g. a 6-8 kb core cluster inside a 56 kb
    padded region is typical) — using it as "the BGC" for proximity purposes
    produces false "touching" calls against anything that happens to fall in
    the flanking padding (confirmed Aug 2026: a dGTPase anti-phage gene ~20 kb
    from the real PUFA/EPA synthase core genes was showing as 0-distance
    "inside" the BGC purely because it fell within the padded region). The
    core_location field on each protocluster feature gives the tight
    biosynthetic-gene boundary instead — when multiple protoclusters exist in
    one region (common: antiSMASH merges nearby clusters into one region),
    the union (min start, max end) across all of them is used, since that's
    already why antiSMASH grouped them together.

    core_location is in BioPython's 0-based half-open notation, relative to
    the region's own local 1-based numbering (position 1 = Orig. start).
    """
    contig = None
    orig_start = orig_end = None
    core_starts, core_ends = [], []
    with open(gbk_path) as f:
        for line in f:
            if contig is None:
                m = LOCUS_RE.match(line)
                if m:
                    contig = m.group(1)
            m = ORIG_START_RE.search(line)
            if m:
                orig_start = int(m.group(1))
            m = ORIG_END_RE.search(line)
            if m:
                orig_end = int(m.group(1))
            m = CORE_LOCATION_RE.search(line)
            if m:
                core_starts.append(int(m.group(1)))
                core_ends.append(int(m.group(2)))
    if contig is None or orig_start is None or orig_end is None:
        return None
    region_start, region_end = orig_start + 1, orig_end
    if core_starts:
        core_start = orig_start + min(core_starts) + 1
        core_end = orig_start + max(core_ends)
    else:
        # No protocluster/core_location found (seen for some RiPP-type
        # regions) — fall back to the padded region boundary.
        core_start, core_end = region_start, region_end
    return contig, region_start, region_end, core_start, core_end


def process_sample(sample, bakta_tsv, systems_tsv, antismash_dir, window_genes, writer):
    if not os.path.isfile(bakta_tsv):
        print(f"WARNING: no Bakta tsv for {sample} at {bakta_tsv} — skipping", file=sys.stderr)
        return 0
    by_contig, by_locus_tag = load_bakta_genes(bakta_tsv)
    systems = load_defense_systems(systems_tsv, by_locus_tag)

    n = 0
    for gbk_path in sorted(glob.glob(os.path.join(antismash_dir, "*.region*.gbk"))):
        m = REGION_RE.search(gbk_path)
        if not m:
            continue
        region_num = int(m.group(1))
        basename = os.path.basename(gbk_path)
        record_id = f"{sample}_{basename}_region_{region_num}"

        parsed = parse_bgc_gbk(gbk_path)
        if parsed is None:
            print(f"WARNING: could not parse coordinates from {gbk_path} — skipping", file=sys.stderr)
            continue
        contig, region_start, region_end, orig_start, orig_end = parsed

        contig_genes = by_contig.get(contig, [])
        gi_min, gi_max = bgc_gene_range(contig_genes, orig_start, orig_end)

        base_row = [record_id, sample, contig, region_start, region_end, orig_start, orig_end]

        if gi_min is None or not systems:
            writer.writerow(base_row + [gi_min or "NA", gi_max or "NA",
                                         "NA", "NA", "NA", "NA", "NA", "no"])
            n += 1
            continue

        result = nearest_defense_system(contig, gi_min, gi_max, orig_start, orig_end, systems)
        if result is None:
            writer.writerow(base_row + [gi_min, gi_max, "NA", "NA", "NA", "NA", "NA", "no"])
        else:
            gdist, bdist, sys_ = result
            within = "yes" if gdist <= window_genes else "no"
            writer.writerow(base_row + [gi_min, gi_max, sys_["sys_id"], sys_["type"], sys_["subtype"],
                                         gdist, bdist, within])
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bacass-outdir", required=True, help="Bacass results dir with Bakta/ and defensefinder/")
    ap.add_argument("--funcscan-outdir", required=True, help="Funcscan results dir with bgc/antismash/")
    ap.add_argument(
        "--antismash-subdir",
        default="bgc/antismash",
        help=(
            "Subdir under --funcscan-outdir holding <sample>/*.region*.gbk, relative to "
            "--funcscan-outdir. Default 'bgc/antismash' is antiSMASH's own (pre-sideload-fix) "
            "output. Pass 'bgc/antismash_merged' to use run_bgc_sideload_merge.sh's corrected, "
            "GECCO/DeepBGC-integrated output instead (see CLAUDE.md's BGC-merge caveat) — only "
            "samples already processed by that script will be present, so a run against it "
            "naturally covers whatever subset has finished so far."
        ),
    )
    ap.add_argument("--window-genes", type=int, default=23, help="Gene-index window for 'near' classification (default: 23, matching Shomar et al. 2026)")
    ap.add_argument("-o", "--output", required=True, help="Output TSV path")
    args = ap.parse_args()

    antismash_root = os.path.join(args.funcscan_outdir, args.antismash_subdir)
    samples = sorted(
        d for d in os.listdir(antismash_root)
        if os.path.isdir(os.path.join(antismash_root, d))
    )
    if not samples:
        sys.exit(f"ERROR: no sample subdirectories found under {antismash_root}")

    header = ["Record", "sample", "contig",
              "bgc_region_start", "bgc_region_end",  # antiSMASH's padded region boundary (reference only)
              "bgc_core_start", "bgc_core_end",       # tight core_location boundary — used for all proximity calcs
              "bgc_gene_idx_min", "bgc_gene_idx_max",
              "nearest_defense_sys_id", "nearest_defense_type", "nearest_defense_subtype",
              "defense_gene_distance", "defense_bp_distance", "within_window"]

    total = 0
    with open(args.output, "w", newline="") as out_f:
        writer = csv.writer(out_f, delimiter="\t")
        writer.writerow(header)
        for i, sample in enumerate(samples, 1):
            bakta_tsv = os.path.join(args.bacass_outdir, "Bakta", sample, f"{sample}.tsv")
            systems_tsv = os.path.join(args.bacass_outdir, "defensefinder", sample, f"{sample}_defense_finder_systems.tsv")
            antismash_dir = os.path.join(antismash_root, sample)
            n = process_sample(sample, bakta_tsv, systems_tsv, antismash_dir, args.window_genes, writer)
            total += n
            print(f"[{i}/{len(samples)}] {sample}: {n} BGC records", file=sys.stderr)

    print(f"Done. {total} BGC records written to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
