# macOS Native Shell

This native shell is the first executable AppKit/Metal path for ADR 0002's
target architecture:

```text
Swift/AppKit shell
  native windows, tabs, menus, settings, keybinding UI, command routing

Rust terminal core/runtime
  PTY, libghostty-vt terminal state, panes, Neovim compositor state

AppKit shell + MTKView surface
  native tabs/menus plus Rust Skia/Metal terminal and Neovim surfaces
```

This path is launched by `just terminal`. The Rust
library owns terminal parsing and PTY lifecycle; Swift owns the native macOS UI
and presents Rust Skia/Metal-rendered terminal panes exposed through the C ABI.

## Build

Use the repository command so Rust is built inside the Nix shell while Swift is
compiled with the host Xcode toolchain and SDK:

```sh
just native-build
```

That builds:

- `target/debug/libsatin.a`
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

The standard smoke launches the app briefly and checks its deterministic Skia
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

- Swift calls the Rust C ABI through a thin `RustCore` wrapper.
- Rust exposes a JSON snapshot of tabs, recursive pane layout, active pane, and
  theme.
- Rust exposes a PTY-backed `NativeTerminalRuntime` per pane.
- AppKit owns the native tab bar, main/edit/settings menus, rename/search
  dialogs, context menu, IME client, pasteboard, and accessibility surface.
- The context menu updates tab name and color theme through Rust.
- `TerminalMetalView` is an `MTKView` that presents the Rust Skia/Metal renderer.
- The host starts login shells through the Rust runtime and renders terminal
  text cells from `libghostty-vt` frame snapshots in Rust/Skia.
- Native wheel events scroll the Rust `libghostty-vt` viewport and animate the
  retained terminal window in Rust/Skia.
- Terminal key, focus, paste, selection, and mouse events are encoded against
  live `libghostty-vt` modes. OSC title/cwd/bell/link metadata is surfaced to
  native UI.
- All split leaves render into clipped regions of the shared Metal drawable.
  New panes inherit cwd, and native Neovim replacement is an explicit command.
- Kitty image placements and extended terminal decorations are rendered by the
  Rust Skia/Metal path. Native Neovim image.nvim placements reach the same path
  through an early Lua-to-RPC bridge instead of a synthetic TTY.
- Runtime output wakes AppKit through dispatch sources; only active renderer
  animations schedule additional Metal frames.
- The native tab strip ends with a borderless new-tab action. Every pane reserves
  a native header for close, split, and artifact actions; terminal and Neovim
  grids begin below that chrome.
- Session schema v3 restores recursive splits, terminal/Neovim pane kinds,
  working directories, the active leaf, and consume-once tmux reattach metadata
  with legacy migration.
- Explicit local `tmux -CC` projects byte-safe pane streams, bounded history,
  alternate screens, modes, zoom, bells, and tmux-owned tab/pane actions through
  native surfaces. The unified toolbar picker switches, creates, attaches, and
  detaches sessions on the local server. Reattach checkpoints are limited to a
  live local tmux socket.
- `just native-smoke` verifies that the native host can launch and render a
  window snapshot, native tabs, dark terminal surface, and PTY text without
  manual interaction. It also requires `skia-frames=yes`.

`just native-resize-smoke`, `just native-session-smoke`, and
`just native-soak` cover resize propagation, session compatibility, and
repeated lifecycle/handoff scenarios.

`just nvim-layout-redraw-smoke` covers Neovim redraw delivery after closing the
active sibling pane and after resizing the host window.

`just native-tmux-smoke` covers native projection, history, paste, zoom, Satin
control actions, alternate-screen reattach, explicit detach, and missing-session
recovery.
