#!/bin/bash
# Usage: probe_queue.sh [queue1 queue2 ...]
# Submits a minimal job to each queue, reads the PEND reason, then kills it.
# Default queues: hpc milan hpcspecial

if [ $# -eq 0 ]; then
    QUEUES=(hpc milan hpcspecial)
else
    QUEUES=("$@")
fi

for QUEUE in "${QUEUES[@]}"; do
    JOBID=$(bsub \
        -q "$QUEUE" \
        -J "probe_${QUEUE}" \
        -n 1 \
        -R "rusage[mem=1GB]" \
        -W 00:01 \
        -o /dev/null \
        -e /dev/null \
        sleep 60 2>&1 | grep -oP "(?<=Job <)\d+")

    if [ -z "$JOBID" ]; then
        echo "$QUEUE: SUBMIT FAILED (no job ID — likely no access)"
        continue
    fi

    # Poll until LSF has assigned a real PEND reason (not just "waiting for scheduling")
    for i in $(seq 1 15); do
        sleep 2
        REASON=$(bjobs -p "$JOBID" 2>/dev/null)
        echo "$REASON" | grep -q "New job is waiting for scheduling" || break
    done
    bkill "$JOBID" > /dev/null 2>&1

    echo "$QUEUE (job $JOBID): $REASON"
done
