#!/bin/bash
# Recompile Python .pyc files in conda envs with UNCHECKED_HASH invalidation mode.
#
# Why: Python's default bytecode validation does a stat() on every .py source at
# import time to compare timestamps. Under BeeGFS metadata pressure those stats
# can fail (spurious ENOENT) or stall — both have caused real incidents on this
# pipeline. UNCHECKED_HASH stores a content hash in the .pyc header (computed at
# compile time) and tells Python to load the .pyc directly without checking the
# source. Net effect: imports go from "open + stat + maybe-read" to just "open".
#
# Idempotent: per-env marker file (.unchecked_hash_applied) skips already-done
# envs. Re-run after any conda env rebuild — a new env hash directory will not
# have the marker. Pass --force to ignore markers and recompile everything.
#
# Skips:
#   - envs without a python3.X interpreter (non-Python tools: FastQC, abricate, etc.)
#   - python2.7 envs (PycInvalidationMode is Python 3.7+ only; the one py2 env we
#     care about — DeepARG — has its own sitecustomize.py + Theano cache fix)
#
# Run cost: ~5 min total across all envs on first invocation; ~0.1s per env when
# all markers are in place (just a `test -f` per env).

set -euo pipefail

FORCE=${1:-}
BACASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

recompile_one() {
    local env_dir="$1" label="$2"
    local marker="${env_dir}/.unchecked_hash_applied"

    if [ -f "${marker}" ] && [ "${FORCE}" != "--force" ]; then
        echo "  [skip] ${label}: marker exists"
        return
    fi

    local py
    # `|| true` prevents `set -o pipefail` from killing the script when grep
    # finds no python3.X binary (envs that hold non-Python tools).
    py=$(ls "${env_dir}/bin/" 2>/dev/null | grep -E '^python3\.[0-9]+$' | sort -V | tail -1 || true)
    if [ -z "${py}" ]; then
        echo "  [skip] ${label}: no python3.X interpreter"
        return
    fi

    # Skip Python < 3.7: PycInvalidationMode was added in 3.7. The handful of
    # 3.6 envs in this repo are old funcscan tool envs; they remain in
    # TIMESTAMP mode. We still create the marker — semantically it means "we
    # considered this env and intentionally took no action" — so the self-heal
    # in setup.sh doesn't re-trigger every source. Re-run with --force after a
    # Python upgrade to revisit.
    local minor
    minor=${py#python3.}
    if [ "${minor}" -lt 7 ]; then
        echo "  [skip] ${label}: ${py} predates PycInvalidationMode (need 3.7+)"
        touch "${marker}"
        return
    fi

    local sp="${env_dir}/lib/${py}/site-packages"
    if [ ! -d "${sp}" ]; then
        sp=$(echo "${env_dir}"/lib/python*/site-packages 2>/dev/null | awk '{print $1}')
    fi
    if [ ! -d "${sp}" ]; then
        echo "  [skip] ${label}: no site-packages directory"
        return
    fi

    echo "  [run]  ${label} (${py}): ${sp}"
    # Only touch the marker if Python exits cleanly. compileall reports per-file
    # errors via stderr but does not exit non-zero for those — Python exits
    # non-zero only on fatal errors (missing module, etc.). So marker presence
    # = "we tried successfully", individual SyntaxErrors in some package files
    # are tolerated (those files stay in TIMESTAMP mode but the rest are HASH).
    if "${env_dir}/bin/${py}" -c "
import compileall, py_compile
compileall.compile_dir(
    '${sp}',
    invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH,
    force=True,
    quiet=1, workers=0)
"; then
        touch "${marker}"
    else
        echo "  [warn] ${label}: Python invocation failed; marker NOT created (will retry)"
    fi
}

echo "=== Recompiling .pyc files with UNCHECKED_HASH ==="
echo "    Force mode: ${FORCE:-(off — pass --force to ignore markers)}"
echo

# 1. Miniconda root — where conda CLI itself lives
recompile_one /work3/josne/miniconda3 "miniconda3 root"

# 2. Every pre-built tool env in .conda_envs/
for env_dir in "${BACASS_DIR}"/.conda_envs/env-*; do
    [ -d "${env_dir}" ] || continue
    recompile_one "${env_dir}" "$(basename "${env_dir}")"
done

echo
echo "=== Done ==="
echo "Verify a sample .pyc with:"
echo "  python3 -c \"import struct; f=open('<path>/__pycache__/__init__.cpython-3??.pyc','rb'); f.read(4); print(hex(struct.unpack('<I',f.read(4))[0]))\""
echo "Expected: 0x00000003 (UNCHECKED_HASH bit set)"
