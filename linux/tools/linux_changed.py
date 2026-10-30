#!/usr/bin/env python3
"""Say whether a release changes what Linux users install.

Versions move in lockstep with macOS, so every release edits the Linux version
fields. A release changes Linux when any packaged input differs from the
previous release tag once those fields are set aside. Releases that do not
change Linux get no Linux assets, and the update notice ignores them.
Prints `linux=true` or `linux=false`, also to $GITHUB_OUTPUT when set.
"""
import argparse
import os
import re
import subprocess

# Everything `cargo deb` and package_extension.py put in a download.
INPUTS = ["linux", "docs/marketing/brand/app-icon.png", "LICENSE"]
# The lockstep version fields, as tools/check_version.py reads them.
VERSION_FIELDS = {
    "linux/Cargo.toml": r'^(version = )"[^"]+"',
    "linux/Cargo.lock": r'(\[\[package\]\]\s+name = "hotch"\s+version = )"[^"]+"',
    "linux/gnome-extension/metadata.json": r'("version-name":\s*)"[^"]+"',
}
TAG = re.compile(r"v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?")
TOP = subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True).stdout.strip()


def git(*args):
    # Paths are repository-relative wherever the script runs from.
    return subprocess.run(["git", "-C", TOP, *args], check=True, capture_output=True).stdout


def version(tag):
    """Sort key, or None for a tag that is not a release version."""
    match = TAG.fullmatch(tag)
    if not match:
        return None
    major, minor, patch, pre = match.groups()
    return (int(major), int(minor), int(patch), pre is None, pre or "")


def previous(tag):
    """The highest release tag below `tag`. A stable release skips prereleases."""
    current = version(tag)
    if current is None:
        raise SystemExit(f"Not a release tag: {tag}")
    older = [
        (key, name)
        for name in git("tag", "--list").decode().split()
        for key in [version(name)]
        if key is not None and key < current and (key[3] or not current[3])
    ]
    return max(older)[1] if older else None


def tree(ref):
    """Path -> content, with the lockstep version fields blanked."""
    files = {}
    listing = git("ls-tree", "-r", "-z", ref, "--", *INPUTS).decode().split("\0")
    for entry in filter(None, listing):
        meta, path = entry.split("\t", 1)
        mode, _, blob = meta.split()
        if path in VERSION_FIELDS:
            text = git("cat-file", "blob", blob).decode()
            blob = re.sub(VERSION_FIELDS[path], r'\1"VERSION"', text, count=1, flags=re.M)
        files[path] = (mode, blob)
    return files


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    before = previous(args.tag)
    if before is None:
        changed, reason = True, "no earlier release tag"
    else:
        old, new = tree(before), tree(args.tag)
        paths = sorted(p for p in old.keys() | new.keys() if old.get(p) != new.get(p))
        changed = bool(paths)
        reason = f"{len(paths)} Linux file(s) changed since {before}" if paths else f"Linux unchanged since {before}"
        for path in paths:
            print(f"  {path}")
    print(f"{args.tag}: {reason}")
    print(f"linux={'true' if changed else 'false'}")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"linux={'true' if changed else 'false'}\nprevious={before or ''}\n")


if __name__ == "__main__":
    main()
