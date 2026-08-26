/*
    Run BGC screening tools

    Patched copy of subworkflows/local/bgc.nf. Deployed by
    submit_funcscan_distributed.sh (same mechanism as deepbgc_pipeline_main.nf
    / antismash_antismash_main.nf) so it survives `nextflow pull`.

    Reorders execution so GECCO_RUN and DEEPBGC_PIPELINE run before
    ANTISMASH_ANTISMASH, and feeds their antiSMASH-sideload JSON output
    (`.out.json`, both optional — a tool finding nothing for a sample emits
    nothing) into the patched ANTISMASH_ANTISMASH module via `--sideload`, so
    antiSMASH itself produces one authoritative, self-consistent output per
    sample instead of leaving the merge to COMBGC's fragile post-hoc
    GenBank/clusterblast parse (see CLAUDE.md's BGC-merge caveat). COMBGC
    still runs afterward, unchanged, as a fallback/compat path.

    Only the reordering, the two new `ch_*_sideload` channels, and the
    `ch_gbks_with_sideload` join + ANTISMASH_ANTISMASH call differ from
    upstream — diff against subworkflows/local/bgc.nf on any funcscan version
    bump to reapply cleanly.
*/

include { UNTAR as UNTAR_ANTISMASHDB             } from '../../modules/nf-core/untar/main'
include { ANTISMASH_ANTISMASHDOWNLOADDATABASES   } from '../../modules/nf-core/antismash/antismashdownloaddatabases/main'
include { ANTISMASH_ANTISMASH                    } from '../../modules/nf-core/antismash/antismash/main'
include { GECCO_RUN                              } from '../../modules/nf-core/gecco/run/main'
include { HMMER_HMMSEARCH as BGC_HMMER_HMMSEARCH } from '../../modules/nf-core/hmmer/hmmsearch/main'
include { DEEPBGC_DOWNLOAD                       } from '../../modules/nf-core/deepbgc/download/main'
include { DEEPBGC_PIPELINE                       } from '../../modules/nf-core/deepbgc/pipeline/main'
include { COMBGC                                 } from '../../modules/local/combgc'
include { TABIX_BGZIP as BGC_TABIX_BGZIP         } from '../../modules/nf-core/tabix/bgzip/main'
include { MERGE_TAXONOMY_COMBGC                  } from '../../modules/local/merge_taxonomy_combgc'

workflow BGC {
    take:
    fastas // tuple val(meta), path(PREPPED_INPUT.out.fna)
    faas   // tuple val(meta), path(<ANNO_TOOL>.out.faa)
    gbks   // tuple val(meta), path(<ANNO_TOOL>.out.gbk)
    tsvs   // tuple val(meta), path(MMSEQS_CREATETSV.out.tsv)

    main:
    ch_versions = Channel.empty()
    ch_bgcresults_for_combgc = Channel.empty()

    // When adding new tool that requires FAA, make sure to update conditions
    // in funcscan.nf around annotation and AMP subworkflow execution
    // to ensure annotation is executed!
    ch_faa_for_bgc_hmmsearch = faas

    // DEEPBGC — moved ahead of ANTISMASH so its sideload JSON is available below
    ch_deepbgc_sideload = Channel.empty()
    if (!params.bgc_skip_deepbgc) {
        if (params.bgc_deepbgc_db) {

            ch_deepbgc_database = Channel.fromPath(params.bgc_deepbgc_db, checkIfExists: true)
                .first()
        }
        else {
            DEEPBGC_DOWNLOAD()
            ch_deepbgc_database = DEEPBGC_DOWNLOAD.out.db
            ch_versions = ch_versions.mix(DEEPBGC_DOWNLOAD.out.versions)
        }

        DEEPBGC_PIPELINE(gbks, ch_deepbgc_database)
        ch_versions = ch_versions.mix(DEEPBGC_PIPELINE.out.versions)
        ch_bgcresults_for_combgc = ch_bgcresults_for_combgc.mix(DEEPBGC_PIPELINE.out.bgc_tsv)
        ch_deepbgc_sideload = DEEPBGC_PIPELINE.out.json
    }

    // GECCO — moved ahead of ANTISMASH so its sideload JSON is available below
    ch_gecco_sideload = Channel.empty()
    if (!params.bgc_skip_gecco) {
        ch_gecco_input = gbks
            .groupTuple()
            .multiMap {
                fastas: [it[0], it[1], []]
            }

        GECCO_RUN(ch_gecco_input, [])
        ch_versions = ch_versions.mix(GECCO_RUN.out.versions)
        ch_geccoresults_for_combgc = GECCO_RUN.out.gbk
            .mix(GECCO_RUN.out.clusters)
            .groupTuple()
            .map { meta, files ->
                [meta, files.flatten()]
            }
        ch_bgcresults_for_combgc = ch_bgcresults_for_combgc.mix(ch_geccoresults_for_combgc)
        ch_gecco_sideload = GECCO_RUN.out.json
    }

    // ANTISMASH
    if (!params.bgc_skip_antismash) {
        // Check whether user supplies database and/or antismash directory. If not, obtain them via the module antismash/antismashdownloaddatabases.
        // Important for future maintenance: For CI tests, only the "else" option below is used. Both options should be tested locally whenever the antiSMASH module gets updated.
        if (params.bgc_antismash_db && file(params.bgc_antismash_db, checkIfExists: true).extension == 'gz') {
            UNTAR_ANTISMASHDB([[id: 'antismashdb'], file(params.bgc_antismash_db, checkIfExists: true)])
            ch_antismash_databases = UNTAR_ANTISMASHDB.out.untar.map { _meta, dir -> [dir] }
        }
        else if (params.bgc_antismash_db && file(params.bgc_antismash_db, checkIfExists: true).isDirectory()) {
            ch_antismash_databases = Channel.fromPath(params.bgc_antismash_db, checkIfExists: true).first()
        }
        else {
            ANTISMASH_ANTISMASHDOWNLOADDATABASES()
            ch_versions = ch_versions.mix(ANTISMASH_ANTISMASHDOWNLOADDATABASES.out.versions)
            ch_antismash_databases = ANTISMASH_ANTISMASHDOWNLOADDATABASES.out.database
        }

        // Fold GECCO's and DeepBGC's antiSMASH-sideload JSON into the same meta-keyed tuple as
        // the gbk input (not a separate positional path channel — see antismash_antismash_main.nf
        // patch comment for why). Both sideload channels are optional-output-derived, so a
        // sample where a tool found nothing simply null-fills via remainder:true; coalesced to [].
        ch_gbks_with_sideload = gbks
            .join(ch_deepbgc_sideload, remainder: true)
            .join(ch_gecco_sideload, remainder: true)
            .map { meta, gbk, deepbgc_json, gecco_json ->
                def sideload = []
                if (deepbgc_json) {
                    sideload << deepbgc_json
                }
                if (gecco_json) {
                    sideload << gecco_json
                }
                [meta, gbk, sideload]
            }

        ANTISMASH_ANTISMASH(ch_gbks_with_sideload, ch_antismash_databases, [])

        ch_versions = ch_versions.mix(ANTISMASH_ANTISMASH.out.versions)
        ch_antismashresults = ANTISMASH_ANTISMASH.out.knownclusterblast_dir
            .mix(ANTISMASH_ANTISMASH.out.gbk_input)
            .groupTuple()
            .map { meta, files ->
                [meta, files.flatten()]
            }

        // Filter out samples with no BGC hits
        ch_antismashresults_for_combgc = ch_antismashresults
            .join(fastas, remainder: false)
            .join(ANTISMASH_ANTISMASH.out.gbk_results, remainder: false)
            .map { meta, gbk_input, _fasta, _gbk_results ->
                [meta, gbk_input]
            }

        ch_bgcresults_for_combgc = ch_bgcresults_for_combgc.mix(ch_antismashresults_for_combgc)
    }

    // HMMSEARCH
    if (params.bgc_run_hmmsearch) {
        if (params.bgc_hmmsearch_models) {
            ch_bgc_hmm_models = Channel.fromPath(params.bgc_hmmsearch_models, checkIfExists: true)
        }
        else {
            error('[nf-core/funcscan] error: hmm model files not found for --bgc_hmmsearch_models! Please check input.')
        }

        ch_bgc_hmm_models_meta = ch_bgc_hmm_models.map { file ->
            def meta = [:]
            meta['id'] = file.extension == 'gz' ? file.name - '.hmm.gz' : file.name - '.hmm'

            [meta, file]
        }

        ch_in_for_bgc_hmmsearch = ch_faa_for_bgc_hmmsearch
            .combine(ch_bgc_hmm_models_meta)
            .map { meta_faa, faa, meta_hmm, hmm ->
                def meta_new = [:]
                meta_new['id'] = meta_faa['id']
                meta_new['hmm_id'] = meta_hmm['id']
                [meta_new, hmm, faa, params.bgc_hmmsearch_savealignments, params.bgc_hmmsearch_savetargets, params.bgc_hmmsearch_savedomains]
            }

        BGC_HMMER_HMMSEARCH(ch_in_for_bgc_hmmsearch)
        ch_versions = ch_versions.mix(BGC_HMMER_HMMSEARCH.out.versions)
    }

    // COMBGC

    ch_bgcresults_for_combgc
        .join(fastas, remainder: true)
        .filter { meta, bgcfile, fasta ->
            if (!bgcfile) {
                log.warn("[nf-core/funcscan] BGC workflow: No hits found by BGC tools; comBGC summary tool will not be run for sample: ${meta.id}")
            }
            return [meta, bgcfile, fasta]
        }

    COMBGC(ch_bgcresults_for_combgc)
    ch_versions = ch_versions.mix(COMBGC.out.versions)

    // COMBGC concatenation
    if (!params.run_taxa_classification) {
        ch_combgc_summaries = COMBGC.out.tsv.map { it[1] }.collectFile(name: 'combgc_complete_summary.tsv', storeDir: "${params.outdir}/reports/combgc", keepHeader: true)
    }
    else {
        ch_combgc_summaries = COMBGC.out.tsv.map { it[1] }.collectFile(name: 'combgc_complete_summary.tsv', keepHeader: true)
    }

    // MERGE_TAXONOMY
    if (params.run_taxa_classification) {

        ch_mmseqs_taxonomy_list = tsvs.map { it[1] }.collect()
        MERGE_TAXONOMY_COMBGC(ch_combgc_summaries, ch_mmseqs_taxonomy_list)
        ch_versions = ch_versions.mix(MERGE_TAXONOMY_COMBGC.out.versions)

        ch_tabix_input = Channel.of(['id': 'combgc_complete_summary_taxonomy'])
            .combine(MERGE_TAXONOMY_COMBGC.out.tsv)

        BGC_TABIX_BGZIP(ch_tabix_input)
        ch_versions = ch_versions.mix(BGC_TABIX_BGZIP.out.versions)
    }

    emit:
    versions = ch_versions
}
