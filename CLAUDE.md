# CLAUDE.md — nf-core/bacass

## Project Overview

**Bacass** (v2.5.0) is an nf-core bacterial assembly and annotation pipeline built with Nextflow DSL2. It supports short-read, long-read (Nanopore), and hybrid assemblies with multiple assembler and annotation tool choices.

- **Template**: nf-core 3.3.2
- **Nextflow**: >=24.10.5, installed at `/work3/josne/miniconda3/envs/bacass/bin/nextflow` (v25.10.4)
- **Conda**: 25.11.1 at `/work3/josne/miniconda3`
- **License**: MIT
- **HPC**: DTU HPC, LSF scheduler, queue `hpc`

## Current Settings & Design Choices

### Portability approach

We chose **Option C**: Nextflow manages conda environments per-process using `-profile conda`. All environments are pre-built and cached in `.conda_envs/` inside the project. No HPC modules or containers needed — everything is self-contained.

### Environment setup (`setup.sh`)

- Sources `/work3/josne/miniconda3/etc/profile.d/conda.sh` to initialize the conda shell function
- Activates `/work3/josne/miniconda3/envs/bacass` (provides Nextflow 25.10.4)
- Must use `#!/bin/bash` (not `#!/bin/sh`) because `conda activate` is a bash function
- Must always source `conda.sh` first — without it, `conda activate` fails with "Run conda init first" in non-interactive shells (bsub jobs)

### Exported variables

| Variable | Value | Purpose |
|---|---|---|
| `NXF_HOME` | `<project>/.nextflow_home/` | Nextflow home (pulled pipelines, plugins) — project-local |
| `NXF_CONDA_CACHEDIR` | `<project>/.conda_envs/` | Pre-built per-process conda environments |
| `NXF_WORK` | `<project>/work/` | Nextflow work directory |
| `BACASS_KRAKEN2DB` | `<project>/assets/databases/minikraken2_v2_8GB_201904.tgz` | Kraken2 database (compressed archive) |
| `BACASS_KMERFINDERDB` | `<project>/assets/databases/kmerfinder_20190108_stable_dirs/bacteria` | Kmerfinder database (directory) |
| `BACASS_BAKTADB` | `<project>/assets/databases/bakta_db` | Bakta annotation database (full, ~72 GB) |

### Resource configuration (`conf/base.config`)

Tuned for DTU HPC's smallest nodes: **20 cores / 128 GB RAM** (47 Huawei XH620 V3 2660v3 nodes). Memory capped at 120 GB to leave headroom for OS. A `check_max()` function enforces hard ceilings so nothing exceeds node limits, even on retry.

**Hard ceilings**: 20 CPUs / 120 GB / 48h per process

| Label | Attempt 1 | Attempt 2 (retry) | Processes |
|---|---|---|---|
| `process_single` | 1 CPU / 6 GB / 4h | 1 CPU / 12 GB / 8h | cat/fastq, gunzip, untar, multiqc, bakta/dbdownload |
| `process_low` | 4 CPU / 16 GB / 4h | 8 CPU / 32 GB / 8h | prokka, nanoplot, toulligqc, filtlong, samtools/index, kraken2/db_preparation, kmerfinder/summary |
| `process_medium` | 8 CPU / 40 GB / 8h | 16 CPU / 80 GB / 16h | fastqc, fastp, pycoqc, porechop, dragonflye, minimap2, samtools/sort, quast, busco, bakta, dfast, kmerfinder, custom/multiqc |
| `process_high` | 16 CPU / 40 GB / 16h | 20 CPU / 80 GB / 32h | unicycler, canu, nanopolish |
| `process_high_memory` | 120 GB | 120 GB (capped) | (unused currently) |

**Per-process resource overrides** (in `conf/modules.config` — these override the label defaults):

| Process | CPUs | Memory | Time | Reason |
|---|---|---|---|---|
| `UNICYCLER` | 8 | 8 GB → 16 GB retry | 16h → 32h retry | Observed peak 3.8 GB / ~6% CPU eff. on 16 CPUs; SPAdes single-threaded between phases |
| `BAKTA` | 8 | 16 GB → 32 GB retry | — | Observed peak 4.5 GB at 7 min / 32–50% CPU eff.; full DB diamond alignment ~8 GB |
| `KRAKEN2` | 8 | 16 GB → 32 GB retry | 8h | minikraken2 DB is ~8 GB; 16 GB gives 2× headroom |
| `FASTQC_RAW/TRIM` | 2 | 4 GB → 8 GB retry | — | Single-threaded tool; process_medium (40 GB) was massively over-provisioned |
| `FASTP` | 4 | 8 GB → 16 GB retry | — | Low memory tool; 4 CPUs covers worker + I/O threads |
| `BUSCO_BUSCO` | 4 | 8 GB → 16 GB retry | — | Bacterial BUSCO (HMMER-based) is memory-light; doesn't scale past ~4 CPUs |
| `QUAST` | 2 | 4 GB → 8 GB retry | — | Mostly single-threaded for bacterial genomes |
| `RACON` | 8 | 40 GB | 8h | Moderate parallelism, 8 CPUs sufficient for bacterial genomes |
| `MEDAKA` | 8 | 40 GB | 8h | 8 CPUs sufficient for bacterial genomes |
| `LIFTOFF` | 8 | 40 GB | 8h | Annotation of small bacterial genomes, fast at 8 cores |
| `MINIASM` | 1 | 16 GB | 8h | Single-threaded — does not pass `task.cpus` to the command |

**Error handling**: retries on OOM/timeout exit codes (130-145, 104, 175). maxRetries = 1. Resources double on retry.

### LSF submission — two modes

#### Single-node (`submit_bacass.sh`)

All processes run on one node. Nextflow uses the local executor.

| Setting | Value |
|---|---|
| Queue | `hpc` |
| Cores | 20 |
| Memory | 6 GB/core (120 GB total, under 128 GB node limit) |
| Kill limit | 6.5 GB/core |
| Wall time | 72h (max allowed on `hpc` queue) |
| Email | josne@dtu.dk (start + completion) |
| Output | `bacass_<JOBID>.out` / `.err` |
| `-resume` | enabled (user added it) |

#### Critical: LSF memory reservation in NF 25.10.4

**NF 25.10.4 does NOT divide `rusage[mem=X]` by CPUs** — only `-M` (the kill limit) is divided. This is empirically observed behaviour (confirmed via `bjobs -l`), not an officially acknowledged upstream bug. This means a 16-CPU / 40 GB job auto-generates `rusage[mem=40960]` per slot, so LSF tries to reserve 40960 MB × 16 = 640 GB on one node. No 128 GB node can satisfy this, causing jobs to PEND with "Resource (mem) limit defined on queue has been reached."

**DTU HPC memory interpretation (confirmed by HPC support, A. Bordoni):** DTU HPC's LSF is configured in **per-core** mode — `-M` is interpreted per slot, not per job. `perJobMemLimit = true` would mean "memory is for the whole job" and should NOT be used here. Keep `perJobMemLimit = false` so NF divides `-M` by CPUs.

**Two fixes are applied:**

1. **Shadow lsf.conf** (`setup.sh`): DTU HPC's `/lsf/conf/lsf.conf` has `LSB_JOB_MEMLIMIT=Y`. NF auto-detects this and sets `perJobMemLimit=true`, disabling `-M` division. `setup.sh` shadows the file with `LSB_JOB_MEMLIMIT=N` and exports `LSF_ENVDIR` to it, so NF sees `perJobMemLimit=false` and divides `-M` by CPUs correctly.

2. **`perTaskReserve = true`** (`conf/lsf.config`): Controls rusage division. NF auto-detects this from `RESOURCE_RESERVE_PER_TASK` in `lsf.conf` — DTU HPC does not set it, so we set `perTaskReserve = true` explicitly in the executor config. NF then generates a single clean `-R "select[mem>=<total>] rusage[mem=<per-slot>]"` string with rusage correctly divided by CPUs. Source: [NF issue #1071](https://github.com/nextflow-io/nextflow/issues/1071), merged 2019.

**Result:** For an 8-CPU / 8 GB UNICYCLER job: `-M 1024` (8192/8), `-R "select[mem>=8192] rusage[mem=1024]"` — no conflicting entries, 8 GB total reservation.

**Never set `perJobMemLimit = true`** — this would disable `-M` division.

**Scheduler polling:** HPC support (A. Bordoni) advised that each `pollInterval` tick translates to a real `bjobs` call that loads the LSF daemon. Keep `pollInterval = '5 min'`. Do not add `submitRateLimit` or `queueStatInterval` — LSF enforces its own submission limits.

#### Distributed (`submit_bacass_distributed.sh`)

Nextflow runs as a lightweight head process and submits each pipeline task as a separate bsub job via the LSF executor. Tuned for 100+ genome runs: queue size is capped at 8 concurrent jobs to avoid hammering the cluster fairshare, and Unicycler runs in bold/no-correct mode for 2-3x faster assemblies.

| Setting | Value |
|---|---|
| Head process | 1 core, 4 GB, 72h |
| Per-task resources | From base.config labels (up to 24 CPU / 128 GB) |
| LSF executor config | `conf/lsf.config` |
| Queue | `hpc` |
| Max concurrent jobs | 20 (keeps ~320 cores peak) |
| `perJobMemLimit` | `false` in `conf/lsf.config` — only divides `-M`, not `rusage` in NF 25.10.4. Rusage fix is the `clusterOptions` closure (see above). Shadow lsf.conf also applied for `-M` correctness. |
| Poll interval | 5 min (HPC support: shorter intervals hammer the LSF daemon with bjobs calls) |
| `-resume` | enabled |
| `--unicycler_args` | `""` (not set by default) |

### I/O performance (`conf/modules.config`)

Unicycler (SPAdes internally) is extremely I/O intensive — thousands of small temp files. Running on network storage is very slow. We set `scratch = true` on the UNICYCLER process so Nextflow stages the task on local scratch (`$TMPDIR`, which LSF sets to a job-specific directory like `/tmp/pbs.<JOBID>.<node>` on the local SSD). Falls back to `/tmp` if `$TMPDIR` is unset.

DTU compute nodes have 480 GB local SSD with ~226 GB available on `/tmp`.

### Wall time choice

LSF wall time is set to 72h (max for `hpc` queue). This does not affect scheduling priority — LSF uses fairshare scheduling based on recent usage, not requested wall time. The 72h limit ensures the head job outlives all individual processes (max single-process time is 32h on retry).

### DTU HPC node types (for reference)

| Node type | Count | Cores | RAM | Local disk |
|---|---|---|---|---|
| Huawei XH620 V3 (2660v3) | 47 | 20 | 128 GB | 1 TB SATA |
| Huawei XH620 V3 (2650v4) | 30 | 24 | 256 GB | 480 GB SSD |
| Huawei XH620 V3 (2650v4) | 6 | 24 | 512 GB | 480 GB SSD |
| ThinkSystem SD530 (6126) | 24 | 24 | 384-768 GB | 480 GB SSD |
| ThinkSystem SD530 (6226R) | 28 | 32 | 384-768 GB | 480 GB SSD |
| ThinkSystem SD530 (6142) | 4 | 32 | 384 GB | 480 GB SSD |
| ThinkSystem SD630 V2 | 4 | 48 | 512 GB | 480 GB SSD |
| ThinkSystem SR630 V3 | 2 | 64 | 1024 GB | — |
| AMD EPYC (various) | 6 | 64-128 | 512-1536 GB | — |

We target the 47 smallest (20-core / 128 GB) Huawei nodes as the baseline, so all jobs can schedule on any node. Note: the 47 smallest nodes have SATA disks (not SSD), so `scratch = true` is slower there but still faster than network storage.

### Annotation tool choice

We use **Bakta** (not Prokka) as the default annotation tool. Bakta provides more comprehensive annotation using the full UniProt database and produces `.gbff` (GenBank) and `.faa` (protein FASTA) files that feed directly into downstream BGC screening with nf-core/funcscan.

The Bakta full database (~72 GB) is stored in `assets/databases/bakta_db/` and referenced via `$BACASS_BAKTADB` in `setup.sh`. The submit scripts pass `--annotation_tool bakta --baktadb $BACASS_BAKTADB`.

**pyhmmer compatibility**: Bakta 1.9.3, GECCO 0.9.10, and DeepBGC 0.1.31 are all incompatible with pyhmmer >=0.12.0 (`hit.name`/`hmm.accession` changed from `bytes` to `str`). We pin `pyhmmer<0.12` via custom environment YAMLs:
- **Bakta**: `conf/bakta_environment.yml`, overridden in `conf/modules.config` with `conda = "${projectDir}/conf/bakta_environment.yml"`
- **GECCO**: `conf/gecco_environment.yml`, overridden in `conf/funcscan_overrides.config`
- **DeepBGC**: `conf/deepbgc_environment.yml`, overridden in `conf/funcscan_overrides.config`

The funcscan overrides are passed via `-c conf/funcscan_overrides.config` in `submit_funcscan.sh`. The config reads `$BACASS_DIR` (exported in the submit script) to resolve the YAML paths.

### Downstream BGC screening with nf-core/funcscan

For functional screening we chain bacass output into [nf-core/funcscan](https://nf-co.re/funcscan/) v3.0.0 as a separate pipeline rather than integrating tools directly into bacass. This keeps bacass clean and leverages funcscan's full screening suite.

**Pipeline chain**: bacass (assembly + Bakta annotation) → funcscan (BGC + AMP + ARG screening)

Funcscan runs three screening modules:
- **BGC screening**: antiSMASH, DeepBGC, GECCO (biosynthetic gene clusters)
- **AMP screening**: ampir, amplify, macrel, hmmsearch (antimicrobial peptides)
- **ARG screening**: ABRicate, AMRFinderPlus, DeepARG, fARGene, RGI (antimicrobial resistance genes)

#### Bridging script (`bacass_to_funcscan.sh`)

The bridging script auto-generates the funcscan samplesheet from bacass results. It scans the results directory for assembly FASTAs (Unicycler or Dragonflye) and annotation output (Bakta `.gbff`/`.faa` or Prokka `.gbk`/`.faa`), then writes a 4-column CSV (`sample,fasta,protein,gbk`). Funcscan accepts pre-annotated input, so it skips re-annotation and goes straight to screening.

| Funcscan input | Bacass output | Source directory |
|---|---|---|
| `fasta` | Assembly FASTA | `results/Unicycler/` or `results/Dragonflye/` |
| `protein` | `.faa` protein FASTA | `results/Bakta/<sample>/` or `results/Prokka/<sample>/` |
| `gbk` | `.gbff` or `.gbk` GenBank file | `results/Bakta/<sample>/` or `results/Prokka/<sample>/` |

#### Funcscan submission — distributed (`submit_funcscan.sh`)

Funcscan uses the same distributed LSF executor pattern as bacass: a lightweight head process (1 core / 4 GB) submits each screening task as a separate LSF job via `conf/lsf.config`. This is essential for 100+ genomes because funcscan runs ~15 tools per sample — on a single node those would serialize and take days.

| Setting | Value | Reasoning |
|---|---|---|
| Head process | 1 core, 4 GB, 72h | Lightweight — only dispatches sub-jobs |
| Per-task resources | From funcscan's process labels | Each tool gets its own LSF job with appropriate resources |
| LSF executor config | `conf/lsf.config` (shared with bacass) | Same queue, same limits — 20 concurrent jobs, 25/min submit rate |
| Conda env overrides | `conf/funcscan_overrides.config` | Pins `pyhmmer<0.12` for GECCO and DeepBGC via custom environment YAMLs |
| Wall time | 72h | Head job must outlive all sub-jobs; 72h is max for `hpc` queue |
| `-resume` | enabled | Safe to resubmit after interruption — skips completed tasks |

**Two `-c` config files**: The nextflow command passes both `-c conf/lsf.config` (LSF executor settings) and `-c conf/funcscan_overrides.config` (conda environment overrides for GECCO/DeepBGC). Nextflow merges multiple `-c` configs in order, so both take effect.

**Databases**: all pre-downloaded to `assets/databases/` (gitignored):

| Tool | Path | Size |
|---|---|---|
| antiSMASH | `assets/databases/antismash_db/` | 9.4 GB |
| DeepBGC | `assets/databases/deepbgc_db/` | 2.8 GB |
| CARD/RGI | `assets/databases/card_database_processed/` | 65 MB |
| AMRFinderPlus | `assets/databases/amrfinderplus_db/` | 237 MB |
| DeepARG | `assets/databases/deeparg_db/` | 4.8 GB |
| DRAMP (AMPcombi2) | `assets/databases/amp_DRAMP_database/` | 11 MB |

Note: `card_database_processed` name is required — funcscan detects it and skips the `RGI_CARDANNOTATION` step. All paths are hardcoded in `submit_funcscan.sh`.

**Config collision**: funcscan must be launched from a temp directory (not the bacass project root) because bacass's `nextflow.config` would otherwise be auto-loaded, causing samplesheet validation to use bacass's schema (expects `ID` column) instead of funcscan's (expects `sample` column). The `submit_funcscan.sh` script handles this automatically by creating a temp dir, launching from there, and cleaning up after.

**Portability**: `NXF_HOME` is set project-local in `setup.sh`, so pulled pipelines (like funcscan) are cached in `.nextflow_home/assets/` rather than `~/.nextflow/`. Conda environments are shared via `NXF_CONDA_CACHEDIR`. Funcscan uses a separate work directory (`work_funcscan/`) to avoid collisions with bacass.

## Repository Layout

```
main.nf                         # Entry point — includes workflows/bacass.nf
workflows/bacass.nf             # Main workflow logic (~695 lines)
nextflow.config                 # Pipeline configuration, profiles, env settings
nextflow_schema.json            # Parameter schema (validated by nf-schema plugin)
setup.sh                        # Environment setup (conda, nextflow, DB paths)
submit_bacass.sh                # LSF single-node submit script
submit_bacass_distributed.sh    # LSF distributed submit script
bacass_to_funcscan.sh           # Generate funcscan samplesheet from bacass results
submit_funcscan.sh              # LSF distributed submit script for nf-core/funcscan
conf/
  base.config                   # Resource labels, tuned for DTU HPC 20-core/128GB
  lsf.config                    # LSF executor config for distributed runs
  modules.config                # Per-process ext.args, publishDir, scratch, ext.when
  bakta_environment.yml         # Bakta conda env with pyhmmer<0.12 pin
  test*.config                  # 10 test profiles
modules/
  nf-core/                      # 25+ downloaded nf-core modules (DO NOT edit by hand)
  local/                        # 7 custom modules
subworkflows/
  nf-core/                      # 4 nf-core subworkflows (DO NOT edit by hand)
  local/                        # 4 local subworkflows
bin/                            # Python helper scripts
tests/                          # nf-test files (*.nf.test) and snapshots (*.nf.test.snap)
assets/
  databases/                    # Databases: Kraken2, Kmerfinder, Bakta, antiSMASH, DeepBGC, CARD, AMRFinderPlus, DeepARG, DRAMP (gitignored)
  multiqc_config*.yml           # MultiQC configs per assembly type
.conda_envs/                    # Pre-built conda environments (gitignored)
.nextflow_home/                 # Nextflow home: pulled pipelines, plugins (gitignored)
docs/                           # usage.md, output.md, images/
```

## Key Files You Will Touch Most Often

| File | Purpose |
|---|---|
| `submit_bacass.sh` | Edit INPUT, OUTDIR, ASSEMBLY_TYPE for each run |
| `submit_bacass_distributed.sh` | Same, for distributed runs |
| `bacass_to_funcscan.sh` | Generate funcscan samplesheet from bacass results |
| `submit_funcscan.sh` | Submit nf-core/funcscan BGC screening job |
| `conf/modules.config` | Configure process args (`ext.args`), publishDir, scratch, `ext.when`, Bakta conda override |
| `conf/bakta_environment.yml` | Bakta conda env spec with pyhmmer<0.12 pin |
| `conf/gecco_environment.yml` | GECCO conda env spec with pyhmmer<0.12 pin |
| `conf/deepbgc_environment.yml` | DeepBGC conda env spec with pyhmmer<0.12 pin |
| `conf/funcscan_overrides.config` | Nextflow config overriding GECCO/DeepBGC conda envs for funcscan |
| `conf/base.config` | Resource allocation (CPUs, memory, time per label, hard ceilings) |
| `conf/lsf.config` | LSF executor tuning (queue, queue size, submit rate) |
| `workflows/bacass.nf` | Main workflow — add/remove steps, wire channels |
| `nextflow.config` | Profiles, params defaults, env block |
| `nextflow_schema.json` | Parameter definitions for `--help` and validation |
| `modules/local/*/main.nf` | Custom process definitions |
| `setup.sh` | Environment setup (change if conda/nextflow paths move) |

## Coding Conventions

### Nextflow / Groovy Style

- **Indentation**: 4 spaces (Nextflow/Groovy), 2 spaces (YAML, Markdown, JSON)
- **Line width**: 120 characters max (Prettier enforced)
- **Process names**: `UPPER_CASE` (e.g., `FASTQC`, `KRAKEN2`, `PROKKA`)
- **Channel names**: `ch_` prefix, `snake_case` (e.g., `ch_reads_for_assembly`)
- **Parameters**: `snake_case` (e.g., `assembly_type`, `skip_kraken2`)
- **Variables inside processes**: `camelCase` (e.g., `def prefix`, `def args`)

### nf-core Module Rules

- **NEVER edit files under `modules/nf-core/` or `subworkflows/nf-core/`**. Use `nf-core modules update/install`.
- `modules.json` tracks installed module versions — do not edit manually.
- Local modules in `modules/local/` follow the same structure.

### Process Structure Template

```groovy
process TOOLNAME {
    tag "$meta.id"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "biocontainers/tool:version"

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta), path("*.ext"), emit: result
    path "versions.yml"         , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args   = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    tool command $args $reads -o ${prefix}.ext

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        tool: \$(tool --version 2>&1 | sed 's/.*v//')
    END_VERSIONS
    """
}
```

## Pipeline Parameters

- `--assembly_type`: `short`, `long`, or `hybrid` (required)
- `--assembler`: `unicycler` (default), `canu`, `miniasm`, `dragonflye`
- `--annotation_tool`: `prokka` (pipeline default), `bakta` (our default), `dfast`, `liftoff`
- `--baktadb`: path to Bakta database (use `$BACASS_BAKTADB` from setup.sh)
- `--polish_method`: `medaka` (default), `nanopolish`
- `--kraken2db`: path to Kraken2 database (`.tgz` or directory)
- `--kmerfinderdb`: path to Kmerfinder database
- `--unicycler_args`: extra args passed to Unicycler (e.g., `"--mode bold"` for faster assembly)
- `--skip_*`: skip individual steps (`--skip_kraken2`, `--skip_busco`, `--skip_annotation`, etc.)

## Testing

### Framework: nf-test

```bash
nf-test test --profile docker                                      # all tests
nf-test test tests/default.nf.test --profile docker                # specific test
nf-test test tests/default.nf.test --profile docker --update-snapshot  # update snapshots
```

### Available tests

`default`, `hybrid`, `hybrid_dragonflye`, `long`, `long_miniasm`, `long_miniasm_prokka`, `long_dragonflye`, `long_liftoff`, `dfast`

## Linting

```bash
npx prettier@3.6.2 --check .       # check formatting
npx prettier@3.6.2 --write .       # fix formatting
nf-core pipelines lint             # nf-core standards check
```

Config: `.prettierrc.yml` (120 char width, 4-space indent, 2-space for YAML/MD/JSON)

## Git & CI Workflow

- **Main branch**: `master` (releases)
- **Development branch**: `dev` (PRs target here)
- **Commit style**: lowercase, descriptive
- **CI on PR**: Prettier check, nf-core lint, nf-test matrix (conda/docker/singularity x 2 NF versions)
- **Pre-commit hooks**: Prettier, trailing whitespace, end-of-file fix

## Common Tasks

### Add a new local module

1. Create `modules/local/toolname/main.nf` + `environment.yml`
2. Include in `workflows/bacass.nf`
3. Add process config in `conf/modules.config`
4. Wire channels in the workflow

### Add a new nf-core module

```bash
nf-core modules install <module_name>
```

### Modify process arguments (without editing modules)

Edit `conf/modules.config`:
```groovy
withName: 'PROKKA' {
    ext.args = '--kingdom Bacteria --genus MyGenus'
}
```

### Enable local scratch for an I/O-heavy process

Add `scratch = true` in `conf/modules.config` (uses `$TMPDIR` → local SSD):
```groovy
withName: 'CANU' {
    scratch = true
}
```

### Change resource limits for a different HPC

Edit `conf/base.config` — adjust `params.max_cpus`, `params.max_memory`, `params.max_time` and the label values. The `check_max()` function ensures nothing exceeds the ceilings.

### Run BGC screening after bacass

```bash
# 1. Generate funcscan samplesheet from bacass results
#    Auto-detects Bakta/Prokka and Unicycler/Dragonflye output
./bacass_to_funcscan.sh /path/to/bacass/results

# 2. Edit submit_funcscan.sh — set INPUT (path to generated CSV) and OUTDIR

# 3. Submit — runs distributed across the cluster, same as bacass
bsub < submit_funcscan.sh
```

The bridging script scans the results directory, pairs each sample's assembly FASTA with its annotation files (`.faa` + `.gbff`/`.gbk`), and writes a 4-column CSV. Samples with missing files are skipped with a warning. Funcscan skips re-annotation when pre-annotated files are provided.

### Troubleshooting

- **"conda: command not found"** in bsub job: ensure `#!/bin/bash` shebang and that `setup.sh` sources `conda.sh` before `conda activate`
- **"Run conda init first"**: `conda.sh` must be sourced before `conda activate` — already handled in `setup.sh`
- **Lock file error after killed job**: delete `.nextflow/cache/*/db/LOCK` and re-run with `-resume`
- **SPAdes/Unicycler slow**: `scratch = true` is already set in modules.config; also consider `--unicycler_args "--mode bold"` for faster assembly
- **`AttributeError: 'str' object has no attribute 'decode'`** (Bakta, GECCO, DeepBGC): pyhmmer >=0.12 broke all three tools. Fixed via custom environment YAMLs that pin `pyhmmer<0.12`: `conf/bakta_environment.yml` (applied through `conf/modules.config`), `conf/gecco_environment.yml` and `conf/deepbgc_environment.yml` (applied through `conf/funcscan_overrides.config` passed with `-c` in `submit_funcscan.sh`)
- **Funcscan "Missing required field(s): ID"**: bacass's `nextflow.config` is being loaded instead of funcscan's. The `submit_funcscan.sh` avoids this by launching from a temp directory. If running interactively, `cd` to a directory without a `nextflow.config`
- **NCBI download BadZipFile**: the `bin/download_reference.py` fix strips assembly-name suffixes from kmerfinder accessions (e.g., `GCF_003345295.1_ASM334529v1` → `GCF_003345295.1`) and validates zip files before extraction
- **"Multiple -R resource requirement strings are not supported"** in distributed mode: LSF rejects multiple `-R` flags for span/affinity sections. The fix was to remove `clusterOptions = '-R "span[hosts=1]"'` from `conf/lsf.config` — single-process tasks don't need it since LSF places them on one host by default
- **Unicycler jobs stuck PEND — "Resource (mem) limit defined on queue has been reached"**: NF 25.10.4 does not divide `rusage[mem=X]` by CPUs — only `-M` is divided. A 16-CPU/40 GB job gets `rusage[mem=40960]` per slot = 640 GB total reservation; no 128 GB node can host this. Tell-tale sign: `-M 2560` (divided correctly) but `rusage[mem=40960]` (not divided). Two-part fix already applied: (1) `setup.sh` generates shadow `conf/lsf_shadow/lsf.conf` with `LSB_JOB_MEMLIMIT=N` (so NF's `shouldDivide` is true for `-M`); (2) `clusterOptions` closure in `conf/lsf.config` appends `-R "rusage[mem=memory/cpus]"` — LSF last-wins rule overrides the auto-generated undivided rusage. Verify fix: `bjobs -l <jobid> | grep Combined` should show `rusage[mem=2560.00]` for 16-CPU jobs. If broken again: kill head and resubmit with `-resume`.
- **Fairshare priority depleted / jobs stuck PEND for >24h**: LSF fairshare on DTU HPC decays slowly. Running 65+ samples in distributed mode can burn fairshare and drop priority significantly. Resource overrides in `conf/modules.config` right-size over-provisioned processes (KRAKEN2, RACON, MEDAKA, LIFTOFF, MINIASM) to reduce fairshare consumption. If already stuck: kill everything and resubmit with `-resume` after priority recovers.
