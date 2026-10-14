# Renderer behavior and verification

This document records the current retained renderer behavior and its focused
visual smoke coverage. Long-term design constraints remain in
[`docs/adr`](adr/README.md).

## Ownership boundary

AppKit owns windows, tabs, menus, pane layout, input routing, dialogs, and
context menus. The Kizu core in `core/` owns terminal state, the Neovim
compositor, retained renderer state, and the drawing path. Terminal behavior
remains owned by `libghostty-vt`. The decision and its trade-offs are recorded
in [ADR 0019](adr/0019-replace-the-rust-core-with-kizu.md).

Both `just terminal` and `just neovim` draw retained renderer models into the
current `MTKView` drawable. The renderer owns backgrounds, glyphs, decorations,
images, scroll animation, and Neovide-derived four-corner cursor geometry.

## Drawing path

Each frame is built as a display list (`core/src/draw`): a flat run of
rectangle, line, quad, text-run, image, and clip commands in device pixels that
names no drawing library. The CoreGraphics backend (`core/src/draw/quartz.kizu`)
executes the list on the CPU into a premultiplied BGRA bitmap, and the host
boundary (`core/host`) copies the pixels each pane wrote into the drawable's
`MTLTexture`. Swift still owns the `MTKView` and presents the drawable. The C
exports keep the `satin_skia_metal_*` names the Swift host already links; Skia
is not used.

By default the list is drawn on the GPU instead. The GPU backend
(`core/src/draw/gpu.kizu`) turns it into triangles: rectangles of one color,
glyphs from an atlas that CoreGraphics rasterizes each glyph into once, at one
of four positions a pixel, and images over their own textures, each run of
triangles inside its clip. `NativeGpuRenderer.swift` uploads the atlas's
changed part and draws the triangles with Metal into the drawable. The CPU
backend stays as the fallback: set `SATIN_GPU_RENDERER=0`, or run
`defaults write dev.soyukke.satin gpuRenderer -bool false`. The GPU path
differs from the CPU one in that a glyph's y is rounded to a whole pixel, a
quad command is not antialiased, and a glyph is blended as coverage.

Measured at 200x60 cells on a 3000x1800 target, a frame costs about 1.8 ms
with a warm shaped-run cache and about 10 ms when every run is new text.

The core starts no threads. The host waits on the PTY, the Neovim pipe, or the
control server's kernel queue descriptor and calls the matching drain export
from its one calling thread.

## Scroll model

`core/src/term/render.kizu` owns the retained-window spring model. Terminal and
Neovim runtimes feed two event-driven scroll sources into it:

- Terminal history applies integer rows to `libghostty-vt`, retains fractional
  wheel movement in the renderer, and settles to a cell boundary after wheel
  idle. Primary-screen output growth comes from the VT scrollbar state.
- Direct interactive Neovim uses `win_viewport.scroll_delta`. Other full-screen
  terminal applications use explicit VT insert, delete, or scroll commands and
  their declared scroll region.
- Projected tmux panes decode those VT commands into compact row/region metadata.
  An already-hydrated pane is resized through its live VT runtime; a size-only
  snapshot never triggers a full scrollback capture. Initial history hydration
  is active-window-first and permits only one capture in flight, keeping tmux
  navigation out of a multi-window capture backlog. Hydration never drops an
  overlapping scroll animation, forwards unrelated redraw bytes, or replays the
  live cells a second time. Normal `%output` preserves the incremental VT/OSC
  parser across record boundaries; only an actual hydration resets it.
- Neovim TUI inside local tmux emits a private, versioned OSC event from
  `WinScrolled` when a vertical split or file tree forces a partial-width redraw.
  The terminal retained window animates only the declared row/column rectangle;
  neighboring windows, separators, and statuslines stay fixed. Coalesced rapid
  scroll events are bounded to that inner rectangle before they enter the
  retained spring, avoiding the far-jump discontinuity at a pane boundary.

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

Neighboring cells that share a color and style form one text run. CoreText
shapes each run with standard ligatures on, and every cell's glyphs are placed
back on that cell's own column, so text stays on the grid. Fonts are tried in
a fixed order: the configured family in the run's weight and slant, the file
`SATIN_FONT` names, the bundled FiraCode Nerd Font, the default system family,
the font CoreText falls back to for the text, and the bundled LastResort last.
The bundled fonts are loaded at run time from `fonts/` beside the executable or
`Contents/Resources/fonts` in the bundle. Faint, blink, underline variants and
colors, strikethrough, and overline remain grid-aligned.

Shaped runs are cached by a hash of their cells' text, weight, and slant. The
cache holds up to 10,000 runs and 65,536 glyphs and is emptied whole when
either limit is passed; it is not an LRU.

Known differences from the earlier Skia renderer:

- Glyphs are rasterized by CoreGraphics with font smoothing off. There is no
  font hinting and none of Skia's contrast and gamma tables, so glyph edge
  pixels differ from the Skia build.
- Shaping is CoreText's. Ligatures, contextual alternates, and mark positioning
  are applied, but a font's rarer features need not match the previous shaper.
- A configured family without a bold or italic face is drawn regular.

AppKit owns the `NSTextInputClient` contract and IME candidate coordinates, but
the active preedit string is composited by the same CoreText shaper as committed
grid text. This keeps CJK fallback metrics and the cell baseline stable when a
composition is committed.

Kitty graphics are decoded through `libghostty-vt` and composited with pane
clipping and z-order. Embedded Neovim and projected tmux panes bridge image.nvim
commands into the same bounded decoder while arbitrary regular-file reads stay
disabled.

## Visual smoke matrix

Renderer changes normally run the non-capturing `just native-smoke` plus the
relevant focused recipes. For retained Neovim scrolling and layout, start with:

The user-facing reproduction sequence is kept in
[`manual-regression-checklist.md`](manual-regression-checklist.md).

- `just nvim-smoke-scroll` checks Ctrl-D-style retained scroll animation.
- `just nvim-smoke-jump` checks large jump animation.
- `just nvim-smoke-side-pane` keeps file-tree and other side-pane scroll hints
  column-bounded.
- `just nvim-layout-redraw-smoke` checks pane close and rapid host resize without
  a lost Metal frame request.
- `just frame-liveness-smoke` injects a redraw request at the idle/pause boundary,
  then repeats terminal input and tab switching. Every phase waits for the
  matching `CAMetalDrawable` presentation rather than only accepting a submitted
  renderer frame.
- `just nvim-smoke-commandline` and `just nvim-smoke-cursor-move` reject false
  scroll animation from command-line or cursor-only redraws.

The scroll, jump, side-pane, and tmux reattach recipes use the production
`CAMetalDisplayLink`. Their input is routed as an AppKit key event, and each
scroll must retain a nonzero fractional position on a later presented frame;
raw control-byte injection or a smoke-only frame scheduler is insufficient.

Pixel-backed checks add:

- `just nvim-smoke-scroll-visual` records two physical `Ctrl-D` inputs at
  60 fps, requires multiple presented intermediate frames for both inputs, and
  rejects movement in the fixed side pane.
- `just nvim-smoke-shaped-text-visual` checks Japanese, Nerd Font,
  combining-mark, and ambiguous-width glyph pixels.
- `just nvim-smoke-cursor-switch` checks cursor ownership after tab switches.
- `just nvim-smoke-cursor-blink` checks the configured cursor blink-off phase.
- `just nvim-smoke-ui-surfaces` checks blended floating windows and native
  message-area selection/copy behavior.
- `just nvim-smoke-popupmenu` checks the retained completion menu and glyphs.

The cursor-shape coverage also drives normal block, insert `ver25`, and replace
`hor20` modes through Neovim `mode_info_set` and `mode_change`. The smoke recipes
require renderer frames; `native-smoke` asserts `skia-frames=yes`, a result key
that keeps its old name.

`just test` also renders offscreen into a real Metal drawable and reads the
pixels back (`core/scripts/test-drawable`). It opens no window and captures no
screen, so it runs in CI and while self-hosting.

Pixel-backed recipes use macOS Screen & System Audio Recording permission. Do
not run them while self-hosting in Satin. When pixels are explicitly required,
run the relevant visual recipe from an external terminal after confirming the
permission prompt is intended. State/model smokes remain the default regression
path during self-hosting.

## Remaining direction

Deeper Neovide parity may externalize eligible floating or message grids into
independent macOS windows. Ordinary Neovim splits and file-tree panes remain
inside the compositor. Future renderer extensions stay event-driven.
