# 0012: Unify shell and Command-N Neovim runtime

Date: 2026-08-01
Amended: 2026-08-18

Status: Accepted

## Context

Neovim previously had two presentation paths. Command-N used `nvim --embed`
and received per-window `ext_multigrid` and `win_viewport` events, while a
shell `nvim` command ran the TUI inside `libghostty-vt`. A full-screen TUI can
emit explicit VT scroll commands, but Neovim redraws split windows, terminal
buffers, and plugin layouts with cursor-addressed line updates. Those bytes do
not retain which window scrolled. Inferring that meaning from terminal
snapshots reintroduces false movement for cursor, statusline, and side-pane
redraws.

Replacing the terminal process outright would also be incorrect. It would
destroy the calling shell, lose shell-local environment and job state, and
make `nvim` return semantics differ from a normal foreground command.

## Decision

- Direct interactive `nvim` commands in Satin's zsh integration invoke the
  bundled `satin-nvim` launcher. This is executable-level shell integration;
  AppKit never parses raw keystrokes or guesses shell commands.
- The launcher resolves the real Neovim executable and passes its absolute
  path, cwd, arguments, and invocation environment through the owner-only
  control socket. The host starts that executable with `--embed` and the same
  native multigrid runtime used by Command-N.
- A local terminal handoff uses its OSC 7 working directory. A projected tmux
  pane uses tmux's `current_path`, which remains authoritative even though its
  external renderer runtime has no PTY cwd. If the selected directory no longer
  exists, Satin fails the launch instead of silently opening Neovim elsewhere.
- The terminal PTY and shell object remain alive but hidden while native
  Neovim is active. The launcher blocks like a normal foreground editor. On
  Neovim exit, the host restores the same PTY, returns Neovim's exit status,
  and lets the same shell process continue.
- Headless, embedded, remote, stdin-driven, nested tmux/SSH, and explicit
  `SATIN_NVIM_TUI=1` invocations execute the real Neovim binary without native
  handoff. This preserves CLI and nested-terminal semantics. In a local tmux
  pane, the launcher also installs a bounded `WinScrolled` bridge. It emits a
  private OSC row/rectangle event only when the TUI must repaint a partial-width
  window instead of sending a VT scroll command.
- The terminal renderer retains generic VT scroll support for arbitrary TUI
  applications and never infers Neovim motion from cell snapshots. Native
  Neovim consumes `win_viewport`; nested tmux Neovim consumes the explicit OSC
  event from the launcher and clips the retained spring to that window's rows
  and columns.
- The shell-native smoke opens `nvim` from the real shell, verifies argument
  delivery, creates a terminal split, checks a column-bounded viewport scroll,
  verifies the suspended shell remains available as a tmux gateway, exits
  Neovim, and verifies the shell PID and exported state are unchanged.

## Consequences

Normal shell and Command-N launches now share one renderer and one Neovim
compositor. Split and plugin layouts no longer depend on terminal escape
sequence choices, and fixes do not need to be duplicated across a TUI-specific
Neovim path.

Nested tmux remains a real TUI. Full-width scrolls continue to use standard VT
commands; partial-width split and file-tree scrolls use the launcher-injected
event. Satin does not compare old and new terminal rows to guess motion.

The application bundle includes a small signed launcher and zsh startup bridge.
The internal `open-neovim` control request is long-lived by design: its response
is completed when Neovim exits so the launcher preserves foreground-command
blocking and exit status.
