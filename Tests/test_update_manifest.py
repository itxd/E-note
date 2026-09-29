import base64
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import sys
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("generate_appcast", ROOT / "scripts/generate_appcast.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class UpdateManifestTests(unittest.TestCase):
    def setUp(self):
        self.info = plistlib.loads((ROOT / "Info.plist").read_bytes())
        self.info["SUPublicEDKey"] = base64.b64encode(bytes(32)).decode()

    def archive(self, directory):
        path = Path(directory) / "E-note-macOS-universal.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("E note.app/Contents/Info.plist", plistlib.dumps(self.info))
        return path

    def test_version_and_key_come_from_packaged_app(self):
        self.info["CFBundleShortVersionString"] = "9.8.7"
        self.info["CFBundleVersion"] = "123"
        with tempfile.TemporaryDirectory() as directory:
            info, version, build = manifest.read_release(self.archive(directory))
        self.assertEqual((version, build), ("9.8.7", "123"))
        self.assertEqual(info["SUPublicEDKey"], self.info["SUPublicEDKey"])

    def test_download_is_bound_to_immutable_release_tag(self):
        feed = manifest.make_feed(self.info, "9.8.7", "123", "E note.zip", 45, "signature", "A & B < C")
        enclosure = feed.find("channel/item/enclosure")
        self.assertEqual(enclosure.get("url"),
                         "https://github.com/itxd/E-note/releases/download/v9.8.7/E%20note.zip")
        self.assertEqual(enclosure.get("length"), "45")
        self.assertEqual(enclosure.get("{" + manifest.SPARKLE_NS + "}edSignature"), "signature")

    def test_rejects_disabled_signature_checks(self):
        for key in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                original = self.info[key]
                self.info[key] = False
                with self.assertRaises(ValueError):
                    manifest.read_release(self.archive(directory))
                self.info[key] = original

    def test_rejects_development_builds(self):
        self.info["ENoteDevelopmentBuild"] = True
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                manifest.read_release(self.archive(directory))

    def test_rejects_other_apps_and_untrusted_feeds(self):
        for key, value in (("CFBundleIdentifier", "other.app"), ("SUFeedURL", "http://example.com/feed.xml"),
                           ("CFBundleVersion", "not-a-build"), ("SUPublicEDKey", "bad"),
                           ("SUSignedFeedFailureExpirationInterval", 1728000)):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                original = self.info[key]
                self.info[key] = value
                with self.assertRaises(ValueError):
                    manifest.read_release(self.archive(directory))
                self.info[key] = original


if __name__ == "__main__":
    unittest.main()
