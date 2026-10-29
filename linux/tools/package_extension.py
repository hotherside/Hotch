#!/usr/bin/env python3
"""Create an installable extension ZIP, excluding fixtures and developer files."""
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "gnome-extension"
VERSION = json.loads((SOURCE / "metadata.json").read_text())["version-name"]
output = ROOT / "target" / f"hotch-gnome-{VERSION}.zip"
output.parent.mkdir(parents=True, exist_ok=True)
files = ["metadata.json", "extension.js", "data.js", "model.js", "stylesheet.css", "icons/claude.svg", "icons/codex.svg"]
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for name in files:
        archive.write(SOURCE / name, name)
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    assert set(archive.namelist()) == set(files)
print(output)
