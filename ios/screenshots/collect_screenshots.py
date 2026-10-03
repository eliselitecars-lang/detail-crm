#!/usr/bin/env python3
"""Gathers the screenshot tour's PNGs into one folder (.github/workflows/screenshots.yml).

The UI test writes every screenshot to SHOTS_DIR as <name>.png (names start
with a two-digit order, e.g. 01-owner-today). When that folder has none (the
runner could not write to it), the PNGs are exported from the .xcresult
instead (`xcrun xcresulttool export attachments`, Xcode 16+) and named after
their attachment names.

  collect_screenshots.py --raw DIR --xcresult PATH --out DIR

Exit status 1 when no screenshot was found.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SUFFIX = re.compile(r"_\d+_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")


def attachment_entries(node: object):
    if isinstance(node, dict):
        if "exportedFileName" in node:
            yield node
        for value in node.values():
            yield from attachment_entries(value)
    elif isinstance(node, list):
        for value in node:
            yield from attachment_entries(value)


def from_xcresult(xcresult: Path, out: Path) -> list[Path]:
    if not xcresult.exists():
        return []
    work = Path(tempfile.mkdtemp(prefix="attachments-"))
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(xcresult),
                    "--output-path", str(work)], check=True)
    manifest = json.loads((work / "manifest.json").read_text())
    copied = []
    for entry in attachment_entries(manifest):
        source = work / entry["exportedFileName"]
        if source.suffix.lower() != ".png" or not source.exists():
            continue
        name = Path(entry.get("suggestedHumanReadableName") or source.name).stem
        name = SUFFIX.sub("", name)
        target = out / f"{name}.png"
        shutil.copyfile(source, target)
        copied.append(target)
    return copied


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--xcresult", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    copied = []
    if args.raw.is_dir():
        for png in sorted(args.raw.glob("*.png")):
            target = args.out / png.name
            shutil.copyfile(png, target)
            copied.append(target)
        report = args.raw / "report.txt"
        if report.exists():
            shutil.copyfile(report, args.out / "report.txt")
    if not copied:
        print(f"no PNGs in {args.raw}; exporting the attachments of {args.xcresult}")
        try:
            copied = from_xcresult(args.xcresult, args.out)
        except (subprocess.CalledProcessError, OSError, ValueError, KeyError) as error:
            print(f"could not export attachments: {error}", file=sys.stderr)
    for path in sorted(copied):
        print(f"  {path.name}")
    print(f"{len(copied)} screenshot(s) in {args.out}")
    return 0 if copied else 1


if __name__ == "__main__":
    sys.exit(main())
