#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    nf-core/bacass — preassembled-genome entry point
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    Separate entry point from main.nf/workflows/bacass.nf (neither is touched by this
    file) for genomes that are already assembled — e.g. downloaded from NCBI via
    bin/download_ncbi_assemblies.py — rather than assembled here from reads. Builds its
    DAG directly from a two-column (ID, Fasta) samplesheet instead of the read-based
    samplesheet main.nf expects. See CLAUDE.md for the full rationale.

    Usage:
        nextflow run main_preassembled.nf -profile conda \
            --input samplesheet_preassembled.csv \
            --outdir <results_dir> \
            --baktadb "$BACASS_BAKTADB"

----------------------------------------------------------------------------------------
*/

include { BACASS_PREASSEMBLED } from './workflows/bacass_preassembled'
include { samplesheetToList   } from 'plugin/nf-schema'

workflow {

    main:

    // Check required path params exist up front, same pattern as workflows/bacass.nf
    def checkPathParamList = [ params.input, params.multiqc_config ]
    for (param in checkPathParamList) { if (param) { file(param, checkIfExists: true) } }

    if (!params.input) {
        error("Please provide an input samplesheet with '--input' (columns: ID,Fasta).")
    }
    if (!params.outdir) {
        error("Please provide an output directory with '--outdir'.")
    }
    if (!params.skip_annotation && !params.baktadb && !params.baktadb_download) {
        error(
            "The Bakta database argument is missing. Please supply '--baktadb <path>' " +
            "(or '--baktadb_download true' to fetch it) — this entry point is Bakta-only, " +
            "or pass '--skip_annotation true' to skip annotation entirely."
        )
    }

    // params.assembly_type is left at its nextflow.config default (null) here — CUSTOM_MULTIQC
    // passes it straight through to bin/multiqc_to_custom_csv.py's --assembly_type flag, whose
    // per-assembly-type branches only fire for exactly "short"/"long"/"hybrid" and silently no-op
    // otherwise (verified via -stub-run), which is the desired behaviour since this entry point
    // never runs kmerfinder.

    //
    // Build ch_assembly directly from the (ID, Fasta) samplesheet
    //
    Channel
        .fromList(samplesheetToList(params.input, "${projectDir}/assets/schema_input_preassembled.json"))
        .map { meta, fasta ->
            tuple(meta, file(fasta, checkIfExists: true))
        }
        .set { ch_assembly }

    BACASS_PREASSEMBLED (
        ch_assembly
    )
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
