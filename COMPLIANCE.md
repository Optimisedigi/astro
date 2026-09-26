# Release exposure notes

Snapshot: 26 September 2026 · GG Coder compliance-guard · **Engineering guidance, not legal advice.**

Scope: first-DMG preparation from source based on commit `2c1960b`, including the local feature changes reviewed in this release-preparation commit. This is not a completed public-launch or legal review. No signed installer has been published by this pass.

## Exposure profile

- **Confirmed:** native macOS client; people connect their own AI provider accounts. Chat, images, live audio and selected memory are sent to the relevant provider. Journal formatting sends the entry being formatted; ordinary journal storage is separate from chat memory.
- **Confirmed:** credentials use macOS Keychain. Chats, journal and memory are local files; generated images are also saved in `~/Pictures/Astro`, as disclosed in the README.
- **Confirmed:** agent tools can execute commands with the user's permissions. This is not a sandboxed viewer for hostile instructions. Only grant the system permissions needed for the tasks you intend Astro to perform.
- **Confirmed:** this release work adds no analytics, payment collection, shared database, public upload service or email campaign.
- **Assumed:** the eventual GitHub download is reachable worldwide; minors could obtain it. The operator's legal entity, target countries and intended age policy have not been supplied. These facts need an owner decision before a general-public launch.

## Findings and handoffs

| ID | Priority | Evidence | Status / next action |
|---|---|---|---|
| R-01 | Release blocker | RUNTIME: only development/local signing identities were found; no Developer ID Application identity was available. | Obtain Developer ID signing and a notarytool Keychain profile. Do not publish an unsigned fallback or a fake download link. |
| R-02 | Data integrity | RUNTIME: a regression test reproduced replacement of an unreadable journal day. | The new-day write now refuses to replace an existing file that was not loaded; the UI retains the draft on save failure. This is not a backup system. |
| R-03 | Distribution notices | CODE: the Xcode dependency lock and upstream notices are now in `Release/`; `project.yml` includes the notices in the app. | Keep notices and the lock aligned on updates. No blanket licence clearance is claimed for artwork, sounds or downloaded model weights. |
| R-04 | LAWYER / owner review | CODE: ChatGPT/GPT-Live and other provider account integrations are present. | Verify that distributing these integrations is permitted under the applicable providers' current terms. Technical access or a working login is not permission to redistribute an integration. |
| R-05 | LAWYER / owner review | DEDUCED: no operator-specific privacy notice, audience/age policy or distribution licence has been supplied. | Decide the operator, intended audience and permitted reuse. Review privacy notice needs for this client and third-party processing; do not invent a company, retention promise or licence grant. |
| R-06 | Before public launch | CODE: generated-media features and live speech are present. | Review jurisdiction-specific AI/media disclosure and provenance requirements, and preserve provider markings. Account permission and generated-media labelling are separate questions. |
| R-07 | Before public launch | CODE: the app exposes native forms, icon controls and voice UI. | Complete keyboard, VoiceOver, focus, contrast and reduced-motion checks on the signed build. README screenshots have text alternatives; that does not establish app accessibility. |
| R-08 | Recovery limitation | CODE: user-entered data is local; this pass does not add automatic backup/restore. | Users should include Astro's Application Support data and Pictures/Astro in their Mac backups. No restore drill or recovery-time guarantee was performed. |

## Implemented controls in this pass

- No private signing key or notarization password is accepted by the packaging script; Apple's tool reads the named Keychain profile.
- The packager refuses unsigned/development-signed apps, missing hardened runtime, debugging entitlement, missing microphone entitlement and incompatible app metadata. It requires Apple's Accepted result, stapled tickets and native verification before writing the DMG/cask outputs.
- The Homebrew cask is generated from the actual final checksum. There is no `:no_check`, Gatekeeper bypass or data-deleting `zap` stanza.
- Signing files and generated release output are ignored by Git. No credential-bearing CI workflow was introduced.
- Public copy distinguishes a pending installer from a downloadable release and corrects the requirement to Apple silicon/macOS 15+.
- Archive self-tests do not request live privacy permissions or deliver real reminders; the focus test explicitly uses typing mode rather than starting a live call.
- A limited historical and working-tree scan found no matches for the checked private-key, provider-token, GitHub-token and AWS-key patterns. This is not a comprehensive secret audit.

## Not verified by this preparation

Apple notarization and signing, Gatekeeper opening a browser-downloaded DMG, installation on a separate Mac, Homebrew installation, provider contract permission, a complete native accessibility audit, real-service failure/cancellation behavior, and recovery from a lost Mac remain unverified. The user's report that live voice works is not an independent live-service test by this pass.

No regulated health, financial, hiring, housing, payment or public-content platform feature was introduced by this work. Applicable legal obligations still depend on the eventual operator, users, use cases and jurisdictions; this document is not a conclusion that US, EU or UK requirements have been satisfied.
