#!/usr/bin/env python3
"""Read-only sampling of a running process; Python standard library only."""
import argparse
import csv
import json
import pathlib
import statistics
import subprocess
import time


def cpu_seconds(value):
    days = 0
    if "-" in value:
        day, value = value.split("-", 1)
        days = int(day)
    result = 0.0
    for part in value.split(":"):
        result = result * 60 + float(part)
    return days * 86400 + result


def sample(pid):
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "time=", "-o", "rss="],
        check=True, capture_output=True, text=True,
    )
    parts = result.stdout.split()
    if len(parts) != 2:
        raise RuntimeError("Process unavailable")
    return cpu_seconds(parts[0]), int(parts[1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.pid <= 0 or not 1 <= args.seconds <= 3600:
        parser.error("Use a positive PID and 1–3600 seconds")
    initial_cpu, initial_rss = sample(args.pid)
    started = time.monotonic()
    previous_time, previous_cpu = started, initial_cpu
    rows = [(0.0, initial_cpu, "", initial_rss)]
    for _ in range(args.seconds):
        time.sleep(1)
        cpu, rss = sample(args.pid)
        now = time.monotonic()
        if cpu < previous_cpu:
            raise RuntimeError("CPU counter reset; process may have restarted")
        rows.append((now - started, cpu, 100 * (cpu - previous_cpu) / (now - previous_time), rss))
        previous_time, previous_cpu = now, cpu
    with args.output.open("w", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(["elapsed_s", "cpu_time_s", "interval_cpu_percent", "rss_kib"])
        writer.writerows(rows)
    print(json.dumps({
        "pid": args.pid, "samples": len(rows), "durationSeconds": rows[-1][0],
        "averageCPUPercent": 100 * (rows[-1][1] - initial_cpu) / rows[-1][0],
        "rssKiBMin": min(r[3] for r in rows), "rssKiBMedian": statistics.median(r[3] for r in rows),
        "rssKiBMax": max(r[3] for r in rows), "rawCSV": str(args.output),
        "notes": "RSS is not physical footprint; ps CPU counter resolution limits short samples",
    }, indent=2))


if __name__ == "__main__":
    main()
