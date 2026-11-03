#!/usr/bin/env python3
"""Check the built CLI without requesting any device reports or settings."""
import json
from pathlib import Path
import subprocess
import sys

probe = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "build/razerlite-probe"


def run(*arguments):
    return subprocess.run([str(probe.resolve()), *arguments], capture_output=True, text=True, timeout=10)


help_result = run("--help")
assert help_result.returncode == 0 and "--read-battery" in help_result.stdout, "Rebuild the probe first"
cases = [
    (["--read-battery", "--read-mouse"], "一次选择一个读取后端", False),
    (["--read-battery", "--read-charging"], "一次选择一个读取后端", False),
    (["--read-battery", "--watch", "1"], "读取选项与 --watch 不能组合", False),
    (["--device-id", "missing"], "--device-id 仅用于读取选项", False),
    (["--read-battery", "--device-id", "razerlite-test-nonexistent-device"], "未找到唯一", True),
]
for arguments, expected_error, discovery_allowed in cases:
    result = run(*arguments)
    assert result.returncode == 1 and not result.stdout and expected_error in result.stderr, (arguments, result)
    if not discovery_allowed:
        assert "discoveryReady=" not in result.stderr, arguments
    print("PASS rejection:", " ".join(arguments))

result = run()
assert result.returncode == 0, result.stderr
snapshot = json.loads(result.stdout)
assert snapshot["mode"] == "discovery-only; no feature queries requested"
assert not snapshot.get("batteryReadouts") and not snapshot.get("mouseReadouts")
print("PASS help and default passive discovery")
