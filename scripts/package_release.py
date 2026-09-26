#!/usr/bin/env python3
"""Notarize an exported Astro.app, then produce a DMG and checksum-pinned cask.

Never installs an app, changes Gatekeeper, reads private keys, or publishes files.
Credentials are read by Apple's notarytool from the named Keychain profile.
"""

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def run(*args, timeout=1800, stdout_only=False):
    """Run native tools with argument arrays and record the outcome, not secrets."""
    started = time.monotonic()
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    print(json.dumps({"tool": args[0], "operation": list(args[1:3]),
                      "exit_code": result.returncode, "seconds": round(time.monotonic() - started, 2)}))
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout if stdout_only else result.stdout + result.stderr


def validate_app(app):
    if app.name != "Astro.app" or not app.is_dir():
        raise ValueError("Pass an exported, Developer ID-signed Astro.app directory.")
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != "com.universe.app":
        raise ValueError("The bundle ID must remain com.universe.app to preserve user data and sign-ins.")
    version = info.get("CFBundleShortVersionString", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("The release version must have three numeric components.")
    executable = info.get("CFBundleExecutable", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", executable):
        raise ValueError("Invalid app executable name.")
    if info.get("LSMinimumSystemVersion") != "15.0":
        raise ValueError("Review the cask's macOS requirement before changing the app's deployment target.")
    architectures = run("/usr/bin/lipo", "-archs", str(app / "Contents/MacOS" / executable)).strip()
    if architectures != "arm64":
        raise ValueError("This release recipe supports the Apple silicon build only.")
    if not (app / "Contents/Resources/Licenses").is_dir():
        raise ValueError("Build the app with the bundled Release/Licenses directory before exporting.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    details = run("/usr/bin/codesign", "-d", "--verbose=4", str(app))
    identity = re.search(r"^Authority=(Developer ID Application: .+)$", details, re.MULTILINE)
    runtime = re.search(r"^CodeDirectory .*flags=.*\bruntime\b", details, re.MULTILINE)
    if not identity or not runtime or "Timestamp=" not in details:
        raise ValueError("A Developer ID Application signature, hardened runtime and timestamp are required.")
    entitlements = run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(app))
    xml = re.search(r"(<\?xml.*?</plist>)", entitlements, re.DOTALL)
    if not xml:
        raise ValueError("Could not inspect the app's signing entitlements.")
    signed_entitlements = plistlib.loads(xml.group(1).encode())
    if signed_entitlements.get("com.apple.security.get-task-allow", False):
        raise ValueError("Debugging entitlements are not allowed in a public release.")
    if not signed_entitlements.get("com.apple.security.device.audio-input", False):
        raise ValueError("The hardened app needs the audio-input entitlement for voice features.")
    return version, identity.group(1)


def notarize(path, profile):
    output = run("/usr/bin/xcrun", "notarytool", "submit", str(path),
                 "--keychain-profile", profile, "--wait", "--timeout", "20m", "--output-format", "json",
                 stdout_only=True)
    response = json.loads(output)
    if response.get("status") != "Accepted":
        raise RuntimeError(f"Apple did not accept the submission: {response}")
    return response["id"]


def cask(version, digest):
    return f'''cask "astro" do
  version "{version}"
  sha256 "{digest}"

  url "https://github.com/Optimisedigi/astro/releases/download/v#{{version}}/Astro.dmg"
  name "Astro"
  desc "Menu bar AI assistant with chat, voice, images, journal and reminders"
  homepage "https://github.com/Optimisedigi/astro"

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Astro.app"

  uninstall quit: "com.universe.app"
end
'''


def package(app, destination, profile):
    app = app.resolve(strict=True)
    destination = destination.resolve()
    if destination == app or app in destination.parents:
        raise ValueError("Release output must be outside the source app bundle.")
    version, identity = validate_app(app)
    # Reserve a new output directory. Never overwrite a previous release.
    destination.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="astro-package-") as temporary:
        work = Path(temporary)
        volume = work / "volume"
        volume.mkdir()
        staged_app = volume / "Astro.app"
        run("/usr/bin/ditto", str(app), str(staged_app))
        app_zip = work / "Astro.zip"
        run("/usr/bin/ditto", "-c", "-k", "--keepParent", str(staged_app), str(app_zip))
        app_submission = notarize(app_zip, profile)
        run("/usr/bin/xcrun", "stapler", "staple", str(staged_app))
        run("/usr/bin/xcrun", "stapler", "validate", str(staged_app))
        run("/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", str(staged_app))
        (volume / "Applications").symlink_to("/Applications", target_is_directory=True)
        dmg = work / "Astro.dmg"
        run("/usr/bin/hdiutil", "create", "-volname", "Astro", "-srcfolder", str(volume),
            "-format", "UDZO", "-fs", "HFS+", str(dmg))
        run("/usr/bin/codesign", "--sign", identity, "--timestamp", str(dmg))
        dmg_submission = notarize(dmg, profile)
        run("/usr/bin/xcrun", "stapler", "staple", str(dmg))
        run("/usr/bin/xcrun", "stapler", "validate", str(dmg))
        run("/usr/bin/codesign", "--verify", "--strict", str(dmg))
        run("/usr/bin/hdiutil", "verify", str(dmg))
        run("/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", str(dmg))
        with dmg.open("rb") as source:
            digest = file_digest(source)
        shutil.copyfile(dmg, destination / "Astro.dmg")
        (destination / "SHA256SUMS").write_text(f"{digest}  Astro.dmg\n")
        (destination / "astro.rb").write_text(cask(version, digest))
        metadata = {"version": version, "architecture": "arm64", "minimum_macos": "15.0", "sha256": digest,
                    "notarization": {"app": app_submission, "dmg": dmg_submission}}
        (destination / "release.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    print(f"Verified release files: {destination}\nNotarization uploads went to Apple. Nothing has been published to GitHub or installed.")


def file_digest(source):
    digest = hashlib.sha256()
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Exported Developer ID-signed Astro.app")
    parser.add_argument("--output", type=Path, required=True, help="New directory for the verified DMG and cask")
    parser.add_argument("--notary-profile", default="astro-notary", help="notarytool Keychain profile name")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Packaging requires macOS and Xcode's command-line tools.")
    try:
        package(args.app.expanduser(), args.output.expanduser(), args.notary_profile)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
