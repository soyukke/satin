<p align="center">
  <img src="assets/app-icon.png" width="180" height="180" alt="Satin app icon">
</p>

<h1 align="center">Satin</h1>

<p align="center">
  A native macOS terminal with tabs, splits, animated cursor movement, and smooth scrolling.
</p>

<p align="center">
  <a href="https://github.com/soyukke/satin/releases/latest"><img
    src="https://img.shields.io/github/v/release/soyukke/satin"
    alt="Latest release"></a>
  <a href="https://github.com/soyukke/satin/actions/workflows/macos.yml"><img
    src="https://github.com/soyukke/satin/actions/workflows/macos.yml/badge.svg"
    alt="macOS production gate"></a>
  <a href="LICENSE"><img
    src="https://img.shields.io/github/license/soyukke/satin"
    alt="MIT License"></a>
</p>

> [!IMPORTANT]
> Existing Neovide Tabs installations should first update to the signed
> [0.1.7 migration bridge](https://github.com/soyukke/neovide-tabs/releases/tag/v0.1.7).
> Its in-app updater installs `Satin.app` from this repository without breaking
> the existing Ed25519 trust chain or discarding settings and session state.

Satin combines a Rust terminal core and Neovide-derived Skia/Metal
renderer with a native AppKit shell. Terminal bytes flow through a real PTY and
`libghostty-vt`, while AppKit owns the macOS window, menus, tabs, pane layout,
settings, and input translation.

## Highlights

- Native tabs, recursive splits, working-directory inheritance, and session
  restore.
- Neovide-style animated cursor movement and retained smooth scrolling.
- Native copy/paste, IME, rectangular selection, scrollback search, clickable
  links, and a scroll indicator.
- A native Settings window for appearance, shell, startup directory,
  keybindings, session behavior, and signed updates.
- An experimental native Neovim UI backed by `nvim --embed`, `ext_multigrid`,
  and the same Skia/Metal renderer.
- Kitty graphics support and an owner-only `satinctl` automation interface.
- Publisher-signed in-app updates distributed through GitHub Releases.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer

Intel Macs are not supported.

## Install

1. Download the macOS arm64 ZIP from the
   [latest GitHub Release](https://github.com/soyukke/satin/releases/latest).
2. Extract `Satin.app` and move it to `/Applications`.
3. Launch the application from `/Applications`.

Public release archives are publisher-signed for the in-app updater but are
not currently notarized with an Apple Developer ID. On first launch, macOS may
require Control-clicking the app and choosing Open, or allowing it from
System Settings → Privacy & Security. Later releases can be installed from
Help → Check for Updates… → Update and Restart.

## Build from source

```sh
./scripts/dev
```

or:

```sh
nix develop --command just terminal
```

The development environment is managed by the repository's Nix flake and
requires Xcode. `libghostty-vt-sys` currently needs Zig 0.15.2 for the Ghostty
commit it builds, so the flake uses `nixpkgs#zig_0_15`. No Homebrew-managed
dependencies are required.

```sh
nix develop
just terminal
```

## Commands

```sh
just             # list recipes
just terminal    # build and launch the native AppKit terminal host
just neovim      # build and launch the native Neovim UI pane
just native-build # build the AppKit/Metal host without launching it
just native-package # build and locally verify a hardened-runtime .app
just native-release # build a ZIP plus checksummed update manifest
just native-update-test # test version ordering and GitHub update metadata
just native-update-install-smoke # test atomic replacement and rollback paths
just native-update-release-smoke # verify a signed ZIP with the embedded key
just native-settings-smoke # capture and verify every native Settings tab
just native-control-smoke # exercise satinctl and its owner-only socket
just native-kitty-smoke # verify Kitty transfer, isolation, deletion, and pixels
just native-notarize # Developer ID sign, notarize, staple, and assess the .app
just native-smoke # launch the native host briefly and write a PNG smoke shot
just native-package-smoke # visually verify the exact Release .app executable
just native-resize-smoke # verify window resizing reaches terminal pane grids
just native-session-smoke # verify v2 sessions, migration, and corruption policy
just native-soak # repeat high-risk native lifecycle and input smokes
just terminal-vim-scroll-smoke # verify Vim-style terminal scroll animates in Skia
just terminal-nvim-handoff-smoke # verify explicit native Neovim pane replacement
just terminal-nvim-cwd-smoke # verify native Neovim inherits the terminal cwd
just terminal-nvim-quit-smoke # verify :qa returns the pane to a terminal
just nvim-skia-smoke # screenshot smoke for the native Neovim Skia/Metal pane
just nvim-smoke-all # run deterministic Neovim scroll/jump/pane/cmdline smokes
just nvim-smoke-shaped-text-visual # verify shaped glyph pixels in a screenshot
just nvim-smoke-ui-surfaces # verify split/float/message surfaces and float blend
just nvim-smoke-popupmenu # verify popupmenu model and Skia pixels
just nvim-smoke-cursor-normal-shape # verify normal-mode block cursor in Skia
just nvim-smoke-cursor-shape # verify Neovim mode cursor shape in Skia
just nvim-smoke-cursor-replace-shape # verify replace-mode horizontal cursor in Skia
just nvim-smoke-cursor-blink # verify cursor blink off phase in Skia
just nvim-smoke-cursor-switch # verify cursor body/trail cleanup after tab switch
just adr         # list Architecture Decision Records
just adr-new     # create a new ADR
just check       # cargo check
just lint        # clippy with -D warnings
just test        # cargo test
just fmt         # cargo fmt
just precommit   # fmt --check + lint + test
just ops-lint    # ShellCheck release/smoke scripts and validate Actions YAML
just secrets-staged # scan staged changes for secrets, as the commit hook does
just secrets     # scan all Git history plus the current worktree
just install-hooks # use repo-managed Git hooks
just verify      # fmt --check + check + lint + test
just doctor      # print tool versions and selected font
```

## Architecture Decisions

Architecture Decision Records live in [`docs/adr`](docs/adr). They capture the
long-term direction for decisions such as the native macOS shell, Rust terminal
core, Metal renderer, and Kitty graphics protocol support.

The Rust lint gate is intentionally strict: `just verify` runs
`cargo clippy --all-targets --all-features -- -D warnings`. New code should
either satisfy the lint or have a narrow, explicit reason for an allow.
Function bodies are capped at 70 lines via Clippy, and Rust formatting is capped
at 100 columns via `rustfmt.toml`.

Git pre-commit hooks live in [`.githooks`](.githooks). Run `just install-hooks`
once per clone to make Git use them. The pre-commit hook runs `just precommit`,
which first scans staged changes with Gitleaks, then performs
`cargo fmt -- --check`, Clippy with `-D warnings`, `cargo test`, the bundled
license/provenance audit, ShellCheck, and GitHub Actions validation. Gitleaks is
provided by the Nix development shell;
no Homebrew or globally installed hook framework is required. `just secrets`
performs the publication-grade full-history and worktree scan used by CI.

Please report vulnerabilities through GitHub's private vulnerability reporting
flow as described in [`SECURITY.md`](SECURITY.md), not in a public issue.

Native macOS shell code lives in [`spikes/macos-shell`](spikes/macos-shell).
It links the Rust core and PTY-backed terminal runtime through a small C ABI,
owns the native window/menu/tab surface, and presents Rust Skia/Metal-rendered
terminal and Neovim panes.

## Release

`just native-release` creates the Apple Silicon archive
`spikes/macos-shell/.build/release/Satin-<version>-macOS-arm64.zip` and
`latest.json`. With no Apple credentials it produces an ad-hoc signed artifact
and labels the manifest as `development`.

Pushing a tag that exactly matches the Cargo package version publishes a GitHub
Release after the full verification and packaged-application smoke gates pass:

```sh
git tag v0.2.1
git push origin v0.2.1
```

The tag workflow runs on GitHub's Apple Silicon runner, attaches the arm64 ZIP
and manifest to the Release, generates release notes, and records GitHub build
provenance. Workflow artifacts remain CI diagnostics; the stable distribution
and update channel is GitHub Releases.

For a production artifact, configure a Developer ID Application identity in
`APPLE_SIGNING_IDENTITY` and a `notarytool` keychain profile name in
`APPLE_NOTARY_PROFILE`, then run `just native-release`. That route adds a secure
timestamp, notarizes and staples the bundle, validates the ticket, runs
Gatekeeper assessment, and only then writes the release archive and SHA-256
manifest. Signing credentials and notary secrets are never stored in this
repository.

According to the Updates preference, the packaged application checks GitHub's
latest Release after launch on an every-launch, daily, or weekly interval. It
stays silent when current or offline and presents an alert only when a newer
semantic version is available. Help → Check for Updates… performs the same
check interactively and reports every outcome.

Neovide Tabs 0.1.6 introduced the signed migration bridge to Satin. Version
0.1.7 is the final, notice-complete release in the legacy repository. It uses
the trusted update feed at
`soyukke/satin`, accepts the renamed bundle, and atomically replaces
`Neovide Tabs.app` with `Satin.app`. Satin migrates the old macOS defaults
domain on first launch without overwriting values already saved by Satin.

For every update, Satin downloads the exact arm64 asset and schema-2 manifest,
validates its declared size and SHA-256, verifies its Ed25519 publisher
signature, extracts and validates the bundle ID/version/architecture/code
signature, then stages it alongside the installed application. A detached
helper waits for the old process to exit, swaps the staged bundle into place,
launches it, and moves the previous bundle to the user's Trash so rollback
remains possible.

The Ed25519 public key and identifier are checked in at
[`assets/update-signing-public-key.json`](assets/update-signing-public-key.json).
The private key is never stored in the repository. Release Actions read
`UPDATE_SIGNING_PRIVATE_KEY_B64` from GitHub Actions Secrets. The maintainer's
recoverable local copy remains in macOS Keychain under the legacy service
`dev.soyukke.neovide-tabs.update-signing`, account `soyukke`, so the update
trust root survives the rename. Losing both copies would prevent existing
installations from trusting future updates, so key rotation must be shipped
and cross-signed before retiring this key.

This updater signature authenticates project releases without an Apple
Developer ID. It does not remove the first-install Gatekeeper warning; Apple
notarization remains a separate trust boundary.

Rust diagnostic verbosity is controlled by
`SATIN_LOG=off|error|warn|info|debug|trace`; native lifecycle/runtime/session
events use macOS unified logging.

## Terminal Features

- Launches the native AppKit terminal host through `just terminal`.
- Spawns the user's shell in a real PTY from the Rust runtime.
- Feeds PTY output through `libghostty-vt`.
- Renders terminal and Neovim panes through the Rust Skia/Metal adapter.
- Encodes keys and mouse events with `libghostty-vt` using active terminal
  modes, including application cursor mode, bracketed paste, and focus events.
- Supports AppKit IME composition, native copy/paste, drag/rectangular
  selection, select-all, scrollback search, command-clickable OSC 8 and plain
  URL links, OSC title updates, bell feedback, and a native scroll indicator.
- Keeps recursive split layout and tab metadata in the Rust core. AppKit renders
  every split leaf into a clipped region of one shared Metal drawable and routes
  focus/input to the selected pane.
- Inherits the active pane working directory for new tabs, splits, and explicit
  native Neovim replacement.
- Stores font size, Option-as-Alt, bell attention, session-restore preferences,
  and versioned recursive tab/pane session metadata in macOS `UserDefaults`.
- Provides a native Settings window for general behavior, font and theme,
  shell and startup directory, conflict-checked keybindings, and signed-update
  frequency. Live-safe settings apply immediately; shell and directory changes
  apply to newly created panes.
- Bundles `satinctl`, a versioned local control CLI for reading visible pane
  text, sending input and keys, creating and naming tabs/splits, changing
  themes, and coordinating agent status.
- Uses runtime wakeup descriptors and renderer animation deadlines instead of
  permanent 60 Hz polling, and tears down PTY process groups and reader threads
  when panes close.
- Animates cursor movement in the Rust Skia/Metal renderer with a
  Neovide-style trail.
- Scrolls `libghostty-vt` history from the native wheel event and animates the
  retained terminal window through the Skia/Metal renderer.
- Launches an experimental native Neovim UI pane through `just neovim` or the
  File → Open Native Neovim command, backed by `nvim --embed`, `ext_multigrid`,
  and a Rust editor/window compositor instead of terminal cell diffing. Typing
  `nvim` in a shell remains ordinary terminal input and is never intercepted.
- Preserves terminal faint, blink, overline, strikethrough, underline variants,
  and underline colors through the retained model.
- Decodes Kitty graphics through `libghostty-vt` and composites visible image
  placements in Skia/Metal with pane clipping and z-order. RGBA and Skia image
  objects are cached by image generation and released with their pane runtime.
  Direct data, owner-scoped Kitty temporary files, and shared memory are
  supported; arbitrary regular-file reads remain disabled.

## Settings

Open Satin → Settings… or press `Command-,`.

- General controls Option-as-Alt, bell attention, and session restore.
- Appearance selects a fixed-pitch font, font size, and the default theme for
  new tabs.
- Terminal selects an executable absolute shell path and an existing startup
  directory for new panes. Empty values use the login shell and inherit the
  active working directory.
- Keybindings customizes session, pane, Neovim, zoom, and update commands.
  Invalid, duplicate, and standard app-reserved shortcuts are rejected.
- Updates enables signed checks and selects every-launch, daily, or weekly
  frequency.

Invalid stored paths, removed fonts, or corrupt keybindings are repaired to
safe defaults during load so preferences cannot prevent startup.

## Local control API

Every pane receives `SATIN_SOCKET`, `SATIN_TAB_ID`, `SATIN_PANE_ID`, and
`SATINCTL`, and can invoke:

```sh
"$SATINCTL" list
"$SATINCTL" read-screen
"$SATINCTL" split --vertical
"$SATINCTL" status set running "working"
"$SATINCTL" status wait --timeout 300
```

The app bundle also contains `Contents/MacOS/satinctl` for external scripts.
Its directory is prepended to the pane's initial `PATH`; use `$SATINCTL` when
a shell startup file replaces `PATH`.
The Unix socket is owner-only, verifies the peer UID, and has bounded request,
client, and timeout limits; it is not a remote-control interface. See
[`docs/satinctl.md`](docs/satinctl.md) for commands, JSON behavior, and the
security boundary.

## Native Shortcuts

- `Command-T`: new tab
- `Command-D` / `Command-Shift-D`: vertical / horizontal split
- `Command-W`: close the active pane
- `Command-N`: explicitly replace the active terminal pane with native Neovim
- `Command-C`, `Command-V`, `Command-A`, `Command-F`: copy, paste, select all,
  and scrollback search
- `Command-+`, `Command--`, `Command-0`: terminal font size

## Scroll Design

`src/neovide_render.rs` owns the retained-window spring model. The terminal and
Neovim runtimes feed scroll events into the same renderer state.

There are two scroll sources targeted by the renderer:

- History scroll: integer rows are applied to `libghostty-vt`; fractional rows
  are held in the renderer and settled back to a cell boundary after wheel idle.
- Screen shift: when the visible rows look like they moved up/down between two
  frames, the renderer starts from the old visual position and springs to the new
  one.

The native host keeps AppKit responsible for tabs, menus, input routing, and
context menus. Cell drawing is owned by the Rust Skia/Metal adapter for both
normal terminal panes and native Neovim panes.

The native Neovim pane uses Neovim `ext_multigrid` redraw events to keep
separate grids for editor windows, floating windows, messages, cmdline, and file
tree panes. Rust now emits a Neovide-derived retained command batch from those
events: `grid_line` produces `DrawLine`, `grid_scroll` produces `Scroll`, and
`win_viewport` produces `Viewport`. Neovim scroll animation is driven by
event-origin command hints instead of snapshot-diff guessing.

The renderer model contains the background, cursor, and retained windows with
screen placement, window kind, z-order, hidden state, scroll animation position,
and colored cell lines. The Skia/Metal adapter consumes this model directly.

`just terminal` and `just neovim` draw content from retained renderer models.
The Rust Skia/Metal adapter wraps the current `MTKView` drawable, draws the
retained terminal or Neovim windows, and owns cursor body/trail rendering. The
AppKit overlay is limited to native UI such as tabs, menus, dialogs, and context
menus.

The Rust renderer model also carries viewport margins, scrollback line source,
scroll position, and event-origin scroll hint metadata. The Skia/Metal adapter
uses those fields to draw animated Neovim scrollback inside the scrollable inner
region while fixed rows such as statusline-like margins stay outside the
scrolling clip. The native nvim path reads those hints from
`NeovideRendererModelSnapshot`.

Neovim text in the Skia/Metal path is shaped by a Neovide-derived Rust shaper
instead of direct `Canvas::draw_str` cell drawing. The shaper uses `swash` to map
grapheme clusters onto grid-cell positions, caches Skia `TextBlob`s with `lru`,
loads `$SATIN_FONT` as the primary face, falls back through Skia `FontMgr`
character matching, and keeps bundled Neovide font assets as default and last
resort faces. Cell style carries bold, italic, faint, blink, underline
variants/colors, strikethrough, and overline from terminal SGR state into the
renderer; bold and italic participate in font fallback while decorations are
grid-aligned.
`nvim-shaped-text-visual` captures the Skia/Metal surface and checks that the
Japanese, Nerd Font, combining-mark, and ambiguous-width fixture cells contain
visible glyph pixels at the retained-model coordinates.
`nvim-smoke-cursor-switch` captures the Skia/Metal surface after switching tabs
and checks that the active tab's cursor body is visible while the previous tab's
cursor/trail and marker text are absent.
The cursor shape smokes drive Neovim `mode_info_set` / `mode_change` through
normal block, insert `ver25`, and replace `hor20` modes and check both the
renderer model and captured pixels. `nvim-smoke-cursor-blink` verifies the
Skia/Metal cursor body is hidden during the configured blink off phase without
requiring continuous redraw.
`nvim-smoke-ui-surfaces` also captures the Skia/Metal surface and verifies that
floating-window highlight `blend` values become alpha-composited background
pixels instead of opaque cells.
`nvim-smoke-popupmenu` drives command-line completion through Neovim
`ext_popupmenu`, then checks both the retained popupmenu model and captured
Skia/Metal glyph pixels.

The smoke recipes require Skia frames; `native-smoke` also checks
`skia-frames=yes`.

## Remaining Direction

The native Neovim compositor can continue toward deeper Neovide parity,
including externalized windows and richer editor-side drag selection. Those
renderer extensions remain event-driven; terminal behavior stays owned by
`libghostty-vt`.

## Contributing

Bug reports and focused feature requests are welcome through GitHub Issues.
Accepted pull requests are currently limited to repository maintainers;
external pull requests are closed automatically without checking out or
executing their contents. Before publishing a change, run `just precommit`;
renderer changes should also run the relevant native terminal or Neovim smoke
recipes.

## License

The Satin source is available under the [MIT License](LICENSE),
copyright © 2026 soyukke. Adapted code, bundled fonts, and other third-party
components remain under their respective licenses as documented in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). Release bundles include
these notices, the full font license, and generated Rust dependency license
texts under `Contents/Resources/Legal/`; Help → Acknowledgements… reveals them.
