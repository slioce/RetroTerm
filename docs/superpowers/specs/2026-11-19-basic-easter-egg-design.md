# BASIC easter egg — design

## Intent
With the C64 theme selected, typing `basic` at the shell prompt starts a small Commodore-style
BASIC V2 inside the tab: banner, `READY.`, `?SYNTAX  ERROR`, screen editing. `SYS 64738` or
`EXIT` returns to the shell. A nostalgia easter egg, not a faithful emulator.

## Decisions
- Banner: `**** RETROTERM BASIC V2 ****` (no company name anywhere).
- Exit: `SYS 64738` (the real reset vector) and `EXIT`.
- No disk: `LOAD`/`SAVE`/`VERIFY`/`OPEN`/`CLOSE` answer `?DEVICE NOT PRESENT  ERROR`.
- C64 screen editing: arrows move the cursor, typed characters overwrite, Return takes the row
  under the cursor, so a LISTed line can be edited in place.
- Reduced size: about 1 000 lines of interpreter and console plus tests, against the 4 800 of the
  app. Deliberately left out: DATA/READ, GET, CONT, DEF FN, PEEK/POKE, `%` variables, keyword
  crunching, ROM-exact number formatting, TAB/SPC, TI, FRE.

## Goals
- Zero footprint on the user's shell: no PATH entries, no rc files, no shell functions.
- No new `TerminalConfig` fields. Pure Swift, so signing and hardened runtime are untouched.
- Interpreter and console testable headlessly.

## Non-goals / anti-goals
- Fidelity to the ROM. `TOTAL=5` works here (on a C64 `TO` is crunched out of it).
- Any change to `TerminalNSView`, `KeyEncoder` or `Terminal`.

## Approaches considered
1. A real `basic` executable put on PATH by the app, signalling through a private OSC. Robust
   detection, but it pollutes PATH, is visible to `which`, and breaks a user's own `basic`.
   Rejected.
2. Detect the typed word in the app and divert input. Chosen: confined to the app, only active in
   the C64 theme, and `TerminalSession.send` is already the single funnel for typed bytes.
3. Interpreter design: a blocking interpreter on its own thread (INPUT waits on a semaphore) versus
   a step machine the host drives. Chosen the step machine: no thread can ever block holding the
   session lock, Ctrl-C is a flag between statements, tests are synchronous.

## How it is built
- Target `RetroBasic` (depends on `RetroTermCore` only): `BasicMachine` (interpreter), `Parser`,
  `Runtime`, `BasicConsole` + `TerminalScreen` (screen editor over a `Terminal`).
- App: `BasicHost` (one serial queue per session, 32 statements per 1 ms slice) and the hooks in
  `TerminalSession`: typed-line tracker, `shouldEnterBasic`, `enterBasic`/`exitBasic`, PTY output
  held in `heldOutput` (capped at 1 MB) while BASIC runs.
- Entry: Ctrl-U to the shell, banner clears the screen. Exit: release held output, clear, Ctrl-L.

## Accepted limits
- Typing exactly `basic` alone inside `cat` or a REPL without alternate screen also triggers it.
- Plain `sh` does not redraw its prompt on Ctrl-L.
- Non-ASCII input is dropped in BASIC. Lines over 80 characters are truncated.
