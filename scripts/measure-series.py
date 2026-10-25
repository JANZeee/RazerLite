#!/usr/bin/env python3
"""Run repeated, read-only process measurements. Keep the app idle throughout."""
import argparse
import datetime
import json
import pathlib
import platform
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("--label", required=True)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--directory", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.trials <= 10:
        parser.error("Use 1–10 trials")
    args.directory.mkdir(parents=True, exist_ok=True)
    identity = subprocess.check_output(
        ["/bin/ps", "-p", str(args.pid), "-o", "lstart=", "-o", "command="], text=True
    ).strip()
    summaries = []
    for trial in range(1, args.trials + 1):
        prefix = args.directory / f"{args.label}-{trial}"
        current = subprocess.check_output(
            ["/bin/ps", "-p", str(args.pid), "-o", "lstart=", "-o", "command="], text=True
        ).strip()
        if current != identity:
            raise RuntimeError("Process identity changed")
        result = subprocess.run([
            sys.executable, str(pathlib.Path(__file__).with_name("measure-process.py")),
            str(args.pid), "--seconds", str(args.seconds), "--output", str(prefix.with_suffix(".csv")),
        ], capture_output=True, text=True, check=True)
        summary = json.loads(result.stdout)
        prefix.with_suffix(".json").write_text(json.dumps(summary, indent=2) + "\n")
        summaries.append(summary)
        print(f"{args.label} {trial}/{args.trials}: CPU {summary['averageCPUPercent']:.4f}%, "
              f"median RSS {summary['rssKiBMedian'] / 1024:.2f} MiB", flush=True)
    (args.directory / f"{args.label}-summary.json").write_text(json.dumps({
        "label": args.label, "process": identity, "platform": platform.platform(),
        "recordedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(), "trials": summaries,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
