# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

RetroTerm: a native macOS 14 terminal emulator that looks like a 1980s CRT. Pure SwiftPM (no Xcode project), Metal rendering, shaders compiled at runtime from a Swift string. GPL-3.0-or-later.

## Commands

```sh
swift build                                  # debug build
swift test                                   # emulator tests (RetroTermCore only)
swift test --filter TerminalTests/testWideChars   # one test
make build                                   # release build packaged as build/RetroTerm.app (ad-hoc signed)
make debug                                   # same, debug configuration
make run                                     # relaunch build/RetroTerm.app
make icon                                    # regenerate Resources/AppIcon.icns from Scripts/make-icon.swift
SIGN_IDENTITY=... make dmg                   # notarised DMG (Scripts/notarize.sh)
```

If `xcode-select` points at the Command Line Tools, `swift test` fails with "unable to resolve module dependency: 'XCTest'": run it as `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

Only `RetroTermCore` and `RetroBasic` have tests. The app target has none; verify UI/rendering changes by rebuilding the bundle, relaunching (`pkill -x RetroTerm; open build/RetroTerm.app`) and inspecting a full-resolution crop of the window (`screencapture -x`). A downscaled screenshot hides glyph artefacts. If a copy is installed in `/Applications`, `tell application "RetroTerm"` in AppleScript launches that one: drive the app via `System Events` process "RetroTerm" and check `ps` shows the `build/` binary.

Preferences are a single JSON blob under `defaults` domain `com.alessandrolioce.RetroTerm`, key `RetroTerm.config`. To test a setting without the UI, `defaults export` the domain, edit the JSON, `defaults import` it, then relaunch.

## Architecture

Four targets, strictly layered:

- `CPTY` (C): `forkpty` spawn, window-size ioctl, cwd lookup of a pid. Nothing else lives in C.
- `RetroTermCore` (Swift, no AppKit): the emulator. Testable headlessly.
- `RetroBasic` (Swift, depends on `RetroTermCore` only): the BASIC easter egg. Testable headlessly.
- `RetroTerm` (SwiftUI + AppKit + Metal): windows, tabs, input, rendering, settings.

### Emulator core

`VTParser` is a state machine that turns bytes into delegate callbacks (`parserPrint`, `parserCSI`, `parserOSC`, ...). `Terminal` implements that delegate and owns all state: `lines` (screen), `scrollback`, cursor, modes, alt screen, charsets. It is single-threaded and unaware of the PTY; it reports to the host only through closures (`output` for responses like DA/CPR, `onTitleChange`, `onBell`, `onClipboard`, `onCursorStyleChange`). `generation` is a counter bumped on every change; the view redraws only when it moves. `KeyEncoder` maps key events to byte sequences (modes such as application cursor keys come from `Terminal`).

`Line` carries a `wrapped` flag so selection/copy can rejoin soft-wrapped lines; `scrollbackBase` plus scrollback count gives absolute line indices that survive scrolling. Wide characters occupy a `.wide` cell followed by a `.wideSpacer` cell.

### Session and threading

`TerminalSession` = one shell + one `Terminal` + one `TerminalNSView`. The boot banner (`config.bootBannerText`, editable in Appearance > Window) is typed one character at a time on the read queue; PTY output arriving meanwhile is held in `heldOutput` and fed when the last character lands, so the prompt never interleaves with the banner. PTY output is read on a private `DispatchQueue` and fed to the terminal under `session.lock`. **Every access to `terminal` from the main thread must go through `session.withTerminal {}` or `session.snapshot(viewOffset:)`**, which take that lock. The view never holds a reference to `Terminal` directly; it renders a `TerminalSnapshot` (value copy of the visible lines, including the scrollback window when scrolled up).

`TabManager` owns sessions per window and forwards their `objectWillChange`; `TerminalContainer` swaps the selected session's NSView into the SwiftUI hierarchy. Menu commands reach the active tab through the `tabManager` focused value. Custom menu items are placed in the system View menu with `CommandGroup(after: .toolbar)`, not a second `CommandMenu("View")`.

### Rendering pipeline (`Renderer` + `Shaders.swift`)

Three Metal passes per frame, all at drawable resolution:

1. **Grid**: `buildVertices` emits two triangles per background cell and per glyph from `GlyphAtlas` (CoreText rasterised lazily into one 2048² texture, keyed by text/bold/italic). The vertex shader applies `cellScale` around `originX/originY`; the fragment shader uses sharp-bilinear sampling for bitmap glyphs.
2. **Bloom**: quarter-res downsample + two blur passes, only when glow is on.
3. **CRT composite**: curvature warp, rounded mask, scanlines, vignette, flicker, noise, chromatic aberration, bell flash.

Glyph metrics live in `Renderer.cellWidth/cellHeight` (device pixels, already multiplied by `pixelScale`). `pixelScale` > 1 is the "bitmap" look: rasterise at `fontSize/pixelScale` and magnify. `TerminalNSView.updateGrid()` is the single place that decides cols/rows, origin, cell scale and atlas size from the view bounds and `config.screenFit`:

- `.reflow`: cols/rows follow the window, scale 1.
- `.stretch` / `.fit`: cols/rows fixed (`fixedCols/fixedRows`), font magnified to the displayed row height, remaining stretch applied via `cellScale`, scanline period multiplied by the same magnification. Bitmap pixel size deliberately does not scale.

Anything that maps between screen points and cells (mouse hit-testing, IME rect, precise scrolling) must go through `Renderer.cell(at:)`, `viewRect(col:row:)`, `displayedCellHeight`, which account for both the curvature warp and `cellScale`.

### BASIC easter egg (`RetroBasic`)

With the C64 theme selected, typing `basic` at the shell prompt and pressing Return starts a small
Commodore-style BASIC V2 in the tab; `SYS 64738` or `EXIT` returns to the shell. Three layers:

- `BasicMachine`: the interpreter, driven in steps. `submitLine` takes a typed line, `step(budget:)`
  runs up to N statements and returns `.ready`, `.running`, `.awaitingLine` (INPUT) or `.exit`;
  `supplyLine` answers an INPUT, `interrupt` is Ctrl-C. It never blocks, so tests are synchronous.
  Lines are stored as text and parsed lazily; there is no keyword crunching and no ROM-exact
  number formatting (a deliberate subset: no DATA/READ, GET, CONT, DEF FN, PEEK/POKE, `%` variables).
- `BasicConsole`: the C64 screen editor over a `BasicScreen`. Typed characters overwrite in upper
  case, arrows and Home move the terminal cursor, Return hands the logical row under the cursor to
  the machine (a LISTed line can be edited in place), Ctrl-C breaks. `TerminalScreen` adapts a
  `Terminal`, under the session lock in the app and unlocked in tests.
- `BasicHost` (app target): one serial queue per session that feeds keys to the console and
  advances a running program in 32-statement slices with a 1 ms pause.

Detection lives in `TerminalSession.send(_:)`, the single funnel for typed and pasted bytes: it
tracks the current typed line and, on Return, checks the theme, that no alternate screen or mouse
mode is active, and that `basic` sits on screen right before the cursor. It then sends Ctrl-U to
the shell (which forgets the word), holds PTY output in `heldOutput` (the boot-banner mechanism,
capped at 1 MB) while BASIC runs, and on exit releases it, clears the screen and sends Ctrl-L so
the prompt redraws. Known limit: typing exactly `basic` inside `cat` or a REPL without alternate
screen also triggers it.

### Keyboard sound

`KeyClickPlayer` plays a sample pack from `Resources/Sounds/Tactile` (`press-*.wav`, `large-*.wav`, optional `release-*.wav`), falling back to a synthesised click. All samples must stay under a permissive licence (currently CC0 from Freesound, attributions in that folder's README): no GPL or other copyleft assets, so the app can be redistributed in any form. `build-app.sh` copies `Resources/Sounds` into the bundle; outside the bundle the player walks up from the executable to find the source tree.

### Settings

`TerminalConfig` is `Codable` with a hand-written tolerant `init(from:)`: every new field needs a default and a `d(.key, &field)` line there, or old preferences fail to decode. Migrations of changed defaults also live in that initializer. `AppSettings.shared.config` is `@Published`; views subscribe and call `updateGrid()` on any change.

## Distribution

Developer ID + notarisation, outside the Mac App Store: a local-shell terminal cannot live in App Sandbox. `SIGN_IDENTITY=... ./Scripts/build-app.sh` signs with hardened runtime and `Resources/RetroTerm.entitlements` (currently empty: no sandbox, nothing relaxed); `Scripts/notarize.sh` builds the DMG, submits with `notarytool` and staples. Keep hardened runtime working: no JIT, no unsigned dylibs, no library injection. A version bump touches `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` and the default boot banner in `AppSettings.swift`.

## Design decisions (do not revert)

- Curvature default 0.008, slider capped at 0.03. Larger values visibly bend text lines.
- Fixed-grid modes keep bitmap pixels at the configured size; scaling them produced jagged glyphs.
- Sharp-bilinear sampling for bitmap glyphs.
