/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE: Local to the pipeline
//
include { CUSTOM_MULTIQC            } from '../modules/local/custom/multiqc'

//
// MODULE: Installed directly from nf-core/modules
//
include { QUAST                     } from '../modules/nf-core/quast'
include { BUSCO_BUSCO               } from '../modules/nf-core/busco/busco/main'
include { GUNZIP                    } from '../modules/nf-core/gunzip'

//
// SUBWORKFLOWS: Consisting of a mix of local and nf-core/modules
//
include { BAKTA_DBDOWNLOAD_RUN      } from '../subworkflows/local/bakta_dbdownload_run'
include { paramsSummaryMap          } from 'plugin/nf-schema'
include { paramsSummaryMultiqc      } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML    } from '../subworkflows/nf-core/utils_nfcore_pipeline'

// Optional reference for QUAST, same params bacass.nf's skip_kmerfinder QUAST branch supports
if (params.reference_fasta) {
    reference_fasta = file(params.reference_fasta, type: 'file')
}
if (params.reference_gff) {
    reference_gff = file(params.reference_gff, type: 'file')
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    Entry point for genomes that are already assembled (e.g. downloaded from NCBI) rather
    than assembled from reads. Feeds `ch_assembly` — the same [meta, fasta] channel shape
    that workflows/bacass.nf's assembler modules (Unicycler/Canu/Dragonflye/...) populate —
    directly from the samplesheet, then reuses the exact same downstream modules bacass.nf
    uses for `ch_assembly` (GUNZIP, QUAST, BUSCO_BUSCO, BAKTA_DBDOWNLOAD_RUN), unchanged, so
    output lands in the same publishDir layout (Bakta/<id>/<id>.faa etc.) that every
    downstream script in this repo (run_defensefinder_scan.sh, run_padloc_scan.sh,
    bin/bgc_defense_proximity.py, bacass_to_funcscan.sh, ...) already expects.

    Read-based QC (Kraken2, kmerfinder) is intentionally not run here — both are wired to
    raw reads in bacass.nf, not to `ch_assembly`, and there are no reads for pre-assembled
    input. BUSCO completeness + QUAST + NCBI's own submission QC stand in for now.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow BACASS_PREASSEMBLED {

    take:
    ch_assembly // channel: [ val(meta), path(fasta) ] — already-assembled genomes

    main:
    ch_versions       = Channel.empty()

    //
    // Uncompress assembly for downstream tools that require it, same branch bacass.nf uses
    //
    ch_assembly
        .branch{ meta, fasta ->
            gzip: fasta.name.endsWith('.gz')
            skip: true
        }
        .set{ ch_assembly_for_gunzip }

    GUNZIP ( ch_assembly_for_gunzip.gzip )
    ch_assembly_flat = ch_assembly_for_gunzip.skip.mix( GUNZIP.out.gunzip )
    ch_versions       = ch_versions.mix( GUNZIP.out.versions )

    //
    // MODULE: QUAST, assembly QC
    //
    ch_assembly
        .collect{it[1]}
        .map{ consensus -> tuple([id:'report'], consensus) }
        .set{ ch_to_quast }

    QUAST(
        ch_to_quast,
        params.reference_fasta ? [[:], reference_fasta] : [[:],[]],
        params.reference_gff ? [[:], reference_gff] : [[:],[]]
    )
    ch_quast_multiqc = QUAST.out.results
    ch_versions       = ch_versions.mix(QUAST.out.versions)

    //
    // MODULE: BUSCO, assess genome assembly completeness
    //
    ch_busco_multiqc = Channel.empty()
    if (!params.skip_busco) {
        BUSCO_BUSCO (
            ch_assembly,                                                        // tuple val(meta), path(fasta)
            params.busco_mode,                                                  // val mode
            params.busco_lineage,                                               // val lineage
            params.busco_db_path ? file(params.busco_db_path) : [],             // path busco_lineages_path
            params.busco_config_file ? file(params.busco_config_file) : [],     // path config_file (optional)
            params.busco_clean_intermediates                                    // val clean_intermediates
        )
        ch_busco_multiqc = BUSCO_BUSCO.out.short_summaries_txt
        ch_versions = ch_versions.mix(BUSCO_BUSCO.out.versions)
    }

    //
    // SUBWORKFLOW: BAKTA, gene annotation (this entry point is Bakta-only by design — see CLAUDE.md)
    //
    ch_bakta_txt_multiqc = Channel.empty()
    if ( !params.skip_annotation ) {
        BAKTA_DBDOWNLOAD_RUN (
            ch_assembly_flat.filter{ meta, fasta -> !fasta.isEmpty() },
            params.baktadb,
            params.baktadb_download
        )
        ch_bakta_txt_multiqc    = BAKTA_DBDOWNLOAD_RUN.out.bakta_txt_multiqc.map{ meta, bakta_txt -> [ bakta_txt ]}
        ch_versions             = ch_versions.mix(BAKTA_DBDOWNLOAD_RUN.out.versions)
    }

    //
    // Collate and save software versions
    //
    softwareVersionsToYAML(ch_versions)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'nf_core_'  +  'bacass_preassembled_software_'  + 'mqc_'  + 'versions.yml',
            sort: true,
            newLine: true
        ).set { ch_collated_versions }

    //
    // MODULE: MultiQC
    //
    ch_multiqc_config                     = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config              = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
    ch_multiqc_logo                       = params.multiqc_logo ? Channel.fromPath(params.multiqc_logo, checkIfExists: true) : Channel.empty()
    summary_params                        = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary                   = Channel.value(paramsSummaryMultiqc(summary_params))
    ch_multiqc_custom_methods_description = params.multiqc_methods_description ? Channel.fromPath(params.multiqc_methods_description, checkIfExists: true) : Channel.fromPath("$projectDir/assets/methods_description_template.yml", checkIfExists: true)

    CUSTOM_MULTIQC (
        ch_multiqc_config.ifEmpty([]),
        ch_multiqc_custom_config.ifEmpty([]),
        ch_multiqc_logo.ifEmpty([]),
        ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'),
        ch_multiqc_custom_methods_description.ifEmpty([]),
        ch_collated_versions.ifEmpty([]),
        [],                                        // fastqc      — no reads for preassembled input
        [],                                        // fastqc_trim
        [],                                        // fastp
        [],                                        // nanoplot
        [],                                        // porechop
        [],                                        // filtlong
        [],                                        // pycoqc
        [],                                        // kraken2_short
        [],                                        // kraken2_long
        ch_quast_multiqc.collect{it[1]}.ifEmpty([]),
        ch_busco_multiqc.collect{it[1]}.ifEmpty([]),
        [],                                        // prokka — this entry point is Bakta-only
        ch_bakta_txt_multiqc.collect().ifEmpty([]),
        [],                                        // extra (kmerfinder) — not run for preassembled input
    )

    emit:
    multiqc_report = CUSTOM_MULTIQC.out.report.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                        // channel: [ path(versions.yml) ]
}
