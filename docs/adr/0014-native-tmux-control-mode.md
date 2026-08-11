# 0014: Project explicit tmux control mode into native tabs and panes

Date: 2026-08-07

Status: Accepted

## Context

Running `tmux attach` in a terminal is already correct terminal behavior and must
remain available. Native integration has a different contract: tmux windows and
panes should become Satin tabs and splits without scraping the rendered terminal
screen or maintaining a second, conflicting layout model.

tmux exposes this contract through control mode (`tmux -CC`). It wraps a
line-oriented protocol in a DCS boundary, emits pane output keyed by stable pane
IDs, reports topology notifications, and accepts ordinary tmux commands. iTerm2
uses the same gateway/controller shape: one hidden control client owns the
connection while native surfaces render the individual panes.

## Decision

- Keep ordinary `tmux`, `tmux attach`, and nested tmux sessions as terminal TUI
  content. Enter native integration only after the explicit `tmux -CC` DCS
  handshake appears on a Satin-owned local PTY.
- Treat tmux as a user-owned external executable and require tmux 3.2 or newer;
  do not bundle or install it with Satin. Resolve one absolute executable path
  for native operations in this order: the explicit Terminal Settings override,
  the configured login shell's `PATH`, the app environment, then known package
  manager and system prefixes. Validate candidates with `tmux -V`, bound shell
  environment and process probes with timeouts, cache the result per settings
  identity, and surface a useful error when resolution fails.
- Use that resolved executable identity for every native operation performed
  outside control mode: session discovery, attach, create, and automatic
  reattach. Never inject a bare `tmux` command and leave its identity to the
  interactive shell. While attached, query sessions through the existing
  control client so discovery observes exactly the connected server without
  launching a second client or depending on the app's `PATH`.
- Treat the original terminal runtime as a hidden gateway for the lifetime of
  control mode. Preserve the complete local Satin workspace and restore it when
  tmux emits `%exit` and closes the DCS boundary, so the original shell resumes
  in the same pane.
- Parse and bound the incremental control stream as bytes in Rust. Decode tmux's
  octal output escapes without forcing pane output through UTF-8, and quote every
  topology field with `#{q:...}` so tabs, newlines, and backslashes cannot alter
  row boundaries. tmux is the source of truth: protocol notifications trigger a
  `list-panes` topology refresh instead of inferring changes from terminal
  snapshots.
- Enable tmux control-mode pause-after flow control. On `%pause`, continue the
  pane and replace its projected state with a fresh bounded capture. A malformed
  protocol stream detaches the control client, reports the failure, and restores
  the ordinary Satin workspace; rejected ordinary tmux commands are logged
  without tearing down a healthy projection.
- Map an attached tmux session to a native tab group, windows to tabs, panes to
  splits, and tmux layout geometry to retained split ratios. Use a disjoint
  native ID namespace while the projection is active.
- Size the tmux control client from the full terminal content grid, never from
  the active projected pane. Pane-local sizing would feed every split back as a
  smaller client size and create a layout/resize notification loop.
- Show a persistent native toolbar control as `Local` or `tmux · <session>` and
  add the attached session to the macOS window title. The control opens the
  session picker; do not rely on the absence of a tmux status line to communicate
  that input and layout are being proxied.
- Give every tmux pane an external `libghostty-vt` runtime. Feed `%output` bytes
  into that runtime and reuse the existing Skia-Metal terminal renderer. Route
  encoded keyboard, text, mouse, focus, and resize operations back to the gateway
  as tmux commands. Route paste through a private tmux buffer and `paste-buffer
  -p`, leaving tmux responsible for the application's bracketed-paste contract.
  Apply pending explicit VT scroll commands before checking whether the retained
  scroll spring needs another Metal frame. This keeps terminal Neovim scrolling
  smooth even when no cursor animation or later `%output` happens to schedule it.
- On first projection of a pane whose effective `allow-passthrough` value is
  `off`, set that pane-local option to `on`; preserve an existing `on` or `all`
  value and never change the window/global default. Decode tmux's outer
  `DCS tmux;` envelope incrementally before feeding pane output to
  `libghostty-vt`. This makes Kitty graphics and other explicitly wrapped
  terminal protocols work through control mode, including when an escape or
  terminator is split across `%output` records. Use `on`, not `all`, so an
  invisible pane cannot bypass tmux's visibility guard.
- During pane hydration, continue decoding passthrough envelopes but buffer the
  bounded inner stream until after the captured VT state is installed. Ordinary
  live text remains covered by `capture-pane`; Kitty data is not part of that
  capture and must be replayed afterwards as one uninterrupted stream. This
  prevents a hydration reset from cutting an image transfer in half and
  exposing the remaining Base64 as terminal text.
- When `satin-nvim` deliberately falls back to an interactive TUI inside tmux,
  preload an image.nvim Kitty transport adapter. The adapter reads image.nvim's
  cropped file in the Neovim process, converts it to bounded direct-transfer
  chunks, and then applies tmux's passthrough envelope. Write each envelope
  synchronously to the editor pane TTY from Neovim's main thread; an async
  stdout write can otherwise be interleaved with TUI redraw bytes inside the
  same DCS. Normalize image.nvim's negative display z-index to zero because the
  retained terminal renderer composites opaque cell backgrounds above negative
  Kitty placements. Do not enable arbitrary Kitty file reads in the terminal
  host; terminal output still cannot ask Satin to open an unrelated user file.
- Hydrate each initial, resized, resumed, or newly discovered pane with a bounded
  `capture-pane -p -e -C` capture. Restore scrollback, the saved primary screen
  behind an active alternate screen, cursor/scroll-region state, input modes,
  DEC private modes, and extended-key mode. If topology changes during a capture,
  discard that stale result and recapture the newest pane state. Refresh topology
  after capture, reapply tmux's authoritative cursor after hydration, and expose
  the live external-VT cursor to AppKit so IME preedit follows the focused pane.
- Use `window_visible_layout` for native geometry and retain hidden runtimes while
  a tmux window is zoomed. The session control includes `Zoom`; native actions can toggle
  zoom without destroying the unzoomed pane tree.
- Route native and supported Satin CLI new, split, select, move, rename, and close
  tab/pane actions to tmux. Apply the resulting notifications rather than
  optimistically mutating a second model. Native Neovim replacement is rejected
  while tmux owns the pane; ordinary terminal Neovim remains tmux content.
- Forward pane bells through Satin's existing attention policy without replacing
  tmux window names with application pane titles.
- Preserve ordinary key events byte-for-byte. For an auto-repeated Return while
  the pane's foreground command is a configured login shell on the primary
  screen, keep at most one pending repeat and release it when the projected VT
  reports that the next prompt is ready. Prefer OSC 133 semantic-prompt state;
  before shell integration has been observed, use the nonempty cursor line as
  the compatibility signal. Cancel the pending repeat on key-up, focus loss, or
  a foreground-command change. This prevents the pane TTY from echoing queued
  newlines ahead of a slow prompt without imposing a fixed repeat interval or
  changing input semantics for full-screen applications and other keys.
- Keep one tmux-backed tab internally consistent: Satin-local panes are not
  inserted into a tmux-owned window.
- Continuously checkpoint the reattach descriptor while control mode is attached
  and clear it when the projection ends. Save it only when the socket is a local
  Unix socket and tmux's reported server PID is live, alongside the preserved
  Satin workspace. Resolve the reported local server PID back to its executable
  path and persist that executable identity with the socket and session. Older
  descriptors without an executable path remain valid and fall back to normal
  resolution; a persisted executable that no longer exists does the same.
  Consume this descriptor before issuing one automatic `tmux -S <socket> -CC
  attach-session -t <session>` after workspace restore. Validate both values and
  shell-quote them before writing the command to the restored local PTY.
- Do not save a reattach descriptor after explicit detach. If the socket or
  session disappeared, surface tmux's initial attach error in the restored
  terminal and remain in the ordinary Satin workspace. The consumed descriptor
  is not retried on every launch; a later clean exit from an active projection
  records a fresh one.

The parser and architecture follow tmux's official control-mode protocol. The
controller/gateway split is informed by iTerm2's `sources/tmux` implementation.

## Consequences

Native integration is predictable and opt-in. Existing terminal behavior and
the Neovim handoff remain independent. tmux survives Satin UI changes because
Satin never owns its session state. A clean app restart returns to the exact
local server and session that was projected, while explicit detach remains a
durable request to stay in the ordinary workspace.

Finder/Dock launches no longer depend on macOS's sparse GUI `PATH`, and Nix,
Homebrew, MacPorts, and manually installed tmux binaries can all be selected
without Satin taking ownership of those installations. Terminal Settings shows
the detected path, version, and discovery source and provides an explicit path
override for ambiguous environments.

This contract targets an explicitly entered, local `tmux -CC` client. Native
selection, search, copy, and scrollback continue to operate on each projected VT
surface; Satin does not scrape tmux's client-wide chooser or copy-mode screens.
Native tabs and the persistent session control intentionally replace the tmux status line.

The native picker discovers sessions from the current local tmux server, switches
the existing control client between them, and can create a session on that server.
After returning to `Local`, the window remembers that one server socket so its
sessions remain listed and new sessions use the same server. Before any native
tmux projection, `Local` uses the default local server. Selection starts an
explicit `-CC` attach in the active shell. Selecting `Local` sends
`detach-client` and restores the preserved Satin workspace. Satin still owns one
tmux control client at a time; remembering one socket does not aggregate servers.

Remote bootstrap and simultaneous multi-server aggregation are separate product
features. They must build on the same protocol boundary and must not introduce
screen scraping or an AppKit-only terminal path.
