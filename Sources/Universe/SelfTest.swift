import AVFoundation
import AppKit
import CryptoKit
import Foundation

/// Offline proof that the agent loop executes tools end-to-end (no API key needed).
/// A scripted fake model requests write → read → bash; the real tools run on disk.
/// Run: `Universe --selftest`
enum SelfTest {
    @MainActor
    static func run() async -> Bool {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "✅ \(label)" : "❌ \(label)")
            if !condition { failures += 1 }
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("universe-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // 1. Direct tool execution
        let registry = ToolRegistry.shared
        let writeResult = await registry.run(name: "write", input: [
            "file_path": "hello.txt", "content": "hello from the agent loop",
        ], workingDirectory: workspace)
        check(writeResult.contains("Wrote"), "write tool: \(writeResult)")

        let readResult = await registry.run(name: "read", input: ["file_path": "hello.txt"], workingDirectory: workspace)
        check(readResult.contains("hello from the agent loop"), "read tool returns written content")

        let editResult = await registry.run(name: "edit", input: [
            "file_path": "hello.txt", "old_text": "hello", "new_text": "goodbye",
        ], workingDirectory: workspace)
        check(editResult.contains("Edited"), "edit tool: \(editResult)")

        let bashResult = await registry.run(name: "bash", input: [
            "command": "cat hello.txt",
        ], workingDirectory: workspace)
        check(bashResult.contains("exit 0") && bashResult.contains("goodbye from the agent loop"),
              "bash tool sees edited file")

        let escapeResult = await registry.run(name: "read", input: ["file_path": "/etc/passwd"], workingDirectory: workspace)
        check(escapeResult.contains("escapes workspace"), "path escape outside workspace is blocked")

        // Sibling-prefix attack: absolute path whose string merely starts with the workspace path
        let sibling = workspace.deletingLastPathComponent().appendingPathComponent(workspace.lastPathComponent + "-evil", isDirectory: true)
        try? "secret".write(to: sibling.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let siblingResult = await registry.run(name: "read", input: [
            "file_path": sibling.appendingPathComponent("s.txt").path,
        ], workingDirectory: workspace)
        check(siblingResult.contains("escapes workspace"), "sibling-prefix escape is blocked")

        // Symlink attack: link inside workspace pointing outside must not pass
        try? FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("link.txt"),
            withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
        )
        let symlinkResult = await registry.run(name: "read", input: ["file_path": "link.txt"], workingDirectory: workspace)
        check(symlinkResult.contains("escapes workspace"), "symlink escape is blocked")

        // 2. Full agent loop with a fake model: turn 1 requests write, turn 2 confirms.
        var turns = 0
        let fakeProvider: EventStreamProvider = { messages, _ in
            AsyncThrowingStream { continuation in
                turns += 1
                if turns == 1 {
                    continuation.yield(.toolUse(id: "toolu_test_1", name: "write", input: [
                        "file_path": "loop.txt", "content": "written by the agent loop",
                    ]))
                    continuation.yield(.stop(reason: "tool_use"))
                } else {
                    // Verify the loop fed back a tool_result
                    let lastMessage = messages.last?["content"] as? [[String: Any]]
                    let resultText = lastMessage?.first?["content"] as? String ?? ""
                    if resultText.contains("Wrote") {
                        continuation.yield(.text("File created."))
                    } else {
                        continuation.yield(.text("MISSING TOOL RESULT"))
                    }
                    continuation.yield(.stop(reason: "end_turn"))
                }
                continuation.finish()
            }
        }

        var streamedText = ""
        var toolActivities: [ToolActivity] = []
        let loop = AgentLoop(workspace: workspace)
        do {
            try await loop.run(
                apiMessages: [["role": "user", "content": [["type": "text", "text": "make a file"]]]],
                streamProvider: fakeProvider,
                onText: { streamedText += $0 },
                onToolActivity: { toolActivities.append($0) }
            )
        } catch {
            check(false, "agent loop threw: \(error.localizedDescription)")
        }

        check(turns == 2, "loop ran 2 turns (tool_use → end_turn)")
        check(toolActivities.contains { if case .started(_, "write", _) = $0 { return true }; return false },
              "loop dispatched the write tool")
        check(toolActivities.contains { if case .finished(_, let failed) = $0 { return !failed }; return false },
              "loop reported the write tool finishing successfully")
        check(toolActivities.contains { if case .started(_, _, let detail) = $0 { return detail == "loop.txt" }; return false },
              "tool row shows the file it touched")
        check(ToolActivity.looksLikeFailure("Error: nope") && !ToolActivity.looksLikeFailure("Wrote 3 lines"),
              "tool failure detection")
        check(streamedText == "File created.", "loop fed tool_result back to the model")
        let onDisk = (try? String(contentsOf: workspace.appendingPathComponent("loop.txt"), encoding: .utf8)) ?? ""
        check(onDisk == "written by the agent loop", "file exists on disk with model-requested content")

        // 3. Schedule parsing + schedule tools
        await runScheduleChecks(check: check)

        // 4. Markdown scanner
        runMarkdownChecks(check: check)

        // 5. OAuth sign-in (pure logic only — no network)
        await runOAuthChecks(check: check)

        // 6. Models, permissions and speech settings
        await runSettingsChecks(check: check)

        // 7. Onboarding flag logic
        runOnboardingChecks(check: check)

        // 8. Task and skill stores
        runStoreChecks(check: check)

        // 9. Clipboard history + panel tools
        await runPanelToolChecks(check: check)

        // 10. Mood menubar icon
        await runMoodIconChecks(check: check)

        // 11. Notch notifications
        await runNotchChecks(check: check)

        print(failures == 0 ? "\nSELFTEST PASSED" : "\nSELFTEST FAILED (\(failures) failures)")
        return failures == 0
    }

    @MainActor
    static func runStoreChecks(check: (Bool, String) -> Void) {
        // Task store
        let taskStore = TaskStore.shared
        let originalLists = taskStore.taskLists

        let list = taskStore.createList(title: "Selftest List")
        check(taskStore.taskLists.contains { $0.id == list.id }, "tasks: createList persists")
        check(taskStore.taskLists.first?.title == "Selftest List", "tasks: createList sets title")

        taskStore.addItem(to: list.id, title: "Item 1")
        taskStore.addItem(to: list.id, title: "Item 2")
        let updated = taskStore.taskLists.first { $0.id == list.id }
        check(updated?.items.count == 2, "tasks: addItem appends")
        check(updated?.items.first?.title == "Item 1", "tasks: addItem sets title")

        taskStore.toggleItem(listID: list.id, itemID: updated!.items[0].id)
        let toggled = taskStore.taskLists.first { $0.id == list.id }
        check(toggled?.items.first?.isCompleted == true, "tasks: toggleItem marks complete")
        check(toggled?.completedCount == 1, "tasks: completedCount reflects toggle")

        taskStore.deleteItem(listID: list.id, itemID: updated!.items[1].id)
        let deleted = taskStore.taskLists.first { $0.id == list.id }
        check(deleted?.items.count == 1, "tasks: deleteItem removes")

        taskStore.delete(id: list.id)
        check(!taskStore.taskLists.contains { $0.id == list.id }, "tasks: delete removes")

        // Skill store
        let skillStore = SkillStore.shared
        let originalSkills = skillStore.skills

        let skill = Skill(id: UUID(), name: "Selftest Skill", description: "A test skill",
                          content: "Do the thing.", source: .global, createdAt: Date(), updatedAt: Date())
        skillStore.save(skill)
        check(skillStore.skills.contains { $0.name == "Selftest Skill" }, "skills: save persists")

        let found = skillStore.skill(named: "Selftest Skill")
        check(found?.content == "Do the thing.", "skills: skill(named:) finds by name")

        let searched = skillStore.search("Selftest")
        check(searched.count == 1, "skills: search finds by name")

        skillStore.delete(id: skill.id)
        check(!skillStore.skills.contains { $0.name == "Selftest Skill" }, "skills: delete removes")

        // Restore original state
        for list in taskStore.taskLists { taskStore.delete(id: list.id) }
        for list in originalLists { taskStore.save(list) }
    }

    @MainActor
    static func runNotchChecks(check: (Bool, String) -> Void) async {
        // The notch path is pure geometry: closed, non-empty, flush with the top edge.
        let rect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let path = NotchShapePath.path(in: rect)
        check(!path.isEmpty, "notch: path draws")
        check(path.boundingBox.minY == 0, "notch: flat top is flush with y=0")
        check(abs(path.boundingBox.width - rect.width) < 0.5, "notch: path spans the full width")

        // Larger radii still produce a valid closed path (animation endpoints).
        let expanded = NotchShapePath.path(in: CGRect(x: 0, y: 0, width: 380, height: 100),
                                           topCornerRadius: 14, bottomCornerRadius: 20)
        check(!expanded.isEmpty && expanded.boundingBox.height == 100, "notch: expanded path valid")

        // Screen extension must return a sane fallback on any display.
        if let screen = NSScreen.main {
            let size = screen.notchSize
            check(size.width > 0 && size.height > 0, "notch: notchSize positive on this display")
            check(screen.notchFrame.midX == screen.frame.midX, "notch: frame is centered")
        }

        // Overlay tracker: active on first show, inactive only after debounce.
        NotchOverlayTracker.overlayDidShow()
        check(NotchOverlayTracker.isActive, "notch: tracker active while overlay shown")
        NotchOverlayTracker.overlayDidHide()
        check(NotchOverlayTracker.isActive, "notch: tracker debounces before going inactive")
        try? await Task.sleep(for: .milliseconds(600))
        check(!NotchOverlayTracker.isActive, "notch: tracker inactive after debounce")
    }

    @MainActor
    static func runMoodIconChecks(check: (Bool, String) -> Void) async {
        // Every mood must draw a non-blank template image.
        for mood in MenuBarMood.Mood.allCases {
            let image = MenuBarIcon.create(mood: mood, animationFrame: false)
            check(image.isTemplate, "mood icon: \(mood.rawValue) is a template image")
            check(image.size == NSSize(width: 18, height: 18), "mood icon: \(mood.rawValue) is 18pt")
            // Rasterise and confirm ink.
            var hasInk = false
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                outer: for y in 0..<rep.pixelsHigh where y % 2 == 0 {
                    for x in 0..<rep.pixelsWide where x % 2 == 0 {
                        if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 { hasInk = true; break outer }
                    }
                }
            }
            check(hasInk, "mood icon: \(mood.rawValue) draws visible pixels")
        }

        // Animation frames differ for animated moods (antenna/mouth move).
        func png(_ mood: MenuBarMood.Mood, _ frame: Bool) -> Data? {
            let image = MenuBarIcon.create(mood: mood, animationFrame: frame)
            return image.tiffRepresentation
        }
        check(png(.thinking, false) != png(.thinking, true), "mood icon: thinking animates between frames")
        check(png(.speaking, false) != png(.speaking, true), "mood icon: speaking animates between frames")
        check(png(.afternoon, false) == png(.afternoon, true), "mood icon: passive mood ignores animation frame")

        // Activity moods override time-of-day; clearing restores it.
        let moodState = MenuBarMood.shared
        moodState.setActivity(.thinking)
        check(moodState.mood == .thinking, "mood: activity overrides time of day")
        moodState.setActivity(.error)
        check(moodState.mood == .error, "mood: error overrides other activity")
        moodState.setActivity(nil)
        check(!moodState.mood.isActivity, "mood: clearing activity restores time of day")
        check(MenuBarMood.Mood.allCases.count == 10, "mood: all 10 Tama moods present")

        // Mascot state machine (CLI build exercises the dependency-free path).
        check(MascotState.allCases.count == 6, "mascot: all 6 Tama states present")
        let mascot = MascotController.shared
        mascot.setState(.waiting)
        check(mascot.currentState == .waiting, "mascot: setState applies")
        mascot.notifyKeystroke()
        check(mascot.currentState == .typing, "mascot: keystroke enters typing")
        mascot.setState(.idle)
        check(mascot.currentState == .idle, "mascot: returns to idle")

        // Squircle icons used in list rows.
        let session = MenuBarIcon.sessionIcon(mood: .afternoon)
        let symbol = MenuBarIcon.symbolIcon(name: "checklist")
        check(session.size == NSSize(width: 28, height: 28), "mood icon: session squircle is 28pt")
        check(symbol.size == NSSize(width: 28, height: 28), "mood icon: symbol squircle is 28pt")
    }

    @MainActor
    static func runPanelToolChecks(check: (Bool, String) -> Void) async {
        let store = ClipboardStore.shared
        let before = store.entries

        func entry(_ text: String) -> ClipboardEntry {
            ClipboardEntry(id: UUID(), timestamp: Date(), contentType: .text,
                           textContent: text, imageData: nil, fileURL: nil,
                           sourceAppName: "Selftest", sourceAppBundle: nil)
        }

        store.add(entry("clipboard selftest alpha"))
        check(store.entries.first?.textContent == "clipboard selftest alpha", "clipboard: add inserts at front")
        let countAfterFirst = store.entries.count
        store.add(entry("clipboard selftest alpha"))
        check(store.entries.count == countAfterFirst, "clipboard: identical text is deduplicated")

        let long = ClipboardEntry(id: UUID(), timestamp: Date(), contentType: .text,
                                  textContent: String(repeating: "word ", count: 30),
                                  imageData: nil, fileURL: nil, sourceAppName: nil, sourceAppBundle: nil)
        check(long.preview.count <= 51 && long.preview.hasSuffix("…"), "clipboard: preview truncates at word boundary")

        let fileEntry = ClipboardEntry(id: UUID(), timestamp: Date(), contentType: .fileURL,
                                       textContent: nil, imageData: nil, fileURL: "/tmp/example/report.pdf",
                                       sourceAppName: nil, sourceAppBundle: nil)
        check(fileEntry.preview == "report.pdf", "clipboard: file preview shows filename")
        check(fileEntry.copyableText == "/tmp/example/report.pdf", "clipboard: file copies its path")

        check(store.search(query: "selftest alpha").count == 1, "clipboard: search matches preview")
        check(store.search(query: "zzz-no-match").isEmpty, "clipboard: search misses cleanly")

        if let added = store.entries.first(where: { $0.textContent == "clipboard selftest alpha" }) {
            store.delete(added)
        }
        check(store.entries.count == before.count, "clipboard: delete removes the entry")

        // Panel tool registry (Night Shift may be absent on unsupported hardware)
        let registry = PanelToolRegistry.shared
        check(registry.allTools.contains { $0 is ClipboardHistoryTool }, "tools: clipboard history registered")
        check(registry.allTools.contains { $0 is KeepAwakeTool }, "tools: keep awake registered")
        check(registry.search(query: "clipboard").count == 1, "tools: search filters by name")
        check(registry.search(query: "").count == registry.allTools.count, "tools: empty query returns all")

        // Keep Awake really takes and releases a power assertion.
        if let keepAwake = registry.allTools.first(where: { $0 is KeepAwakeTool }) as? KeepAwakeTool {
            keepAwake.toggle()
            check(keepAwake.isEnabled, "tools: keep awake enables")
            keepAwake.toggle()
            check(!keepAwake.isEnabled, "tools: keep awake releases")
        }
    }

    @MainActor
    static func runOnboardingChecks(check: (Bool, String) -> Void) {
        // Save and restore the real flag so the selftest doesn't clobber the user's state.
        let saved = UserDefaults.standard.bool(forKey: OnboardingModel.defaultsKey)

        OnboardingModel.reset()
        check(!UserDefaults.standard.bool(forKey: OnboardingModel.defaultsKey),
              "onboarding: reset clears the flag")

        let model = OnboardingModel(fixed: [
            .accessibility: .granted, .fullDisk: .granted, .microphone: .granted,
            .speech: .granted, .appManagement: .granted, .screenRecording: .granted,
            .notifications: .granted, .browser: .ready("Safari detected."),
        ])
        check(model.outstanding.isEmpty, "onboarding: all granted → no outstanding steps")
        check(model.isComplete, "onboarding: all granted → auto-completes")
        check(UserDefaults.standard.bool(forKey: OnboardingModel.defaultsKey),
              "onboarding: complete() persists the flag")

        OnboardingModel.reset()
        let mixed = OnboardingModel(fixed: [
            .accessibility: .denied, .fullDisk: .denied, .microphone: .granted,
            .speech: .granted, .appManagement: .denied, .screenRecording: .granted,
            .notifications: .granted, .browser: .ready("Safari detected."),
        ])
        check(mixed.outstanding.count == 2, "onboarding: 2 unsatisfied required permissions")
        check(mixed.outstanding.allSatisfy { !$0.optional }, "onboarding: outstanding are required only")
        check(mixed.currentPermission?.kind == .accessibility, "onboarding: starts at first outstanding")
        check(!mixed.isLastStep, "onboarding: not last step with 3 outstanding")

        mixed.advance()
        check(mixed.currentPermission?.kind == .fullDisk, "onboarding: advances to next outstanding")
        mixed.advance()
        check(mixed.isLastStep, "onboarding: last step after advancing past all but one")
        mixed.complete()
        check(mixed.isComplete, "onboarding: complete() marks as done")
        check(UserDefaults.standard.bool(forKey: OnboardingModel.defaultsKey),
              "onboarding: complete() persists the flag")

        // Optional-only outstanding: skip is allowed.
        OnboardingModel.reset()
        let optionalOnly = OnboardingModel(fixed: [
            .accessibility: .granted, .fullDisk: .granted, .microphone: .granted,
            .speech: .granted, .appManagement: .denied, .screenRecording: .granted,
            .notifications: .granted, .browser: .denied,
        ])
        check(optionalOnly.outstanding.isEmpty, "onboarding: optional-only → no required outstanding")
        check(optionalOnly.isComplete, "onboarding: optional-only → auto-completes")
        optionalOnly.skipCurrent()
        check(optionalOnly.isComplete, "onboarding: skip on optional completes")

        // Restore the user's real flag.
        UserDefaults.standard.set(saved, forKey: OnboardingModel.defaultsKey)
    }

    @MainActor
    static func runSettingsChecks(check: (Bool, String) -> Void) async {
        // Model catalog
        let ids = ModelRegistry.models.map(\.id)
        check(Set(ids).count == ids.count, "models: no duplicate ids")
        check(ModelRegistry.models.allSatisfy { $0.contextWindow > 0 && $0.maxOutputTokens > 0 },
              "models: every model declares real limits")
        check(ModelRegistry.selectableModels.allSatisfy { $0.provider.isImplemented },
              "models: only reachable providers are selectable")
        check(!ModelRegistry.selectableModels.isEmpty, "models: at least one selectable model")
        check(ModelRegistry.models(for: .anthropic).contains { $0.id == "claude-sonnet-5" },
              "models: new Sonnet 5 present")
        check(ModelRegistry.models(for: .gemini).contains { $0.id == "gemini-3-pro-preview" },
              "models: new Gemini 3 Pro present")
        check(AIProvider.allCases.allSatisfy(\.isImplemented),
              "models: all providers have a sign-in path")

        let registry = ModelRegistry.shared
        let original = registry.selectedModelID
        check(ModelRegistry.selectableModels.contains { $0.id == original }, "models: default selection is reachable")
        registry.selectedModelID = "claude-haiku-4-5-20251001"
        check(registry.selectedModel.name == "Claude Haiku 4.5", "models: selection resolves to the right model")
        registry.selectedModelID = original

        // Permissions: every row must map to a real Settings pane and describe itself.
        let checker = PermissionsChecker()
        await checker.refresh()
        check(checker.permissions.count == PermissionsChecker.Kind.allCases.count, "permissions: every kind has a row")
        check(checker.permissions.allSatisfy { !$0.title.isEmpty && !$0.reason.isEmpty },
              "permissions: every row explains itself")
        check(PermissionsChecker.Kind.allCases.allSatisfy { URL(string: PermissionsChecker.settingsURL(for: $0)) != nil },
              "permissions: every kind deep-links somewhere valid")
        check(PermissionsChecker.settingsURL(for: .accessibility).hasSuffix("Privacy_Accessibility"),
              "permissions: accessibility pane link")
        check(PermissionsChecker.settingsURL(for: .fullDisk).hasSuffix("Privacy_AllFiles"),
              "permissions: full disk pane link")
        check(PermissionsChecker.Status.granted.isSatisfied && PermissionsChecker.Status.ready("x").isSatisfied,
              "permissions: granted and ready count as satisfied")
        check(!PermissionsChecker.Status.denied.isSatisfied && !PermissionsChecker.Status.unknown.isSatisfied,
              "permissions: denied and unknown are never claimed as granted")
        check(checker.outstanding.allSatisfy { !$0.optional }, "permissions: optional rows never block onboarding")

        // Speech rate mapping drives the speed slider.
        check(SpeechService.rate(for: 1.0) == AVSpeechUtteranceDefaultSpeechRate, "speech: 1x is the system default rate")
        check(SpeechService.rate(for: 2.0) > SpeechService.rate(for: 1.0), "speech: faster is faster")
        check(SpeechService.rate(for: 0.5) < SpeechService.rate(for: 1.0), "speech: slower is slower")
        check(SpeechService.rate(for: 9) <= AVSpeechUtteranceMaximumSpeechRate, "speech: out-of-range speed is clamped high")
        check(SpeechService.rate(for: -1) >= AVSpeechUtteranceMinimumSpeechRate, "speech: out-of-range speed is clamped low")
        check(SpeechService.availableVoices.allSatisfy { $0.language.hasPrefix("en") }, "speech: voice list is English only")
    }

    static func runOAuthChecks(check: (Bool, String) -> Void) async {
        let login = AnthropicOAuth.beginLogin()
        let items = URLComponents(url: login.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { items.first { $0.name == name }?.value }

        check(login.url.host == "claude.ai" && login.url.path == "/oauth/authorize", "oauth: authorize endpoint")
        check(param("client_id") == AnthropicOAuth.clientID, "oauth: client id matches the learning-ai site")
        check(param("redirect_uri") == AnthropicOAuth.redirectURI, "oauth: redirect uri matches the site")
        check(param("scope") == AnthropicOAuth.scopes, "oauth: scopes match the site")
        check(param("response_type") == "code" && param("code") == "true", "oauth: paste-code response type")
        check(param("code_challenge_method") == "S256", "oauth: PKCE uses S256")

        // The challenge must be the base64url SHA-256 of the verifier, unpadded.
        let expected = Data(SHA256.hash(data: Data(login.verifier.utf8))).base64URLEncodedString()
        check(param("code_challenge") == expected, "oauth: challenge is SHA-256 of the verifier")
        check(!expected.contains("=") && !expected.contains("+") && !expected.contains("/"),
              "oauth: challenge is base64url without padding")

        // Verifier and state must be unguessable and never repeat between attempts.
        let second = AnthropicOAuth.beginLogin()
        check(login.verifier != second.verifier && login.state != second.state, "oauth: verifier and state are fresh per attempt")
        check(login.verifier.count >= 43 && login.state.count >= 43, "oauth: 256 bits of entropy per secret")

        // Paste parsing: every shape a user can bring back.
        let plain = try? AnthropicOAuth.parsePastedCode("abc123")
        check(plain?.code == "abc123" && plain?.state == nil, "oauth: bare code parses")
        let hashed = try? AnthropicOAuth.parsePastedCode("  abc123#st4te \n")
        check(hashed?.code == "abc123" && hashed?.state == "st4te", "oauth: code#state parses and trims")
        let fromURL = try? AnthropicOAuth.parsePastedCode("https://platform.claude.com/oauth/code/callback?code=xyz&state=s1")
        check(fromURL?.code == "xyz" && fromURL?.state == "s1", "oauth: whole callback URL parses")
        check((try? AnthropicOAuth.parsePastedCode("")) == nil, "oauth: empty paste rejected")
        check((try? AnthropicOAuth.parsePastedCode("not a code!")) == nil, "oauth: junk paste rejected")
        check((try? AnthropicOAuth.parsePastedCode(String(repeating: "a", count: 5000))) == nil, "oauth: oversized paste rejected")

        // A code carrying someone else's state must never be exchanged.
        do {
            try await AnthropicOAuth.completeLogin(pastedCode: "abc123#wrongstate", pending: login)
            check(false, "oauth: state mismatch blocks the exchange")
        } catch let error as AnthropicOAuth.OAuthError {
            check(error == .stateMismatch, "oauth: state mismatch blocks the exchange")
        } catch {
            check(false, "oauth: state mismatch blocks the exchange")
        }

        check(AnthropicOAuth.constantTimeEquals("abc", "abc"), "oauth: state compare accepts a match")
        check(!AnthropicOAuth.constantTimeEquals("abc", "abd"), "oauth: state compare rejects a mismatch")
        check(!AnthropicOAuth.constantTimeEquals("abc", "abcd"), "oauth: state compare rejects a length mismatch")

        // Expiry maths drives refresh; get it wrong and sessions die or never renew.
        var tokens = AnthropicOAuth.Tokens(json: ["access_token": "t", "refresh_token": "r", "expires_in": 3600.0])
        check(tokens?.accessToken == "t" && tokens?.refreshToken == "r", "oauth: token response decodes")
        check(tokens?.needsRefresh == false && tokens?.isExpired == false, "oauth: fresh token is not refreshed")
        tokens?.expiresAt = Date().addingTimeInterval(60)
        check(tokens?.needsRefresh == true && tokens?.isExpired == false, "oauth: near-expiry token refreshes early")
        tokens?.expiresAt = Date().addingTimeInterval(-1)
        check(tokens?.isExpired == true, "oauth: past-expiry token is expired")
        check(AnthropicOAuth.Tokens(json: ["refresh_token": "r"]) == nil, "oauth: response without an access token is rejected")

        // Keychain round trip, then a clean sign-out.
        let hadSession = AnthropicOAuth.isSignedIn
        if !hadSession, let sample = AnthropicOAuth.Tokens(json: ["access_token": "selftest", "expires_in": 3600.0]) {
            AnthropicOAuth.TokenStore.save(sample)
            check(AnthropicOAuth.TokenStore.load()?.accessToken == "selftest", "oauth: tokens round-trip through the Keychain")
            AnthropicOAuth.signOut()
            check(!AnthropicOAuth.isSignedIn, "oauth: sign-out clears the Keychain")
        }
    }

    static func runMarkdownChecks(check: (Bool, String) -> Void) {
        func kinds(_ source: String) -> [String] {
            Markdown.parse(source).map { block in
                switch block {
                case .paragraph: return "paragraph"
                case .heading: return "heading"
                case .bullet: return "bullet"
                case .numbered: return "numbered"
                case .checklist: return "checklist"
                case .quote: return "quote"
                case .code: return "code"
                case .table: return "table"
                case .rule: return "rule"
                }
            }
        }

        check(kinds("# Title\n\nHello **world**.") == ["heading", "paragraph"], "markdown: heading + paragraph")
        check(kinds("- one\n- two") == ["bullet"], "markdown: bullet list")
        check(kinds("1. one\n2. two") == ["numbered"], "markdown: numbered list")
        check(kinds("- [ ] todo\n- [x] done") == ["checklist"], "markdown: checklist")
        check(kinds("> quoted") == ["quote"], "markdown: block quote")
        check(kinds("---") == ["rule"], "markdown: horizontal rule")

        if case .code(let language, let text)? = Markdown.parse("```swift\nlet x = 1\n```").first {
            check(language == "swift" && text == "let x = 1", "markdown: fenced code keeps language and body")
        } else {
            check(false, "markdown: fenced code keeps language and body")
        }

        // A response mid-stream has an unterminated fence; it must still render as code.
        if case .code(_, let text)? = Markdown.parse("```\nhalf written").first {
            check(text == "half written", "markdown: unterminated fence streams as code")
        } else {
            check(false, "markdown: unterminated fence streams as code")
        }

        // Text inside a fence must never be re-parsed as markdown.
        check(kinds("```\n# not a heading\n- not a list\n```") == ["code"], "markdown: fence content is not parsed")

        if case .table(let header, let rows)? = Markdown.parse("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |").first {
            check(header.count == 2 && rows.count == 2 && String(rows[1][1].characters) == "4",
                  "markdown: table header and rows")
        } else {
            check(false, "markdown: table header and rows")
        }

        if case .checklist(let items)? = Markdown.parse("- [x] shipped\n- [ ] pending").first {
            check(items.count == 2 && items[0].done && !items[1].done, "markdown: checkbox state")
        } else {
            check(false, "markdown: checkbox state")
        }

        // Inline spans survive, and a stray marker does not blow up the parse.
        check(String(Markdown.inline("**bold** and `code`").characters) == "bold and code", "markdown: inline spans stripped to text")
        check(!String(Markdown.inline("unclosed **bold").characters).isEmpty, "markdown: unclosed span does not crash")
        check(kinds("") == [], "markdown: empty input yields no blocks")
    }

    // Schedule parsing + store checks run before UI exists, so they can use ScheduleStore safely.
    @MainActor
    static func runScheduleChecks(check: (Bool, String) -> Void) async {
        // Parser: every documented form
        check(ScheduleParser.parse("30m") != nil, "parse '30m'")
        check(ScheduleParser.parse("in 10 minutes") != nil, "parse 'in 10 minutes'")
        check(ScheduleParser.parse("every 2h") != nil, "parse 'every 2h'")
        check(ScheduleParser.parse("tomorrow 3pm") != nil, "parse 'tomorrow 3pm'")
        check(ScheduleParser.parse("monday 9:30am") != nil, "parse 'monday 9:30am'")
        check(ScheduleParser.parse("0 9 * * *")?.scheduleType == "cron", "parse cron '0 9 * * *'")
        check(ScheduleParser.parse("garbage") == nil, "reject unparseable schedule")

        // Cron next-run: '0 9 * * *' lands at 09:00
        if let next = CronSchedule.next(after: Date(), expression: "0 9 * * *") {
            let c = Calendar.current.dateComponents([.hour, .minute], from: next)
            check(c.hour == 9 && c.minute == 0, "cron next run at 09:00")
        } else {
            check(false, "cron next run at 09:00")
        }

        // Tool output formats match Tama's
        let wd = FileManager.default.temporaryDirectory
        let created = try? await CreateReminderTool().run(input: [
            "name": "test", "message": "hi", "schedule": "30m",
        ], workingDirectory: wd)
        check(created?.contains(#""success": true"#) == true && created?.contains(#""type": "reminder"#) == true,
              "create_reminder JSON format")
        let bad = try? await CreateReminderTool().run(input: [
            "name": "x", "message": "y", "schedule": "whenever",
        ], workingDirectory: wd)
        check(bad?.contains("Could not parse schedule") == true, "create_reminder rejects bad schedule")
        let deleted = try? await DeleteScheduleTool().run(input: ["name": "test"], workingDirectory: wd)
        check(deleted?.contains("Deleted schedule 'test'") == true, "delete_schedule JSON format")

        // Firing: drive the poll with an injected future clock (no waiting).
        let store = ScheduleStore.shared
        _ = store.create(name: "once-job", kind: .reminder, schedule: "30m", message: "one shot")
        _ = store.create(name: "repeat-job", kind: .reminder, schedule: "every 1m", message: "recurring")
        check(store.jobs.count == 2, "two jobs armed")

        let future = Date().addingTimeInterval(3600) // past both due times
        store.fireDue(now: future)
        check(store.deliveredWithoutBundle.contains { $0.contains("once-job") }, "once job fired")
        check(store.deliveredWithoutBundle.contains { $0.contains("repeat-job") }, "recurring job fired")
        check(!store.jobs.contains { $0.name == "once-job" }, "once job consumed after firing")

        let repeats = store.jobs.filter { $0.name == "repeat-job" }
        check(repeats.count == 1, "recurring job re-armed exactly once (no duplicate)")
        check(repeats.first.map { $0.nextRun > future } == true, "recurring job re-armed into the future")

        // Second poll at the same instant must not re-fire the re-armed job
        let before = store.deliveredWithoutBundle.count
        store.fireDue(now: future)
        check(store.deliveredWithoutBundle.count == before, "re-armed job does not immediately re-fire")

        _ = store.delete(name: "repeat-job")
        check(store.jobs.isEmpty, "cleanup: no jobs left behind")
    }
}
