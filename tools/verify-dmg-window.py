#!/usr/bin/env python3
"""Check that Finder really persisted a disk image's window layout.

Run against a mounted volume, after the layout has been applied:

    tools/verify-dmg-window.py "/Volumes/Hotch 0.1.0" \
        --icon-size 96 --item Hotch.app=178,214 --item Applications=482,214

Why this is not done by asking Finder
-------------------------------------
Finder answers questions about a window from live state, not from what it wrote,
and the two disagree in both directions:

  * ``background picture of <icon view options>`` cannot be read back at all on
    current macOS, even when the write landed correctly.
  * ``arrangement`` and ``icon size`` read back as the values just set, and then
    revert to defaults when the window closes — a build that trusted the
    read-back shipped a disk image whose background had silently reverted to
    plain white.

The volume's own ``.DS_Store`` is what the recipient's Finder will read, so that
is what gets checked here. Nothing is written; a non-zero exit means the layout
did not stick and the image should not be shipped.

Format, as much as is needed
----------------------------
``.DS_Store`` is a Buddy-allocated B-tree of records, each
``<name-length:u16><name:utf-16be><structId:4><type:4><payload>``. Two record
types matter:

  ``icvp``  a binary plist of icon view options (``bplist00`` …), holding
            ``arrangeBy``, ``iconSize``, ``backgroundType`` and, for a picture
            background, ``backgroundImageAlias``.
  ``Iloc``  a 16-byte blob per item: x and y as big-endian uint32, then padding.

Records are located by scanning rather than by walking the B-tree. That is
enough to answer "did this land", it cannot corrupt anything, and it keeps this
script short enough to stay obviously correct.
"""

# macOS ships Python 3.9, which cannot evaluate `X | None` annotations.
from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path

BACKGROUND_TYPE_PICTURE = 2


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def find_icon_view_options(blob: bytes) -> dict:
    """The embedded binary plist of icon view options, or {} if absent.

    Grown one byte at a time because the record does not carry the plist's
    length in any form this scan can see, and plistlib is the only thing that
    knows where it ends.
    """
    for match in re.finditer(b"bplist00", blob):
        start = match.start()
        limit = min(start + 8192, len(blob))
        for end in range(start + 40, limit):
            try:
                parsed = plistlib.loads(blob[start:end])
            except Exception:
                continue
            if isinstance(parsed, dict) and "iconSize" in parsed:
                return parsed
            break
    return {}


def find_icon_position(blob: bytes, name: str) -> tuple[int, int] | None:
    """The recorded icon position for one item, or None if it has none."""
    needle = name.encode("utf-16-be") + b"Ilocblob"
    index = blob.find(needle)
    if index < 0:
        return None
    payload = index + len(needle) + 4  # skip the blob's length field
    if payload + 8 > len(blob):
        return None
    x = int.from_bytes(blob[payload:payload + 4], "big")
    y = int.from_bytes(blob[payload + 4:payload + 8], "big")
    return x, y


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("volume", help="mounted volume, e.g. '/Volumes/Hotch 0.1.0'")
    parser.add_argument("--icon-size", type=float, required=True)
    parser.add_argument("--background", required=True,
                        help="file name expected inside the background alias")
    parser.add_argument("--item", action="append", default=[], metavar="NAME=X,Y",
                        help="an item and the position it must hold; repeatable")
    args = parser.parse_args()

    store = Path(args.volume) / ".DS_Store"
    if not store.is_file():
        fail(f"{store} does not exist — Finder wrote no layout at all")
    blob = store.read_bytes()

    problems: list[str] = []

    options = find_icon_view_options(blob)
    if not options:
        problems.append("no icvp record: the icon view options were never written")
    else:
        if options.get("arrangeBy") != "none":
            problems.append(
                f"arrangeBy is {options.get('arrangeBy')!r}, want 'none'"
                " — anything else snaps the icons to a grid and ignores their positions")
        if options.get("iconSize") != args.icon_size:
            problems.append(f"iconSize is {options.get('iconSize')!r}, want {args.icon_size}")
        if options.get("backgroundType") != BACKGROUND_TYPE_PICTURE:
            problems.append(
                f"backgroundType is {options.get('backgroundType')!r},"
                f" want {BACKGROUND_TYPE_PICTURE} (picture)"
                " — the window would open plain white, with no instructions on it")
        alias = options.get("backgroundImageAlias")
        if not alias:
            problems.append("backgroundImageAlias is missing")
        elif args.background.encode() not in alias:
            problems.append(f"backgroundImageAlias does not mention {args.background}")

    for spec in args.item:
        name, _, coordinates = spec.partition("=")
        want = tuple(int(part) for part in coordinates.split(","))
        got = find_icon_position(blob, name)
        if got is None:
            problems.append(f"{name}: no Iloc record, its position was not saved")
        elif got != want:
            problems.append(f"{name}: position {got}, want {want}")

    if problems:
        print(f"error: {store} does not describe the intended window", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        sys.exit(1)

    positions = " ".join(spec for spec in args.item)
    print(f"  dmg window verified: background={args.background}"
          f" icons={int(args.icon_size)}pt unarranged {positions}")


if __name__ == "__main__":
    main()
