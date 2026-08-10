# 0016: Bridge Kitty graphics into native Neovim

Date: 2026-08-10

Status: Accepted

## Context

Satin implements the Kitty graphics protocol in its terminal runtime, but the
native Neovim pane runs `nvim --embed`. Its standard input and output carry
MessagePack RPC instead of a PTY byte stream. `image.nvim` therefore cannot
open stdout as a TTY or query its pixel dimensions, and Kitty escape sequences
never reach `libghostty-vt`.

Falling back to Neovim's TUI would discard the retained multigrid renderer and
its Neovide-parity scrolling model. Sending file paths to the host would also
weaken the existing rule that terminal output cannot request arbitrary file
reads.

## Decision

- Inject a small Lua compatibility bridge before user configuration when Satin
  starts embedded Neovim.
- The bridge provides Satin implementations of image.nvim's terminal geometry
  and Kitty writer modules. Layout, cropping, lifecycle, and deletion remain
  owned by image.nvim.
- Convert image.nvim file transmission to bounded direct Kitty chunks inside
  the Neovim process, then send those chunks to the host with the
  `satin_kitty_graphics` RPC notification. The host never receives a path to
  open.
- Parse notifications with a PTY-free `KittyGraphicsBridge` backed by
  `libghostty-vt`. Synchronize its cell and pixel size with native Neovim
  resize events and reuse the existing placement, RGBA, and Skia caches.
- Advertise the bridge as the namespaced capability
  `g:satin_features.kitty_graphics`. Satin merges this key into an existing
  feature dictionary before user configuration. Users do not set it
  themselves; configurations that disable image.nvim for every GUI client can
  use it to opt Satin back in without enabling unsupported GUIs.
- Bound each RPC payload to 64 KiB. Existing Kitty parser and image-store limits
  remain in force.

## Consequences

Native Neovim panes can display and delete image.nvim Kitty placements without
introducing a second image decoder or reverting to terminal rendering.
Terminal panes continue to consume ordinary Kitty byte streams unchanged.

The adapter intentionally follows image.nvim's current Lua module interface.
Dependency upgrades must run the native Neovim image smoke, which validates the
Lua-to-RPC transport, `libghostty-vt` placement state, and captured Skia pixels.
