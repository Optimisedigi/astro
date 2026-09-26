"""Offline checks for release safeguards; no signing credentials or network access."""

import hashlib
import io
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import package_release as release


class ReleaseChecks(unittest.TestCase):
    def test_streamed_checksum(self):
        self.assertEqual(release.file_digest(io.BytesIO(b"Astro")), hashlib.sha256(b"Astro").hexdigest())

    def test_cask_pins_the_artifact_and_keeps_user_data(self):
        digest = hashlib.sha256(b"test artifact").hexdigest()
        text = release.cask("0.1.0", digest)
        self.assertIn(f'sha256 "{digest}"', text)
        self.assertIn("releases/download/v#{version}/Astro.dmg", text)
        self.assertIn("depends_on arch: :arm64", text)
        self.assertIn('depends_on macos: ">= :sequoia"', text)
        self.assertIn('app "Astro.app"', text)
        self.assertNotIn(":no_check", text)
        self.assertNotIn("zap ", text)
        self.assertNotIn("sudo", text)

    def test_rejected_notarization_stops(self):
        with patch.object(release, "run", return_value='{"status":"Invalid","id":"test-rejection"}'):
            with self.assertRaisesRegex(RuntimeError, "did not accept"):
                release.notarize(Path("test.dmg"), "test-profile")

    def test_notarization_uses_keychain_profile_and_waits_for_acceptance(self):
        with patch.object(release, "run", return_value='{"status":"Accepted","id":"test-accepted"}') as run:
            self.assertEqual(release.notarize(Path("test.dmg"), "test-profile"), "test-accepted")
        self.assertIn("--keychain-profile", run.call_args.args)
        self.assertIn("--wait", run.call_args.args)
        self.assertNotIn("--password", run.call_args.args)

    def test_output_cannot_modify_the_source_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Astro.app"
            app.mkdir()
            with self.assertRaisesRegex(ValueError, "outside the source"):
                release.package(app, app / "output", "unused")
            self.assertFalse((app / "output").exists())

    def test_unexpected_bundle_id_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Astro.app"
            (app / "Contents").mkdir(parents=True)
            with (app / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleIdentifier": "wrong.bundle"}, stream)
            with self.assertRaisesRegex(ValueError, "bundle ID"):
                release.validate_app(app)

    def test_existing_output_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Astro.app"
            app.mkdir()
            output = Path(directory) / "existing-release"
            output.mkdir()
            sentinel = output / "Astro.dmg"
            sentinel.write_bytes(b"previous release bytes")
            with patch.object(release, "validate_app", return_value=("0.1.0", "test-identity")):
                with self.assertRaises(FileExistsError):
                    release.package(app, output, "unused")
            self.assertEqual(sentinel.read_bytes(), b"previous release bytes")


if __name__ == "__main__":
    unittest.main()
