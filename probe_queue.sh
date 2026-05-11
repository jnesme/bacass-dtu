#!/bin/bash
# Usage: probe_queue.sh [queue1 queue2 ...]
# Submits a minimal 1-CPU test job to each queue and tails the output.
# Default queues: hpc milan hpcspecial
# Output files: probe_<queue>_<jobid>.{out,err}

QUEUES=("${@:-hpc milan hpcspecial}")
if [ $# -eq 0 ]; then
    QUEUES=(hpc milan hpcspecial)
fi

JOBIDS=()

for QUEUE in "${QUEUES[@]}"; do
    JOBID=$(bsub \
        -q "$QUEUE" \
        -J "probe_${QUEUE}" \
        -n 1 \
        -R "rusage[mem=1GB]" \
        -W 00:05 \
        -o "probe_${QUEUE}_%J.out" \
        -e "probe_${QUEUE}_%J.err" \
        bash -c '
echo "===== QUEUE / HOST ====="
echo "Queue:   $LSB_QUEUE"
echo "Host:    $(hostname)"
echo "Kernel:  $(uname -r)"

echo ""
echo "===== CPUs ====="
nproc --all
lscpu | grep -E "^CPU\(s\)|^Thread|^Core|^Socket|^Model name|^NUMA"

echo ""
echo "===== MEMORY ====="
free -h | head -2

echo ""
echo "===== /tmp ====="
df -h /tmp | tail -1

echo ""
echo "===== /localssd ====="
df -h /localssd 2>/dev/null || echo "(not present)"

echo ""
echo "===== SCRATCH ====="
df -h "$TMPDIR" 2>/dev/null || echo "TMPDIR not set"
' 2>&1 | grep -oP "(?<=Job <)\d+")
    if [ -n "$JOBID" ]; then
        echo "Submitted to $QUEUE: job $JOBID (probe_${QUEUE}_${JOBID}.out)"
        JOBIDS+=("$JOBID")
    else
        echo "FAILED to submit to $QUEUE (permission denied or queue unavailable)"
    fi
done

if [ ${#JOBIDS[@]} -eq 0 ]; then
    echo "No jobs submitted."
    exit 1
fi

echo ""
echo "Waiting for jobs to finish..."
for JOBID in "${JOBIDS[@]}"; do
    while bjobs "$JOBID" 2>/dev/null | grep -qE "PEND|RUN"; do
        sleep 5
    done
done

echo ""
echo "===== RESULTS ====="
for QUEUE in "${QUEUES[@]}"; do
    OUT=$(ls probe_${QUEUE}_*.out 2>/dev/null | tail -1)
    if [ -n "$OUT" ]; then
        echo ""
        echo "--- $QUEUE ($OUT) ---"
        cat "$OUT"
    fi
done
