#!/usr/bin/env python3
"""
Shared organism-metadata rewrite logic for Bakta's own GenBank (.gbff) and EMBL (.embl) output, plus
a GTDB-Tk classify_wf summary parser. Bakta never populates SOURCE/ORGANISM (GenBank) or OS/OC (EMBL)
-- conf/modules.config's BAKTA_BAKTA ext.args passes --genus/--species when the live pipeline's
KmerFinder-derived confidence gate allows it (see conf/modules.config, README.md's "KmerFinder
confidence threshold" section), but for already-published runs, or when a more authoritative source
(GTDB-Tk) becomes available after the fact, these functions patch Bakta's own output files directly.

Only .gbff/.embl carry this metadata -- confirmed .gff3/.tsv have no organism/source fields at all
(Bakta's flatter, feature-only formats).
"""

import csv
import re


_SP_PLACEHOLDER_RE = re.compile(r"^sp\d+$")


def parse_gtdbtk_classification(summary_tsv_path):
    """
    Parse a gtdbtk classify_wf summary TSV (gtdbtk.bac120.summary.tsv or gtdbtk.ar53.summary.tsv)
    into dict[sample] = (organism_label, taxonomy_str, genus, species_or_None).

    GTDB-Tk's own `sp######` placeholder species (accession-derived, e.g. "Yoonia sp000967725") means
    "confident, distinct species-level cluster, not yet formally named" -- NOT a real Latin binomial,
    and NOT the same as an unresolved call. Treated as genus-only for organism_label/taxonomy
    purposes (writing "sp000967725" into a GenBank ORGANISM field would look like real nomenclature
    when it isn't), while still trusting the genus fully.
    """
    result = {}

    with open(summary_tsv_path, newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            sample = row["user_genome"]
            ranks = row["classification"].split(";")
            rank_dict = {r[:3]: r[3:] for r in ranks if len(r) > 3}

            genus = rank_dict.get("g__") or None
            species_field = rank_dict.get("s__") or None

            species = None
            if species_field and genus:
                # species_field is the full binomial, e.g. "Halomonas litopenaei" or
                # "Yoonia sp000967725" -- strip the genus prefix to get the epithet.
                epithet = species_field[len(genus):].strip() if species_field.startswith(genus) else None
                if epithet and not _SP_PLACEHOLDER_RE.match(epithet):
                    species = species_field  # keep the full binomial, matching organism_label convention

            if genus:
                organism_label = f"{sample} {species if species else genus}"
                lineage_ranks = ["d__", "p__", "c__", "o__", "f__", "g__"]
                taxonomy_parts = [rank_dict[r] for r in lineage_ranks if rank_dict.get(r)]
                if species:
                    taxonomy_parts.append(species)
                taxonomy = "; ".join(taxonomy_parts) + "." if taxonomy_parts else "."
            else:
                organism_label = sample
                taxonomy = "."

            result[sample] = (organism_label, taxonomy, genus, species)

    return result


def rewrite_gbff_source_organism(lines, organism_label, taxonomy):
    """
    Rewrite a GenBank (.gbff) record's SOURCE / ORGANISM (+ taxonomy continuation) lines.
    Idempotent: no-op if SOURCE already matches organism_label exactly.
    """
    expected_source_line = f"SOURCE      {organism_label}\n"
    if any(line == expected_source_line for line in lines if line.startswith("SOURCE")):
        return lines

    out = []
    i = 0
    while i < len(lines):
        line = lines[i]

        if line.startswith("SOURCE"):
            out.append(f"SOURCE      {organism_label}\n")

        elif line.startswith("  ORGANISM"):
            out.append(f"  ORGANISM  {organism_label}\n")
            i += 1
            wrote_taxonomy = False
            while i < len(lines) and lines[i].startswith("            "):
                if not wrote_taxonomy:
                    out.append(f"            {taxonomy}\n")
                    wrote_taxonomy = True
                i += 1
            continue

        else:
            out.append(line)

        i += 1

    return out


def rewrite_embl_os_oc(lines, organism_label, taxonomy):
    """
    Rewrite an EMBL (.embl) record's OS (Organism Species) / OC (Organism Classification, may wrap
    across multiple OC lines for long lineages) lines. Idempotent: no-op if OS already matches
    organism_label exactly.
    """
    expected_os_line = f"OS   {organism_label}\n"
    if any(line == expected_os_line for line in lines if line.startswith("OS   ")):
        return lines

    out = []
    i = 0
    while i < len(lines):
        line = lines[i]

        if line.startswith("OS   "):
            out.append(f"OS   {organism_label}\n")

        elif line.startswith("OC   "):
            out.append(f"OC   {taxonomy}\n")
            i += 1
            while i < len(lines) and lines[i].startswith("OC   "):
                i += 1
            continue

        else:
            out.append(line)

        i += 1

    return out
