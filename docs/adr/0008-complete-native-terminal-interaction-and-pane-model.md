# 0008: Complete the native terminal interaction and pane model

Date: 2026-07-28

Status: Accepted

The explicit-only Neovim handoff clause is superseded by ADR 0012. Raw
keystroke inference remains prohibited; shell integration now operates at the
executable/control-protocol boundary.

## Context

The AppKit host can run a real PTY and render `libghostty-vt` state through
Skia/Metal, but its interaction layer is still an MVP. Key sequences are
manually encoded, the text view does not participate in macOS text input,
terminal mouse and selection state are not connected, and the Rust pane layout
is not exposed to the host. A typed `nvim` command is also inferred from raw
keystrokes, which is not safe across SSH, REPL, nested shell, or line-editing
contexts.

The terminal library already exposes state-aware key and mouse encoders,
selection formatting, paste sanitization, OSC metadata, hyperlink lookup, and
Kitty graphics placement state. Duplicating those semantics in Swift would
create correctness debt.

## Decision

- Rust owns terminal input encoding, selection state, paste sanitization,
  hyperlink lookup, terminal metadata, image placement snapshots, and PTY
  lifecycle.
- Swift translates AppKit events into normalized Rust FFI input, implements
  `NSTextInputClient`, owns the pasteboard and notification presentation, and
  performs native pane layout and hit-testing.
- The recursive Rust pane layout is included in the core snapshot. The native
  host renders every visible leaf into a bounded region of the shared Metal
  drawable and routes input to the selected leaf.
- Neovim native handoff is an explicit native command. Raw terminal keystrokes
  are never interpreted as shell commands by the host.
- New tabs and splits inherit the active terminal pane's last OSC-reported
  working directory, falling back to the application working directory.
- Kitty graphics state remains owned by `libghostty-vt`; the renderer consumes
  placement snapshots and draws them in the same clipped Skia region as text.
- Native preferences and restorable tab metadata use macOS `UserDefaults`.
  Running processes are not serialized; restored panes start fresh login shells
  in their saved working directories.

## Consequences

Terminal protocol decisions remain synchronized with the active terminal
state, including application cursor/keypad modes, Kitty keyboard flags, mouse
tracking, bracketed paste, selection movement, and image scrolling.

The shared Metal renderer must keep animation state per runtime and clip every
render call to its pane region. AppKit must not draw a parallel cell renderer;
composition text, selection affordances, menus, and pane chrome remain native
overlays.

The explicit native Neovim command is predictable in local shells, SSH
sessions, REPLs, and alternate-screen applications.
