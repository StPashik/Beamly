import hashlib
import importlib.util
import io
from pathlib import Path
import runpy
import sys
import tarfile
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch


class MediaSourceSafetyTests(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).resolve().parents[2] / "Scripts/build-media.py"
        spec = importlib.util.spec_from_file_location("media_build", source)
        self.builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.builder)
        self.temporary = tempfile.TemporaryDirectory(prefix="beamly-source-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.builder.DOWNLOADS = self.root

    def test_checksum_mismatch_is_rejected_before_extraction(self):
        archive = self.root / "fixture.tar"
        archive.write_bytes(b"tampered download")
        self.builder.SOURCES = {"fixture": {"archive": archive.name, "directory": "fixture", "sha256": "0" * 64}}
        with self.assertRaisesRegex(RuntimeError, "Incorrect source SHA-256"):
            self.builder.extract("fixture", self.root)
        self.assertEqual(list(self.root.iterdir()), [archive])

    def test_verified_archive_cannot_escape_the_build_directory(self):
        archive = self.root / "fixture.tar"
        with tarfile.open(archive, "w") as package:
            entry = tarfile.TarInfo("../escaped-source")
            entry.size = 1
            package.addfile(entry, io.BytesIO(b"x"))
        self.builder.SOURCES = {"fixture": {"archive": archive.name, "directory": "fixture",
                                          "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}}
        work = self.root / "work"
        work.mkdir()
        with self.assertRaises(tarfile.OutsideDestinationError):
            self.builder.extract("fixture", work)
        self.assertFalse((self.root / "escaped-source").exists())

    def test_intel_build_host_checks_arm_linkage_without_executing_arm_code(self):
        root = Path(__file__).resolve().parents[2]
        app = root / "build/Beamly.app"
        if not (app / "Contents/Helpers/ffmpeg").exists():
            self.skipTest("Build the packaged app first")
        output = io.StringIO()
        script = root / "Scripts/verify-bundled-media.py"
        with patch("platform.machine", return_value="x86_64"), patch.object(sys, "argv", [str(script), str(app)]), redirect_stdout(output):
            runpy.run_path(str(script), run_name="__main__")
        self.assertIn("arm64: signatures/linkage/deployment verified; runtime requires an Apple Silicon host.", output.getvalue())
        self.assertIn("x86_64: signed helpers run without Homebrew", output.getvalue())


if __name__ == "__main__":
    unittest.main()
