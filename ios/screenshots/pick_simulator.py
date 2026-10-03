#!/usr/bin/env python3
"""Picks the simulator for the screenshot tour (.github/workflows/screenshots.yml).

The newest available iOS runtime's newest iPhone Pro Max (the 6.9-inch
display App Store Connect asks screenshots for). When that runtime has no
such device yet, one is created from the newest Pro Max device type the
runtime supports; failing that, the runtime's newest iPhone is used.

Prints one line: <udid> TAB <device name> TAB <runtime name>. macOS only.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys


def simctl_json(*args: str) -> dict:
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", *args, "-j"], text=True))


def version_key(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", text or "")) or (0,)


def model_key(name: str) -> tuple[int, int]:
    """'iPhone 17 Pro Max' -> (17, 1); Pro Max ranks above the plain model."""
    match = re.search(r"iPhone (\d+)", name)
    return (int(match.group(1)) if match else 0, 1 if "Pro Max" in name else 0)


def main() -> int:
    runtimes = [
        rt for rt in simctl_json("runtimes", "available").get("runtimes", [])
        if rt.get("platform", "iOS") == "iOS" and rt.get("isAvailable", True)
        and "iOS" in rt.get("identifier", "")
    ]
    runtimes.sort(key=lambda rt: version_key(rt.get("version", "")), reverse=True)
    devices = simctl_json("devices", "available").get("devices", {})

    for runtime in runtimes:
        name = runtime.get("name", runtime["identifier"])
        available = [d for d in devices.get(runtime["identifier"], []) if d.get("isAvailable", True)]
        pro_max = [d for d in available if "iPhone" in d["name"] and "Pro Max" in d["name"]]
        if pro_max:
            best = max(pro_max, key=lambda d: model_key(d["name"]))
            print(f"{best['udid']}\t{best['name']}\t{name}")
            return 0
        types = [t for t in runtime.get("supportedDeviceTypes", [])
                 if "iPhone" in t.get("name", "") and "Pro Max" in t.get("name", "")]
        if types:
            best_type = max(types, key=lambda t: model_key(t["name"]))
            udid = subprocess.check_output(
                ["xcrun", "simctl", "create", best_type["name"], best_type["identifier"], runtime["identifier"]],
                text=True,
            ).strip()
            print(f"{udid}\t{best_type['name']}\t{name}")
            return 0
        iphones = [d for d in available if d["name"].startswith("iPhone")]
        if iphones:
            best = max(iphones, key=lambda d: model_key(d["name"]))
            print(f"{best['udid']}\t{best['name']}\t{name}")
            return 0

    print("no iPhone simulator or iOS runtime is available", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
