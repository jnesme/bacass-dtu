#!/bin/bash
# =============================================================================
# poll_nodes.sh — Node-level health monitor for running LSF jobs
# =============================================================================
# Monitors hardware impact of your running jobs at the node level, not job level.
# Two tiers of metrics depending on access:
#
#   Tier 1  (login node, always works)
#     lsload: load average, CPU%, free memory, I/O rate per node
#
#   Tier 2  (SSH, works when running from a compute node)
#     vmstat: context-switches/s, runnable threads, kernel CPU%, I/O wait
#     /proc:  total OS thread count → threads/core ratio
#     /sys:   InfiniBand TX+RX rate (MB/s, 2s sample)
#
# Usage:
#   ./bin/poll_nodes.sh                  # poll all nodes running your jobs
#   ./bin/poll_nodes.sh -u josne         # explicit user
#   ./bin/poll_nodes.sh -n n-62-27-18    # specific node only
#   watch -n 30 ./bin/poll_nodes.sh      # live dashboard (30s refresh)
#
# Run as a job for Tier 2 access (SSH between compute nodes):
#   bsub -q hpcspecial -n 1 -W 00:30 ./bin/poll_nodes.sh
# =============================================================================

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

USER_FILTER="${USER:-josne}"
NODE_FILTER=""
SSH_TIMEOUT=5          # seconds before SSH attempt gives up
VMSTAT_SAMPLES=3       # vmstat 1 N — first sample is since-boot, rest are real

# Tier 1 thresholds (lsload)
WARN_LOAD=20           # r1m > 20  → likely overloaded (1× a 20-core node)
CRIT_LOAD=40           # r1m > 40  → severely overloaded
WARN_CPU=80            # CPU utilisation % (ut field)
CRIT_CPU=95
WARN_FREE_MEM_GB=10    # free memory on node in GB
CRIT_FREE_MEM_GB=4
WARN_IO=500            # LSF io index (arbitrary units)
CRIT_IO=2000

# Tier 2 thresholds (SSH — vmstat, /proc, /sys/class/infiniband)
WARN_CS=300000         # context-switches/s
CRIT_CS=600000
WARN_SY=10             # kernel CPU % (sys time — CS overhead indicator)
CRIT_SY=20
WARN_THREAD_RATIO=4    # total_threads / physical_cores
CRIT_THREAD_RATIO=8
WARN_IB_MBS=1000       # infiniband combined TX+RX MB/s
CRIT_IB_MBS=2000

# ── ANSI colours ──────────────────────────────────────────────────────────────

if [ -t 1 ]; then
    RED='\033[0;31m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

flag() {
    # flag <value> <warn> <crit> <label>
    local val=$1 warn=$2 crit=$3 label=$4
    if awk "BEGIN{exit !($val >= $crit)}"; then
        echo -e "${RED}CRIT:${label}${RESET}"
    elif awk "BEGIN{exit !($val >= $warn)}"; then
        echo -e "${YELLOW}WARN:${label}${RESET}"
    fi
}

parse_mem_gb() {
    # Convert "123.7G" / "512M" / "2T" to integer GB
    local raw=$1
    echo "$raw" | awk '{
        val = $1
        if (val ~ /T$/) { sub(/T$/,"",val); print int(val * 1024) }
        else if (val ~ /G$/) { sub(/G$/,"",val); print int(val) }
        else if (val ~ /M$/) { sub(/M$/,"",val); print int(val / 1024) }
        else print int(val)
    }'
}

# ── Argument parsing ──────────────────────────────────────────────────────────

while getopts "u:n:h" opt; do
    case $opt in
        u) USER_FILTER="$OPTARG" ;;
        n) NODE_FILTER="$OPTARG" ;;
        h) grep '^#' "$0" | head -30 | sed 's/^# \?//'; exit 0 ;;
        *) echo "Usage: $0 [-u user] [-n node]" >&2; exit 1 ;;
    esac
done

# ── Collect running nodes from bjobs ─────────────────────────────────────────

echo -e "${BOLD}$(date '+%Y-%m-%d %H:%M:%S') — Node health monitor (user: ${USER_FILTER})${RESET}"
echo

if [ -n "$NODE_FILTER" ]; then
    NODES="$NODE_FILTER"
else
    # exec_host format: "8*n-62-27-18" or "n-62-27-18" or "n-62-27-18:n-62-27-19"
    NODES=$(bjobs -noheader -u "$USER_FILTER" -r \
                  -o "exec_host" 2>/dev/null \
            | tr ':' '\n' \
            | sed 's/^[0-9]*\*//' \
            | sort -u)
    if [ -z "$NODES" ]; then
        echo "No running jobs found for user ${USER_FILTER}."
        exit 0
    fi
fi

NODE_COUNT=$(echo "$NODES" | wc -l)
echo -e "Active nodes: ${BOLD}${NODE_COUNT}${RESET}"
echo

# ── Header ────────────────────────────────────────────────────────────────────

printf "${BOLD}%-18s  %-6s  %-5s  %-5s  %-8s  %-8s  %-7s  %-7s  %-8s  %-10s  %s${RESET}\n" \
    "NODE" "STATUS" "r1m" "CPU%" "FreeMem" "IO" \
    "CS/s" "THR/core" "IB MB/s" "TIER" "FLAGS"
printf '%0.s─' {1..110}; echo

# ── Per-node polling ──────────────────────────────────────────────────────────

ALL_FLAGS=""

for node in $NODES; do

    FLAGS=""

    # ── Tier 1: lsload ────────────────────────────────────────────────────────

    LSLOAD=$(lsload -l "$node" 2>/dev/null | grep -v "^HOST" | grep -v "^$" \
             | awk 'NR==1{print}')

    if [ -z "$LSLOAD" ]; then
        printf "%-18s  %-6s  %s\n" "$node" "?" "lsload unavailable"
        continue
    fi

    read -r STATUS R1M UT IO MEM_RAW <<< $(echo "$LSLOAD" | \
        awk '{gsub(/%/,"",$6); print $2, $4, $6, $8, $13}')
    FREE_MEM_GB=$(parse_mem_gb "$MEM_RAW")

    # Tier 1 flags
    FLAGS+=$(flag "$R1M"        "$WARN_LOAD"        "$CRIT_LOAD"        "LOAD")
    FLAGS+=$(flag "$UT"         "$WARN_CPU"         "$CRIT_CPU"         "CPU%")
    FLAGS+=$(flag "$IO"         "$WARN_IO"          "$CRIT_IO"          "IO")
    # free memory: flag if LOW (inverted — warn when value is BELOW threshold)
    if awk "BEGIN{exit !($FREE_MEM_GB < $CRIT_FREE_MEM_GB)}"; then
        FLAGS+="${RED}CRIT:MEM${RESET}"
    elif awk "BEGIN{exit !($FREE_MEM_GB < $WARN_FREE_MEM_GB)}"; then
        FLAGS+="${YELLOW}WARN:MEM${RESET}"
    fi

    # ── Tier 2: SSH ───────────────────────────────────────────────────────────

    CS="–"; THREAD_RATIO="–"; IB_MBS="–"; TIER="1 (lsload)"

    SSH_RESULT=$(ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=${SSH_TIMEOUT} \
        -o StrictHostKeyChecking=no \
        -o LogLevel=ERROR \
        "$node" bash << 'REMOTE' 2>/dev/null
# vmstat: skip first (since-boot) line, average remaining samples
VMSTAT_OUT=$(vmstat 1 3 | tail -2)
CS=$(echo "$VMSTAT_OUT"  | awk '{cs+=$12; n++} END{printf "%.0f", cs/n}')
R=$(echo "$VMSTAT_OUT"   | awk '{r+=$1;  n++} END{printf "%.1f", r/n}')
SY=$(echo "$VMSTAT_OUT"  | awk '{sy+=$14;n++} END{printf "%.0f", sy/n}')
WA=$(echo "$VMSTAT_OUT"  | awk '{wa+=$16;n++} END{printf "%.0f", wa/n}')

# Physical cores and thread count
CORES=$(nproc)
THREADS=$(ps -eo nlwp --no-headers 2>/dev/null | awk '{s+=$1} END{print s+0}')
THREAD_RATIO=$(awk "BEGIN{printf \"%.1f\", ${THREADS}/${CORES}}")

# InfiniBand rate (2s sample; counters in 4-byte words per Linux kernel docs)
IB_RX1=$(cat /sys/class/infiniband/*/ports/1/counters/port_rcv_data  2>/dev/null \
         | paste -sd+ 2>/dev/null | bc 2>/dev/null || echo 0)
IB_TX1=$(cat /sys/class/infiniband/*/ports/1/counters/port_xmit_data 2>/dev/null \
         | paste -sd+ 2>/dev/null | bc 2>/dev/null || echo 0)
sleep 2
IB_RX2=$(cat /sys/class/infiniband/*/ports/1/counters/port_rcv_data  2>/dev/null \
         | paste -sd+ 2>/dev/null | bc 2>/dev/null || echo 0)
IB_TX2=$(cat /sys/class/infiniband/*/ports/1/counters/port_xmit_data 2>/dev/null \
         | paste -sd+ 2>/dev/null | bc 2>/dev/null || echo 0)
IB_MBS=$(awk "BEGIN{printf \"%.0f\", \
    (($IB_RX2 - $IB_RX1) + ($IB_TX2 - $IB_TX1)) * 4 / 2 / 1048576}")

echo "CS=$CS R=$R SY=$SY WA=$WA CORES=$CORES THREADS=$THREADS THREAD_RATIO=$THREAD_RATIO IB_MBS=$IB_MBS"
REMOTE
    )

    if [ -n "$SSH_RESULT" ]; then
        eval "$SSH_RESULT"   # sets CS, R, SY, WA, CORES, THREADS, THREAD_RATIO, IB_MBS
        TIER="1+2 (SSH)"

        # Tier 2 flags
        FLAGS+=$(flag "${CS:-0}"           "$WARN_CS"           "$CRIT_CS"           "CS/s")
        FLAGS+=$(flag "${SY:-0}"           "$WARN_SY"           "$CRIT_SY"           "%sy")
        FLAGS+=$(flag "${THREAD_RATIO:-0}" "$WARN_THREAD_RATIO" "$CRIT_THREAD_RATIO" "THR/core")
        FLAGS+=$(flag "${IB_MBS:-0}"       "$WARN_IB_MBS"       "$CRIT_IB_MBS"       "IB")
    fi

    # ── Format CS/s ───────────────────────────────────────────────────────────

    CS_DISPLAY="–"
    if [ "$CS" != "–" ] && [ -n "${CS:-}" ]; then
        if   [ "$CS" -ge 1000000 ] 2>/dev/null; then CS_DISPLAY=$(awk "BEGIN{printf \"%.1fM\", $CS/1000000}")
        elif [ "$CS" -ge 1000    ] 2>/dev/null; then CS_DISPLAY=$(awk "BEGIN{printf \"%.0fk\", $CS/1000}")
        else CS_DISPLAY="${CS}"
        fi
    fi

    IB_DISPLAY="${IB_MBS:-–}"
    [ "${IB_DISPLAY}" = "0" ] && IB_DISPLAY="–"

    # ── Colour the status field (pad BEFORE adding ANSI codes) ───────────────

    STATUS_PAD=$(printf "%-6s" "$STATUS")
    if [ "$STATUS" = "ok" ]; then
        STATUS_COL="${GREEN}${STATUS_PAD}${RESET}"
    else
        STATUS_COL="${RED}${STATUS_PAD}${RESET}"
    fi

    # ── Flag summary for end-of-report ────────────────────────────────────────

    if [ -n "$FLAGS" ]; then
        ALL_FLAGS+="  ${BOLD}${node}${RESET}: ${FLAGS}\n"
    else
        FLAGS="${GREEN}OK${RESET}"
    fi

    printf "%-18s  %b  %-5s  %-5s  %-8s  %-8s  %-7s  %-8s  %-9s  %-10s  %b\n" \
        "$node" \
        "$STATUS_COL" \
        "$R1M" \
        "${UT}%" \
        "${FREE_MEM_GB}G" \
        "$IO" \
        "$CS_DISPLAY" \
        "${THREAD_RATIO:-–}" \
        "$IB_DISPLAY" \
        "$TIER" \
        "$FLAGS"

done

# ── Summary ───────────────────────────────────────────────────────────────────

echo
if [ -n "$ALL_FLAGS" ]; then
    echo -e "${BOLD}── Flagged nodes ─────────────────────────────────────────────${RESET}"
    echo -e "$ALL_FLAGS"
    echo -e "${BOLD}Thresholds${RESET}:"
    echo "  CS/s:       WARN >${WARN_CS}   CRIT >${CRIT_CS}"
    echo "  Load (r1m): WARN >${WARN_LOAD}       CRIT >${CRIT_LOAD}"
    echo "  THR/core:   WARN >${WARN_THREAD_RATIO}×         CRIT >${CRIT_THREAD_RATIO}×"
    echo "  IB MB/s:    WARN >${WARN_IB_MBS}     CRIT >${CRIT_IB_MBS}"
    echo "  Free mem:   WARN <${WARN_FREE_MEM_GB}G         CRIT <${CRIT_FREE_MEM_GB}G"
else
    echo -e "${GREEN}${BOLD}All nodes within thresholds.${RESET}"
fi
echo
echo -e "Tip: run from a compute node for Tier 2 metrics (CS/s, threads, IB):"
echo -e "  ${CYAN}bsub -q hpcspecial -n 1 -W 00:30 ${0}${RESET}"
