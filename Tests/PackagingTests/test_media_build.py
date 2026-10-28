import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest


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


if __name__ == "__main__":
    unittest.main()
