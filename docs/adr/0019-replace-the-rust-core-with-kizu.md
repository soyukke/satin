# 0019: Replace the Rust core with Kizu

Date: 2026-10-13

Status: Proposed

## Context

ADR 0002 put the terminal core in a Rust crate behind a C ABI, and ADR 0007
drew it with Skia on Metal. That build needed the Rust toolchain, a crate
graph with its own audit and license-report tooling, vendored `libghostty-vt`
bindings, and a C++ link for Skia.

The core is being moved to Kizu, a small systems language whose compiler comes
from the flake input `github:kizu-lang/kizu`, so that the build needs one small
toolchain. Kizu calls C only. Skia is C++, so the renderer could not be carried
over as it was and needed a backend reachable through C.

This record is `Proposed` because the new renderer has not yet been reviewed
visually in the running app. The offscreen tests pass; glyph appearance and
animation feel are unreviewed.

## Decision

Write the core in Kizu under `core/` and remove Rust from the repository. The
Swift host in `spikes/macos-shell` and its C ABI stay as they are.

- `core/src/{core,tmux,vt,term,nvim,draw}` holds the tabs and panes model, tmux
  control mode, the terminal runtime on `libghostty-vt`, the embedded Neovim
  (MessagePack RPC and multigrid UI state), and the renderer.
  `core/shared/{control,artifact}` holds the control socket protocol, server,
  and client, and the artifact store with its Markdown renderer. `core/cli` and
  `core/nvim` are the `satin` command and the `satin-nvim` launcher.
- `core/host` exports the C functions the Swift app links: `satin_core_*`,
  `satin_runtime_*`, `satin_nvim_*`, `satin_control_*`, and `satin_skia_metal_*`.
  The last group keeps its old names for the Swift side although Skia is not
  used.
- `libghostty-vt` is built from source with zig by `core/scripts/build-ghostty`
  at a pinned commit.
- The renderer builds each frame as a backend-independent display list
  (`core/src/draw`), rasterizes it on the CPU with CoreText and CoreGraphics
  into a BGRA bitmap, and uploads the pixels to the drawable's `MTLTexture`.
  Swift still presents the drawable. Text is shaped by CoreText with ligatures
  on. The bundled FiraCode Nerd Font and LastResort are loaded from `fonts/`
  beside the executable or `Contents/Resources/fonts` in the bundle;
  `SATIN_FONT` and system fallback work as before. A shaped-run cache replaces
  the Skia text-blob LRU caches.
- The core starts no threads. The host waits on the PTY, the Neovim pipe, or
  the control server's kernel queue descriptor and calls drain. The Rust reader
  threads and wakeup pipes are gone.
- Artifact Markdown code blocks are drawn in one style. The Rust build
  highlighted them with `syntect`; there is no highlighter now.
- `just native-build` and `scripts/native-package` run `core/scripts/build` and
  link `core/target/host/satin.o` and `core/target/native/libghostty-vt.a` with
  CoreText, CoreGraphics, CoreFoundation, and libobjc. Nothing links `-lc++`.
- `just check` type-checks the four Kizu packages. `just test` runs
  `core/scripts/test`: the Kizu tests of each package, the two commands against
  stand-ins, and an offscreen render into a real Metal drawable that is read
  back, with no window and no screen capture. `just verify` is `just ci-static`
  plus `just ci-core`, which replaces `just ci-rust`. `just audit` is removed.
- The version is the `VERSION` file instead of `Cargo.toml`.
  `scripts/ci-change-scope` treats a change of `VERSION` alone as a release
  bump.
- CI runs `just ci-core` on macOS. The CodeQL workflow, the RustSec job, and
  the Dependabot Cargo entry are removed.
- Release bundles no longer carry a generated Rust dependency license report.
  `THIRD_PARTY_NOTICES.md` carries the `libghostty-vt` MIT notice.

This supersedes ADR 0002's choice of Rust for the core and ADR 0004's Clippy
gate. ADR 0007's retained model, scroll spring, and cursor animation are kept;
its Skia/Metal drawing path is replaced by the one above.

## Consequences

Easier:

- The build needs the Kizu compiler, zig, and Xcode. There is no crate graph to
  audit, no generated dependency license report, and no C++ runtime in the
  link.
- The display list names no drawing library, so renderer tests assert on
  commands and on read-back pixels without a window.
- With no core threads, every core call happens on the host's one calling
  thread, and there are no reader threads to join at pane close.

Harder or lost:

- Glyphs are rasterized by CoreGraphics without font hinting and without Skia's
  gamma and contrast tables. Edge pixels differ from the Skia build, and this
  has not been compared in the running app.
- Rasterization is on the CPU. Measured at 200x60 cells on a 3000x1800 target,
  a frame costs about 1.8 ms with a warm cache and about 10 ms when all of its
  text is new.
- The shaped-run cache is emptied whole when it fills; it is not an LRU.
- Artifact code blocks have no syntax highlighting.
- Kizu cannot declare a variadic C function. The PTY's `ioctl` and `fcntl`
  calls use a workaround that is correct only on arm64 macOS; it and the other
  language gaps found during the port are recorded in `core/gaps/README.md`.
- Kizu has no formatter or linter in the gate, so the Clippy and `rustfmt`
  checks of ADR 0004 have no equivalent beyond `kizu check` and the tests.
- CI builds the Kizu compiler from its flake input, and no automated advisory
  or CodeQL scan covers the core. The compiler and `libghostty-vt` pins are
  updated by hand.
- The leveled `SATIN_LOG` diagnostics of the Rust core were not ported.
