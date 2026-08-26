// Patched copy of modules/nf-core/antismash/antismash/main.nf.
// Deployed by submit_funcscan_distributed.sh (same mechanism as
// deepbgc_pipeline_main.nf) so it survives `nextflow pull`.
//
// Adds a `sideload_files` input and `--sideload` to the antismash command,
// so GECCO's and DeepBGC's antiSMASH-sideload JSON output get merged into
// antiSMASH's own run instead of being combined post-hoc by COMBGC (which
// parses antiSMASH's GenBank output + a separately-parsed clusterblast text
// file — fragile, see CLAUDE.md's BGC-merge caveat). Wired up in the paired
// bgc.nf patch, which reorders GECCO_RUN/DEEPBGC_PIPELINE before this
// process and joins their `json` outputs into the new input.
//
// sideload_files is folded into the primary (meta-keyed) tuple, not passed as a separate
// positional path channel — Nextflow pairs a bare `path` input with the primary channel
// purely by emission order, not by meta, so a second per-sample queue channel risks silent
// mispairing across samples. Keeping it inside the tuple that bgc.nf already builds via
// meta-keyed `.join()` (same pattern already used elsewhere in that file) guarantees each
// task gets the right sample's sideload files. `databases`/`gff` stay separate positional
// inputs because they really are constant/broadcast values, not per-sample.
//
// Only the `input:` block and the `--sideload` line in `script:` differ from upstream — diff
// against modules/nf-core/antismash/antismash/main.nf on any funcscan version bump to reapply
// cleanly.
process ANTISMASH_ANTISMASH {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "nf-core/antismash:8.0.1--pyhdfd78af_0"

    input:
    tuple val(meta), path(sequence_input), path(sideload_files)
    path databases
    path gff

    output:
    tuple val(meta), path("${prefix}/{css,images,js}")                    , emit: html_accessory_files
    tuple val(meta), path("${prefix}/*.gbk")                              , emit: gbk_input
    tuple val(meta), path("${prefix}/*.json")                             , emit: json_results
    tuple val(meta), path("${prefix}/*.log")                              , emit: log
    tuple val(meta), path("${prefix}/*.zip")                              , emit: zip
    tuple val(meta), path("${prefix}/index.html")                         , emit: html
    tuple val(meta), path("${prefix}/regions.js")                         , emit: json_sideloading
    tuple val(meta), path("${prefix}/clusterblast/*_c*.txt")              , emit: clusterblast_file          , optional: true
    tuple val(meta), path("${prefix}/knownclusterblast/region*/ctg*.html"), emit: knownclusterblast_html     , optional: true
    tuple val(meta), path("${prefix}/knownclusterblast/")                 , emit: knownclusterblast_dir      , optional: true
    tuple val(meta), path("${prefix}/knownclusterblast/*_c*.txt")         , emit: knownclusterblast_txt      , optional: true
    tuple val(meta), path("${prefix}/svg/clusterblast*.svg")              , emit: svg_files_clusterblast     , optional: true
    tuple val(meta), path("${prefix}/svg/knownclusterblast*.svg")         , emit: svg_files_knownclusterblast, optional: true
    tuple val(meta), path("${prefix}/*region*.gbk")                       , emit: gbk_results                , optional: true
    tuple val(meta), path("${prefix}/clusterblastoutput.txt")             , emit: clusterblastoutput         , optional: true
    tuple val(meta), path("${prefix}/knownclusterblastoutput.txt")        , emit: knownclusterblastoutput    , optional: true
    path "versions.yml"                                                   , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args   ?: ''
    prefix   = task.ext.prefix ?: "${meta.id}"
    gff_flag = gff ? "--genefinding-gff3 ${gff}" : ""
    def sideload_list = sideload_files ? (sideload_files instanceof List ? sideload_files : [sideload_files]) : []
    def sideload_flag = sideload_list ? "--sideload ${sideload_list.join(',')}" : ""

    """
    ## We specifically do not include on-the-fly annotations (--genefinding-tool none) as
    ## this should be run as a separate module for versioning purposes

    antismash \\
        ${args} \\
        ${gff_flag} \\
        ${sideload_flag} \\
        -c ${task.cpus} \\
        --output-dir ${prefix} \\
        --output-basename ${prefix} \\
        --genefinding-tool none \\
        --logfile ${prefix}/${prefix}.log \\
        --databases ${databases} \\
        ${sequence_input}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        antismash: \$(echo \$(antismash --version) | sed 's/antiSMASH //;s/-.*//g')
    END_VERSIONS
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    mkdir -p ${prefix}/css
    mkdir ${prefix}/images
    mkdir ${prefix}/js
    touch ${prefix}/NZ_CP069563.1.region001.gbk
    touch ${prefix}/NZ_CP069563.1.region002.gbk
    touch ${prefix}/css/bacteria.css
    touch ${prefix}/genome.gbk
    touch ${prefix}/genome.json
    touch ${prefix}/genome.zip
    touch ${prefix}/images/about.svg
    touch ${prefix}/index.html
    touch ${prefix}/js/antismash.js
    touch ${prefix}/js/jquery.js
    touch ${prefix}/regions.js
    touch ${prefix}/test.log

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        antismash: \$(echo \$(antismash --version) | sed 's/antiSMASH //;s/-.*//g')
    END_VERSIONS
    """
}
