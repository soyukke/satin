# 0015: Use the native navigation layer and system Liquid Glass

Date: 2026-08-08

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

- Put terminal tabs, the persistent Local/tmux session control, and grouped new
  tab/split actions in a standard unified compact `NSToolbar`. Keep the custom
  glass controls at the platform's compact control height and size the session
  surface from its icon and title instead of a fixed wide badge.
- Present session discovery, attach, detach, switch, and creation from a standard
  transient `NSPopover`. Keep the Session menu as a secondary keyboard/menu-bar
  entry point to the same control.
- Use standard AppKit controls and SF Symbols. On macOS Tahoe they receive the
  system Liquid Glass material, interaction response, contrast adaptation, and
  accessibility behavior automatically. On macOS 14 and 15 they retain the
  platform-appropriate AppKit appearance.
- Route platform appearance decisions through `NativePlatformAppearance`.
  Availability checks, full-size titlebar configuration, and construction of
  custom toolbar material must not leak into terminal or session code. Future
  macOS appearance changes should be adopted in that adapter, preferring newer
  standard AppKit behavior before adding another custom presentation path.
- On macOS 26, wrap the custom Local/tmux and pane-action controls in regular
  `NSGlassEffectView` surfaces inside one `NSGlassEffectContainerView`. These
  remain semantic `NSButton` and `NSSegmentedControl` instances; the container
  only supplies system material and proximity merging. On earlier supported
  releases, present the same controls in a standard `NSStackView` with the
  platform's normal bezel styles.
- Extend a theme-derived ambient content background beneath the transparent
  titlebar on macOS 26 so refraction has meaningful content to sample. Constrain
  the opaque Metal terminal surface to the window safe area, ensuring terminal
  and Neovim glyphs never render beneath navigation controls.
- Do not place glass over terminal or Neovim content. Keep the Skia-Metal surface
  opaque and move navigation out of its geometry, leaving only content padding,
  pane focus borders, scrollbars, and input composition overlays in that view.
- Keep Settings on its standard toolbar-style `NSTabViewController` and use the
  same unified titlebar treatment.
- Validate menu commands against the key window. Terminal mutations are disabled
  while Settings or another auxiliary window is active, and standard Window menu
  commands retain their expected macOS shortcuts.

## Consequences

Satin follows the current macOS appearance without emulating refraction or
accessibility modes itself. Explicit glass is restricted to the two custom
toolbar control groups and comes from AppKit. Navigation keeps native semantics
for VoiceOver and evolves with AppKit behind one compatibility boundary.
Terminal grid sizing is independent of the toolbar height, and the renderer
retains a stable opaque content contract.

The toolbar can become space-constrained when many tabs are open. A future tab
overflow design should use native toolbar or menu behavior; it must not restore a
second hand-painted navigation layer inside the terminal renderer.
