# 0015: Use native navigation and pane-local action chrome

Date: 2026-08-08

Amended: 2026-08-13

Status: Accepted

## Context

The original native shell painted its own opaque tab strip, colored tab pills,
tmux badge, and pane-action buttons inside the terminal overlay. That made basic
navigation look different from current macOS apps, duplicated controls that
AppKit already provides, and mixed navigation chrome with the terminal content
coordinate system.

macOS Tahoe applies Liquid Glass to standard navigation and control surfaces.
Apple's guidance reserves glass for that functional layer and keeps content
surfaces legible beneath it. Satin also supports macOS 14 and cannot require a
Tahoe-only custom glass view.

## Decision

- Put terminal tabs, a borderless new-tab action immediately after them, the
  window-scoped Artifacts action, and the persistent Local/tmux session control
  in a standard unified compact `NSToolbar`. Put close and split actions in a
  reserved 24-point header inside every workspace pane so pane-scoped actions
  have an explicit target and remain available away from the active pane. The
  Artifact sidebar retains only its common close action in that header.
- Present session discovery, attach, detach, switch, and creation from a standard
  transient `NSPopover`. Keep the Session menu as a secondary keyboard/menu-bar
  entry point to the same control.
- Use standard AppKit controls and SF Symbols. On macOS Tahoe, toolbar controls
  receive the system navigation material automatically. Pane-header controls
  retain the platform-appropriate AppKit appearance, interaction response,
  contrast adaptation, and accessibility behavior on every supported release.
- Route titlebar availability and window appearance decisions through
  `NativePlatformAppearance`. Pane headers remain semantic AppKit controls and
  do not introduce a second custom glass-material implementation.
- Extend a theme-derived ambient content background beneath the transparent
  titlebar on macOS 26 so refraction has meaningful content to sample. Constrain
  the opaque Metal terminal surface to the window safe area, ensuring terminal
  and Neovim glyphs never render beneath navigation controls.
- Do not place glass or controls over terminal or Neovim cells. Retain the full
  pane bounds for layout and split resizing, but pass only the area below its
  header to grid sizing, mouse coordinates, and Skia-Metal rendering.
- Let the grid reach the left, right, and bottom pane edges without decorative
  padding. Draw outlines at one backing pixel, using adaptive neutral gray for
  inactive panes and subdued system blue for the active pane.
- Treat Command +/-/0 as pane-local font zoom. Keep the configured Appearance
  font size as the shared baseline, retain an in-memory offset per pane ID, and
  use that pane's effective cell metrics consistently for PTY/Neovim resize,
  Skia rendering, mouse coordinates, and input-method placement. Keep the text
  shaper and prepared-line cache per runtime so mixed zoom levels do not evict
  one another's shaped lines on every frame.
- Keep projected tmux panes on the configured baseline. One tmux control client
  negotiates a shared cell grid, so applying a different cell size to one
  projected pane would clip or stretch that pane instead of reflowing it.
- Keep Settings on its standard toolbar-style `NSTabViewController` and use the
  same unified titlebar treatment.
- Validate menu commands against the key window. Terminal mutations are disabled
  while Settings or another auxiliary window is active, and standard Window menu
  commands retain their expected macOS shortcuts.

## Consequences

Satin follows the current macOS appearance without emulating refraction or
accessibility modes itself. The toolbar and pane actions retain native AppKit
semantics for VoiceOver. Terminal grid sizing is independent of both the
toolbar and pane-header heights, and the renderer retains a stable opaque
content contract. A pane action never depends on which pane happened to own
keyboard focus before it was clicked.

The toolbar can become space-constrained when many tabs are open. A future tab
overflow design should use native toolbar or menu behavior; it must not restore a
second hand-painted navigation layer inside the terminal renderer.
