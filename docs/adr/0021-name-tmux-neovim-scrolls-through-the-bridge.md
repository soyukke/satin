# 0021: Name tmux Neovim scrolls through the bridge

Date: 2026-11-19

Status: Accepted

## Context

Inside tmux, Neovim runs as a TUI and Satin sees only the bytes it writes.
Satin used to work out each scroll from those bytes: scroll sequences for
full-width windows, an OSC from the launcher's bridge for windows beside
another, and a comparison of rows between frames for the rest. These sources
disagreed. A scroll could be counted twice or not at all, the OSC arrived a
frame before its rows, and row comparison cannot tell that a file tree beside
the text stayed still.

## Decision

The bridge names every scroll of every window with version 2 of the
`777;SatinScroll` OSC, in screen rows, so that wrapped lines and closed folds
count as they are shown.

- Once a program sends version 2, Satin takes no scroll from its output or its
  rows until it leaves the alternate screen. Version 1 keeps its old meaning
  for an editor started before an update.
- A named scroll waits for the frame that shows its rows moved. Rows that do
  not change within 500 ms showed the same before and after, and the scroll is
  dropped.
- Named scrolls always slide. The rule that settles streaming output applies
  only to scrolls that were not named.
- A named scroll larger than its window is a jump, shown as the native Neovim
  pane shows one.
- Row comparison remains for full-screen programs that name nothing. It gives
  up when the moved rows do not start at the edge of the region.

## Consequences

Whether a Neovim scroll slides no longer depends on the terminal's scroll
sequences, the screen's contents, or where a frame falls between two writes.
Tests drive these rules with an injected clock and a real headless Neovim.

A terminal pane still slides one region at a time. When several windows scroll
together, as with `scrollbind`, only the current window slides.

Scrolls of an editor started before an update are not all named until it is
restarted.
