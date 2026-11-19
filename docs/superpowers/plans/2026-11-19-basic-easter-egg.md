# BASIC Easter Egg Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `basic` typed at the prompt in the C64 theme starts a built-in BASIC; `SYS 64738`/`EXIT` returns to the shell.

**Architecture:** New `RetroBasic` target with a step-driven interpreter and a screen-editor console; the app adds `BasicHost` and hooks in `TerminalSession.send`. See the spec.

**Tech Stack:** Swift, SwiftPM, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-19-basic-easter-egg-design.md`

## Global Constraints
- Banner text exactly `    **** RETROTERM BASIC V2 ****` / ` 64K RAM SYSTEM  38911 BASIC BYTES FREE`.
- Error format `?<MSG>  ERROR` (two spaces), `IN <line>` while running, then `READY.`.
- No new `TerminalConfig` fields. No changes to `TerminalNSView`, `KeyEncoder`, `Terminal`.
- Conventional Commits; `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` green per task.

## Review Focus
- Paste in BASIC must bypass bracketed-paste wrapping (`TerminalSession.paste` checks `basic` first).
- `heldOutput` must never be released by the banner typer while BASIC is active.
- A program busy-looping must cost a few percent of one core (32 statements / 1 ms).
- Shell exit or tab close while a program runs must stop the host queue without touching a freed session.
- Return on a soft-wrapped row must hand the whole logical line to the machine.

---

### Task 1: Scaffold
- [x] `Package.swift`: `RetroBasic` target, `RetroBasicTests`, app depends on it.
- [x] `BasicMachine.powerOn()` prints the banner; `testBannerOnPowerOn`.
- [x] Commit `feat(basic): add RetroBasic target`.

### Task 2–4: Interpreter core
- [x] `Parser.swift`: lexer, statements, expressions with C64 precedence.
- [x] `Runtime.swift`: values, two-character variables, arrays, builtins, number formatting.
- [x] `BasicMachine.swift`: program store, lazy parse, `step`, control flow, errors, INPUT, BREAK, SYS/EXIT.
- [x] 35 tests in `BasicMachineTests`.
- [x] Commit `feat(basic): interpreter core with expressions, control flow and INPUT`.

### Task 5: Console
- [x] `BasicConsole.swift`: `BasicScreen`, `TerminalScreen`, key table, PETSCII→VT, editing modes.
- [x] 12 tests in `BasicConsoleTests` over a real `Terminal(cols: 40, rows: 10)`.
- [x] Commit `feat(basic): screen editor console over a Terminal`.

### Task 6: App integration
- [x] `BasicHost.swift`.
- [x] `TerminalSession`: `trackTyped`, `shouldEnterBasic`, `enterBasic`, `exitBasic`, held output, funnels, teardown.
- [x] `make build`.
- [x] Manual verification, partial: steps 1–3 done in the app (entry, banner, UNDEF'D STATEMENT, GOTO loop, Ctrl-C → BREAK IN 10, CPU 12–20% with PRINT in the loop). Steps 4–10 not run: the keyboard was in use, and the user chose to ship.
- [x] Commit `feat(basic): start BASIC when "basic" is typed in the C64 theme`.

### Task 7: Docs
- [x] CLAUDE.md, README, this plan and the spec.

## Manual verification
1. Theme c64 in the prefs blob; relaunch `build/RetroTerm.app`.
2. `basic` + Return: banner exact, `READY.`, no `^U` visible.
3. `10 PRINT "HELLO"`, `20 GOTO 10`, `RUN`, Ctrl-C → `BREAK IN 10`; CPU via `top -pid`.
4. `LIST`, arrow up to line 10, overwrite, Return, `LIST` → edited.
5. INPUT with prompt; `abc` to a numeric INPUT → `?REDO FROM START`.
6. Cmd-V of a program, `RUN`.
7. `SYS 64738` and `EXIT`: screen clears, prompt back, `ls` works.
8. Green theme: `basic` → `command not found`. C64 theme: `echo basic` does not trigger.
9. Close the tab while a program runs; `kill -HUP` the shell of a tab in BASIC.
10. Resize the window in BASIC.
