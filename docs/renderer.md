# Renderer behavior and verification

This document records the current retained renderer behavior and its focused
visual smoke coverage. Long-term design constraints remain in
[`docs/adr`](adr/README.md).

## Ownership boundary

AppKit owns windows, tabs, menus, pane layout, input routing, dialogs, and
context menus. Rust owns terminal state, the Neovim compositor, retained
renderer state, and the Skia/Metal drawing path. Terminal behavior remains
owned by `libghostty-vt`.

Both `just terminal` and `just neovim` draw retained renderer models into the
current `MTKView` drawable. The renderer owns backgrounds, glyphs, decorations,
images, scroll animation, and Neovide-derived four-corner cursor geometry.

## Scroll model

`src/neovide_render.rs` owns the retained-window spring model. Terminal and
Neovim runtimes feed two event-driven scroll sources into it:

- Terminal history applies integer rows to `libghostty-vt`, retains fractional
  wheel movement in the renderer, and settles to a cell boundary after wheel
  idle. Primary-screen output growth comes from the VT scrollbar state.
- Direct interactive Neovim uses `win_viewport.scroll_delta`. Other full-screen
  terminal applications use explicit VT insert, delete, or scroll commands and
  their declared scroll region.

Visible rows are never compared to guess TUI scrolling. Cursor-only redraws,
relative numbers, virtual text, and statusline colors therefore cannot move the
retained viewport.

The native Neovim pane consumes `ext_multigrid` events for editor windows,
floating windows, messages, cmdline, and side panes. `grid_line` produces
`DrawLine`, `grid_scroll` produces `Scroll`, and `win_viewport` produces
`Viewport`. The retained cache stores window placement, kind, z-order, hidden
state, colored cells, logical scrollback, and animation position. Fixed rows
such as statuslines remain outside the animated scroll clip.

## Text and graphics

The Neovide-derived shaper uses `swash` to place grapheme clusters on grid cells,
caches Skia `TextBlob`s with `lru`, uses the configured font as its primary face,
falls back through Skia `FontMgr`, and keeps the bundled fonts as final fallback
faces. Bold and italic participate in fallback; faint, blink, underline
variants and colors, strikethrough, and overline remain grid-aligned.

Kitty graphics are decoded through `libghostty-vt` and composited with pane
clipping and z-order. Embedded Neovim and projected tmux panes bridge image.nvim
commands into the same bounded decoder while arbitrary regular-file reads stay
disabled.

## Visual smoke matrix

Renderer changes normally run the non-capturing `just native-smoke` plus the
relevant focused recipes. For retained Neovim scrolling and layout, start with:

- `just nvim-smoke-scroll` checks Ctrl-D-style retained scroll animation.
- `just nvim-smoke-jump` checks large jump animation.
- `just nvim-smoke-side-pane` keeps file-tree and other side-pane scroll hints
  column-bounded.
- `just nvim-layout-redraw-smoke` checks pane close and rapid host resize without
  a lost Metal frame request.
- `just nvim-smoke-commandline` and `just nvim-smoke-cursor-move` reject false
  scroll animation from command-line or cursor-only redraws.

Pixel-backed checks add:

- `just nvim-smoke-shaped-text-visual` checks Japanese, Nerd Font,
  combining-mark, and ambiguous-width glyph pixels.
- `just nvim-smoke-cursor-switch` checks cursor ownership after tab switches.
- `just nvim-smoke-cursor-blink` checks the configured cursor blink-off phase.
- `just nvim-smoke-ui-surfaces` checks blended floating windows and native
  message-area selection/copy behavior.
- `just nvim-smoke-popupmenu` checks the retained completion menu and glyphs.

The cursor-shape coverage also drives normal block, insert `ver25`, and replace
`hor20` modes through Neovim `mode_info_set` and `mode_change`. The smoke recipes
require Skia frames; `native-smoke` asserts `skia-frames=yes`.

Pixel-backed recipes use macOS Screen & System Audio Recording permission. Do
not run them while self-hosting in Satin. When pixels are explicitly required,
run the relevant visual recipe from an external terminal after confirming the
permission prompt is intended. State/model smokes remain the default regression
path during self-hosting.

## Remaining direction

Deeper Neovide parity may externalize eligible floating or message grids into
independent macOS windows. Ordinary Neovim splits and file-tree panes remain
inside the compositor. Future renderer extensions stay event-driven.
