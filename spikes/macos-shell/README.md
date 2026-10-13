# macOS Native Shell

This native shell is the executable AppKit/Metal path for ADR 0002's target
architecture, with the core replaced by Kizu as recorded in ADR 0019:

```text
Swift/AppKit shell
  native windows, tabs, menus, settings, keybinding UI, command routing

Kizu terminal core/runtime (core/)
  PTY, libghostty-vt terminal state, panes, Neovim compositor state

AppKit shell + MTKView surface
  native tabs/menus plus core-rendered terminal and Neovim surfaces
```

This path is launched by `just terminal`. The Kizu core
owns terminal parsing and PTY lifecycle; Swift owns the native macOS UI and
presents the panes the core rasterizes with CoreText and CoreGraphics into the
Metal drawable, exposed through the C ABI.

## Build

Use the repository command so the Kizu core and `libghostty-vt` are built inside
the Nix shell while Swift is compiled with the host Xcode toolchain and SDK:

```sh
just native-build
```

That builds:

- `core/target/host/satin.o` and `core/target/native/libghostty-vt.a`, which
  the Swift host links
- `core/target/bin/satin` and `core/target/bin/satin-nvim`, copied beside the
  host executable together with `fonts/`
- `spikes/macos-shell/.build/SatinApplication`
- `just native-dev-app` additionally wraps the debug executables in
  `spikes/macos-shell/.build/dev/Satin Dev.app`.

Run the native host with:

```sh
just terminal
```

The development bundle is distinct from `/Applications/Satin.app`: its name is
`Satin Dev`, its bundle ID is `dev.soyukke.satin.dev`, its settings/session
domain and purple app icon are separate, and its control socket is stored below
`~/Library/Application Support/Satin Dev`. Production update checks are disabled
in this bundle.

Run a non-interactive GUI smoke check without requesting screen or system-audio
recording permission with:

```sh
just native-smoke
```

Smoke scenarios launch as a non-key accessory app so they do not steal focus
from the user's current application. Set `SATIN_NATIVE_SMOKE_ALLOW_ACTIVATION=1`
only for an explicitly interactive smoke that requires key-window behavior.

The standard smoke launches the app briefly and checks its deterministic renderer
frame counter. Pixel capture is intentionally opt-in because macOS groups it
under the Screen & System Audio Recording permission. Run `just
native-visual-smoke` only when that permission prompt and a PNG artifact are
explicitly wanted.

Build a release bundle and distributable archive with:

```sh
just native-package
just native-release
```

The package command emits a versioned, hardened-runtime `.app` and verifies its
signature. The release command also writes a ZIP and SHA-256 update manifest.
When `APPLE_SIGNING_IDENTITY` and `APPLE_NOTARY_PROFILE` are both configured it
uses the Developer ID notarization/stapling/Gatekeeper path; otherwise the
manifest marks the result as a development artifact.

## Current Coverage

- Swift calls the core's C ABI through a thin wrapper, still named `RustCore`.
- The core exposes a JSON snapshot of tabs, recursive pane layout, active pane, and
  theme.
- The core exposes a PTY-backed terminal runtime per pane (`satin_runtime_*`).
- AppKit owns the native tab bar, main/edit/settings menus, rename/search
  dialogs, context menu, IME client, pasteboard, and accessibility surface.
- The context menu updates tab name and color theme through the core.
- `TerminalMetalView` is an `MTKView` that presents the core's renderer output.
- The host starts login shells through the core runtime, and the core renders
  terminal text cells from `libghostty-vt` frame snapshots.
- Native wheel events scroll the core's `libghostty-vt` viewport and animate the
  retained terminal window in the core renderer.
- Terminal key, focus, paste, selection, and mouse events are encoded against
  live `libghostty-vt` modes. OSC title/cwd/bell/link metadata is surfaced to
  native UI.
- All split leaves render into clipped regions of the shared Metal drawable.
  New panes inherit cwd, and native Neovim replacement is an explicit command.
- Kitty image placements and extended terminal decorations are rendered by the
  same core renderer. Native Neovim image.nvim placements reach the same path
  through an early Lua-to-RPC bridge instead of a synthetic TTY.
- Runtime output wakes AppKit through dispatch sources; only active renderer
  animations schedule additional Metal frames.
- The native tab strip ends with a borderless new-tab action, and the right side
  of the toolbar owns the window-scoped Artifact picker and searchable Work
  Switcher. Its rows include compact recent-screen excerpts, while the selected
  row previews more of the pane's retained screen text without selecting the pane
  or creating another renderer. Needs Attention, Running, and Other sections keep
  navigation separate from the Work button's unread `waiting`, `blocked`, `done`,
  and `failed` badge without owning a second layout model. Every workspace pane
  reserves a native header for close and split actions; terminal and Neovim grids
  begin below that chrome. The Artifact sidebar uses the same header for close.
- Agent lifecycle state comes from a bundled-shell session boundary, OSC title
  events, and Satin's additional Claude Code hook settings layer. The bridge
  updates the existing status store without scraping pane text or changing
  user-level Codex/Claude configuration. Projected tmux panes subscribe to
  `pane_title` and feed those transitions through the same tracker.
- Session schema v3 restores recursive splits, terminal/Neovim pane kinds,
  working directories, the active leaf, and consume-once tmux reattach metadata
  with legacy migration.
- Explicit local `tmux -CC` projects byte-safe pane streams, bounded history,
  alternate screens, modes, zoom, bells, and tmux-owned tab/pane actions through
  native surfaces. The unified toolbar picker switches, creates, attaches,
  detaches, and confirmation-gates ending sessions on the local server. Reattach
  checkpoints are limited to a live local tmux socket.
- `just native-smoke` verifies that the native host can launch and render a
  window snapshot, native tabs, dark terminal surface, and PTY text without
  manual interaction. It also requires `skia-frames=yes`, a result
  key that keeps its old name.

`just native-resize-smoke`, `just native-session-smoke`, and
`just native-soak` cover resize propagation, session compatibility, and
repeated lifecycle/handoff scenarios.

`just nvim-layout-redraw-smoke` covers Neovim redraw delivery after closing the
active sibling pane and after resizing the host window.

`just native-tmux-smoke` covers native projection, history, paste, zoom, Satin
control actions, the session-row end action, alternate-screen reattach, explicit
detach, delayed-server reattach, saved non-default socket discovery, and
missing-session recovery.

`just native-tmux-zoom-resize-smoke` is the focused regression check for
shared font zoom, nested projected-tmux grid alignment, terminal and TUI Neovim
sizing, and coalesced host-window resize updates.
`just pane-grid-smoke` also runs the local terminal and native Neovim grid checks
as one four-path release regression gate.

README demo media is recorded from an isolated Satin Dev window by running
`SATIN_ALLOW_SCREEN_CAPTURE=1 just readme-demo` in an external terminal. See
`docs/readme-media.md`; the recipe refuses to capture from a self-hosted pane.
