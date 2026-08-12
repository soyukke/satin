# 0007: Vendor Neovide rendering assets for native Neovim quality

Date: 2026-07-02
Amended: 2026-08-13

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
Window placement and grid storage size remain separate inputs, matching
Neovide's `grid_position`/`grid_size` split. Renderer cache dimensions always
come from `grid_resize`, even when `win_viewport_margins` creates window state
before `win_pos`; placement defaults must never shrink a newly resized cache.
`win_viewport.scroll_delta` remains the sole Neovim scroll-animation signal:
zero deltas do not cancel an active spring, and buffer length or rendered text
is never used to override Neovim's viewport semantics.
The retained visible lines and scrollback both use Neovide's
logical-current-index ring model; scrollback capacity is twice the inner
viewport height. Rotation, circular indexing, resizing, and far-jump blank rows
follow `RenderedWindow::flush` in both directions. In particular, positive
animation offsets after an upward viewport jump wrap past the backing array
edge instead of dropping the lower visible rows.

The native host now sends the retained model to a Rust Skia/Metal adapter for
the Neovim cell path. The adapter follows Neovide's macOS Metal pattern: wrap
the current drawable texture as a Skia Metal backend render target, draw the
retained windows, flush Skia, and let the Swift `MTKView` present the drawable.
The AppKit row bridge and cursor overlay have been removed; cursor rendering
lives in the Rust Skia/Metal adapter.
Normal AppKit frame updates do not serialize that retained cell model. Swift
receives only a compact cursor and pending scroll-hint snapshot for input-method
placement and smoke metadata; the complete JSON model remains available to
explicit smoke and control reads. This keeps the Rust retained model as the
rendering authority without duplicating every highlighted cell across the FFI
boundary before Metal can draw it.

Message-area drag selection follows Neovide's client-overlay boundary. A left
press is consumed only when the topmost retained window is a message window;
normal editor, split, floating, and file-tree input continues to Neovim. Rust
retains the selected message grid and local cell range, clamps drags to the
window, draws a 35%-alpha foreground overlay in Skia, and extracts trimmed
multi-line text on release. AppKit owns only pointer routing and the macOS
pasteboard write. Hiding, closing, or destroying the selected message grid
clears the overlay. This preserves the event-origin compositor and avoids an
AppKit cell-renderer selection path.

The retained model now includes viewport margins, scrollback line source, scroll
position, and event-origin scroll hint metadata. The Rust Skia/Metal adapter
clips each window's scrollable inner region and uses that retained scrollback
source for visual scrollback animation. Fixed margin rows remain outside the
scrolling clip.
As in Neovide's `RenderedWindow`, the fractional scroll transform is rounded
to device pixels before drawing cached text. Cursor snapshots retain their
parent grid ID; the renderer applies the same window spring to the cursor and
clamps it inside the scrollable viewport so text does not shimmer independently
from the cursor during `Ctrl-D`, `Ctrl-U`, and large jumps.
Each frame follows Neovide's ordering: retained-window springs advance first,
the renderer snapshot is taken, the cursor destination and its four corner
springs advance from that same post-animation window state, and the result is
drawn. A normal one-line cursor move therefore deforms only the cursor polygon;
it does not translate the editor window.
The AppKit Metal host uses `CAMetalDisplayLink`, whose callback supplies an
available drawable at the attached display's cadence. The link runs only while
Rust reports an immediately active animation, then pauses again at rest. Future
cursor or text-blink deadlines use one replaceable timer, while input resumes
the link for one frame. Rendering therefore neither spins a zero-delay dispatch
loop nor blocks the main thread in `CAMetalLayer.nextDrawable()`.
Native pixel-smoke processes are the exception: the test runner can execute
while `loginwindow` is frontmost, in which case macOS suppresses display-link
callbacks even though the Rust renderer still requests an immediate frame.
The delayed cursor-shape pixel-smoke processes are the exception: they use
`MTKView` one-shot invalidation with the same Skia renderer so their cursor and
blink animations remain testable under a locked compositor. Other smoke cases
continue to exercise the display link. Remove this fallback when the smoke
runner guarantees an active display, or replace it with an offscreen drawable
path; it must not be enabled in the packaged application.
Like Neovide's per-window surface draw, each visible retained normal window
clears its entire grid rectangle to the default background before cached lines
are drawn. This lets a resized foreground grid cover stale root-grid separators
after a split such as Neo-tree closes, even when Neovim does not resend every
blank foreground line. Overlapping floating grids instead share a layer: Satin
clears their combined rectangular footprint before drawing any member, then
composites them in `zindex` / `compindex` order. Message grids remain isolated
layers. This preserves Telescope results and prompt text when a later
transparent border grid overlaps their content. Standard eight-field
`win_float_pos` events are placed from their anchor type, parent grid, and
anchor coordinates; Neovim's optional composed screen coordinates take
precedence when present.

The Rust Skia/Metal adapter also owns Neovim text shaping. It uses a
Neovide-derived `swash` shaping path, groups cell text into grid-positioned
clusters, caches Skia `TextBlob`s with `lru`, uses `$SATIN_FONT` as the
primary font, falls back through Skia `FontMgr::match_family_style_character`,
and vendors Neovide's default Nerd Font and LastResort font assets for stable
fallback behavior. Before generic system fallback, the warning sign and the
five dingbats used by Claude Code's terminal spinner prefer Menlo's monochrome
glyphs. This narrow override prevents one animation frame from resolving to
Apple Color Emoji while preserving configured-font precedence and normal emoji
fallback for every other character. Cell snapshots carry bold, italic,
underline, and strikethrough style from Neovim highlights and terminal SGR
state so renderer
text runs can choose coarse font style and draw grid-aligned decorations without
inventing a second style channel. Neovim highlight `blend` is retained on cells
and the Skia/Metal adapter applies it as alpha-composited background paint for
floating-window transparency.
The mutable Neovim grid and retained line snapshots share copy-on-write cell-row
storage; retained snapshots also share their immutable line text. Above the word
shape cache, the text renderer keeps a bounded prepared-line cache keyed by the
shared cell-row identity and clipped width. A prepared line owns its shaped
`TextBlob`s, colors, styles, and grid spans, so unchanged scrollback lines reuse
glyph work throughout cursor and scroll animation instead of cloning cells,
rebuilding runs, and re-entering the shape cache on every Metal frame. A changed
line gets a new identity; the lower word cache can still reuse glyphs after
background-only changes. Cell-size or font-family changes clear the prepared
cache before the next draw.
Contiguous cells with the same background color and `blend` are emitted as one
Skia rectangle. Diff highlights commonly cover most of a row, so this preserves
cell semantics while avoiding one GPU draw operation per highlighted cell.
Those background runs and the presence of blinking text are derived once when
an immutable retained line is created, then shared with every snapshot clone.
They are renderer-only state and are omitted from the serialized control/smoke
protocol. Metal frames therefore iterate the small run list instead of scanning
every visible cell again, while changed rows remain the only invalidation
boundary.
Neovim `grid_scroll` updates reuse the mutable grid storage as well: full-width
vertical movement rotates row buffers, horizontal movement rotates cell slices,
and partial two-axis movement copies only the affected rows from a copy-on-write
row snapshot. Scrolling no longer deep-clones the complete grid and every cell
string before retained draw commands are applied.
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
previous tab's cursor and marker text are absent.
The cursor-shape smokes capture normal block, insert `ver25`, and replace
`hor20` modes and verify that both the renderer model and Skia pixels represent
the expected cursor body. The cursor-blink smoke captures the configured off
phase and verifies that no cursor body pixels remain visible.
The UI-surfaces smoke captures the Skia/Metal surface as well, verifies split,
float, statusline, and message surfaces in the retained model, and checks that a
blended floating-window cell is rendered near the expected composited color. It
also drives message selection through AppKit and the FFI boundary, verifies the
retained overlay, and checks the copied text while preserving the existing
pasteboard contents.
The popupmenu smoke enables Neovim `ext_popupmenu`, drives command-line
completion through the normal input path, and verifies that the retained
popupmenu model maps to visible Skia/Metal glyph pixels.
The file-tree-close smoke records the closed split's grid and separator column,
then verifies that the grid is no longer visible and that no separator pixels
remain in a captured Skia/Metal frame. A raster renderer regression test also
checks that an empty foreground window masks populated root-grid cells.

The native nvim path consumes scroll metadata from the compact UI state while
the Rust renderer reads retained windows directly. The older per-update JSON
cell frame and AppKit cell renderer are not part of the production frame path.

The normal terminal pane now uses the same Rust Skia/Metal adapter. The
`libghostty-vt` frame is converted into a single retained normal window, terminal
history scroll deltas are recorded as renderer scroll animation state, and
four-corner cursor rendering is shared with the Neovim path. Primary-screen
output growth comes from `libghostty-vt` scrollbar state. Alternate-screen TUI
animation is triggered only by explicit VT line insert/delete or scroll commands
(`CSI L/M/S/T`), and the command's declared VT scroll region supplies the fixed
top and bottom margins. Visible rows and cell background colors are not inspected
to infer either motion or statusline boundaries. Direct interactive Neovim
commands no longer use this terminal path; ADR 0012 routes them to the native
event-origin compositor while retaining the calling PTY. The terminal scroll
tracker remains generic support for other alternate-screen applications.
`native-smoke` requires `skia-frames=yes`, and `shell-nvim-smoke` guards native
terminal-split scrolling plus same-shell restoration.

Neovide MIT attribution and bundled font OFL attribution are tracked in
`THIRD_PARTY_NOTICES.md`.

Externalized windows remain a separate future decision. In this context the
term means mapping eligible floating or message grids to independent macOS
windows, not externalizing normal splits or file-tree panes. Implementing that
requires explicit focus, lifecycle, placement, and session semantics and is not
implied by multigrid rendering alone.

## Consequences

This makes the Neovim pane closer to Neovide's quality and performance model,
but adds Skia/Metal renderer complexity and MIT attribution requirements.

Neovide's per-line Skia `Picture` recording was evaluated for this Metal path
but is not retained: Ganesh picture replay still entered the text/glyph path and
increased end-to-end work in the diff-scroll benchmark. Reconsider it only with
backend-specific frame and glyph-cache measurements; retained line metadata and
prepared `TextBlob`s remain the smaller cache boundary for now.

A GPU image per retained line and a shared line-raster atlas were also evaluated
and rejected. Both reduced renderer CPU in an unoptimized development build,
but the per-line form raised GPU queue p95 to about 5.2 ms in the real
user-configured four-window Diffview workload. The shared atlas removed that
texture-switching regression, yet increased optimized renderer p50 from about
0.67 to 1.11 ms. Neither cache belongs in the production renderer.

The larger cause was the daily `just terminal` path compiling Rust and Swift
without optimization even though it is exercised as an interactive 60 Hz app.
The development Cargo profile now matches release runtime code generation and
disables incremental and debug artifacts; the native Swift host uses `-O` with
whole-module optimization. Rust tests retain their separate test profile. In
three eight-second runs at a fixed 15-point font and 115x37 grid, the median
four-window Diffview renderer p50 fell from 0.943 to 0.673 ms, p95 from 1.757 to
0.842 ms, and p99 from 2.372 to 0.972 ms. Satin CPU fell from 1.39 to 0.76
seconds, main-thread Neovim drain p99 from 1.148 to 0.130 ms, and peak combined
RSS from 236,192 to 229,728 KiB without a Neovim cadence regression. The final
development renderer p50 is within measurement noise of the packaged release
build (0.678 ms under the same geometry).

The opt-in `just nvim-perf` harness records renderer, presentation, GPU queue,
main-thread drain, Neovim cadence and grid geometry, process CPU, and RSS as JSON
for the same synthetic or user Diffview workload without production log noise.

Short-term AppKit drawing optimizations are allowed only as stopgaps. New
Neovim-specific rendering behavior should be added to the Neovide-derived
renderer path once that boundary exists.
