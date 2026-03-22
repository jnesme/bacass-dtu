#!/usr/bin/env python3
"""
Summarize a Nextflow execution trace file by process.

Usage:
    bin/trace_summary.py pipeline_info/execution_trace_*.txt [...]

Multiple trace files can be passed; they are concatenated before analysis.
Only COMPLETED and CACHED tasks are included (FAILED/ABORTED are skipped).
"""

import re
import sys
from collections import defaultdict
from statistics import median


def parse_duration(s):
    """Parse Nextflow duration string to seconds. Returns None if unparseable."""
    if not s or s.strip() in ("-", ""):
        return None
    s = s.strip()
    total = 0.0
    for value, unit in re.findall(r"([\d.]+)\s*(d|h|m|s|ms)", s):
        value = float(value)
        if unit == "d":
            total += value * 86400
        elif unit == "h":
            total += value * 3600
        elif unit == "m":
            total += value * 60
        elif unit == "s":
            total += value
        elif unit == "ms":
            total += value / 1000
    return total if total > 0 else None


def parse_memory(s):
    """Parse Nextflow memory string to GB. Returns None if unparseable."""
    if not s or s.strip() in ("-", ""):
        return None
    m = re.match(r"([\d.]+)\s*(KB|MB|GB|TB|B)", s.strip(), re.IGNORECASE)
    if not m:
        return None
    value, unit = float(m.group(1)), m.group(2).upper()
    return value / (1024 ** 3) * {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3, "TB": 1024**4}[unit]


def parse_cpu(s):
    """Parse '%cpu' string like '258.3%' to float. Returns None if unparseable."""
    if not s or s.strip() in ("-", ""):
        return None
    m = re.match(r"([\d.]+)%?", s.strip())
    return float(m.group(1)) if m else None


def process_name(full_name):
    """Strip workflow prefix and sample ID suffix from task name."""
    # Remove everything up to and including the last colon
    name = re.sub(r"^.*:", "", full_name)
    # Remove trailing sample ID in parentheses
    name = re.sub(r"\s*\(.*\)$", "", name)
    return name.strip()


def fmt_time(seconds):
    if seconds is None:
        return "-"
    if seconds >= 3600:
        return f"{seconds/3600:.1f}h"
    if seconds >= 60:
        return f"{seconds/60:.1f}m"
    return f"{seconds:.1f}s"


def fmt_mem(gb):
    if gb is None:
        return "-"
    if gb >= 1:
        return f"{gb:.1f} GB"
    return f"{gb*1024:.0f} MB"


def fmt_cpu(pct):
    return f"{pct:.0f}%" if pct is not None else "-"


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    rows = []
    header = None
    for path in sys.argv[1:]:
        with open(path) as fh:
            for i, line in enumerate(fh):
                fields = line.rstrip("\n").split("\t")
                if i == 0:
                    if header is None:
                        header = fields
                    continue
                rows.append(fields)

    if header is None:
        print("No data found.", file=sys.stderr)
        sys.exit(1)

    col = {name: idx for idx, name in enumerate(header)}

    # Aggregate by process name
    data = defaultdict(lambda: {"realtime": [], "cpu": [], "rss": [], "retries": 0, "total": 0})

    for row in rows:
        if len(row) < len(header):
            continue
        status = row[col["status"]]
        if status not in ("COMPLETED", "CACHED"):
            continue

        pname = process_name(row[col["name"]])
        rt = parse_duration(row[col["realtime"]])
        cpu = parse_cpu(row[col["%cpu"]])
        rss = parse_memory(row[col["peak_rss"]])

        entry = data[pname]
        entry["total"] += 1
        if rt is not None:
            entry["realtime"].append(rt)
        if cpu is not None:
            entry["cpu"].append(cpu)
        if rss is not None:
            entry["rss"].append(rss)

    # Print table
    cols = ["Process", "Tasks", "Med RT", "Max RT", "Med CPU%", "Max CPU%", "Med RSS", "Max RSS"]
    widths = [max(len(c), 35) if i == 0 else max(len(c), 8) for i, c in enumerate(cols)]
    widths[0] = max(max(len(p) for p in data) + 1, 35)

    def row_str(values):
        return "  ".join(str(v).ljust(w) for v, w in zip(values, widths))

    print(row_str(cols))
    print("  ".join("-" * w for w in widths))

    for pname in sorted(data):
        e = data[pname]
        rt = e["realtime"]
        cpu = e["cpu"]
        rss = e["rss"]
        print(row_str([
            pname,
            e["total"],
            fmt_time(median(rt)) if rt else "-",
            fmt_time(max(rt)) if rt else "-",
            fmt_cpu(median(cpu)) if cpu else "-",
            fmt_cpu(max(cpu)) if cpu else "-",
            fmt_mem(median(rss)) if rss else "-",
            fmt_mem(max(rss)) if rss else "-",
        ]))


if __name__ == "__main__":
    main()
