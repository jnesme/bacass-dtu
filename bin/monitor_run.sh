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

    # Job summary
    echo "--- Jobs ---"
    bjobs -noheader -u josne -q "${QUEUE}" 2>/dev/null \
        | awk '{stat[$4]++} END {for (s in stat) printf "  %-8s %d\n", s, stat[s]}' \
        | sort
    echo ""

    # PEND reasons (if any jobs are pending)
    PEND_JOBS=$(bjobs -noheader -u josne -q "${QUEUE}" 2>/dev/null | awk '$4=="PEND"{print $1}' | head -5)
    if [ -n "${PEND_JOBS}" ]; then
        echo "--- PEND reasons (first 5) ---"
        for JID in ${PEND_JOBS}; do
            REASON=$(bjobs -p "${JID}" 2>/dev/null | tail -1 | xargs)
            echo "  ${JID}: ${REASON}"
        done
        echo ""
    fi

    # Spot-check one running job's resource string
    RUN_JOB=$(bjobs -noheader -u josne -q "${QUEUE}" 2>/dev/null | awk '$4=="RUN"{print $1; exit}')
    if [ -n "${RUN_JOB}" ]; then
        echo "--- Resource check (job ${RUN_JOB}) ---"
        bjobs -l "${RUN_JOB}" 2>/dev/null \
            | grep -E "RESOURCE|rusage|order|LD_PRELOAD|nxf_trace|EXEC_HOST" \
            | sed 's/^/  /'
        echo ""
    fi

    # Node load
    echo "--- Node load (${QUEUE} node) ---"
    EXEC_HOST=$(bjobs -noheader -u josne -q "${QUEUE}" 2>/dev/null | awk '$4=="RUN"{print $6; exit}')
    if [ -n "${EXEC_HOST}" ] && [ "${EXEC_HOST}" != "-" ]; then
        ssh -o ConnectTimeout=3 -o BatchMode=yes "${EXEC_HOST}" \
            "uptime; echo 'procs:' \$(nproc)" 2>/dev/null | sed 's/^/  /'
    else
        echo "  (no running jobs yet)"
    fi

    echo ""
    echo "Refreshing every ${INTERVAL}s — Ctrl+C to stop"
    sleep "${INTERVAL}"
done
