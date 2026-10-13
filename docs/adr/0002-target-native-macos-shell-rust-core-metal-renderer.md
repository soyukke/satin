# 0002: Target a native macOS shell with Rust terminal core and Metal renderer

Date: 2026-07-02

Status: Superseded by [0019](0019-replace-the-rust-core-with-kizu.md)

## Context

The early prototype used `macroquad` for the window, input, and 2D drawing.
That was useful for moving quickly on Neovide-like cursor and scroll animation,
but it was not the target application shell.

The intended product direction is broader:

- native macOS tabs, context menus, settings, and keybinding UI
- Neovide-like cursor and scroll animation
- terminal-grade text rendering
- inline image rendering
- stable PTY, session, pane, and agent-notification behavior

`macroquad` is not a native macOS UI toolkit. Continuing to add AppKit behavior
through one-off bridges would make the application harder to maintain.

## Decision

The long-term target architecture is:

```text
Swift/AppKit shell
  native windows, tabs, menus, settings, keybinding UI, command routing

Rust terminal core
  PTY management, terminal state, scrollback, sessions, panes,
  agent notifications, image protocol parsing/state

MTKView/Metal renderer
  terminal cells, cursor animation, smooth scroll, inline images/textures
```

The native shell becomes the product path once it can launch real PTYs through
the Rust terminal runtime. Prototype renderer code should not remain on the
default launch path after that point.

## Consequences

Native macOS UI is treated as part of the product architecture, not an optional
skin around the prototype.

Renderer-specific behavior should move behind boundaries that can be called from
an AppKit/Metal host. New protocol and session logic should avoid depending on
any frontend toolkit.

The migration should be incremental. First separate reusable Rust core logic
from UI drawing. Then introduce the native shell and Metal view without
rewriting terminal semantics at the same time.
