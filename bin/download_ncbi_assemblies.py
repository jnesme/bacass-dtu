#!/usr/bin/env python3
"""
download_ncbi_assemblies.py
============================
Bulk-downloads genome FASTA files for every accession listed in an NCBI
"Assembly Details" report (e.g. exported per-BioProject), and writes a
two-column samplesheet (`ID,Fasta`) ready for `main_preassembled.nf`.

Generalizes the NCBI Datasets v2alpha REST API logic already proven in
`bin/download_reference.py` (same `_fetch_dataset`/`_extract_files` approach)
to loop over a list of accessions instead of a single kmerfinder winner, and
requests only GENOME_FASTA (no GFF/protein — annotation is redone with Bakta
downstream, so PGAP-format outputs are not needed here).

Input
-----
A tab-separated NCBI assembly-details file with (at minimum) two header
lines followed by rows containing, in order: Assembly accession, Level, WGS,
Chrs, BioSample, Strain, Taxonomy. Only the Assembly accession (column 1)
and Strain (column 6) are used.

Outputs (written inside --out_dir)
-----------------------------------
* `fasta/<ID>.fna.gz`            — one per accession, ID derived from Strain
* `samplesheet_preassembled.csv` — header `ID,Fasta`, ready for
                                    `main_preassembled.nf --input`

Sample IDs are derived from the Strain column with whitespace collapsed to
underscores (e.g. "DSM 25995" -> "DSM_25995") so they are valid Nextflow
sample IDs. Duplicate resulting IDs are treated as a fatal error.
"""
from __future__ import annotations

import argparse
import csv
import gzip
import re
import shutil
import sys
import time
import urllib3
import zipfile
from io import BytesIO
from pathlib import Path
from typing import List, Tuple

# -----------------------------------------------------------------------------
# NCBI Datasets REST API — same approach as bin/download_reference.py, but
# only GENOME_FASTA is requested (no GFF/protein; Bakta redoes annotation).
# -----------------------------------------------------------------------------
_ANNO_SETS: List[List[str]] = [
    ["GENOME_FASTA"],
]

_SUFFIX_MAP = {
    "_genomic.fna": "_genomic.fna.gz",
}

_ACCESSION_RE = re.compile(r"(GC[AF]_\d+\.\d+)")


def _clean_accession(raw: str) -> str:
    m = _ACCESSION_RE.match(raw)
    return m.group(1) if m else raw


def _datasets_url(acc: str, anno_types: List[str]) -> str:
    anno_qs = "&".join(f"include_annotation_type={t}" for t in anno_types)
    return (
        "https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/"
        f"{acc}/download?{anno_qs}&hydrated=FULLY_HYDRATED"
    )


def _fetch_dataset(http: "urllib3.PoolManager", acc: str) -> BytesIO:
    """Try downloading with fallback annotation sets; return ZIP bytes."""
    for anno in _ANNO_SETS:
        url = _datasets_url(acc, anno)
        resp = http.request("GET", url, preload_content=False)
        if resp.status == 200:
            resp.auto_close = False
            buf = BytesIO(resp.data)
            if not zipfile.is_zipfile(buf):
                print(
                    f"[WARN] NCBI returned HTTP 200 but not a valid zip for "
                    f"{acc} with {anno} ({len(buf.getvalue())} bytes). Trying next fallback.",
                    file=sys.stderr,
                )
                continue
            buf.seek(0)
            return buf
        elif resp.status == 400:
            continue
        else:
            raise RuntimeError(f"NCBI API returned HTTP {resp.status} for {acc}")
    raise RuntimeError(f"NCBI API cannot provide a genome FASTA for accession {acc}.")


def _extract_fasta(zip_bytes: BytesIO, acc: str, sample_id: str, fasta_dir: Path):
    with zipfile.ZipFile(zip_bytes) as zf:
        zf.extractall(fasta_dir / f".tmp_{sample_id}")

    data_root = fasta_dir / f".tmp_{sample_id}" / "ncbi_dataset" / "data" / acc
    if not data_root.exists():
        raise RuntimeError(f"Unexpected archive structure for {acc} — cannot find {data_root}")

    matches = list(data_root.rglob("*_genomic.fna"))
    if not matches:
        raise RuntimeError(f"No *_genomic.fna found in archive for {acc}")

    dest_path = fasta_dir / f"{sample_id}.fna.gz"
    with matches[0].open("rb") as src, gzip.open(dest_path, "wb") as dst:
        shutil.copyfileobj(src, dst)

    shutil.rmtree(fasta_dir / f".tmp_{sample_id}")
    return dest_path


# -----------------------------------------------------------------------------
# Assembly-details parsing
# -----------------------------------------------------------------------------


def _sanitize_id(strain: str) -> str:
    return re.sub(r"\s+", "_", strain.strip())


def _parse_assembly_details(path: Path) -> List[Tuple[str, str]]:
    """Return list of (accession, sample_id), skipping comment/header lines."""
    rows: List[Tuple[str, str]] = []
    with path.open() as fh:
        for line in fh:
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 6:
                continue
            accession = _clean_accession(fields[0].strip())
            strain = fields[5].strip()
            if not accession.startswith("GCA_") and not accession.startswith("GCF_"):
                continue
            if not strain:
                raise RuntimeError(f"Empty Strain field for accession {accession} — cannot derive a sample ID")
            rows.append((accession, _sanitize_id(strain)))

    seen = {}
    for accession, sample_id in rows:
        if sample_id in seen and seen[sample_id] != accession:
            raise RuntimeError(
                f"Duplicate sample ID '{sample_id}' derived from Strain column for both "
                f"{seen[sample_id]} and {accession} — resolve manually before downloading."
            )
        seen[sample_id] = accession
    return rows


# -----------------------------------------------------------------------------
# CLI / main
# -----------------------------------------------------------------------------


def _parse_cli(argv: list[str] | None = None):
    p = argparse.ArgumentParser(
        description="Bulk-download genome FASTAs from an NCBI assembly-details list via the NCBI Datasets REST API",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("-f", "--file", required=True, help="NCBI assembly-details TSV (e.g. PRJNA242743_AssemblyDetails.txt)")
    p.add_argument("-o", "--out_dir", required=True, help="Directory to place fasta/ and the samplesheet")
    p.add_argument("--delay", type=float, default=0.5, help="Seconds to sleep between requests (courtesy to the public API)")
    return p.parse_args(argv)


def main(argv: list[str] | None = None):
    args = _parse_cli(argv)
    out_dir = Path(args.out_dir).resolve()
    fasta_dir = out_dir / "fasta"
    fasta_dir.mkdir(parents=True, exist_ok=True)

    rows = _parse_assembly_details(Path(args.file))
    print(f"[INFO] Parsed {len(rows)} accessions from {args.file}", file=sys.stderr)

    http = urllib3.PoolManager()
    samplesheet_rows: List[Tuple[str, str]] = []
    failures: List[str] = []

    for i, (accession, sample_id) in enumerate(rows, start=1):
        dest_gz = fasta_dir / f"{sample_id}.fna.gz"
        if dest_gz.exists():
            print(f"[SKIP] ({i}/{len(rows)}) {sample_id} ({accession}) already downloaded", file=sys.stderr)
            samplesheet_rows.append((sample_id, str(dest_gz)))
            continue

        print(f"[INFO] ({i}/{len(rows)}) Downloading {sample_id} ({accession})...", file=sys.stderr)
        try:
            zip_bytes = _fetch_dataset(http, accession)
            try:
                dest_gz = _extract_fasta(zip_bytes, accession, sample_id, fasta_dir)
            finally:
                zip_bytes.close()
            samplesheet_rows.append((sample_id, str(dest_gz)))
        except Exception as e:
            print(f"[ERROR] Failed to download {accession} ({sample_id}): {e}", file=sys.stderr)
            failures.append(f"{sample_id}\t{accession}\t{e}")

        if args.delay > 0 and i < len(rows):
            time.sleep(args.delay)

    samplesheet_path = out_dir / "samplesheet_preassembled.csv"
    with samplesheet_path.open("w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["ID", "Fasta"])
        for sample_id, fasta_path in samplesheet_rows:
            writer.writerow([sample_id, fasta_path])

    print(f"[INFO] Wrote samplesheet with {len(samplesheet_rows)} genomes -> {samplesheet_path}", file=sys.stderr)

    if failures:
        failures_path = out_dir / "download_failures.tsv"
        failures_path.write_text("\n".join(failures) + "\n")
        print(f"[WARN] {len(failures)} accession(s) failed to download — see {failures_path}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
