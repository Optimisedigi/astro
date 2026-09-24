# Astro

A native macOS menubar agent: ask a question with `⌥Space`, get a streaming answer,
and let it act on your machine through tools.

Built as a working study of [Tama](https://github.com/) — see [SPEC.md](SPEC.md) for the
full reverse-engineering notes that informed the architecture.

## Status

| Area | State |
|---|---|
| Menubar app, no Dock icon | working |
| `⌥Space` global hotkey → floating panel | working |
| Streaming chat (Anthropic) | working |
| Agent loop with bash/read/write/edit | working, workspace-contained |
| Reminders + routines (cron & natural language) | working |
| Voice in (SFSpeechRecognizer) / out (Kokoro TTS via MLX) | working |
| Notch voice calls, optionally on OpenAI live voice (ChatGPT plan) | built, not yet tested live |

## Run it

```sh
swift build && .build/debug/Universe --selftest   # offline checks, no API key needed
```

For the real app (the global hotkey needs a signed bundle):

```sh
xcodegen generate
xcodebuild -project Universe.xcodeproj -scheme Universe -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Universe-*/Build/Products/Debug/Astro.app
```

The app was renamed from Universe to Astro. Code, the Xcode scheme, the bundle ID
(`com.universe.app`), the Keychain service and the data folder keep the old name on
purpose, so existing permissions, sign-ins and chats carry over.

Add your Anthropic API key via the menubar → Settings. It is stored in the Keychain.

## Layout

```
Sources/Universe/
  UniverseApp.swift    app entry, menubar, startup wiring
  PanelController.swift borderless floating panel
  HotKeyManager.swift   Carbon global hotkey
  ClaudeService.swift   streaming SSE client with tool-use parsing
  AgentLoop.swift       stream → run tools → feed results back
  Tools.swift           bash/read/write/edit + registry
  ScheduleParser.swift  "30m", "every 2h", "tomorrow 3pm", cron
  ScheduleStore.swift   JSON persistence, polling, notifications
  VoiceService.swift    speech in and out
  ChatView.swift        panel UI: input row, voice glow, border beam, tabs
  MascotView.swift      the thinking orb beside "Ask anything"
  VoiceGlow.swift       sound-reactive glow (SwiftUI port of voice-glow)
  OpenAIRealtimeCallSession.swift, GPTLive*.swift  OpenAI live voice calls
  ChatGPTWebSearch.swift web search on the ChatGPT plan
  SelfTest.swift        offline verification of the whole loop
Vendor/BorderBeamKit/   border beam (MIT, see VENDORED.md)
Vendor/ThinkingOrbsKit/ Thinking orb (MIT, see VENDORED.md)
```

Data lives in `~/Library/Application Support/Universe/`.

## Notes

- Tools are contained to a workspace directory; symlink and path-escape attempts are
  rejected and covered by tests.
- `--selftest` runs the agent loop against a scripted model, so it needs no network.

## Install

```bash
./install.sh
```

Builds Release, runs the self-test, and installs to `/Applications/Astro.app`. An old
`Universe.app` is moved to the Trash. Signed with the local Apple Development
certificate, so it runs on the machine that built it; shipping to other Macs would
need a Developer ID certificate and notarization.

Then: menubar icon → Settings → **Sign in with Claude**. Global hotkey is ⌥Space.
