<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/nf-core-bacass_logo_dark.png">
    <img alt="nf-core/bacass" src="docs/images/nf-core-bacass_logo_light.png">
  </picture>
</h1>

> **DTU Bioengineering fork** — This is a customized version of [nf-core/bacass](https://github.com/nf-core/bacass) (v2.5.0) tuned for the [DTU HPC cluster](https://www.hpc.dtu.dk/?page_id=2520) (LSF 10 scheduler). It includes pre-configured resource limits for DTU's compute nodes, distributed LSF job submission, self-contained conda environments, and a pipeline chain into [nf-core/funcscan](https://nf-co.re/funcscan/) for downstream BGC/AMP/ARG screening. See [Running on Your Own Samples](#running-on-your-own-samples-dtu-hpc) below.
>
> **Upstream**: [nf-core/bacass](https://github.com/nf-core/bacass) | **Institution**: [DTU Bioengineering](https://www.bioengineering.dtu.dk/) | **HPC**: [DTU HPC cluster specs](https://www.hpc.dtu.dk/?page_id=2520)

[![Nextflow](https://img.shields.io/badge/version-%E2%89%A524.10.5-green?style=flat&logo=nextflow&logoColor=white&color=%230DC09D&link=https%3A%2F%2Fnextflow.io)](https://www.nextflow.io/)
[![nf-core template version](https://img.shields.io/badge/nf--core_template-3.3.2-green?style=flat&logo=nfcore&logoColor=white&color=%2324B064&link=https%3A%2F%2Fnf-co.re)](https://github.com/nf-core/tools/releases/tag/3.3.2)
[![run with conda](http://img.shields.io/badge/run%20with-conda-3EB049?labelColor=000000&logo=anaconda)](https://docs.conda.io/en/latest/)

## Introduction

**nf-core/bacass** is a bioinformatics best-practice analysis pipeline for simple bacterial assembly and annotation. The pipeline is able to assemble short reads, long reads, or a mixture of short and long reads (hybrid assembly).

The pipeline is built using [Nextflow](https://www.nextflow.io), a workflow tool to run tasks across multiple compute infrastructures in a very portable manner. It uses Docker/Singularity containers making installation trivial and results highly reproducible. The [Nextflow DSL2](https://www.nextflow.io/docs/latest/dsl2.html) implementation of this pipeline uses one container per process which makes it much easier to maintain and update software dependencies. Where possible, these processes have been submitted to and installed from [nf-core/modules](https://github.com/nf-core/modules) in order to make them available to all nf-core pipelines, and to everyone within the Nextflow community!

On release, automated continuous integration tests run the pipeline on a full-sized dataset on the AWS cloud infrastructure. This ensures that the pipeline runs on AWS, has sensible resource allocation defaults set to run on real-world datasets, and permits the persistent storage of results to benchmark between pipeline releases and other analysis sources. The results obtained from the full-sized test can be viewed on the [nf-core website](https://nf-co.re/bacass/results).

## Pipeline summary

### Short Read Assembly

This pipeline is primarily for bacterial assembly of next-generation sequencing reads. It can be used to quality trim your reads using [FastP](https://github.com/OpenGene/fastp) and performs basic sequencing QC using [FastQC](https://www.bioinformatics.babraham.ac.uk/projects/fastqc/). Afterwards, the pipeline performs read assembly using [Unicycler](https://github.com/rrwick/Unicycler). Contamination of the assembly is checked using [Kraken2](https://ccb.jhu.edu/software/kraken2/) and [Kmerfinder](https://bitbucket.org/genomicepidemiology/kmerfinder/src/master/) to verify sample purity.

### Long Read Assembly

For users that only have Nanopore data, the pipeline quality trims these using [PoreChop](https://github.com/rrwick/Porechop) or filter long reads by quality using [Filtlong](https://github.com/rrwick/Filtlong) and assesses basic sequencing QC utilizing [NanoPlot](https://github.com/wdecoster/NanoPlot) and [PycoQC](https://github.com/a-slide/pycoQC). Contamination of the assembly is checked using [Kraken2](https://ccb.jhu.edu/software/kraken2/) and [Kmerfinder](https://bitbucket.org/genomicepidemiology/kmerfinder/src/master/) to verify sample purity.

The pipeline can then perform long read assembly utilizing [Unicycler](https://github.com/rrwick/Unicycler), [Miniasm](https://github.com/lh3/miniasm) in combination with [Racon](https://github.com/isovic/racon), [Canu](https://github.com/marbl/canu) or [Flye](https://github.com/fenderglass/Flye) by using the [Dragonflye](https://github.com/rpetit3/dragonflye)(\*) pipeline. Long reads assembly can be polished using [Medaka](https://github.com/nanoporetech/medaka) or [NanoPolish](https://github.com/jts/nanopolish) with Fast5 files.

> [!NOTE]
> Dragonflye is a comprehensive pipeline designed for genome assembly of Oxford Nanopore Reads. It facilitates the utilization of Flye (default), Miniasm, and Raven assemblers, along with Racon (default) and Medaka polishers. For more information, visit the [Dragonflye GitHub](https://github.com/rpetit3/dragonflye) repository.

### Hybrid Assembly

For users specifying both short read and long read (NanoPore) data, the pipeline can perform a hybrid assembly approach utilizing [Unicycler](https://github.com/rrwick/Unicycler) (short read assembly followed by gap closing with long reads) or [Dragonflye](https://github.com/rpetit3/dragonflye) (long read assembly followed by polishing with short reads), taking the full set of information from short reads and long reads into account.

### Assembly QC and annotation

In all cases, the assembly is assessed using [QUAST](http://bioinf.spbau.ru/quast) and [BUSCO](https://busco.ezlab.org/). The resulting bacterial assembly is furthermore annotated using [Prokka](https://github.com/tseemann/prokka), [Bakta](https://github.com/oschwengers/bakta) or [DFAST](https://github.com/nigyta/dfast_core).

If Kmerfinder is invoked, the pipeline will group samples according to the [Kmerfinder](https://bitbucket.org/genomicepidemiology/kmerfinder/src/master/)-estimated reference genomes. Afterwards, two QUAST steps will be carried out: an initial ('general') [QUAST](http://bioinf.spbau.ru/quast) of all samples without reference genomes, and subsequently, a 'by reference genome' [QUAST](http://bioinf.spbau.ru/quast) to aggregate samples with their reference genomes.

> [!NOTE]
> This scenario is supported when [Kmerfinder](https://bitbucket.org/genomicepidemiology/kmerfinder/src/master/) analysis is performed only.

## Running on Your Own Samples (DTU HPC)

This installation is self-contained for DTU HPC. Conda environments, databases, and submit scripts are bundled in the project directory. No manual environment setup is needed — the submit scripts handle everything automatically.

### Step 1: Set up your project directory

Copy the submit scripts to your project directory:

```bash
PROJECT_DIR="/path/to/your/project"
BACASS_DIR="/work3/josne/github/bacass"

cp "${BACASS_DIR}/submit_bacass.sh" "${PROJECT_DIR}/"
cp "${BACASS_DIR}/submit_bacass_distributed.sh" "${PROJECT_DIR}/"
cp "${BACASS_DIR}/bacass_to_funcscan.sh" "${PROJECT_DIR}/"
cp "${BACASS_DIR}/submit_funcscan.sh" "${PROJECT_DIR}/"
```

### Step 2: Prepare a samplesheet

Create a tab-separated `samplesheet.tsv` in your project directory. Use **absolute paths** and `NA` for fields that don't apply.

```tsv
ID      R1                            R2                            LongFastQ                    Fast5    GenomeSize
sample1 /absolute/path/S1_R1.fastq.gz /absolute/path/S1_R2.fastq.gz NA                          NA       NA
sample2 /absolute/path/S2_R1.fastq.gz /absolute/path/S2_R2.fastq.gz NA                          NA       NA
sample3 NA                            NA                            /absolute/path/S3_long.fq.gz /path/FAST5 2.8m
```

| Column | Description |
|---|---|
| `ID` | Unique sample name (no spaces) |
| `R1`, `R2` | Paired-end short reads (Illumina). Use `NA` for long-read-only samples |
| `LongFastQ` | Nanopore long reads. Use `NA` for short-read-only samples |
| `Fast5` | Nanopore Fast5 directory (only needed for nanopolish). Use `NA` otherwise |
| `GenomeSize` | Estimated genome size, e.g., `2.8m` (only needed for long-read assembly). Use `NA` otherwise |

### Step 3: Edit the submit script

Open the submit script and edit the three variables at the top:

```bash
#==========================================================================
# EDIT THESE BEFORE SUBMITTING
#==========================================================================
INPUT="/absolute/path/to/samplesheet.tsv"
OUTDIR="/absolute/path/to/results"
ASSEMBLY_TYPE="short"   # short, long, or hybrid
#==========================================================================
```

Everything else is handled automatically:
- `setup.sh` is sourced inside the script (activates conda, Nextflow, database paths)
- Kraken2 and Kmerfinder databases are passed automatically via `$BACASS_KRAKEN2DB` and `$BACASS_KMERFINDERDB`
- Conda environments are pre-built in `.conda_envs/` — no first-run wait

**Which submit script to use?**

| Scenario | Script | Why |
|---|---|---|
| 1-10 samples | `submit_bacass.sh` | Simple, all processes on one node |
| 10+ samples | `submit_bacass_distributed.sh` | Parallel across nodes, much faster |

### Step 4: Submit

```bash
cd /path/to/your/project
bsub < submit_bacass_distributed.sh   # or submit_bacass.sh for few samples
```

### Step 5: Monitor

```bash
# Check job status
bjobs -w

# Follow live output
tail -f bacass_head_*.out              # distributed mode
tail -f bacass_*.out                   # single-node mode

# Count running sub-jobs (distributed mode)
bjobs -u $USER | grep -c RUN
```

### Step 6: Resume if interrupted

Both submit scripts support `-resume`. If a job is killed or times out, simply resubmit — Nextflow will skip completed steps and continue from where it left off:

```bash
bsub < submit_bacass_distributed.sh   # resubmit the same script
```

### Step 7: Functional screening with nf-core/funcscan (optional)

After bacass completes, you can screen for biosynthetic gene clusters (BGC), antimicrobial peptides (AMP), and antimicrobial resistance genes (ARG) using [nf-core/funcscan](https://nf-co.re/funcscan/) v3.0.0.

Since bacass annotates with Bakta (producing `.gbff` and `.faa` files), funcscan **skips re-annotation** and runs three screening modules:

- **BGC screening**: antiSMASH, DeepBGC, GECCO (biosynthetic gene clusters)
- **AMP screening**: ampir, amplify, macrel, hmmsearch (antimicrobial peptides)
- **ARG screening**: ABRicate, AMRFinderPlus, DeepARG, fARGene, RGI (antimicrobial resistance genes)

The bridging script auto-detects the annotation tool (Bakta `.gbff` or Prokka `.gbk`) and assembler output (Unicycler or Dragonflye), then generates a 4-column CSV (`sample,fasta,protein,gbk`) ready for funcscan. Samples with missing files are skipped with a warning.

```bash
cd /path/to/your/project

# Generate funcscan samplesheet from bacass results
./bacass_to_funcscan.sh /path/to/your/Bacass_results
# → writes funcscan_samplesheet.csv with all completed samples

# Edit submit_funcscan.sh — set INPUT and OUTDIR
vi submit_funcscan.sh

# Submit — runs distributed across the cluster (same as bacass)
bsub < submit_funcscan.sh

# Monitor
tail -f funcscan_head_*.out
bjobs -u $USER -w
```

Funcscan runs distributed just like bacass — a lightweight head process (1 core / 4 GB) dispatches each screening task as a separate LSF job. This is essential for 100+ genomes because funcscan runs ~15 tools per sample. The head job uses 72h wall time to outlive all sub-jobs. `-resume` is enabled so you can safely resubmit after interruption.

### Submit script details

#### Single node (`submit_bacass.sh`)

All processes run on one node. Best for few samples or quick runs.

| Resource | Value |
|---|---|
| Cores | 20 |
| Memory | 120 GB (6 GB/core) |
| Wall time | 72h |
| Output | `bacass_<JOBID>.out` / `.err` |

#### Distributed (`submit_bacass_distributed.sh`)

Each pipeline task is submitted as a separate LSF job. Tuned for 100+ genome runs with fairshare-friendly limits.

| Resource | Value |
|---|---|
| Head process | 1 core, 4 GB |
| Per-task jobs | Resources from base.config labels (up to 20 cores / 120 GB) |
| Max concurrent jobs | 20 (~320 cores peak) |
| Wall time | 72h |
| Unicycler mode | `--mode bold --no_correct` (2-3x faster) |
| `-resume` | enabled |
| Output | `bacass_head_<JOBID>.out` / `.err` |

#### Funcscan (`submit_funcscan.sh`)

Funcscan uses the same distributed pattern as bacass — a lightweight head process dispatches each screening task (antiSMASH, DeepBGC, ABRicate, etc.) as a separate LSF job. This is critical for 100+ genomes because funcscan runs ~15 tools per sample; on a single node they would serialize and take days.

| Resource | Value |
|---|---|
| Head process | 1 core, 4 GB |
| Per-task jobs | Resources from funcscan's process labels (up to 20 cores / 120 GB) |
| Max concurrent jobs | 20 (~320 cores peak, shared limit with bacass) |
| Wall time | 72h (head job must outlive all sub-jobs) |
| `-resume` | enabled |
| Output | `funcscan_head_<JOBID>.out` / `.err` |

Funcscan reuses the same `conf/lsf.config` as bacass for LSF executor settings (queue, concurrency, submit rate). It additionally loads `conf/funcscan_overrides.config` which pins `pyhmmer<0.12` for GECCO and DeepBGC via custom conda environment YAMLs.

### How the submit scripts work

All three submit scripts (bacass single-node, bacass distributed, funcscan) follow the same pattern:

1. LSF allocates the requested resources (full node for single-node, lightweight head for distributed)
2. `source setup.sh` runs inside the job — this initializes conda, activates the bacass environment (provides Nextflow), and exports database paths, conda cache, and `NXF_HOME` (project-local)
3. Nextflow launches the pipeline with `-profile conda`, using pre-built environments from `.conda_envs/`
4. For distributed scripts, `-c conf/lsf.config` tells Nextflow to submit each process as a separate LSF job instead of running locally
5. I/O-intensive processes (Unicycler/SPAdes) use local scratch (`$TMPDIR`) for performance
6. Funcscan launches from a temp directory to avoid bacass's `nextflow.config` interfering with samplesheet validation

You do **not** need to run `source setup.sh` manually before submitting. The scripts do it internally. You only need to source it yourself for interactive runs on the login node.

### Resource allocation per process

All resources are capped at **20 CPUs / 120 GB RAM** to fit DTU HPC's smallest nodes (47 Huawei XH620 V3 with 20 cores / 128 GB). Memory is capped at 120 GB to leave headroom for OS. Values double on retry.

| Label | Attempt 1 | Retry (attempt 2) | Used by |
|---|---|---|---|
| `process_single` | 1 CPU / 6 GB | 1 CPU / 12 GB | cat/fastq, gunzip, untar, multiqc |
| `process_low` | 4 CPU / 16 GB | 8 CPU / 32 GB | prokka, nanoplot, toulligqc, filtlong |
| `process_medium` | 8 CPU / 40 GB | 16 CPU / 80 GB | fastqc, fastp, porechop, dragonflye, quast, busco, bakta, dfast, kmerfinder |
| `process_high` | 16 CPU / 40 GB | 20 CPU / 80 GB | unicycler, canu, nanopolish |

Per-process overrides in `conf/modules.config` reduce resources for processes that don't benefit from high parallelism:

| Process | CPUs | Memory | Reason |
|---|---|---|---|
| kraken2 | 8 | 40 GB | I/O-bound on DB load, doesn't scale past ~8 threads |
| racon | 8 | 40 GB | 8 CPUs sufficient for bacterial genomes |
| medaka | 8 | 40 GB | 8 CPUs sufficient for bacterial genomes |
| liftoff | 8 | 40 GB | Annotation of small bacterial genomes, fast at 8 cores |
| miniasm | 1 | 16 GB | Single-threaded — does not use multiple CPUs |

### Key parameters

| Parameter | Options | Default |
|---|---|---|
| `--assembly_type` | `short`, `long`, `hybrid` | (required) |
| `--assembler` | `unicycler`, `canu`, `miniasm`, `dragonflye` | `unicycler` |
| `--annotation_tool` | `prokka`, `bakta`, `dfast`, `liftoff` | `bakta` (in submit scripts) |
| `--baktadb` | path to Bakta database | `$BACASS_BAKTADB` (from setup.sh) |
| `--polish_method` | `medaka`, `nanopolish` | `medaka` |
| `--unicycler_args` | e.g., `"--mode bold --no_correct"` | `""` |
| `--skip_kraken2` | skip contamination screening | `false` |
| `--skip_kmerfinder` | skip species identification | `false` |
| `--skip_busco` | skip completeness check | `false` |
| `--skip_annotation` | skip gene annotation | `false` |

### Quick reference

```bash
# Full workflow from scratch
cp submit_bacass_distributed.sh bacass_to_funcscan.sh submit_funcscan.sh /your/project/
vi submit_bacass_distributed.sh        # set INPUT, OUTDIR, ASSEMBLY_TYPE
bsub < submit_bacass_distributed.sh    # submit assembly + annotation
# ... wait for completion ...
./bacass_to_funcscan.sh /your/results  # generate funcscan samplesheet
vi submit_funcscan.sh                  # set INPUT, OUTDIR
bsub < submit_funcscan.sh             # submit BGC/AMP/ARG screening (distributed)

# Monitor
bjobs -w
tail -f bacass_head_*.out              # bacass progress
tail -f funcscan_head_*.out            # funcscan progress

# Resume after interruption
bsub < submit_bacass_distributed.sh    # just resubmit — skips completed steps

# Interactive run (login node, for debugging)
source /work3/josne/github/bacass/setup.sh
nextflow run /work3/josne/github/bacass -profile conda \
  --input samplesheet.tsv \
  --outdir results \
  --assembly_type short \
  --annotation_tool bakta \
  --baktadb $BACASS_BAKTADB \
  --kraken2db $BACASS_KRAKEN2DB \
  --kmerfinderdb $BACASS_KMERFINDERDB
```

## Usage (general)

> [!NOTE]
> If you are new to Nextflow and nf-core, please refer to [this page](https://nf-co.re/docs/usage/installation) on how to set-up Nextflow. Make sure to [test your setup](https://nf-co.re/docs/usage/introduction#how-to-run-a-pipeline) with `-profile test` before running the workflow on actual data.

`--kraken2db` can be any [compressed database (`.tar.gz`/`.tgz`)](https://benlangmead.github.io/aws-indexes/k2) or a local path:

```bash
nextflow run nf-core/bacass \
  -profile <docker/singularity/podman/shifter/charliecloud/conda/institute> \
  --input samplesheet.tsv \
  --outdir <OUTDIR>
```

> [!WARNING]
> Please provide pipeline parameters via the CLI or Nextflow `-params-file` option. Custom config files including those provided by the `-c` Nextflow option can be used to provide any configuration _**except for parameters**_; see [docs](https://nf-co.re/docs/usage/getting_started/configuration#custom-configuration-files).

For more details and further functionality, please refer to the [usage documentation](https://nf-co.re/bacass/usage) and the [parameter documentation](https://nf-co.re/bacass/parameters).

## Pipeline output

To see the results of an example test run with a full size dataset refer to the [results](https://nf-co.re/bacass/results) tab on the nf-core website pipeline page.
For more details about the output files and reports, please refer to the
[output documentation](https://nf-co.re/bacass/output).

## Credits

nf-core/bacass was initiated by [Andreas Wilm](https://github.com/andreas-wilm), originally written by [Alex Peltzer](https://github.com/apeltzer) (DSL1), rewritten by [Daniel Straub](https://github.com/d4straub) (DSL2) and maintained by [Daniel Valle-Millares](https://github.com/Daniel-VM).

## Contributions and Support

If you would like to contribute to this pipeline, please see the [contributing guidelines](.github/CONTRIBUTING.md).

For further information or help, don't hesitate to get in touch on the [Slack `#bacass` channel](https://nfcore.slack.com/channels/bacass) (you can join with [this invite](https://nf-co.re/join/slack)).

## Citations

If you use nf-core/bacass for your analysis, please cite it using the following doi: [10.5281/zenodo.2669428](https://doi.org/10.5281/zenodo.2669428)

An extensive list of references for the tools used by the pipeline can be found in the [`CITATIONS.md`](CITATIONS.md) file.

You can cite the `nf-core` publication as follows:

> **The nf-core framework for community-curated bioinformatics pipelines.**
>
> Philip Ewels, Alexander Peltzer, Sven Fillinger, Harshil Patel, Johannes Alneberg, Andreas Wilm, Maxime Ulysse Garcia, Paolo Di Tommaso & Sven Nahnsen.
>
> _Nat Biotechnol._ 2020 Feb 13. doi: [10.1038/s41587-020-0439-x](https://dx.doi.org/10.1038/s41587-020-0439-x).
