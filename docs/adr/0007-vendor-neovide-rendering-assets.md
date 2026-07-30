# 0007: Vendor Neovide rendering assets for native Neovim quality

Date: 2026-07-02

Status: Accepted

## Context

The native Neovim pane now consumes `ext_multigrid`, sends dirty row updates
after the initial full refresh, and emits a Neovide-derived retained command
batch for `DrawLine`, `Scroll`, `Viewport`, and window lifecycle events. The
compatibility frame path previously asked AppKit to draw terminal cells. That
path was useful for prototyping, but it is heavier than Neovide's renderer
because it misses Neovide's full glyph/font cache and Skia/Metal pipeline.

Neovide is MIT licensed and implemented in Rust, so its rendering assets can be
reused with attribution.

## Decision

The long-term native Neovim pane should vendor selected Neovide assets instead
of continuing to grow a parallel renderer. The reuse boundary should start with
the Neovide concepts that directly reduce redraw work:

- `DrawCommand` / `WindowDrawCommand` style retained updates.
- `RenderedWindow` style per-window line cache and scrollback animation.
- Neovide's font loading, shaping, fallback, and glyph cache approach.
- Skia/Metal drawing for the Neovim surface.

The AppKit shell remains responsible for macOS windowing, tabs, menus, session
state, and terminal panes. Neovide-derived code is isolated behind a Rust
renderer boundary while the terminal path continues using `libghostty-vt` for
PTY terminal state.

The native Neovim path maintains a Neovide-derived window line cache and
scrollback animation state. UI events apply `WindowDrawCommand`-style updates
directly to retained windows, which are consumed by the Skia/Metal renderer.

The native host now sends the retained model to a Rust Skia/Metal adapter for
the Neovim cell path. The adapter follows Neovide's macOS Metal pattern: wrap
the current drawable texture as a Skia Metal backend render target, draw the
retained windows, flush Skia, and let the Swift `MTKView` present the drawable.
The AppKit row bridge and cursor overlay have been removed; cursor body and
trail rendering live in the Rust Skia/Metal adapter.

The retained model now includes viewport margins, scrollback line source, scroll
position, and event-origin scroll hint metadata. The Rust Skia/Metal adapter
clips each window's scrollable inner region and uses that retained scrollback
source for visual scrollback animation. Fixed margin rows remain outside the
scrolling clip.

The Rust Skia/Metal adapter also owns Neovim text shaping. It uses a
Neovide-derived `swash` shaping path, groups cell text into grid-positioned
clusters, caches Skia `TextBlob`s with `lru`, uses `$SATIN_FONT` as the
primary font, falls back through Skia `FontMgr::match_family_style_character`,
and vendors Neovide's default Nerd Font and LastResort font assets for stable
fallback behavior. Cell snapshots carry bold, italic, underline, and
strikethrough style from Neovim highlights and terminal SGR state so renderer
text runs can choose coarse font style and draw grid-aligned decorations without
inventing a second style channel. Neovim highlight `blend` is retained on cells
and the Skia/Metal adapter applies it as alpha-composited background paint for
floating-window transparency.
Neovim `mode_info_set` and `mode_change` cursor metadata are retained on the
cursor snapshot as shape, cell percentage, and blink timings; the Skia/Metal
cursor body uses the mode cell percentage for vertical and horizontal cursor
thickness. Cursor blink follows Neovide's state model: `blinkon` or `blinkoff`
of zero disables blinking, `blinkwait` may be zero, and the renderer exposes the
next blink deadline to Swift so blinking does not force continuous redraw.
The shaped-text smoke has a screenshot-backed verifier that maps retained-model
cell coordinates to the captured Skia/Metal surface and checks visible glyph
pixels for Japanese, Nerd Font, combining-mark, and ambiguous-width fixture
cells.
The cursor-switch smoke also captures the Skia/Metal surface after changing
tabs and verifies that the active tab's cursor body is visible while the
previous tab's cursor/trail and marker text are absent.
The cursor-shape smokes capture normal block, insert `ver25`, and replace
`hor20` modes and verify that both the renderer model and Skia pixels represent
the expected cursor body. The cursor-blink smoke captures the configured off
phase and verifies that no cursor body pixels remain visible.
The UI-surfaces smoke captures the Skia/Metal surface as well, verifies split,
float, statusline, and message surfaces in the retained model, and checks that a
blended floating-window cell is rendered near the expected composited color.
The popupmenu smoke enables Neovim `ext_popupmenu`, drives command-line
completion through the normal input path, and verifies that the retained
popupmenu model maps to visible Skia/Metal glyph pixels.

The native nvim path reads scroll metadata from the retained model. The older
JSON frame output and AppKit cell renderer were removed after the Skia/Metal
path became mandatory.

The normal terminal pane now uses the same Rust Skia/Metal adapter. The
`libghostty-vt` frame is converted into a single retained normal window, terminal
history scroll deltas are recorded as renderer scroll animation state, and
cursor body/trail rendering is shared with the Neovim path. `native-smoke`
requires `skia-frames=yes`.

Neovide MIT attribution and bundled font OFL attribution are tracked in
`THIRD_PARTY_NOTICES.md`.

## Consequences

This makes the Neovim pane closer to Neovide's quality and performance model,
but adds Skia/Metal renderer complexity and MIT attribution requirements.

Short-term AppKit drawing optimizations are allowed only as stopgaps. New
Neovim-specific rendering behavior should be added to the Neovide-derived
renderer path once that boundary exists.
