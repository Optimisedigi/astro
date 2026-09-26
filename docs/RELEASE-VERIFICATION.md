# Release-preparation verification

26 September 2026. These checks cover source and an **unsigned local validation archive**, not a published installer.

## Observed passes

- `swift run Universe --selftest`: passed after the journal preservation and test-isolation fixes.
- Xcode Release archive for `arm64`, with automatic package resolution disabled and the committed dependency lock: built successfully. Existing compiler/dependency warnings remain; this is not a warning-free-build claim.
- The executable inside `.gg/release-verified/Astro.xcarchive/Products/Applications/Astro.app`, launched with `--selftest`: passed. The tests record notifications and avoid real privacy preflights/calls.
- Archive inspection: `com.universe.app`, minimum macOS `15.0`, `arm64`, microphone/speech/automation usage descriptions, 14 bundled dependency license texts, unchanged package pins and no user-local linked-library paths.
- `python3 -m unittest discover -s scripts -p 'test_*.py'`: seven offline packaging checks passed. Apple responses in these tests are simulated; this is not a notarization test.
- The packager rejected the real unsigned Xcode archive before creating release output or contacting Apple.
- Generated cask text passed Ruby syntax checking. No live Homebrew cask exists yet.
- Six README render states and two journal render states passed.
- `plutil -lint Info.plist Universe.entitlements` and `bash -n install.sh`: passed. ShellCheck was not installed, so the legacy developer installer was not ShellCheck-verified.
- A limited credential-pattern scan covered Git history and non-ignored working-tree files; no matches for the checked private-key/provider-token/GitHub-token/AWS-key patterns. This is not a comprehensive secret scan.

## Design evidence

The release sequence was checked against Apple's notarization guidance, Homebrew's tap/cask documentation, and the real `scripts/release_dmg.sh` in `JerryZLiu/Dayflow` (refreshed in the local code corpus). Astro deliberately omits unsigned/no-notarization release shortcuts and generates its cask only after native verification and final checksum calculation.

## Still required

Developer ID export/signing, Apple's notarization service, ticket stapling, the final signed-DMG Gatekeeper check, a browser-downloaded install on a clean Mac, Homebrew install/audit, real permission/voice flows and an upgrade check with backed-up sample data. None of those is claimed as verified here. See [RELEASING.md](RELEASING.md) and [COMPLIANCE.md](../COMPLIANCE.md).
