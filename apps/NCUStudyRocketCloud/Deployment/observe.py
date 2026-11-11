#!/usr/bin/env python3
"""Record a bounded coexistence observation without storing request contents."""
import argparse
import datetime as dt
import json
from pathlib import Path
import subprocess
import time
import urllib.request


def sample():
    result = {"time": dt.datetime.now(dt.timezone.utc).isoformat()}
    mem = {line.split(":")[0]: int(line.split()[1]) for line in Path("/proc/meminfo").read_text().splitlines()}
    result.update(availableKiB=mem["MemAvailable"], swapUsedKiB=mem["SwapTotal"] - mem["SwapFree"])
    result["load"] = Path("/proc/loadavg").read_text().strip()
    for service in ("studyrocket-cloud", "soulcourse"):
        props = subprocess.check_output(["systemctl", "show", service, "--property=ActiveState,MemoryCurrent,MemoryPeak,NRestarts,ControlGroup,MainPID"], text=True)
        state = dict(line.split("=", 1) for line in props.splitlines() if "=" in line)
        try:
            status = Path("/proc", state["MainPID"], "status").read_text()
            state["processMemoryKiB"] = {line.split(":")[0]: int(line.split()[1])
                for line in status.splitlines() if line.startswith(("VmRSS:", "VmHWM:", "VmSwap:"))}
        except (OSError, KeyError, ValueError):
            pass
        group = Path("/sys/fs/cgroup") / state.pop("ControlGroup", "").lstrip("/")
        for name in ("memory.events", "memory.swap.current", "memory.pressure"):
            try:
                state[name] = (group / name).read_text().strip()
            except OSError:
                pass
        result[service] = state
    for name, url in (("cloudHealth", "http://127.0.0.1:43818/v1/health"),
                      ("soulcourseReady", "http://127.0.0.1:1309/readyz")):
        start = time.monotonic()
        try:
            with urllib.request.urlopen(url, timeout=5) as response:
                body = json.load(response)
                result[name] = {"status": response.status, "seconds": round(time.monotonic() - start, 4)}
                if name == "soulcourseReady":
                    result[name]["database"] = body.get("checks", {}).get("database")
        except Exception as error:
            result[name] = {"error": type(error).__name__, "seconds": round(time.monotonic() - start, 4)}
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=86400)
    parser.add_argument("--interval", type=int, default=60)
    args = parser.parse_args()
    if not 1 <= args.interval <= 60 or not 1 <= args.seconds <= 172800:
        parser.error("Use 1–60 second samples over at most 48 hours")
    stop = time.monotonic() + args.seconds
    args.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with args.output.open("x", buffering=1) as output:
        while True:
            output.write(json.dumps(sample(), separators=(",", ":")) + "\n")
            remaining = stop - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(args.interval, remaining))
