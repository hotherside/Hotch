#!/usr/bin/env python3
"""Fail before packaging if any macOS/Linux version, or the release tag, drifts."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def match(path, pattern):
    result = re.search(pattern, (ROOT / path).read_text(), re.M)
    if not result:
        raise SystemExit(f"Missing version in {path}")
    return result.group(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag")
    args = parser.parse_args()
    versions = {
        "Makefile": match("Makefile", r"^VERSION\s*:=\s*(\S+)"),
        "macOS fallback": match("Sources/Hotch/About.swift", r'developmentVersion = "([^"]+)"'),
        "Cargo.toml": match("linux/Cargo.toml", r'^version = "([^"]+)"'),
        "Cargo.lock": match("linux/Cargo.lock", r'\[\[package\]\]\s+name = "hotch"\s+version = "([^"]+)"'),
        "GNOME metadata": json.loads((ROOT / "linux/gnome-extension/metadata.json").read_text())["version-name"],
    }
    if args.tag:
        if not re.fullmatch(r"v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", args.tag):
            raise SystemExit("Release tag must be a semantic version, optionally prefixed with v")
        versions["release tag"] = args.tag.removeprefix("v")
    if len(set(versions.values())) != 1:
        raise SystemExit(f"Version mismatch: {versions}")
    print(next(iter(versions.values())))


if __name__ == "__main__":
    main()
