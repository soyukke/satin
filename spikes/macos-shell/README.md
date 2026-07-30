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

Run the native host with:

```sh
just terminal
```

Run a non-interactive GUI smoke check with:

```sh
just native-smoke
```

The smoke check launches the app briefly, writes
`spikes/macos-shell/.build/native-smoke.png`, and exits.

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
  Rust Skia/Metal path.
- Runtime output wakes AppKit through dispatch sources; only active renderer
  animations schedule additional Metal frames.
- Session schema v2 restores recursive splits, terminal/Neovim pane kinds,
  working directories, and the active leaf with legacy migration.
- `just native-smoke` verifies that the native host can launch and render a
  window snapshot, native tabs, dark terminal surface, and PTY text without
  manual interaction. It also requires `skia-frames=yes`.

`just native-resize-smoke`, `just native-session-smoke`, and
`just native-soak` cover resize propagation, session compatibility, and
repeated lifecycle/handoff scenarios.
