#!/usr/bin/env python3
"""Say whether a release changes what Linux users install.

Versions move in lockstep with macOS, so every release edits the Linux version
fields. A release changes Linux when any packaged input differs from the last
release Linux users were offered once those fields are set aside. That is the
newest earlier published release with a `.deb` for every architecture, the
rule the update notice follows, rather than the previous tag: a Linux change
whose packages never shipped is then not lost behind a macOS-only release.
Releases that do not change Linux get no Linux assets, and the update notice
ignores them. Prints `linux=true` or `linux=false`, also to $GITHUB_OUTPUT
when set.

The release list comes from GitHub, for example:
    gh api --paginate "repos/hotherside/Hotch/releases?per_page=100" > releases.json
"""
import argparse
import json
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
# The release workflow's build matrix.
ARCHES = ["amd64", "arm64"]
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


def releases(path):
    """GitHub's release list; `gh api --paginate` writes one JSON array per page."""
    with open(path) as file:
        text = file.read()
    decoder, found, at = json.JSONDecoder(), [], 0
    while text[at:].strip():
        at += len(text[at:]) - len(text[at:].lstrip())
        page, at = decoder.raw_decode(text, at)
        found += page
    return found


def shipped(release):
    """Published with an uploaded `.deb` for every architecture."""
    names = [a["name"] for a in release.get("assets") or [] if a.get("state", "uploaded") == "uploaded"]
    debs = all(any(n.startswith("hotch_") and n.endswith(f"_{arch}.deb") for n in names) for arch in ARCHES)
    return debs and not release.get("draft")


def baseline(tag, published):
    """The newest release below `tag` that Linux users were offered. A stable
    release skips prereleases, whether named so or only flagged on GitHub."""
    current = version(tag)
    if current is None:
        raise SystemExit(f"Not a release tag: {tag}")
    flagged = {r["tag_name"] for r in published if r.get("prerelease")}
    stable = current[3] and tag not in flagged
    older = [
        (key, r["tag_name"])
        for r in published
        for key in [version(r["tag_name"])]
        if key is not None and key < current and shipped(r)
        and (not stable or (key[3] and r["tag_name"] not in flagged))
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
    parser.add_argument("--releases", required=True, help="GitHub's release list as JSON")
    args = parser.parse_args()
    before = baseline(args.tag, releases(args.releases))
    if before is None:
        changed, reason = True, "no earlier release with Linux packages"
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
