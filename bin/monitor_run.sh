#!/bin/bash
# Monitor a running bacass/funcscan LSF job.
# Usage: monitor_run.sh [queue] [interval_seconds]
# Defaults: queue=hpcspecial, interval=30

QUEUE=${1:-hpcspecial}
INTERVAL=${2:-30}

job_detail() {
    local jid=$1
    local detail
    detail=$(bjobs -l "$jid" 2>/dev/null)

    local name cpus mem_cur mem_max mem_lim cpu_eff threads rusage
    name=$(echo "$detail"    | grep -oP '(?<=Job Name <)[^>]+' | sed 's/nf-NFCORE_BACASS_BACASS_//')
    cpus=$(echo "$detail"    | grep -oP '(?<=Started )\d+(?= Task)')
    mem_cur=$(echo "$detail" | grep -oP 'MEM: \K[0-9.]+ \w+' | head -1)
    mem_max=$(echo "$detail" | grep -oP 'MAX MEM: \K[0-9.]+ \w+')
    mem_lim=$(echo "$detail" | grep -A1 'MEMLIMIT' | tail -1 | xargs)
    cpu_eff=$(echo "$detail" | grep -oP 'CPU AVERAGE EFFICIENCY: \K[0-9.]+%')
    threads=$(echo "$detail" | grep -oP 'NTHREAD: \K\d+')
    rusage=$(echo "$detail"  | grep -oP 'rusage\[mem=\K\d+' | head -1)

    # Convert rusage MB → GB for display
    local mem_req=""
    if [ -n "$rusage" ] && [ -n "$cpus" ]; then
        mem_req=$(awk "BEGIN{printf \"%.0fMB×%s\", ${rusage}, \"${cpus}\"}")
    fi

    printf "  %-45s  CPUs:%-3s  MEM cur/max/lim: %-12s %-12s %-8s  CPU eff: %-8s  threads: %s\n" \
        "${name:-?}" "${cpus:-?}" "${mem_cur:-n/a}" "${mem_max:-n/a}" "${mem_lim:-?}" \
        "${cpu_eff:-n/a}" "${threads:-n/a}"
}

while true; do
    clear
    echo "=== $(date) — queue: ${QUEUE} ==="
    echo ""

    # Snapshot all jobs once
    ALL_JOBS=$(bjobs -noheader -u josne -q "${QUEUE}" 2>/dev/null)

    # Summary counts
    echo "--- Summary ---"
    echo "$ALL_JOBS" \
        | awk '{stat[$6]++} END {for (s in stat) printf "  %-8s %d\n", s, stat[s]}' \
        | sort
    echo ""

    # Per-job detail for all running task jobs
    RUN_JOBS=$(echo "$ALL_JOBS" | awk '$6=="RUN" && $4!~/cass_head/{print $1}')
    if [ -n "$RUN_JOBS" ]; then
        echo "--- Running task jobs ---"
        printf "  %-45s  %-9s  %-35s  %-16s  %s\n" \
            "PROCESS" "CPUs" "MEM cur / max / limit" "CPU efficiency" "threads"
        printf "  %s\n" "$(printf '%.0s-' {1..120})"
        for JID in $RUN_JOBS; do
            job_detail "$JID"
        done
        echo ""
    fi

    # PEND reasons
    PEND_JOBS=$(echo "$ALL_JOBS" | awk '$6=="PEND"{print $1}' | head -5)
    if [ -n "${PEND_JOBS}" ]; then
        echo "--- PEND reasons (first 5) ---"
        for JID in ${PEND_JOBS}; do
            REASON=$(bjobs -p "${JID}" 2>/dev/null | tail -1 | xargs)
            echo "  ${JID}: ${REASON}"
        done
        echo ""
    fi

    # Node load
    echo "--- Node load (n-62-21-19) ---"
    lsload n-62-21-19 2>/dev/null | sed 's/^/  /'

    echo ""
    echo "Refreshing every ${INTERVAL}s — Ctrl+C to stop"
    sleep "${INTERVAL}"
done
