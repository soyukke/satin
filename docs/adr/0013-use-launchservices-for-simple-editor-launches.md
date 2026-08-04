# 0013: Use LaunchServices for simple editor launches

Date: 2026-08-04

Status: Accepted

## Context

Opening Satin normally restores a terminal workspace. Opening a file from
Finder has a different intent: start an editor immediately, without exposing an
intermediate prompt or replacing the user's saved terminal session. Finder,
Dock drops, and macOS Services deliver document events before or after normal
application launch, so treating them as command-line arguments would split the
behavior across multiple launch paths.

The editor must still use Satin's existing runtime boundaries. In particular,
interactive `nvim` should reach the native multigrid compositor through the
bundled shell integration, while `vim` and other terminal editors should remain
inside the `libghostty-vt` PTY.

## Decision

- Declare text, directory, and general content document roles in the application
  bundle, plus an `Open in Satin Editor` Service. Finder Open With, Dock drops,
  and the Service all enter one validated `NativeFinderEditorLaunch` model.
- A document event that launches Satin creates exactly one tab and terminal
  pane, skips session restore, and does not overwrite the saved normal session
  when it exits. A document event sent to an already-running Satin opens a new
  editor tab.
- Store a Finder editor executable setting, defaulting to `nvim`. The setting is
  a bare executable name or executable absolute path, not a shell command with
  arguments.
- Start the configured editor through the user's interactive login shell so its
  PATH and startup files apply. The Rust PTY boundary accepts a bounded argv
  vector, quotes every item, and exits that temporary shell when the editor
  finishes. Finder paths never become unquoted shell syntax.
- Keep editor behavior unified: the default bare `nvim` command invokes the
  bundled `satin-nvim` native handoff directly, independent of the selected
  shell; `vim` and other editors retain ordinary terminal semantics.
- Verify the packaged bundle metadata and exercise a real LaunchServices
  document open against the packaged application in CI.

## Consequences

Satin can be selected in Finder's Open With menu and behaves as a focused editor
launcher without adding a second Neovim implementation. User shell startup can
still affect executable discovery, which is intentional; an invalid stored
editor setting is repaired to `nvim`, and a missing executable fails visibly in
the terminal before the simple tab closes.

The current AppKit host owns one application window. Document events received
by a running instance therefore create tabs rather than additional windows.
