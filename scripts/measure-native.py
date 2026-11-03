#!/usr/bin/env python3
"""On-demand macOS process measurement using libproc; no product dependency.

ABI: SDK sys/resource.h rusage_info_v1, libproc.h proc_pid_rusage.
CPU counters are Mach absolute ticks; memory counters are bytes. Child CPU counters
cover reaped children, not all live subprocess work or a launch count.
"""
import argparse
import ctypes
import datetime
import json
import pathlib
import platform
import statistics
import time


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups",
            "pageins", "wired_size", "resident_size", "phys_footprint",
            "proc_start_abstime", "proc_exit_abstime", "child_user_time",
            "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups",
            "child_pageins", "child_elapsed_abstime",
        )
    ]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def timebase():
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    system.mach_timebase_info.restype = ctypes.c_int
    result = Timebase()
    if system.mach_timebase_info(ctypes.byref(result)) != 0 or not result.numer or not result.denom:
        raise RuntimeError("Cannot obtain Mach timebase")
    return result.numer, result.denom


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if platform.system() != "Darwin" or args.pid <= 0 or not 1 <= args.seconds <= 3600:
        parser.error("Requires macOS, a positive PID and 1–3600 seconds")
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pid_rusage.restype = ctypes.c_int
    numer, denom = timebase()
    seconds_per_tick = numer / denom / 1e9
    samples = []
    started = time.monotonic()
    recorded = datetime.datetime.now(datetime.timezone.utc).isoformat()
    identity = None
    for index in range(args.seconds + 1):
        time.sleep(max(0, started + index - time.monotonic()))
        usage = Usage()
        if lib.proc_pid_rusage(args.pid, 1, ctypes.byref(usage)) != 0:
            raise OSError(ctypes.get_errno(), "proc_pid_rusage failed")
        current = (bytes(usage.uuid).hex(), usage.proc_start_abstime)
        if identity is not None and current != identity:
            raise RuntimeError("Process identity changed; refusing mixed samples")
        if usage.proc_exit_abstime:
            raise RuntimeError("Target exited during sampling")
        identity = current
        row = {name: getattr(usage, name) for name, _ in Usage._fields_ if name != "uuid"}
        row["elapsed_s"] = time.monotonic() - started
        samples.append(row)
    first, last = samples[0], samples[-1]
    duration = last["elapsed_s"] - first["elapsed_s"]
    delta = lambda key: last[key] - first[key]
    result = {
        "pid": args.pid, "identity": identity, "recordedAtUTC": recorded,
        "platform": platform.platform(), "durationSeconds": duration,
        "machTimebase": {"numer": numer, "denom": denom},
        "averageCPUPercent": 100 * (delta("user_time") + delta("system_time")) * seconds_per_tick / duration,
        "physicalFootprintBytesMedian": statistics.median(r["phys_footprint"] for r in samples),
        "physicalFootprintBytesMin": min(r["phys_footprint"] for r in samples),
        "physicalFootprintBytesMax": max(r["phys_footprint"] for r in samples),
        "interruptWakeups": delta("interrupt_wkups"),
        "packageIdleWakeups": delta("pkg_idle_wkups"),
        "reapedChildCPUSeconds": (delta("child_user_time") + delta("child_system_time")) * seconds_per_tick,
        "samples": samples,
        "notes": "100% CPU = one core. Kernel wakeup counters are not all timer callbacks. "
                 "Zero child CPU does not prove no children launched. Foreground state is not enforced.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "samples"}, indent=2))


if __name__ == "__main__":
    main()
