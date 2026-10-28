#!/usr/bin/env python3
"""Check the actual signed app's helpers on both CPUs without Homebrew in PATH."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

app = Path(sys.argv[1] if len(sys.argv) > 1 else "build/Beamly.app").resolve()
helpers = app / "Contents/Helpers"
licenses = app / "Contents/Resources/Media-Licenses"
manifest = json.loads((licenses / "Media-sources.json").read_text())
for name, source in manifest.items():
    if not source.get("buildOnly"):
        assert any((licenses / name).iterdir()), f"Missing license: {name}"
environment = {key: os.environ[key] for key in ["HOME", "TMPDIR", "LANG"] if key in os.environ}
environment["PATH"] = "/usr/bin:/bin"

with tempfile.TemporaryDirectory(prefix="beamly-bundled-check-") as folder:
    root = Path(folder)
    subtitle = root / "captions.srt"
    subtitle.write_text("1\n00:00:00,000 --> 00:00:02,000\nBeamly — Привет!\n")
    for arch in ["arm64", "x86_64"]:
        def run(name, *arguments):
            try:
                return subprocess.check_output(["/usr/bin/arch", "-" + arch, str(helpers / name),
                                                 *map(str, arguments)], cwd=root, env=environment, stderr=subprocess.STDOUT)
            except subprocess.CalledProcessError as error:
                print(error.output.decode(errors="replace"), file=sys.stderr)
                raise

        for name in ["ffmpeg", "ffprobe"]:
            tool = helpers / name
            subprocess.run(["codesign", "--verify", "--strict", str(tool)], check=True)
            dependencies = subprocess.check_output(["otool", "-arch", arch, "-L", str(tool)], text=True)
            assert all(line.strip().startswith(("/usr/lib/", "/System/Library/"))
                       for line in dependencies.splitlines() if "compatibility version" in line), dependencies
            load_commands = subprocess.check_output(["otool", "-arch", arch, "-l", str(tool)], text=True)
            assert re.search(r"\bminos 14\.0\b", load_commands), "Unexpected deployment target"
            assert ("ffmpeg version " if name == "ffmpeg" else "ffprobe version ").encode() in run(name, "-version")
        input = root / f"{arch}.mkv"
        run("ffmpeg", "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=10:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", input)
        info = json.loads(run("ffprobe", "-v", "error", "-show_streams", "-of", "json", input))
        assert [s["codec_name"] for s in info["streams"]] == ["h264", "aac"]
        baseline = run("ffmpeg", "-v", "error", "-i", input, "-map", "0:v:0", "-f", "framemd5", "-")
        rendered = run("ffmpeg", "-v", "error", "-i", input, "-vf", "subtitles=filename=captions.srt",
                       "-an", "-f", "framemd5", "-")
        def hashes(output):
            return [line.split(b",")[-1].strip() for line in output.splitlines() if line and not line.startswith(b"#")]
        assert len(hashes(baseline)) == len(hashes(rendered)) == 20
        assert hashes(baseline) != hashes(rendered), "Subtitles were not rendered"
        filters = run("ffmpeg", "-hide_banner", "-filters")
        assert all(name in filters for name in [b" subtitles ", b" zscale ", b" tonemap "])
        assert b"libdav1d" in run("ffmpeg", "-hide_banner", "-decoders")
        print(f"{arch}: signed helpers run without Homebrew; MKV, audio, and rendered Unicode subtitles passed.", flush=True)
