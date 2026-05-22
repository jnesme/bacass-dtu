#!/bin/bash
# Monitor a running bacass/funcscan LSF job.
# Usage: monitor_run.sh [queue] [interval_seconds]
# Defaults: queue=hpcspecial, interval=30

QUEUE=${1:-hpcspecial}
INTERVAL=${2:-30}

while true; do
    clear
    echo "=== $(date) — queue: ${QUEUE} ==="
    echo ""

    # Job summary — STAT is $6 in this LSF's bjobs -noheader format
    echo "--- Jobs ---"
    bjobs -noheader -u josne -q "${QUEUE}" 2>/dev/null \
        | awk '{stat[$6]++} END {for (s in stat) printf "  %-8s %d\n", s, stat[s]}' \
        | sort
    echo ""

    # PEND reasons (if any jobs are pending)
    PEND_JOBS=$(bjobs -noheader -u josne -q "${QUEUE}" 2>/dev/null | awk '$6=="PEND"{print $1}' | head -5)
    if [ -n "${PEND_JOBS}" ]; then
        echo "--- PEND reasons (first 5) ---"
        for JID in ${PEND_JOBS}; do
            REASON=$(bjobs -p "${JID}" 2>/dev/null | tail -1 | xargs)
            echo "  ${JID}: ${REASON}"
        done
        echo ""
    fi

    # Spot-check one running task job's resource string (skip head job)
    RUN_JOB=$(bjobs -noheader -u josne -q "${QUEUE}" 2>/dev/null \
        | awk '$6=="RUN" && $4!~/cass_head/{print $1; exit}')
    if [ -n "${RUN_JOB}" ]; then
        echo "--- Resource check (task job ${RUN_JOB}) ---"
        bjobs -l "${RUN_JOB}" 2>/dev/null \
            | grep -E "rusage|LD_PRELOAD|nxf_trace|Started.*Host" \
            | sed 's/^/  /'
        echo ""
    fi

    # Node load via lsload (no ssh needed)
    echo "--- Node load ---"
    lsload n-62-21-19 2>/dev/null | sed 's/^/  /'

    echo ""
    echo "Refreshing every ${INTERVAL}s — Ctrl+C to stop"
    sleep "${INTERVAL}"
done
