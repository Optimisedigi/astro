# Signed macOS releases

Astro's first public installer targets **Apple silicon (arm64), macOS 15+**. Users install a DMG or a Homebrew cask; only the maintainer needs Xcode. Do not publish an unsigned validation archive or advertise a download that does not exist.

## One-time signing setup

1. In **Xcode → Settings → Accounts**, select the Apple Developer team. Under **Manage Certificates**, create or import a **Developer ID Application** certificate, including its private key. An Apple Development certificate is not a substitute.
2. Confirm that `security find-identity -v -p codesigning` lists that Developer ID identity. Keep private keys out of the repository.
3. In your own Terminal, run the following interactive command and provide your Apple account, team and app-specific password when prompted. Do not paste credentials into chat or commit them:

   ```sh
   xcrun notarytool store-credentials astro-notary
   ```

   The credentials stay in Keychain. The packaging script receives only the profile name.

Signing setup is currently the handoff required before a public binary can be prepared. Apple's signing/notarization service, Gatekeeper acceptance, installation on another Mac and Homebrew installation must still be exercised on the final signed artifact.

## Build the reviewed source

Commit and review the source before making a release tag. Keep the source commit, app version and release tag aligned. Use a clean checkout and the committed dependency lock; do not update dependencies during a release.

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
swift run Universe --selftest
xcodegen generate
mkdir -p Universe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Release/Package.resolved Universe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -project Universe.xcodeproj -scheme Universe \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath .gg/release/Astro.xcarchive \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  archive ARCHS=arm64 ONLY_ACTIVE_ARCH=NO
```

The archive build uses the developer signing configuration. Open the archive in Xcode's Organizer, choose **Distribute App → Custom → Developer ID**, and export the Developer ID-signed app to `.gg/release/export/Astro.app`. Xcode must sign embedded frameworks as well as the app. Do not use `codesign --deep` as a substitute for exporting correctly signed nested code.

Run `.gg/release/export/Astro.app/Contents/MacOS/Astro --selftest` as well: the packaged build includes native dependencies that the lightweight SwiftPM build does not. Test mode records reminder delivery and avoids OS privacy preflights; it does not test real microphone permission or live calls.

The Release configuration enables hardened runtime. Keep the microphone entitlement and the existing bundle ID `com.universe.app`. Do not add `get-task-allow` to distribution builds. `Release/Licenses` is bundled with the app; when dependencies change, update their lock and upstream notices together.

An unsigned compile check may add `CODE_SIGNING_ALLOWED=NO` to the archive command, but that archive is **not a distributable app** and the packager will reject it.

## Package and notarize

```sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' .gg/release/export/Astro.app/Contents/Info.plist)
python3 scripts/package_release.py \
  --app .gg/release/export/Astro.app \
  --output ".gg/dist/v$VERSION" \
  --notary-profile astro-notary
```

The output directory must be new. On failure, inspect the error and use a new output directory for the retry; never reuse or overwrite a published release.

The script:

- Checks bundle ID, version, minimum macOS, arm64 architecture, license resources, Developer ID signature, hardened runtime, timestamp and relevant entitlements.
- Copies the app to temporary staging, submits it to Apple, requires **Accepted**, attaches the notarization ticket and checks Gatekeeper's execution assessment.
- Creates a compressed **Astro.dmg** containing **Astro.app** and an **Applications** shortcut. Signs and notarizes the DMG, attaches its ticket, then verifies its structure and Gatekeeper assessment.
- Produces `Astro.dmg`, `SHA256SUMS`, `release.json` and `astro.rb` only after those checks. The cask contains the exact final DMG checksum, not `:no_check`.
- Uploads the staged app and DMG to Apple for notarization, but never publishes a GitHub release, installs the app, deletes user data, changes Gatekeeper or modifies the source app.

No signing or notarization failure has an unsigned fallback. Failed Apple submissions can be investigated with `xcrun notarytool log` using their submission ID and the same Keychain profile.

## Validate before publishing

On a separate Mac or clean user account, download the final artifact through a browser so macOS applies its normal download checks. Verify:

- The DMG opens, and Astro can be dragged to Applications and launched without disabling Gatekeeper.
- Microphone, speech recognition and automation permission prompts are understandable; granting and denying permissions both work.
- Option-Space opens the panel; the Ask anything section can be dragged without breaking clicks, and dragging inside the Ask anything text box selects text instead.
- The panel's mic button pauses and resumes listening without changing the Microphone switch in Voice Settings.
- Chat, image attachments, image creation, journal save/reload, reminders and the selected live voice engine work with the test account.
- A connection failure and a cancelled call/tool return to a usable state.
- The app works without Xcode installed. Kokoro's optional model downloads and provider sign-in are tested separately; they are not bundled account access.
- An upgrade preserves existing chats, journal and memory. Signing changes can cause macOS to request access again; do not reset or delete the user's data to avoid a prompt.

Read [the release exposure notes](../COMPLIANCE.md) before general distribution. Automated tests do not verify provider account terms, full accessibility, or real-service behavior.

## Publish the DMG, then enable Homebrew

After verification and signing setup, create a version tag for the reviewed source and push that tag. For example, `v0.1.0` belongs to the source that built version `0.1.0`, not to a later documentation-only commit.

Create a draft GitHub release for that tag and upload the three public files:

```sh
gh release create "v$VERSION" \
  ".gg/dist/v$VERSION/Astro.dmg" \
  ".gg/dist/v$VERSION/SHA256SUMS" \
  ".gg/dist/v$VERSION/release.json" \
  --repo Optimisedigi/astro --verify-tag --draft \
  --title "Astro $VERSION" --generate-notes
```

Check the uploaded files and release notes, then publish the draft. Do not replace an existing version's DMG with different bytes; publish a new version instead.

Copy the generated `astro.rb` into the repository as `Casks/astro.rb`. Check it with `brew style Casks/astro.rb` and `brew audit --cask --online Casks/astro.rb`, then commit and push the cask. No cask is committed before there is a real signed download and checksum.

The existing repository doubles as the custom tap, so no second repository is required:

```sh
brew tap optimisedigi/astro https://github.com/Optimisedigi/astro
brew install --cask optimisedigi/astro/astro
```

Test this installation on a clean Mac as well. The cask deliberately has no `zap` deletion list: uninstalling the app does not erase chats, journal, memory or generated images.

Finally, replace the README's pending-release message with a direct link to `https://github.com/Optimisedigi/astro/releases/latest/download/Astro.dmg`, and remove the pending label from the Homebrew commands. Never enable that link before the asset is public.

## References

- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Homebrew: Creating and maintaining a tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Homebrew: Cask cookbook](https://docs.brew.sh/Cask-Cookbook)
