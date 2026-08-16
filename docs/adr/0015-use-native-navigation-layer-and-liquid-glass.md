# 0015: Use native navigation and pane-local action chrome

Date: 2026-08-08

Amended: 2026-08-17

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
  window-scoped Artifacts action, an on-demand Work Switcher, and the persistent
  Local/tmux session control in a standard unified compact `NSToolbar`. Put
  close and split actions in a reserved 24-point header inside every workspace
  pane so pane-scoped actions have an explicit target and remain available away
  from the active pane. The Artifact sidebar retains only its common close
  action in that header.
- Open the Work Switcher with Command-P or the Work overview action immediately
  to the right of Artifacts. Build its searchable rows from the existing tab/pane
  snapshot, runtime metadata, tmux projection, and control status store rather
  than introducing another workspace model. Give visible rows a compact bounded
  excerpt and preview only the selected pane's retained screen text; do not
  allocate another renderer or select the pane merely to preview it. Group rows
  into Needs Attention, Running, and Other while keeping lifecycle state separate
  from unread attention: focusing a pane acknowledges its badge without rewriting
  the producer-owned `waiting`, `blocked`, `done`, or `failed` state. Do not add an
  always-visible workspace sidebar for this initial navigation surface.
- Treat agent lifecycle protocols as producer-owned metadata, not terminal
  content. Consume Codex and Claude Code's OSC title spinner transitions for an
  immediate `running` signal and Codex's Action Required title for `waiting`.
  Reset title tracking from an explicit session-start marker emitted by the
  bundled zsh integration for both supported agents. Classify the first
  spinner cycle as initialization, so opening Codex does not create a false
  unread completion while an already-running session restored with Satin still
  reports activity.
  Close only a current `running` or `waiting` status when that title state ends;
  an already-terminal control or hook status is not overwritten. Add Satin's
  bounded Claude Code lifecycle hooks through the zsh integration as a
  command-line settings layer so `PermissionRequest`,
  `Elicitation`, `Stop`, and `StopFailure` distinguish waiting, done, and failed.
  Preserve the user's settings hierarchy, skip injection for an explicit
  `--settings` or opt-out, and never edit `~/.claude` or Codex's machine-level
  `notify`. Do not infer lifecycle from retained screen rows, pixels, inactivity,
  or process-name polling.
  For projected tmux panes, subscribe to quoted `pane_title` changes and route
  those transitions through the same tracker instead of inspecting pane output.
  When an agent-owned waiting prompt is dismissed with Escape, return that pane
  to `idle`; do not leave a stale attention badge after the UI is back at input.
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
- Treat Command +/-/0 as window-wide font zoom. Keep exactly one effective font
  and cell size in each Satin window; Command-0 returns it to the configured
  Appearance size. Do not retain pane, tab, runtime, or tmux-window zoom offsets.
  Resize local terminal and native Neovim runtimes from that shared cell before
  presenting the next frame so rendering, mouse, cursor, and input-method
  coordinates use the same geometry.
- Size the projected tmux control client with the same shared cell. Recursively
  compose every leaf's real content-frame capacity through horizontal and
  vertical splits, accounting for pane headers and tmux separators. Let tmux
  reflow every underlying PTY; never substitute a pane-specific render scale,
  cursor-following crop, shifted origin, or separate glyph and placement cells.
- Coalesce host-window geometry changes before propagating PTY, Neovim, and tmux
  grid updates. Rendering may continue during live resize, but one burst of
  AppKit frame notifications must not enqueue a matching burst of runtime resize
  or tmux refresh commands.
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
