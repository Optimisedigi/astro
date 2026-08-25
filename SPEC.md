# Tama — Replication Spec

Extracted 2026-08-25 from `/Applications/Tama.app` v2.0.35 (`com.unstablemind.tama`)
via Info.plist, entitlements, `otool -L`, and full binary string dump.
Source of truth for rebuilding a functional equivalent.

---

## 1. App Shape

- **Native Swift/SwiftUI + AppKit hybrid**, arm64-only, min macOS 15, built with Xcode 26 SDK.
- **Menubar app** (`LSUIElement = true`) — no Dock icon. Lives in menu bar + a "virtual notch" overlay.
- Bundle ID pattern: `com.unstablemind.tama` (ours: pick own).

### Entry points
| Trigger | Action |
|---|---|
| `⌥ Space` (tap) | Open prompt panel (global hotkey via Carbon `RegisterEventHotKey`) |
| `⌥ Space` (hold) | Push-to-talk voice input (SFSpeechRecognizer) |
| Menu bar icon | Dropdown panel: tabs for Chat / Tasks / Routines / Skills / Clipboard |
| Notch overlay | Activity indicator, call button, call timer, toast notifications |

---

## 2. Architecture (file map from binary)

**Core agent**
- `AgentLoop.swift` — tool-call loop, `maxTurns` cap, streaming, "Reached maximum number of turns"
- `ClaudeService.swift` — multi-provider streaming client (see §5)
- `StreamParser.swift` + `OpenAIStreamParser`, `CodexStreamParser`, `GeminiStreamParser` — per-provider SSE parsers
- `ModelRegistry.swift` — model list + vision-capability flags
- `ToolRegistry.swift` / `PanelToolRegistry.swift` — tool defs + dispatch
- `ProviderStore` — credentials in `provider-store.enc` (encrypted, Keychain-backed)

**Tools (all registered as LLM function calls)**
`BashTool, ReadTool, EditTool, WriteTool, LsTool, FindTool, GrepTool, WebFetchTool, WebSearchTool, ScreenshotTool, BrowserTool, CreateReminderTool, CreateRoutineTool, ListSchedulesTool, DeleteScheduleTool, TaskTool, SkillTool, ClipboardHistoryTool, NightShiftTool, KeepAwakeTool, DismissTool, EndCallTool, TogglePanelTool, AgentTool`

**UI**
- `FloatingPanel.swift` (+`Presentation/Lists/Response` extensions) — main chat panel
- `DropdownPanelController`, `PromptPanelController` — panel window management
- `VirtualNotch.swift`, `NotchActivityIndicator`, `NotchCallButton`, `NotchCallTimer`, `NotchOverlayTracker`, `NotchNotificationPresenter` — notch UI
- `MascotView.swift` — Rive avatar (`avatar_pack.riv`, 14KB), states: moodIcon e.g. "speaking", idle/typing timers
- `ResponseTextView` + `MarkdownRenderer` — custom NSTextView markdown (code blocks w/ copy buttons, tables, checklists)
- `SessionListView`, `TaskListView/Detail`, `RoutineListView`, `SkillListView/Detail`, `ClipboardHistoryView`
- `SkeletonView`, `ShimmerTextView` — loading states
- `OnboardingController/View`, `LoginView`, `PermissionsView/Checker`, `VoiceSettingsView`, `UpdateView`, `AppUpdater`

**Voice**
- `VoiceService.swift` — SFSpeechRecognizer + AVAudioEngine; RMS-based silence detection (noise floor, silence window, speech boost)
- `SpeechService.swift` — streaming TTS playback: AVAudioEngine playerNode, utterance queue, ordered slots
- `CallSession.swift`, `CallMetrics.swift` — live-call state machine (isListening/isResponding/isActive)

**Stores** (all JSON on disk)
`SessionStore, TaskStore, ScheduleStore, SkillStore, ClipboardStore`

---

## 3. Data & Storage

`~/Library/Application Support/Tama/`
```
provider-store.enc            # encrypted credentials
schedules.json                # reminders + routines
sessions/<UUID>.json          # one file per chat session
tasks/                        # task checklists
Workspace/Screenshots/        # screenshot tool output
KokoroTTS/model/kokoro-v1_0.safetensors      # ~350MB
KokoroTTS/voices/af_bella|af_heart|af_sarah.safetensors
```

**Session JSON schema** (verified from real data):
```json
{
  "id": "UUID", "title": "...", "sessionType": "chat",
  "moodIcon": "speaking",
  "createdAt": "ISO8601", "updatedAt": "ISO8601",
  "messages": [{
    "id": "UUID", "role": "user|assistant|tool",
    "timestamp": "ISO8601",
    "content": [
      {"type": "text", "text": "..."},
      {"type": "toolUse", "id": "call_...", "name": "create_reminder",
       "input": "<base64-encoded JSON string>"}
    ]
  }]
}
```

**Schedule regexes** (extracted verbatim):
```
^in\s+(\d+)\s*(hour|hr|minute|min|day|d)s?$
^(\d+)\s*(m|min|mins|minutes?|h|hr|hrs|hours?|d|days?)$
^every\s+(\d+)\s*(m|min|mins|minutes?|h|hr|hrs|hours?|d|days?)$
^(today|tomorrow|monday|...|sunday)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$
```
Plus cron expressions. Routines poll via `pollTimer` in `ScheduleStore`.

---

## 4. AI Providers & Auth

OAuth (PKCE, loopback callbacks) — reuse your existing subscriptions:
| Provider | Auth URL | Token URL | Callback |
|---|---|---|---|
| Claude | `claude.ai/oauth/authorize` | `platform.claude.com/v1/oauth/token` | `platform.claude.com/oauth/code/callback` |
| OpenAI (Codex) | `auth.openai.com/oauth/authorize` | `auth.openai.com/oauth/token` | `localhost:1455/auth/callback` |
| Gemini | `accounts.google.com/o/oauth2/v2/auth` | `oauth2.googleapis.com/token` | `localhost:8085/oauth2callback` |

API-key providers (endpoints extracted):
- Anthropic: `https://api.anthropic.com/v1/messages` (`anthropic-version`, `oauth-2025-04-20` for OAuth tokens)
- OpenAI Codex: `https://chatgpt.com/backend-api/codex/responses` (SSE, `responses=experimental`, `chatgpt-account-id` header)
- Gemini: `https://cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse`
- Moonshot/Kimi: `https://api.moonshot.ai/v1/chat/completions`
- MiniMax: `https://api.minimax.io/anthropic/v1/messages`
- Xiaomi MiMo: `https://token-plan-sgp.xiaomimimo.com/v1/chat/completions`
- User-Agent: `tama/1.0 (macOS)`; mimics `claude-cli/2.1.75`

**Models** (ModelRegistry): Claude Sonnet 4.6, Claude Haiku 4.5, Gemini 3 Pro/Flash (Preview), Gemini 2.5 Flash, codex-mini-latest, MiniMax M2.7 Highspeed, MiMo-V2-Pro, Kimi K2.6, GPT-5.4 (vision models flagged; screenshot tool refuses non-vision models).

**Speed trick:** answers are fast because it's plain streaming SSE from cloud APIs — first token renders immediately into a custom text view with a character queue (`characterQueue` in FloatingPanel). No local LLM.

---

## 5. System Prompts (extracted verbatim)

### Chat prompt (abridged structure — full text in `prompts/chat-system.md`)
- Identity: "You are Tama, a personal assistant living on the user's desktop."
- Personality: texting-a-close-friend tone, concise, lead with the answer, "no fluff"
- Agency: "3-5 steps ahead", do don't ask, progressive disclosure ("I did X — want Y too?")
- Tool workflow: explore first (ls/find/grep), read before edit, chain tools
- Appends `[environment]\nplatform: macOS` + working directory + tool inventory

### Voice call prompt
- "Live voice conversation… a phone call, not a chat window"
- **ZERO DEAD AIR** — always narrate before/during tool calls ("one sec, pulling that up…")
- 1–2 sentences per turn default; TTS-safe output (no markdown, numbers as words)
- Rotate filler phrases; mirror user's language; interruptions reset the stack

### Routine prompt
`You are a helpful assistant running a scheduled routine. Be concise.`

### Skills system
Markdown files in workspace `.gg/skills/` with YAML frontmatter (name, description);
injected as `<skill_content name="...">…</skill_content>` + "Treat the above skill instructions as authoritative."

---

## 6. Voice Pipeline

1. **STT:** SFSpeechRecognizer + AVAudioEngine, on-device; RMS adaptive silence detection (`noiseFloorRMS`, `silenceWindow`, `speechBoostFactor`) to detect end-of-speech
2. **LLM:** same agent loop, voice system prompt
3. **TTS:** **Kokoro-82M** fully on-device via **MLX Swift** (mlx-swift), weights from `huggingface.co/prince-canuma/Kokoro-82M`
   - `KokoroSwift` + `MisakiSwift` (G2P phonemizer) + eSpeak data bundles
   - Streaming synthesis: sentence chunks → `orderedSlots` → AVAudioPlayerNode gapless playback
   - Voices: af_bella, af_heart, af_sarah (.safetensors voice embeddings)

---

## 7. Key Implementation Details

- **Panels:** borderless `NSPanel` subclasses (`StablePanel`), `canBecomeKeyWindow` overridden, fixed `panelWidth`, animated dismiss (`isDismissing`)
- **Browser automation:** downloads Chrome for Testing (~400MB, optional), talks Chrome DevTools Protocol (`ChromiumManager.swift`)
- **Screenshot tool:** ScreenCaptureKit, downscaled, 0–1000 coordinate grid for pointing; saves to `Workspace/Screenshots/`
- **Clipboard:** 5s `NSTimer` polling `changeCount`; ignores `org.nspasteboard.ConcealedType/TransientType/AutoGeneratedType`, 1Password, TypeIt4Me
- **NightShift tool:** private `CoreBrightness` framework (`CBBlueLightClient`)
- **Markdown:** custom inline scanner regex renderer, not a library
- **Permissions onboarding:** Accessibility, Full Disk Access, Microphone, Speech Recognition, Screen Recording, Notifications — each with deep-link `x-apple.systempreferences:` URLs
- **Highlightr** bundle — code syntax highlighting; **ZIPFoundation** — unpacking downloads
- Sparkle-style `AppUpdater`/`UpdateView` (self-update)

---

## 8. MVP Replication Order

1. SwiftUI menubar app + `⌥Space` hotkey + borderless floating panel
2. Anthropic SSE streaming chat (API key first; OAuth later) → custom NSTextView markdown renderer
3. SessionStore JSON persistence + session list
4. Agent loop + core tools (bash, read, edit, write, ls, find, grep, web_fetch)
5. Schedules (reminders via UNUserNotification) + routines
6. Voice: SFSpeechRecognizer → Kokoro TTS via MLX
7. Notch overlay, mascot (Rive), browser tool, clipboard history
