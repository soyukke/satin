# 0006: Use Neovim multigrid for the native Neovim pane

Date: 2026-07-02

Status: Accepted

Superseded in part by [0019](0019-replace-the-rust-core-with-kizu.md): where
this record names the Rust core, its crates and Cargo tooling, or the
Skia/Metal renderer, 0019 replaced them with the Kizu core in `core/` and its
CoreText/CoreGraphics renderer. The rest of the decision stands; the text below
is kept as it was written.

## Context

The native terminal path can render Neovim through a PTY, but terminal screen
diffing cannot reliably tell editor scrolling apart from cmdline updates,
statusline redraws, file-tree splits, floating windows, and other TUI layout
changes.

Neovide avoids this class of bugs by consuming Neovim UI events directly. In
particular, `grid_scroll` is a screen-cell copy primitive, while editor scroll
semantics come from per-window viewport events.

## Decision

The `just neovim` path uses `nvim --embed` with `ext_multigrid` and keeps a
Rust-side editor/window model. The Rust model owns grids, window positions,
viewport margins, cursor projection, and frame composition.

Scroll animation for the native Neovim pane is derived from `win_viewport`
movement and clipped to the affected window viewport. Raw `grid_scroll` events
only mutate grid state and are not exposed as animation triggers.

## Consequences

The Neovim pane can avoid terminal-diff heuristics for Neo-tree, cmdline,
statusline, and split-window redraws.

The terminal path remains useful for arbitrary TUI programs, but it is not the
quality target for native Neovim behavior.

Future Neovide parity work should extend the multigrid compositor instead of
adding more terminal row-diff special cases.
