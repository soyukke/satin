# 0018: Split the native host by responsibility

Date: 2026-08-12

Status: Accepted

## Context

`SatinApplication.swift` grew to 11,932 lines and owned the Rust FFI pane
wrappers, AppKit rendering helpers, toolbar models, application lifecycle, menu
construction, and the terminal shell controller. Its source-size exception had
also grown to 11,945 lines. That made unrelated changes collide and encouraged
new behavior to enter the same file because every native concern was already
reachable there.

## Decision

- Remove `SatinApplication.swift`. The executable entry point and AppKit
  lifecycle live in `SatinMain.swift` and `SatinAppDelegate.swift`.
- Split native runtime and presentation by ownership:
  - Rust-backed pane lifecycle and FFI adapters live in
    `NativePaneRuntime.swift`.
  - macOS appearance compatibility and ambient chrome live in
    `NativeAppearance.swift`.
  - The application main menu has one stable owner in
    `NativeMainMenuController.swift`. Key-window transitions validate existing
    items instead of rebuilding `NSApp.mainMenu`; settings changes update only
    the affected shortcut properties.
  - pane runtime collections live behind `NativePaneStore`; control status
    revision, waiter, and timeout invariants live behind
    `NativePaneStatusStore`.
  - text rendering, native text input, and smoke-only inspection use separate
    `TerminalTextView` source units.
  - shell control routing, commands, presentation, pane interaction, session
    restore, Neovim dispatch, and runtime/tmux integration use separate
    `TerminalShell` source units.
- Compile smoke orchestration only when `SATIN_SMOKE_SCENARIOS` is defined.
  `native-build` enables it for the behavior suites; `native-package` does not,
  so test scenarios and their state are absent from the release executable.
- Keep every new source unit below the default 1,000-line limit and remove the
  `SatinApplication.swift` source-size exception entirely.
- Preserve renderer, tmux, terminal, persistence, and UI behavior during this
  ownership change. Functional changes remain separate pull requests.
- New pane navigation, pane chrome, and artifact behavior must enter the
  corresponding owner instead of rebuilding an application-controller
  monolith.

## Consequences

Native builds list the source units explicitly. Shell extensions share a
module-internal controller surface, while state with independent invariants is
owned by dedicated stores. Nothing becomes a public API outside the executable
module.

Code review can distinguish production behavior from smoke orchestration and
can review control, pane, session, and tmux changes independently. The
controller extensions remain coordination seams rather than fully independent
services; future stateful behavior should move behind a store or coordinator
instead of adding another controller dictionary.
