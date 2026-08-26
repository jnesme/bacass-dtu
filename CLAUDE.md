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
| `BACASS_KRAKEN2DB` | `assets/databases/minikraken2_v2_8GB_201904_UPDATE` |
| `BACASS_KMERFINDERDB` | `assets/databases/kmerfinder_20190108_stable_dirs/bacteria` |
| `BACASS_BAKTADB` | `assets/databases/bakta_db` |
| `BACASS_BUSCODB` | `assets/databases/busco_db` |

## Resource Configuration (`conf/base.config`)

**Hard ceilings**: 20 CPUs / 120 GB / 48h. `check_max()` enforces limits on retry.

| Label | CPUs/Mem/Time | Retry |
|---|---|---|
| `process_single` | 1 / 6 GB / 4h | 1 / 12 GB / 8h |
| `process_low` | 4 / 16 GB / 4h | 8 / 32 GB / 8h |
| `process_medium` | 8 / 40 GB / 8h | 16 / 80 GB / 16h |
| `process_high` | 16 / 40 GB / 16h | 20 / 80 GB / 32h |

**Per-process overrides** (in `conf/modules.config`):

| Process | CPUs | Memory | Time | scratch | maxForks |
|---|---|---|---|---|---|
| `UNICYCLER` | **4** | 8→16 GB | 8→16h | ✓ | **15** |
| `BAKTA` | 6 | 20→40 GB | — | — | **8** |
| `KRAKEN2` / `KRAKEN2_LONG` | 8 | 10→20 GB | 1h | — | **15** |
| `KMERFINDER` | **1** | **8→16 GB** | — | — | **15** |
| `FASTQC_RAW/TRIM` | **2** | 4→8 GB | — | — | **10** |
| `FASTP` | 4 | 3→6 GB | — | — | **20** |
| `BUSCO_BUSCO` | 4 | 2→4 GB | — | ✓ | **15** |
| `QUAST` | 2 | 4→8 GB | — | — | — |
| `RACON` | 8 | 40 GB | 8h | — | **10** |
| `MEDAKA` | 8 | 40 GB | 8h | — | **10** |
| `LIFTOFF` | 8 | 40 GB | 8h | — | **10** |
| `MINIASM` | 8 | 40 GB | 8h | — | 10 |

BUSCO uses `scratch = true` to reduce BeeGFS I/O load. FASTP, KRAKEN2/KRAKEN2_LONG, and BAKTA had `scratch = true` removed (Mar 2026) — their DB/large-output I/O wasn't helped by staging (DB inputs are directories, always symlinked regardless of scratch; FASTP's rsync staging itself caused BeeGFS burst traffic). UNICYCLER uses `scratch = true` and cleans stale SPAdes checkpoints via the first line of its script block in `modules/local/unicycler/main.nf` — see Troubleshooting below.

**FastQC CPU/maxForks rationale**: FastQC supports multi-threading via `-t`: each thread processes one file in parallel. `cpus=2` + `-t 2` processes R1 and R2 simultaneously for paired-end data — honest and efficient. The original incident (1.8M CS/s, Mar 2026) was caused by `cpus=2` with no `-t` flag: the JVM spawned ~20 threads regardless, and LSF bin-packed 10 jobs onto one 20-core node → 200 threads competing for 20 cores. With honest CPU declarations, LSF bin-packing naturally limits jobs per node to match actual thread use. `maxForks=10` provides an additional global concurrency cap. **Note**: with the LSF executor, `maxForks` defaults to effectively unlimited (the head job has 1 CPU; `maxForks` default = CPUs−1 applies to local executor only). Must be set explicitly for any tool where actual resource use differs from nf-core defaults. **Caution**: `conf/modules.config` sets `FASTQC_TRIM` args in two `withName` blocks — one guarded by `skip_fastqc` only, one nested inside `skip_fastp` (the block that actually wins in a normal run, since it appears later in the file). Both must carry `-t 2`, or this fix silently regresses. Verify with `nextflow config . -profile conda | grep -A3 "FASTQC_TRIM'"` after touching either block.

**BUSCO maxForks rationale**: For prokaryotic genomes, BUSCO uses Prodigal for gene prediction (not AUGUSTUS). HMMER is genuinely multi-threaded (cpus=4); `maxForks=15` bounds concurrent InfiniBand reads of the lineage dataset (directory input, always symlinked) and caps total HMMER slots (15×4=60).

**InfiniBand/BeeGFS I/O maxForks rationale**: directory inputs (database paths) are always symlinked and read over InfiniBand regardless of `scratch`. FASTP `maxForks=20`: no scratch (removed Mar 2026 — rsync staging caused BeeGFS burst traffic); cap is a general concurrency bound, not DB-related — FASTP is C++ and well-behaved. KRAKEN2 `maxForks=15`: scratch removed too (DB dir was always symlinked, not rsynced); caps concurrent 7.5 GB DB reads (15×8=120 LSF slots). BAKTA `maxForks=8`: scratch removed too; 72 GB DB too large to rsync anyway; 8×6=48 slots. KMERFINDER `maxForks=15`: 17 GB DB, no scratch (15×17 GB=255 GB concurrent); `cpus=1` because kmerfinder.py is single-threaded Python.

**Memory right-sizing (Aug 2026)**: `FASTP` (8→3 GB) and `BUSCO_BUSCO` (8→2 GB) were both reduced after checking real usage across the batch2 83-sample run (parsed `Max Memory` from each task's `.command.log`): FASTP peaked at 1.38 GB, BUSCO at 445 MB — both were over-reserved by 5-18x with no offsetting benefit (unlike CPU under-declaration, over-reserving memory only blocks other users from shared node RAM). `KMERFINDER` (8 GB) was checked the same way and left untouched — a single low sample looked like a reduction candidate, but the full 73-sample distribution had a median of 5.8 GB, so 8 GB is already correctly sized. Always pull the full usage distribution across a real batch before resizing a memory declaration, not a single sample — see [[feedback_resource_tuning]] in project memory.

**Error handling**: retries on exit codes 130-145, 104, 126, 175. `maxRetries = 1`. Resources double on retry. Exit 126 added Aug 2026 — transient exec-time filesystem hiccup ("`/usr/bin/env: bad interpreter: No such file or directory`"), same class of intermittent BeeGFS/NFS flakiness as the ENOENT issues below, just at `exec()` instead of `import()` time. Not tool-specific — any Python-shebang process can hit it.

## LSF Submission

### Single-node (`submit_bacass.sh`)
Local executor. 20 cores, 120 GB (6 GB/core), 72h wall time, `hpc` queue.

### Distributed (`submit_bacass_distributed.sh`)
Head process: 1 core / 4 GB / 72h. Per-task via `conf/lsf.config`. Max 80 concurrent jobs (`queueSize`). `pollInterval = '2 min'`.

### hpcspecial queue (project-local, when banned from `hpc`)
Project-specific scripts in `/work3/josne/Projects/Vibrio_Galathea3/vibrio_seq/`:
- `submit_bacass_hpcspecial.sh` — head job on `hpcspecial`
- `lsf_hpcspecial.config` — per-task jobs on `hpcspecial`; `queueSize=10`, `pollInterval=5 min` (single node, testing)

**Do not commit these to the codebase** — they are project-local overrides. `hpcspecial` is a multi-node queue (nodes added May 2026); distributed mode is valid for testing.

**funcscan on hpcspecial**: `submit_funcscan_hpcspecial.sh` adds `--bgc_skip_deepbgc` for test runs. The real failure mode is a stale `/tmp/josne/.deepbgc_db.lock` left on a node after a killed job — every DEEPBGC retry hits line 13 of the patch script and exits 1. If DEEPBGC fails repeatedly after a manual job kill, clear the lock: `bsub -q hpcspecial -n 1 -W 00:05 -R "rusage[mem=512]" "rm -f /tmp/josne/.deepbgc_db.lock"`. The full `submit_funcscan_distributed.sh` does NOT skip DeepBGC.

### Critical: LSF Memory Fix (NF 25.10.4)

NF 25.10.4 does NOT divide `rusage[mem=X]` by CPUs. Three fixes applied:

1. **Shadow lsf.conf** (`setup.sh`): DTU HPC has `LSB_JOB_MEMLIMIT=Y` → NF disables `-M` division. Shadow with `LSB_JOB_MEMLIMIT=N`, export `LSF_ENVDIR` to shadow dir.
2. **`perTaskReserve = true`** (`conf/lsf.config`): divides `rusage` by CPUs → single clean `-R "select[mem>=<total>] rusage[mem=<per-slot>]"`.
3. **`clusterOptions` `-M`** (`conf/lsf.config`): adds explicit per-slot kill limit at 5% above rusage. With `LSB_JOB_MEMLIMIT=N`, `-M` is per-slot → total enforcement = declared × 1.05. Without this, `rusage` is advisory only and jobs exceeding their memory declaration are never killed (retry logic never fires).

**Never set `perJobMemLimit = true`** — generates conflicting `-R` strings without the shadow. Verify: `bjobs -l <jobid>` → single `-R` string, plus `-M` entry at `(declared_MB × 1.05 / cpus)` per slot.

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
- `UNICYCLER`: `scratch = true` + stale SPAdes checkpoint cleanup in `modules/local/unicycler/main.nf` (see Troubleshooting)

**Samplesheet**: `./bacass_to_funcscan.sh <results_dir> <output.csv>` → 4-column CSV (sample, fasta, protein, gbk).

**After re-running bacass** (e.g. following assembly correctness issues), use `bin/compare_assemblies_for_funcscan.sh` to generate a samplesheet that preserves the funcscan `-resume` cache for unchanged assemblies and only re-runs changed ones — avoiding a full funcscan re-run.

## Standalone Aggregation Scripts

Regenerate a pipeline's aggregation results (MultiQC, Kmerfinder summary, hAMRonization/AMPcombi summaries) directly from a published `OUTDIR`, entirely outside Nextflow. Needed when a batch's raw reads and/or Nextflow work dir have been deleted — at that point `-resume` can never touch that batch again (Nextflow validates every input path with `checkIfExists: true` before it even reaches cache logic), so this is the only way to produce a report spanning it. Read-only against sources; nothing in a batch's OUTDIR is modified except the aggregation script's own output.

**Single batch:**
```bash
./run_bacass_aggregation.sh <OUTDIR> [assembly_type]      # QUAST + Kmerfinder summary + MultiQC
./run_funcscan_aggregation.sh <OUTDIR>                      # hamronize summarize + ampcombi complete + MultiQC
```

**Multiple batches combined** — merge into a union directory first, then aggregate that:
```bash
./merge_bacass_batches.sh <TARGET_DIR> <BATCH_DIR_1> <BATCH_DIR_2> [...]
./run_bacass_aggregation.sh <TARGET_DIR>
# same pattern with merge_funcscan_batches.sh / run_funcscan_aggregation.sh
```
The merge scripts symlink files (not whole directories — `find -mindepth N -maxdepth N`, which the aggregation scripts rely on, doesn't descend into symlinked directories) into a fresh `TARGET_DIR`, and refuse to run if the same sample ID appears in more than one source batch or if `TARGET_DIR` already exists. Merging while a batch is still mid-run produces a valid-but-partial snapshot (samples get `NA` in columns for stages they haven't reached yet) — re-merge once all batches are actually finished for a complete report.

**Submitting via `bsub`**: the `#BSUB` header in each script is only auto-parsed by `bsub < script.sh`, which can't pass a positional argument. To pass `OUTDIR`, specify resources explicitly and invoke the script directly instead:
```bash
bsub -q hpc -n 8 -R "span[hosts=1] rusage[mem=6GB]" -M 6500MB -W 02:00 \
  -o bacass_aggregation_%J.out -e bacass_aggregation_%J.err \
  ./run_bacass_aggregation.sh <OUTDIR>
```
Merges themselves are cheap (symlinking, seconds) — run them directly in your shell, no `bsub` needed.

**Known caveat**: `run_funcscan_aggregation.sh` intentionally never regenerates `reports/combgc/combgc_complete_summary.tsv` — see its Step 3 comment. Investigated Aug 2026: per-sample `combgc_summary.tsv` files were found to contain only antiSMASH rows while the existing aggregate also has DeepBGC/GECCO rows for the same samples (confirmed systemic, confirmed DeepBGC/GECCO data existed before COMBGC ran). Exact root cause undetermined — funcscan's own work dir and the contemporaneous `.nextflow.log` are both gone — but a **likely mechanism** surfaced Aug 2026 via direct feedback from an antiSMASH core developer (unconfirmed against this specific run): nf-core/funcscan's `COMBGC` module doesn't read antiSMASH's native JSON results file. Instead it parses antiSMASH's GenBank output (lossy — GenBank format can't represent everything antiSMASH computes) plus a separately-parsed clusterblast text output, then merges that against DeepBGC's and GECCO's own independently-parsed output formats — rather than using the antiSMASH "sideload" format DeepBGC/GECCO both provide, which is designed to feed their results *into* antiSMASH so it emits one single self-consistent JSON. A three-source, format-mismatched, home-grown merge like this is a plausible way to silently drop rows depending on parse order or matching quirks, matching what we observed — but this has not been verified against funcscan's actual `COMBGC` source or the specific run in question. Leave the existing aggregate untouched rather than risk overwriting good data with an incomplete regeneration.

**BGC sideload merge fix** (`./run_bgc_sideload_merge.sh <bacass-outdir> <funcscan-outdir> [cpus]`, submit via `bsub` like the others; then `python bin/antismash_merged_summary.py --funcscan-outdir <dir> -o <output.tsv>`): fixes the above caveat for an already-published funcscan `OUTDIR`, using the method the antiSMASH developer described — antiSMASH's own `--reuse-results` (reuses its already-computed native JSON, skipping re-detection) + `--sideload` (merges in DeepBGC's and GECCO's antiSMASH-sideload JSON) — instead of COMBGC's GenBank/clusterblast parse. Two-step per sample: (1) rerun GECCO with `--antismash-sideload` (funcscan never passes this flag, so no GECCO sideload JSON exists in any prior run — DeepBGC's sideload JSON already exists in every prior run and needs no rerun); (2) `antismash --reuse-results <original>.json --sideload <deepbgc>.json,<gecco>.json` into a new `bgc/antismash_merged/<sample>/` tree (original `bgc/antismash/` untouched). Smoke-tested Aug 2026 on S0204: both steps ~37s each (cheap — not a full antiSMASH run), BGC region count went 8 → 18 with clean per-region tool provenance recoverable from the merged JSON's `modules['antismash.detection.sideloader']['subregions']` (each tagged `tool.name`). `bin/antismash_merged_summary.py` parses this directly into a corrected summary table — no GenBank/clusterblast parsing at all.

The same fix is also applied to the **live pipeline** for future runs: `conf/funcscan_overrides.config` adds `--antismash-sideload` to `GECCO_RUN`'s args; `conf/funcscan_patches/antismash_antismash_main.nf` forks the antiSMASH module to accept a per-sample `sideload_files` input (folded into the same meta-keyed tuple as the sequence input — a bare second `path` channel would pair by emission order, not by sample, risking silent mispairing); `conf/funcscan_patches/bgc.nf` forks the BGC subworkflow to run `GECCO_RUN`/`DEEPBGC_PIPELINE` before `ANTISMASH_ANTISMASH` and join their `.out.json` channels (both `optional: true`; missing sides null-fill via `remainder: true`) into that new input. Deployed by `submit_funcscan_distributed.sh` the same way as `deepbgc_pipeline_main.nf`. COMBGC still runs afterward unchanged, as a fallback/compat path — not removed. DAG-validated Aug 2026 via `nextflow run nf-core/funcscan -stub-run` (exercises channel wiring/tuple arity without real BGC detection): `GECCO_RUN`, `DEEPBGC_PIPELINE`, `ANTISMASH_ANTISMASH` all completed cleanly in the new order for 2 real samples — not yet validated with a full non-stub run.

**geNomad plasmid/virus scan** (`./run_genomad_scan.sh <OUTDIR> [threads]`, submit via `bsub` like the others): runs geNomad end-to-end on every `Unicycler/*.scaffolds.fa.gz` in a bacass OUTDIR, publishing per-sample results to `OUTDIR/genomad/<sample>/` plus a cross-sample `genomad_summary.tsv` (n_plasmids, n_viruses, largest_plasmid_bp, has_conjugation_genes, amr_gene_families). geNomad (env + database) lives outside this repo, at `/work3/josne/miniconda3/envs/genomad` and `/work3/josne/Databases/genomad_db`. Unlike Unicycler's own "closed/circular" flag (a narrow graph-topology heuristic — only 17/38 completed batch2 samples had one), geNomad scores every contig by composition + marker genes regardless of topology, catching plasmid-derived contigs that never closed. ~3.5 min/sample at 8 threads for a ~6 Mb genome.

**DefenseFinder anti-phage defense-system scan + BGC proximity** (`./run_defensefinder_scan.sh <OUTDIR> [workers]`, submit via `bsub` like the others): runs DefenseFinder (protein mode, against Bakta's already-called `.faa`) on every `Bakta/<sample>/<sample>.faa` in a bacass OUTDIR, publishing per-sample results to `OUTDIR/defensefinder/<sample>/` plus a cross-sample `defensefinder_summary.tsv`. DefenseFinder (env + models) lives outside this repo, at `/work3/josne/miniconda3/envs/defensefinder` and `/work3/josne/Databases/defensefinder_models`; `hmmsearch` must be on `PATH` (the script prepends the env's `bin/`, since defense-finder invokes it as a bare command). ~48s/sample at 4 workers (protein-mode, no re-assembly). Motivated by Shomar et al. 2026 (*Cell Host & Microbe*, "A family of lanthipeptides with anti-phage function"), which found lanthipeptide BGCs enriched near defense systems in Actinobacteria — `bin/bgc_defense_proximity.py` joins this output against antiSMASH BGC calls (`<funcscan-outdir>/bgc/antismash/`) to compute the nearest defense system per BGC, in both gene-index distance (default window: ±23 genes, matching the paper) and bp distance. Gene-index numbering is derived from Bakta's `.tsv` (`type=="cds"` rows, file order) rather than DefenseFinder's own `hit_pos` column, but the two have been verified to match exactly — this lets the same indexing scheme be applied to BGC boundaries, which DefenseFinder never sees.

## Repository Layout

```
main.nf / workflows/bacass.nf   # Entry point / main workflow
nextflow.config                 # Profiles, params defaults
setup.sh                        # Conda + Nextflow env setup
submit_bacass.sh                # Single-node LSF submit
submit_bacass_distributed.sh    # Distributed LSF submit
bacass_to_funcscan.sh           # Generate funcscan samplesheet
submit_funcscan_distributed.sh  # Funcscan LSF submit
run_bacass_aggregation.sh       # Standalone QUAST+Kmerfinder+MultiQC re-run from an OUTDIR
run_funcscan_aggregation.sh     # Standalone hamronize/ampcombi/MultiQC re-run from an OUTDIR
merge_bacass_batches.sh         # Merge multiple bacass OUTDIRs for a combined aggregation
merge_funcscan_batches.sh       # Merge multiple funcscan OUTDIRs for a combined aggregation
run_genomad_scan.sh             # geNomad plasmid/virus scan across a bacass OUTDIR's assemblies
run_defensefinder_scan.sh       # DefenseFinder anti-phage defense-system scan across a bacass OUTDIR's Bakta proteomes
run_bgc_sideload_merge.sh       # Fixes fragile COMBGC merge: antiSMASH --reuse-results + --sideload against a published funcscan OUTDIR
conf/
  base.config                   # Resource labels
  lsf.config                    # LSF executor (perTaskReserve, pollInterval)
  modules.config                # ext.args, publishDir, scratch, resource overrides
  bakta_environment.yml         # pyhmmer<0.12 pin for Bakta
  gecco_environment.yml         # pyhmmer<0.12 pin for GECCO
  deepbgc_environment.yml       # pyhmmer<0.12 pin for DeepBGC
  funcscan_overrides.config     # GECCO/DeepBGC conda overrides + resource fixes
  funcscan_patches/             # Local patches to pulled funcscan pipeline code, deployed at submit time (survive `nextflow pull`)
modules/nf-core/                # DO NOT edit — use nf-core modules update/install
modules/local/                  # 7 custom modules
bin/                            # Python helpers + compare_assemblies_for_funcscan.sh
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

## Nextflow Reporting

`timeline`, `report`, and `trace` are all **disabled** in `nextflow.config` (Mar 2026, HPC admin request). When enabled, Nextflow injects `nxf_mem_watch()`/`nxf_trace_linux()` etc. into every `.command.run` script — each job runs a background polling loop writing `.command.trace` to BeeGFS every second. With 80 concurrent jobs this creates significant BeeGFS write overhead. LSF `bstat` and job-finished emails provide sufficient resource info.

`dag` remains enabled (static graph, no per-task overhead). Same setting applied in `conf/funcscan_overrides.config`.

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

# After re-running bacass, avoid a full funcscan re-run by only submitting changed assemblies
bin/compare_assemblies_for_funcscan.sh old_bacass_dir new_bacass_dir old_funcscan_sheet.csv updated_sheet.csv
# Then update INPUT in submit_funcscan_distributed.sh and run with -resume
```

## Troubleshooting

- **Jobs PEND "Resource (mem) limit"**: LSF memory fix not active — check shadow lsf.conf and `perTaskReserve = true` in `conf/lsf.config`. Verify: `bjobs -l <id>` shows single `-R` with divided rusage.
- **"conda: command not found" / "Run conda init first"**: ensure `#!/bin/bash` and `conda.sh` sourced in `setup.sh`
- **`/bin/activate: No such file or directory`**: `conda info --json` returning empty (NFS failure). Fix: `/work3/josne/miniconda3/bin/conda` is already patched to short-circuit `conda info --json`. See MEMORY.md.
- **Spurious ENOENT on BeeGFS files**: previously mitigated via `bin/libnfs_retry.so` (LD_PRELOAD); removed entirely (May 2026) — the extra `stat()` per ENOENT was hammering BeeGFS metadata. Two durable replacements now live in tracked files:
  - **`conda info --json` short-circuit**: bash function defined in `setup.sh` (search for "Short-circuit"). Returns hardcoded JSON instead of letting Nextflow invoke conda's Python CLI. Survives `conda update` because it's not in conda's install tree. Other `conda` invocations fall through to the real binary via `command conda`.
  - **UNCHECKED_HASH bytecode**: `bin/recompile_pyc.sh` recompiles all conda env site-packages so Python's `.pyc` validation skips the source-file `stat()`. `setup.sh` has a self-heal hook that triggers a recompile whenever a conda env lacks the `.unchecked_hash_applied` marker (run-once per env, ~5 min on first invocation, negligible thereafter). `--force` re-runs everything. Skips Python 2 envs and non-Python tool envs.
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
- **Unicycler silently reusing wrong SPAdes assembly**: When `scratch = true` and a job is aborted mid-assembly (e.g. LSF walltime kill), the partial `spades_assembly/K27/` etc. checkpoint dirs remain in `/tmp/`. If a subsequent job coincidentally lands on the same node with the same random scratch path, Unicycler finds existing checkpoints and reuses them — producing a chimeric assembly with another sample's graph topology but correct read depths. Fixed by `rm -rf spades_assembly/ 2>/dev/null || true` as the **first line of the script block** in `modules/local/unicycler/main.nf`. Note: `beforeScript` cannot fix this — it fires before Nextflow's `cd $NXF_SCRATCH`, so it would target the NFS work dir instead of the scratch dir. The local module is used instead of the nf-core one (include redirected in `workflows/bacass.nf`). If re-running bacass after this bug was triggered, use `bin/compare_assemblies_for_funcscan.sh` to avoid a full funcscan re-run.
- **HPC admin kills job / 1.8M context-switches/s**: Java tools (FastQC) declare few CPUs but spawn many JVM threads. LSF packs jobs by declared CPUs → many JVMs/node → CS explosion. Fix: raise declared CPUs to match actual thread footprint + `maxForks` cap. See resource table above. With LSF executor, `maxForks` must be set explicitly — it does NOT auto-limit based on node CPUs (that only applies to local executor).
- **Head job killed by admin, pipeline incomplete**: check `bhist -l <jobid>` for `TERM_ADMIN`. Resubmit with `-resume` — completed tasks (FASTP etc.) are cached, pipeline continues from where it was killed.
- **Lock file error after killed job**: `rm .nextflow/cache/*/db/LOCK && nextflow run ... -resume`
- **Fairshare depleted**: kill all jobs, wait for priority recovery, resubmit with `-resume`
- **Bakta `ERROR: Circos could not be executed!`**: patch circos shebang to absolute perl path in pre-built env. See MEMORY.md.
- **`KMERFINDER_SUMMARY` `No module named 'yaml'`**: missing `conda` directive in `main.nf` — already fixed.
- **NCBI `BadZipFile`**: `bin/download_reference.py` strips assembly-name suffixes from kmerfinder accessions — already fixed.
