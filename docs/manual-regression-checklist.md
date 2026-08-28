# Manual regression checklist

Date: 2026-08-28

This checklist covers the terminal, tab-title, agent-activity, Neovim, tmux,
split-pane, and working-directory regressions reported through 2026-08-28. Run
it against `Satin Dev`, not an installed release build.

## Preparation

- [ ] Start the current development build with `just terminal`.
- [ ] Confirm the window title and menu identify the application as `Satin Dev`.
- [ ] Open a file longer than two screens, such as `src/terminal_runtime.rs`.
- [ ] Use the normal user Neovim configuration for Neo-tree checks. Use
  `:vsplit` as the plugin-independent fallback.

## Local Neovim scrolling

- [ ] From a local Satin terminal, run `nvim src/terminal_runtime.rs` and confirm
  it opens in the native Neovim pane.
- [ ] Wait two seconds, press `Ctrl-D` once, and confirm the first input animates.
- [ ] Press `Ctrl-D` five more times with a short pause between inputs. Confirm
  every input animates; animation must not be limited to the first input.
- [ ] Press `Ctrl-U` five times and confirm every reverse scroll animates.
- [ ] Double-tap `Ctrl-D`, then double-tap `Ctrl-U`. Confirm rapid inputs restart
  or extend the current animation instead of jumping without animation.
- [ ] Enter and leave command-line mode with `:` and `Escape`. Confirm this does
  not create a false scroll animation or leave cmdline/statusline trails.

## Neo-tree and split windows

- [ ] Open Neo-tree on the left and keep a long file in the right editor window.
- [ ] With the editor focused, repeat `Ctrl-D` and `Ctrl-U` five times each.
  Confirm the editor animates every time while Neo-tree remains fixed.
- [ ] Close Neo-tree, run `:vsplit`, and repeat the same inputs in the right
  window. Confirm only the focused window animates.
- [ ] Move focus with `Ctrl-W h` and `Ctrl-W l`, then scroll each eligible window.
  Confirm the animation follows the focused Neovim grid and does not move the
  neighboring window, separator, statusline, or cmdline.
- [ ] Close and reopen the side window. Confirm no stale text or separator trail
  remains.

## tmux Neovim scrolling

- [ ] From a local terminal, attach to or create a tmux session and run
  `nvim src/terminal_runtime.rs` inside tmux.
- [ ] In a full-width tmux Neovim window, wait two seconds and repeat `Ctrl-D`
  and `Ctrl-U` five times each. Confirm the first and every later input animate.
- [ ] Open Neo-tree or `:vsplit` inside tmux and repeat the scrolling checks.
  Confirm only the target rectangle animates and the neighboring columns remain
  fixed.
- [ ] Double-tap `Ctrl-D` and `Ctrl-U` inside the tmux split. Confirm both inputs
  are retained; there must be no one-shot-only behavior.
- [ ] Detach and reattach the tmux session, then repeat one `Ctrl-D` and one
  `Ctrl-U`. Confirm animation still works after rehydration.

## tmux connection and return path

- [ ] Open native Neovim from a local terminal so the original shell is
  suspended behind the Neovim pane.
- [ ] Use the Session control to connect to an existing tmux session.
- [ ] Confirm Satin uses the suspended terminal as the connection gateway and
  does not show `Select a terminal pane before connecting to tmux.`
- [ ] Detach from tmux and confirm the original local shell returns and accepts
  input.
- [ ] Click a session row's `x`, cancel the warning, and confirm the session is
  still listed. Repeat and choose **End Session**; confirm only that session is
  removed and its running programs exit.
- [ ] Restart `Satin Dev` while a tmux session with splits and Neovim is active.
  Confirm the session, split layout, content, active window, and cwd restore.

## Working-directory contract

- [ ] In a local terminal, enter a directory containing a space, press
  `Command-T`, and run `pwd` in the new tab. Confirm it exactly matches the
  source pane, even when Appearance > Startup directory points elsewhere.
- [ ] Repeat from a tmux pane after changing directory, including after
  switching tmux sessions. Confirm the new tmux window uses that pane's
  `pane_current_path` rather than Satin's startup, home, repository, or process
  directory.
- [ ] Repeat `Command-T` from different panes in the same local/tmux tab. Confirm
  the currently active pane, not the tab's first pane or a cached previous pane,
  owns the inherited cwd.

- [ ] In a local terminal, run
  `mkdir -p /tmp/satin-cwd-check && cd /tmp/satin-cwd-check`, then run `nvim`.
  Confirm `:pwd` reports `/tmp/satin-cwd-check` exactly.
- [ ] Repeat the same cwd check from a projected tmux pane. Confirm tmux
  `current_path`, not Satin's process cwd, is used.
- [ ] In one pane, enter an empty temporary directory. Remove that directory
  from another pane, then try to open native Neovim from the first pane.
- [ ] Confirm Satin shows `Could Not Open Neovim` and does not silently open
  Neovim in the repository root, home directory, or another stale directory.
- [ ] Return the shell to an existing directory and confirm Neovim opens there.

## Tab title and agent activity ownership

- [ ] Rename a local tab manually, start Claude Code or Codex, and submit work.
  Confirm the running spinner appears beside the stable tab title without
  inserting a spinner glyph, agent version, cwd, or OSC title into the name.
- [ ] Let the turn finish, start another turn, and switch tabs while it runs.
  Confirm the indicator stops and restarts with status while the manual title
  remains unchanged through every transition and session save/restore.
- [ ] Repeat in tmux after manually renaming the tmux window. Confirm
  `pane_title` changes drive the same running/waiting/done states while the tmux
  window name remains unchanged.
- [ ] Exercise a tab containing multiple panes. Confirm one running pane is
  enough to show one tab indicator, and that it stops only when no pane in that
  tab is `running`.

## Pane drag and drop

- [ ] Create three local panes, including a terminal and native Neovim pane.
  Grab the dotted area in a pane's top band, not an action button. Confirm a
  lifted ghost band follows the pointer smoothly and the highlighted drop area
  eases between targets rather than jumping.
- [ ] Drop near the center of another pane. Confirm the two pane positions swap,
  the dragged pane remains selected, and both runtimes retain their output,
  cwd, cursor, title/status, and input responsiveness.
- [ ] Repeat at the target's left, right, top, and bottom edges. Confirm the
  preview covers the corresponding half and the final split tree places the
  dragged pane on that side only after release.
- [ ] Drop a directly adjacent pane onto the side where it already sits.
  Confirm no target drop highlight appears, the lifted proxy becomes neutral
  rather than actionable, and release returns it to the source without changing
  the layout or divider ratio. Drop it on the opposite side and confirm only the
  pane positions exchange.
- [ ] Release outside every pane. Confirm the preview returns to its source and
  the layout does not change. Confirm close/split buttons in the same band still
  click normally and do not begin a drag.
- [ ] Repeat center and edge drops in tmux. Confirm tmux pane identities and
  processes survive, the tmux layout is authoritative after each drop, and no
  duplicate local pane or fallback split appears.
- [ ] Open the artifact sidebar and narrow several panes. Confirm the artifact
  pane has no drag handle, pane controls remain clickable, and terminal content
  stays below every header throughout the gesture.

## Regression-path audit

- [ ] Confirm terminal OSC title handling writes pane metadata/status only and
  has no call to `core.renameTab`.
- [ ] Confirm local rename, session restore, explicit CLI `--title`, and tmux
  `rename-window` are the only tab-title mutation owners.
- [ ] Confirm native and CLI tmux new-window/split defaults use
  `#{pane_current_path}` and do not issue a bare `new-window`.
- [ ] Confirm new local tabs require the active runtime cwd and do not silently
  fall back to startup directory, home, repository root, or process cwd.
- [ ] Search for removed compatibility state such as `NativeTabTitleCoordinator`,
  `titleIsManual`, and `newPaneWorkingDirectory`; no production references
  should remain.

## Pane geometry during tmux resize

- [ ] Create three tmux panes, with Neovim running in one of them.
- [ ] Use `Command-+`, `Command--`, and `Command-0`. Confirm font size is shared
  across the whole Satin window and every tmux pane still fits its frame.
- [ ] Rapidly grow the window and shrink it back. Confirm tmux settles on the
  final smaller grid rather than retaining the peak grid size.
- [ ] Confirm text, cursor, mouse targeting, and IME stay inside each pane after
  the resize, with no crop or renderer-only scaling.

## Automated evidence

Run screen-capture checks only from outside Satin after explicitly allowing the
macOS screen-recording permission.

- [ ] Run `just nvim-smoke-scroll-visual` and confirm it reports exactly two
  presented scroll animation groups and near-zero fixed-pane pixel changes.
- [ ] Run `just nvim-smoke-scroll`, `just nvim-smoke-jump`, and
  `just nvim-smoke-side-pane`.
- [ ] Run `just native-tmux-smoke` and `just pane-grid-smoke`.
- [ ] Run `just native-tab-title-cwd-smoke`; confirm it reports
  `title=stable activity=separate cwd=inherited fallback=none`.
- [ ] Run `just native-pane-dnd-smoke`; confirm it reports
  `handle=band preview=animated no-change-highlight=none`,
  `no-change-adjacency=both`,
  `runtime=retained layout=reparented`, and `cancel=noop fallback=none`.
- [ ] With three side-by-side local panes, drag the middle pane over the
  right-side 20% of the left pane, then over the left-side 20% of the right
  pane. Confirm neither direction shows a source or target pane highlight,
  the proxy reads `Already there`, and dropping preserves every divider ratio.
- [ ] In `just native-tmux-smoke`, confirm the native result contains
  `pane-dnd=noop+center+edge no-change-highlight=none`.
- [ ] Run `just terminal-nvim-cwd-smoke` and `just precommit`.
- [ ] Quit Satin and cancel the warning once, then quit successfully. Disable
  **Confirm before quitting Satin** in General settings and confirm Quit no
  longer prompts.

## Acceptance

- [ ] No item above reproduces the first-input-only, intermittent animation,
  split/Neo-tree, tmux return, pane-DnD, agent-title overwrite, wrong Command-T
  cwd, or stale tmux grid regressions.
- [ ] Record any failure with the exact section, whether it was local or tmux,
  the focused Neovim window, and whether it failed on the first or a later
  input.
