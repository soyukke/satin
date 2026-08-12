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

- Keep the terminal shell controller in `SatinApplication.swift` while moving
  independent top-level responsibilities behind file boundaries:
  - Rust-backed pane lifecycle and FFI adapters live in
    `NativePaneRuntime.swift`.
  - macOS appearance compatibility and ambient chrome live in
    `NativeAppearance.swift`.
  - tmux projection, toolbar identifiers, and artifact popover models live in
    `NativeShellModels.swift`.
  - application lifecycle, menus, updates, and Finder routing live in
    `SatinAppDelegate.swift`.
  - the executable entry point lives in `SatinMain.swift`.
- Keep extracted files below the default 1,000-line source limit. Reduce the
  remaining `SatinApplication.swift` exception to 9,500 lines so future work
  cannot silently restore the removed responsibilities.
- Treat this as a mechanical ownership change. Do not change renderer, tmux,
  terminal, persistence, or UI behavior in the extraction.
- Continue shrinking the controller through focused follow-up changes. New pane
  navigation, pane chrome, and artifact behavior must be placed in their owning
  component rather than growing the application lifecycle file again.

## Consequences

Native builds list the new Swift sources explicitly, and a few helpers become
module-internal instead of file-private where extracted runtime types require
them. They remain unavailable outside the executable module.

Code review can now distinguish runtime, appearance, shell-model, and lifecycle
changes. `SatinApplication.swift` remains larger than the default limit, so this
decision creates a ratchet rather than declaring the decomposition complete.
