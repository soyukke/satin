# 0014: Project explicit tmux control mode into native tabs and panes

Date: 2026-08-07

Amended: 2026-08-23

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
  the app environment, known package manager and system prefixes, then the
  configured login shell's `PATH` as the last fallback. This avoids starting a
  competing interactive shell during terminal startup. Validate candidates with
  `tmux -V`, bound shell environment and process probes with timeouts, cache the
  result per settings identity, and surface a useful error when resolution fails.
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
- Resolve a projected pane's working directory from tmux `current_path`, not
  from its renderer-only terminal runtime. When native Neovim temporarily hides
  a local shell, keep that suspended shell eligible as the control-mode gateway
  so the session picker can return to tmux without requiring another pane.
- Give every tmux pane an external `libghostty-vt` runtime. Feed `%output` bytes
  into that runtime and reuse the existing Skia-Metal terminal renderer. Route
  encoded keyboard, text, mouse, focus, and resize operations back to the gateway
  as tmux commands. Route paste through a private tmux buffer and `paste-buffer
  -p`, leaving tmux responsible for the application's bracketed-paste contract.
  Apply pending explicit VT scroll commands before checking whether the retained
  scroll spring needs another Metal frame. This keeps terminal Neovim scrolling
  smooth even when no cursor animation or later `%output` happens to schedule it.
  Preserve the VT/OSC parser between ordinary `%output` records because tmux may
  split one control sequence across records; reset it only when installing a
  captured hydration state. Bound coalesced row deltas to the declared inner
  scroll region so rapid repeated input cannot collapse into a one-row far jump.
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
- Subscribe the control client to quoted `pane_title` changes and include that
  field in every topology snapshot. Feed projected title transitions through
  the same bounded Codex and Claude Code lifecycle tracker as local panes, and
  remove pane-local title and status metadata when tmux removes a pane. Do not
  infer agent state from captured pane content.
- Preserve ordinary key events byte-for-byte. For an auto-repeated Return while
  the pane's foreground command is a configured login shell on the primary
  screen, keep at most one pending repeat and release it when the projected VT
  reports that the next prompt is ready. Prefer OSC 133 semantic-prompt state;
  count at most one `133;B` ready marker between prompt lifecycle transitions,
  because multiple shell integrations can append equivalent markers to one prompt;
  treat a new ready marker as authoritative shell ownership when tmux's
  `pane_current_command` notification lags, and clear that ownership when a line
  is submitted;
  once backpressure starts, retain it across foreground children run by prompt hooks
  until prompt readiness, key-up, or focus loss;
  before shell integration has been observed, use the nonempty cursor line as
  the compatibility signal. This prevents the pane TTY from echoing queued
  newlines ahead of a slow prompt without imposing a fixed repeat interval or
  changing input semantics for full-screen applications and other keys.
- Keep one tmux-backed tab internally consistent: Satin-local panes are not
  inserted into a tmux-owned window.
- Allow at most one Satin native projection for a tmux server session, while
  continuing to allow ordinary non-control tmux clients. Identify the lease by
  tmux's server PID, numeric session ID, and canonical socket path rather than
  its renameable session name. Before attach or `switch-client`, acquire a
  bundle-neutral, owner-only advisory file lock with `LOCK_NB`; retain the open
  close-on-exec file descriptor for the projection lifetime. The lock-file
  contents are diagnostic only. File existence, a saved PID, and application
  preferences are never treated as ownership, so quit, crash, and reboot release
  authority in the kernel without stale-lock recovery.
- Never wait for another Satin projection while holding a lease. Each busy or
  unavailable acquisition attempt fails immediately. During a session switch,
  retain the current lease, acquire the target nonblockingly, and promote it only
  when the target snapshot arrives, then release the old lease. A bounded staging
  timeout releases a target whose attach or switch never completes. This avoids
  hold-and-wait and circular-wait edges in the native session state machine.
- Before attaching, inspect the target's tmux clients and reject an existing
  control-mode client. This compatibility check catches release builds that
  predate the shared lease. Immediately after tmux enters control mode, query
  the current session again through that client and require exactly one
  control-mode client before configuring flow control or projecting a snapshot.
  Subscribe to changes in the session's attached-client list and repeat that
  check so an older release attaching later also revokes the newer projection.
  These checks close manual `tmux -CC` and attach-race gaps; failure sends
  `detach-client` and restores the local workspace.
- Continuously checkpoint the reattach descriptor while control mode is attached
  and clear it when the projection ends. Save it only when the socket is a local
  Unix socket and tmux's reported server PID is live, alongside the preserved
  Satin workspace. Resolve the reported local server PID back to its executable
  path and persist that executable identity with the socket and session. Older
  descriptors without an executable path remain valid and fall back to normal
  resolution; a persisted executable that no longer exists does the same.
  Validate both values and shell-quote them before writing one automatic
  `tmux -S <socket> -CC attach-session -t <session>` command to the restored
  local PTY. Keep the descriptor until tmux enters control mode. If the target
  lease is busy, retry acquisition for a bounded two-second shutdown window,
  then remain Local and preserve the descriptor for a later restart rather than
  consuming it or waiting indefinitely.
- Serialize automatic restore, picker attach, session creation, and
  `switch-client` as generation-scoped connection attempts. An explicit picker
  choice invalidates every callback or delayed write from automatic restore and
  consumes that pending descriptor. Permit at most one shell attach command per
  generation; switching an attached client must stay on the control connection
  and must never inject a second command into the projected pane.
- Do not save a reattach descriptor after explicit detach. If the socket or
  session disappeared, surface tmux's initial attach error in the restored
  terminal, consume the missing descriptor, and remain in the ordinary Satin
  workspace. A deferred busy descriptor remains restartable; a later clean exit
  from an active projection records a fresh one.

The parser and architecture follow tmux's official control-mode protocol. The
controller/gateway split is informed by iTerm2's `sources/tmux` implementation.

## Consequences

Native integration is predictable and opt-in. Existing terminal behavior and
the Neovim handoff remain independent. tmux survives Satin UI changes because
Satin never owns its session state. A clean app restart returns to the exact
local server and session that was projected, while explicit detach remains a
durable request to stay in the ordinary workspace.

Release and development bundles can run simultaneously, but they cannot project
the same tmux server session at the same time. Rejection is nonblocking and does
not terminate the tmux session. Killing or crashing the owner releases the lease
automatically, so the surviving or restarted app can attach without deleting a
lock file or clearing preferences.

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
