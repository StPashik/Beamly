#!/usr/bin/env python3
"""Ship complete corresponding media source beside the application release."""

import hashlib
import json
from pathlib import Path
import plistlib
import tarfile

root = Path(__file__).resolve().parent.parent
version = plistlib.loads((root / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
sources = json.loads((root / "Resources/Media-sources.json").read_text())
destination = root / "dist" / f"Beamly-FFmpeg-Sources-{version}.tar.xz"
destination.parent.mkdir(exist_ok=True)
with tarfile.open(destination, "w:xz") as archive:
    for relative in ["LICENSE", "Resources/Media-sources.json", "Resources/Info.plist", "Scripts/build-media.py",
                     "Scripts/embed-media.sh", "Scripts/verify-bundled-media.py", "Scripts/package-media-sources.py",
                     "Docs/Bundled-media.md"]:
        archive.add(root / relative, arcname=relative)
    for source in sources.values():
        relative = ".build/media-sources/" + source["archive"]
        path = root / relative
        if hashlib.sha256(path.read_bytes()).hexdigest() != source["sha256"]:
            raise RuntimeError(f"Incorrect source archive: {path}")
        archive.add(path, arcname=relative)
    for name in ["Configurations", "Licenses"]:
        archive.add(root / ".build/media-universal" / name, arcname=name)
print(f"Complete corresponding media source: {destination}")
