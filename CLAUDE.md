# CLAUDE.md — nf-core/bacass

## Project Overview

**Bacass** (v2.5.0) is an nf-core bacterial assembly and annotation pipeline (Nextflow DSL2). Short-read, long-read (Nanopore), and hybrid assemblies with multiple assembler/annotation options.

- **Nextflow**: v25.10.4 at `/work3/josne/miniconda3/envs/bacass/bin/nextflow`
- **Conda**: 25.11.1 at `/work3/josne/miniconda3`
- **HPC**: DTU HPC, LSF scheduler, queue `hpc` (target: 20-core / 128 GB nodes)
- **Profile**: `-profile conda`, all envs pre-built in `.conda_envs/`

## Environment (`setup.sh`)

- Must use `#!/bin/bash`; sources `conda.sh` then activates `bacass` env
- Exports:

| Variable | Value |
|---|---|
| `NXF_HOME` | `<project>/.nextflow_home/` |
| `NXF_CONDA_CACHEDIR` | `<project>/.conda_envs/` |
| `NXF_WORK` | `<project>/work/` |
| `BACASS_KRAKEN2DB` | `assets/databases/minikraken2_v2_8GB_201904.tgz` |
| `BACASS_KMERFINDERDB` | `assets/databases/kmerfinder_20190108_stable_dirs/bacteria` |
| `BACASS_BAKTADB` | `assets/databases/bakta_db` |

## Resource Configuration (`conf/base.config`)

**Hard ceilings**: 20 CPUs / 120 GB / 48h. `check_max()` enforces limits on retry.

| Label | CPUs/Mem/Time | Retry |
|---|---|---|
| `process_single` | 1 / 6 GB / 4h | 1 / 12 GB / 8h |
| `process_low` | 4 / 16 GB / 4h | 8 / 32 GB / 8h |
| `process_medium` | 8 / 40 GB / 8h | 16 / 80 GB / 16h |
| `process_high` | 16 / 40 GB / 16h | 20 / 80 GB / 32h |

**Per-process overrides** (in `conf/modules.config`):

| Process | CPUs | Memory | Time |
|---|---|---|---|
| `UNICYCLER` | 8 | 8→16 GB | 16→32h |
| `BAKTA` | 8 | 16→32 GB | — |
| `KRAKEN2` | 8 | 16→32 GB | 8h |
| `FASTQC_RAW/TRIM` | 2 | 4→8 GB | — |
| `FASTP` | 4 | 8→16 GB | — |
| `BUSCO_BUSCO` | 4 | 8→16 GB | — |
| `QUAST` | 2 | 4→8 GB | — |
| `RACON` | 8 | 40 GB | 8h |
| `MEDAKA` | 8 | 40 GB | 8h |
| `LIFTOFF` | 8 | 40 GB | 8h |
| `MINIASM` | 1 | 16 GB | 8h |

**Error handling**: retries on exit codes 130-145, 104, 175. `maxRetries = 1`. Resources double on retry.

## LSF Submission

### Single-node (`submit_bacass.sh`)
Local executor. 20 cores, 120 GB (6 GB/core), 72h wall time, `hpc` queue.

### Distributed (`submit_bacass_distributed.sh`)
Head process: 1 core / 4 GB / 72h. Per-task via `conf/lsf.config`. Max 150 concurrent jobs. `pollInterval = '2 min'`.

### Critical: LSF Memory Fix (NF 25.10.4)

NF 25.10.4 does NOT divide `rusage[mem=X]` by CPUs. Two fixes applied:

1. **Shadow lsf.conf** (`setup.sh`): DTU HPC has `LSB_JOB_MEMLIMIT=Y` → NF disables `-M` division. Shadow with `LSB_JOB_MEMLIMIT=N`, export `LSF_ENVDIR` to shadow dir.
2. **`perTaskReserve = true`** (`conf/lsf.config`): divides `rusage` by CPUs → single clean `-R "select[mem>=<total>] rusage[mem=<per-slot>]"`.

**Never set `perJobMemLimit = true`**. Verify: `bjobs -l <jobid>` → single `-R` string.

## Annotation: Bakta

Default annotation tool (not Prokka). Full DB at `assets/databases/bakta_db/` (~72 GB). Submit scripts pass `--annotation_tool bakta --baktadb $BACASS_BAKTADB`.

**pyhmmer pin**: Bakta 1.9.3, GECCO 0.9.10, DeepBGC 0.1.31 are incompatible with pyhmmer >=0.12. Pin via:
- `conf/bakta_environment.yml` → overridden in `conf/modules.config`
- `conf/gecco_environment.yml`, `conf/deepbgc_environment.yml` → overridden in `conf/funcscan_overrides.config`

## Funcscan (BGC/AMP/ARG Screening)

Pipeline chain: bacass → [nf-core/funcscan](https://nf-co.re/funcscan/) v3.0.0 (separate run).

Screening: BGC (antiSMASH, DeepBGC, GECCO), AMP (ampir, amplify, macrel, hmmsearch), ARG (ABRicate, AMRFinderPlus, DeepARG, fARGene, RGI).

**Databases** at `assets/databases/` (gitignored): antismash_db (9.4 GB), deepbgc_db (2.8 GB), card_database_raw (symlink→processed, 65 MB), amrfinderplus_db (237 MB), deeparg_db (4.8 GB), amp_DRAMP_database (11 MB).

**Key rules**:
- Launch funcscan from `$(dirname $OUTDIR)`, NOT the bacass project root (avoids nextflow.config collision)
- `--arg_rgi_db` must point to `card_database_raw` symlink, NOT `card_database_processed` directly
- `FUNCSCAN_WORK` must be the same dir for test and full run (enables `-resume`)
- Two `-c` flags: `-c conf/lsf.config -c conf/funcscan_overrides.config`
- `UNICYCLER`: `scratch = true` (SPAdes I/O intensive; uses `$TMPDIR` on local SSD)

**Samplesheet**: `./bacass_to_funcscan.sh <results_dir> <output.csv>` → 4-column CSV (sample, fasta, protein, gbk).

## Repository Layout

```
main.nf / workflows/bacass.nf   # Entry point / main workflow
nextflow.config                 # Profiles, params defaults
setup.sh                        # Conda + Nextflow env setup
submit_bacass.sh                # Single-node LSF submit
submit_bacass_distributed.sh    # Distributed LSF submit
bacass_to_funcscan.sh           # Generate funcscan samplesheet
submit_funcscan_distributed.sh  # Funcscan LSF submit
conf/
  base.config                   # Resource labels
  lsf.config                    # LSF executor (perTaskReserve, pollInterval)
  modules.config                # ext.args, publishDir, scratch, resource overrides
  bakta_environment.yml         # pyhmmer<0.12 pin for Bakta
  gecco_environment.yml         # pyhmmer<0.12 pin for GECCO
  deepbgc_environment.yml       # pyhmmer<0.12 pin for DeepBGC
  funcscan_overrides.config     # GECCO/DeepBGC conda overrides + resource fixes
modules/nf-core/                # DO NOT edit — use nf-core modules update/install
modules/local/                  # 7 custom modules
bin/                            # Python helpers + libnfs_retry.so (LD_PRELOAD)
assets/databases/               # All databases (gitignored)
.conda_envs/                    # Pre-built conda envs (gitignored)
.nextflow_home/                 # NXF_HOME: pulled pipelines, plugins (gitignored)
```

## Coding Conventions

- **Indentation**: 4 spaces (Nextflow/Groovy), 2 spaces (YAML/MD/JSON)
- **Line width**: 120 chars (Prettier enforced via `.prettierrc.yml`)
- **Process names**: `UPPER_CASE`; **channels**: `ch_` prefix, `snake_case`; **params**: `snake_case`; **vars inside processes**: `camelCase`
- **NEVER edit** `modules/nf-core/` or `subworkflows/nf-core/`; `modules.json` auto-managed

### Process Template

```groovy
process TOOLNAME {
    tag "$meta.id"
    label 'process_medium'
    conda "${moduleDir}/environment.yml"
    input:  tuple val(meta), path(reads)
    output: tuple val(meta), path("*.ext"), emit: result
            path "versions.yml", emit: versions
    when: task.ext.when == null || task.ext.when
    script:
    def args   = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    tool $args $reads -o ${prefix}.ext
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        tool: \$(tool --version 2>&1 | sed 's/.*v//')
    END_VERSIONS
    """
}
```

## Pipeline Parameters

- `--assembly_type`: `short` | `long` | `hybrid` (required)
- `--assembler`: `unicycler` (default), `canu`, `miniasm`, `dragonflye`
- `--annotation_tool`: `bakta` (our default), `prokka`, `dfast`, `liftoff`
- `--baktadb`, `--kraken2db`, `--kmerfinderdb`: database paths
- `--unicycler_args`: e.g., `"--mode bold"` for 2-3× faster assembly
- `--skip_*`: `--skip_kraken2`, `--skip_busco`, `--skip_annotation`, etc.

## Testing & Linting

```bash
nf-test test --profile docker                          # all tests
nf-test test tests/default.nf.test --profile docker    # single test
npx prettier@3.6.2 --check .                           # lint
nf-core pipelines lint                                 # nf-core check
```

Tests: `default`, `hybrid`, `hybrid_dragonflye`, `long`, `long_miniasm`, `long_miniasm_prokka`, `long_dragonflye`, `long_liftoff`, `dfast`

## Common Tasks

```bash
# Add nf-core module
nf-core modules install <module_name>

# Override process args (conf/modules.config)
withName: 'PROKKA' { ext.args = '--kingdom Bacteria' }

# Enable local scratch for I/O-heavy process
withName: 'CANU' { scratch = true }

# Run funcscan after bacass
./bacass_to_funcscan.sh /path/to/results samplesheet.csv
head -6 samplesheet.csv > samplesheet_test.csv   # 5-sample test first
bsub < submit_funcscan_distributed.sh
```

## Troubleshooting

- **Jobs PEND "Resource (mem) limit"**: LSF memory fix not active — check shadow lsf.conf and `perTaskReserve = true` in `conf/lsf.config`. Verify: `bjobs -l <id>` shows single `-R` with divided rusage.
- **"conda: command not found" / "Run conda init first"**: ensure `#!/bin/bash` and `conda.sh` sourced in `setup.sh`
- **`/bin/activate: No such file or directory`**: `conda info --json` returning empty (NFS failure). Fix: `/work3/josne/miniconda3/bin/conda` is already patched to short-circuit `conda info --json`. See MEMORY.md.
- **Spurious ENOENT on BeeGFS files**: `bin/libnfs_retry.so` LD_PRELOADed via `beforeScript` AND exported in `setup.sh` so bash itself loads the library (protects bash `source` builtins including conda activation). See MEMORY.md to rebuild.
- **`AttributeError: 'str' object has no attribute 'decode'`** (Bakta/GECCO/DeepBGC): pyhmmer >=0.12 incompatibility. Fixed via `pyhmmer<0.12` in custom env YAMLs.
- **Funcscan "Missing required field(s): ID"**: bacass `nextflow.config` auto-loaded. Launch funcscan from outside the bacass project dir.
- **Funcscan `GECCO_RUN` "mv: are the same file"**: `ext.prefix = { "${meta.id}_gecco" }` in `conf/funcscan_overrides.config` (already applied).
- **Funcscan `DEEPBGC_PIPELINE` mv double-suffix bug**: `ext.prefix = "deepbgc"` (static) in `conf/funcscan_overrides.config` (already applied).
- **Funcscan `DEEPBGC_PIPELINE` NFS/infiniband read-bottlenecking**: deepbgc_db (2.8 GB Pfam) is staged as a symlink → all hmmscan reads go over NFS. Fix: `conf/funcscan_patches/deepbgc_pipeline_main.nf` rsyncs the db to `/tmp/josne/deepbgc_db/` before running and sets `DEEPBGC_DOWNLOADS_DIR=/tmp/josne/deepbgc_db`. rsync is idempotent — multiple jobs on the same node only copy once. Deployed by `submit_funcscan_distributed.sh`.
- **Funcscan `RGI_CARDANNOTATION` "mkdir: File exists"**: use `card_database_raw` symlink, not `card_database_processed` dir (already in submit script).
- **Funcscan `DEEPBGC_PIPELINE`/`DEEPARG_PREDICT` single-threaded/timeout**: `cpus=10,time=48h` / `cpus=8,time=4h` in `conf/funcscan_overrides.config` (already applied).
- **Funcscan `DEEPARG_PREDICT` Theano JIT C-header failures**: persistent cache pre-warmed at `env-cff2.../theano_persistent_cache/` via `sitecustomize.py`. See MEMORY.md to re-warm.
- **Funcscan `ANTISMASH_ANTISMASH` `blastp returned 127`**: LD_LIBRARY_PATH set in `env-3afb.../etc/conda/activate.d/ncbi_blast_lib.sh` (already applied).
- **Funcscan `ANTISMASH_ANTISMASH` Jinja2 `FileNotFoundError`**: `html_renderer.py` patched to DictLoader (pre-loads all templates). See MEMORY.md to reapply if env rebuilt.
- **Funcscan Python tools `can't open file`**: bash heredoc wrappers applied to all Python entry-point scripts. See MEMORY.md for pattern and env list.
- **Lock file error after killed job**: `rm .nextflow/cache/*/db/LOCK && nextflow run ... -resume`
- **Fairshare depleted**: kill all jobs, wait for priority recovery, resubmit with `-resume`
- **Bakta `ERROR: Circos could not be executed!`**: patch circos shebang to absolute perl path in pre-built env. See MEMORY.md.
- **`KMERFINDER_SUMMARY` `No module named 'yaml'`**: missing `conda` directive in `main.nf` — already fixed.
- **NCBI `BadZipFile`**: `bin/download_reference.py` strips assembly-name suffixes from kmerfinder accessions — already fixed.
