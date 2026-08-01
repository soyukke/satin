# 0010: Use native settings and an owner-only control API

Date: 2026-07-29

Status: Accepted

## Context

The application needs durable user preferences without turning AppKit into a
second terminal core. It also needs a stable automation surface for local
agents and scripts. Driving accessibility events or scraping pixels would tie
automation to window focus and presentation details, while a network listener
would add an unnecessary remote attack surface.

Tab indexes are presentation order and pane objects are process-local, so
automation also needs identifiers whose meaning survives tab selection and
reordering. Long-running agents need a way to report and wait for bounded pane
state without polling the screen.

## Decision

- AppKit owns a standard Settings window with General, Appearance, Terminal,
  Keybindings, and Updates sections. Preferences are persisted in
  `UserDefaults`. Input, notification, font, and menu-safe changes apply live;
  shell and startup-directory changes apply to newly created panes.
- Stored values are validated when loaded and saved. Invalid shell paths,
  directories, fonts, shortcut syntax, duplicate shortcuts, and shortcuts
  reserved by standard app commands fall back safely instead of preventing the
  terminal from starting.
- The Rust core assigns monotonically increasing tab and pane IDs. IDs are
  stable for the lifetime of the corresponding object and are distinct from
  the current tab index.
- Local automation uses versioned, newline-delimited JSON over one Unix-domain
  socket. Version 1 supports listing tabs and panes, reading the visible screen,
  sending input and named keys, creating tabs and splits, renaming tabs,
  selecting themes, and setting or waiting for bounded agent status.
- The bundled Neovim launcher uses an internal `open-neovim` request carrying
  the resolved executable, cwd, arguments, and invocation environment. Its
  response remains open until native Neovim exits so the foreground shell
  command can preserve blocking and exit-status semantics.
- The bundled `satinctl` executable is the supported client. Each terminal
  pane receives `SATIN_SOCKET`, `SATIN_TAB_ID`, `SATIN_PANE_ID`, and
  `SATINCTL`; the bundled CLI directory is prepended to that pane's initial
  `PATH`. The absolute `SATINCTL` value remains authoritative when a shell
  startup file replaces `PATH`. The former `NVTERM_*` names remain accepted as
  migration aliases but are no longer documented as the primary interface.
- The socket parent must already be owner-only or is created owner-only. The
  socket is mode `0600`, stale paths are replaced only when they are sockets
  owned by the current user and are no longer accepting connections. A live
  socket is never replaced. Connected peer credentials must match the
  application's effective UID. There is no TCP listener.
- Requests are limited to 1 MiB, concurrent clients to 32, normal responses to
  30 seconds, and status waits to one hour. The native Neovim launcher request
  is lifecycle-bound instead of timer-bound. AppKit handles commands on the
  main queue; Rust owns socket I/O, limits, peer checks, and request routing.

## Consequences

Settings remain native macOS UI and do not leak renderer or terminal-runtime
policy into Swift. Live font changes cross the existing FFI boundary into the
Rust shaper and Skia renderer, while new-pane shell configuration remains a PTY
spawn concern.

Automation is deterministic and works without focus, accessibility permission,
or screen scraping. It is intentionally local-user authority: any process
running as the same macOS user can control the application. The API must not be
exposed through a shared directory, forwarded socket, or remote transport.

Protocol additions must preserve version 1 behavior or introduce a new version.
The CLI, socket permission tests, and end-to-end control smoke are release
gates.
