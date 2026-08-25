# Universe — design

## Thesis

**A quiet native utility.** Content is the interface; chrome recedes. Nothing decorative
earns space. If a pixel is not content, state, or a control you need right now, it goes.

## What the reference actually uses

Inspected from the reference app bundle, not guessed:

- `Assets.car` holds **only the app icon** — no custom palette, no custom imagery.
  The whole look is **SF Symbols + SwiftUI materials + native controls**.
- Markdown is rendered by a **hand-written scanner**, not a library.
- Bundled libraries state the intent: Highlightr (syntax highlighting), Rive (mascot),
  KokoroSwift/MisakiSwift/mlx-swift (on-device TTS), ZIPFoundation (downloads).

Layout and animation are compiled away and cannot be recovered, so spacing below is
Apple HIG plus our own consistency rules — same idioms, not pixel-matched.

## Tokens

| Token | Value | Used for |
| --- | --- | --- |
| Gutter | 12pt | Pane padding, row insets |
| Row gap | 8pt | Items in a list |
| Block gap | 12pt | Messages, sections |
| Corner (panel) | 16pt | Panel, sheets |
| Corner (block) | 10pt | Rows, code blocks, bubbles |
| Control height | 28pt | Buttons, fields, tabs |
| Icon family | SF Symbols only | No emoji in UI |
| Type | System font, semantic sizes | `.headline` / `.callout` / `.caption` |
| Colour | Semantic only | `.primary` `.secondary` `.tertiary` `Color.accentColor` |
| Surface | `.regularMaterial` | Panel background |

Never hard-code a hex colour: semantic colours give light/dark and contrast for free.

## Rules

- **Feedback**: every tool call, load, error, and empty state has a visible state.
  No silent work, no abrupt appearance.
- **Motion**: shared duration (0.2s) and easing; honour Reduce Motion.
- **Accessibility floor**: full keyboard operation, visible focus, VoiceOver label on
  every control, semantic colours for contrast. Not traded for polish.
- **Empty states** say what to do next, never just "nothing here".

## Verification

`Universe --render-states <dir>` rasterises registered UI states offscreen with
`ImageRenderer` and fails if a state is the wrong size or effectively blank.

`ImageRenderer` does **not** rasterise `ScrollView` contents, lazy stacks, `TextField`,
`SecureField`, `ProgressView`, or `.link`-styled buttons — they come out as yellow
placeholder bars. Register **content views** (e.g. `MessageListView`), not whole panels,
keep content views free of lazy containers, and read a placeholder bar as "this control
is not gated", not as a failure. Layout, copy and every custom-drawn view still gate.

Gates for every phase: `swift build` · `--selftest` · `--render-states` · `xcodebuild`
plus a launch-and-quit smoke run.
