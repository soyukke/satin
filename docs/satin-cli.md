# Satin CLI

`satin` controls a running Satin instance through its local Unix-domain socket.
The executable is bundled inside `Satin.app` and its directory is prepended to
the initial `PATH` of every terminal pane. Use the absolute `$SATIN_CLI` value
when a shell startup file replaces `PATH`.

## Agent guide

```sh
satin skill
```

This prints the release-matched `skills/satin/SKILL.md` embedded in the CLI.
It does not require a running application or modify an agent's configuration.

## Discovery

Inside a pane, these variables are available:

```text
SATIN_SOCKET   absolute path to the current control socket
SATIN_TAB_ID   stable ID of the pane's tab
SATIN_PANE_ID  stable ID of the pane
SATIN_CLI      absolute path to the bundled CLI
```

Confirm the calling context before automation:

```sh
satin identify --json
```

`identify` requires the pane environment, connects to the current socket, and
verifies that both identifiers still belong to the same live context.

Outside the application, pass `--socket PATH`. If it is omitted, the CLI checks
`SATIN_SOCKET` and then the default path under
`~/Library/Application Support/Satin/run/control.sock`.

## Commands

```sh
satin list
satin read-screen --pane 1
satin send --pane 1 "printf 'hello\n'"
satin send --pane 1 - < input.txt
satin key --pane 1 Enter
satin key --pane 1 Ctrl+C

satin new-tab --cwd /path/to/project --title project
satin new-tab --cwd /path/to/project --title project --background
satin split --pane 1 --vertical --cwd /path/to/project --background
satin split --pane 1 --horizontal
satin select-tab --tab 2
satin move-tab --tab 2 --index 0
satin rename-tab --tab 2 "project"
satin close-tab --tab 2
satin select-pane --pane 3
satin close-pane --pane 3
satin set-theme --tab 2 Harbor

satin status set --pane 1 running "running tests"
satin status wait --pane 1 --timeout 300
satin status set --pane 1 done "tests passed"

satin artifact policy --json
satin artifact policy set --max-columns 80 --max-rows 32 \
  --language ja-JP --overflow compact
satin artifact add --kind table --title "Test results" \
  --language ja-JP --file /absolute/path/results.json --json
satin artifact add --id ARTIFACT_ID --kind markdown --title "Test results" \
  --language ja-JP --file /absolute/path/results.md --json
satin artifact list --json
satin artifact list ARTIFACT_ID --json
satin artifact show ARTIFACT_ID --background
satin artifact show ARTIFACT_ID@2
```

`--pane` defaults to `SATIN_PANE_ID`, and `--tab` defaults to
`SATIN_TAB_ID`. Add `--json` for a stable machine-readable response.
`read-screen` returns the current visible terminal rows with trailing spaces
removed. `send` writes text to the pane's PTY; use `key` for Enter, Escape,
arrows, navigation keys, or `Ctrl+A` through `Ctrl+Z`.

Tab and pane targets use stable IDs from `list`; only `move-tab --index` uses
the current zero-based presentation index. A new tab can set its cwd and title
atomically. `--background` creates and starts the requested tab or split, then
restores the previously active tab and pane. The final tab and final pane cannot
be closed through automation. For artifacts, `--background` keeps focus in the
workspace while the right sidebar opens or refreshes.

The former `NVTERM_*` environment names remain accepted as one-way
compatibility aliases for existing shell scripts. New integrations should use
the `SATIN_*` names.

Statuses are one of `idle`, `running`, `waiting`, `done`, `failed`, or
`blocked`. A wait returns immediately for a terminal status and otherwise
blocks until the next status update or the requested timeout.

## Artifacts

Artifacts snapshot an absolute local source file into a versioned, bounded
presentation.
The default maximum is 80 terminal cells by 32 rows. `artifact policy set`
changes the maximum, presentation language, and overflow behavior:

- `compact` registers the source and reports omitted rows or columns.
- `defer` registers the source but shows a small deferred-preview card.
- `reject` refuses registration when the rendered preview would omit content.

Supported kinds are `text`, `markdown`, `table`, `tree`, `timeline`, `diff`,
and PNG `image`. JSON arrays or objects and comma- or tab-delimited files can
back a table. Text-like sources are limited to 8 MiB and PNG sources to 16 MiB.
Each version has a human-readable `artifact.md`; non-Markdown imports retain a
raw source snapshot beside it. The original input path is no longer required
after registration.

Markdown uses a terminal-native CommonMark/GFM presentation. It renders
headings, paragraphs, ordered and unordered lists, task markers, blockquotes,
strong, emphasis, strikethrough, links, inline and fenced code, thematic rules,
and GFM tables instead of displaying their source punctuation. Inline styles
remain local to their text span. A fenced language token selects bundled
syntax highlighting; unknown languages remain readable as uniformly accented
code. Raw HTML is not executed. A report can embed relative PNG files below the
Markdown file's directory:

````markdown
| Check | Result |
| --- | --- |
| tests | pass |

```rust
let width = 80;
```

![Trend](images/trend.png)
````

Registration snapshots up to four such PNGs, at most 32 MiB combined, and the
viewer places them inline through Kitty graphics. Absolute paths, `..`, remote
URLs, data URLs, and non-PNG media are not loaded. Changing only an embedded PNG
still creates a new artifact version.

Mermaid is not a rendered Markdown feature. A fenced `mermaid` block remains a
readable code block. When a diagram matters, render it to a local PNG first and
embed that PNG in the report; Satin does not bundle a browser or execute
Mermaid JavaScript.

`artifact add` returns a stable ID. Passing that ID back with `--id` appends a
version; unchanged content is idempotent and retains the existing version.
`artifact list` shows the latest versions, while `artifact list ID` shows one
artifact's versions. `show ID` selects the latest snapshot and `show ID@N`
selects an immutable prior version.

The normal store is owner-only at
`~/Library/Application Support/Satin/artifacts`. For a custom control socket
outside a `run` directory, the store is `<socket-parent>/artifacts`, which keeps
tests and isolated instances self-contained. The store is deliberately
readable without Satin:

```text
artifacts/
├── INDEX.md
└── title--ID/
    ├── README.md
    ├── current.md
    ├── metadata.json
    ├── images/chart.png        # current embedded-asset mirror
    └── versions/v001/
        ├── artifact.md
        └── images/chart.png    # immutable version snapshot
```

JSON is internal metadata; Markdown is the human-facing document. `INDEX.md`
and each `README.md` link to the current and prior snapshots.

The Artifacts action at the right edge of the native toolbar opens a popover with
the five most recent titles, versions, update times, and short previews. Selecting
a row opens a window-scoped right sidebar without replacing a terminal, Neovim,
or tmux pane. Selecting another artifact or running `artifact show` again replaces
only the viewer inside that same sidebar. Omitting `--pane` targets
`SATIN_PANE_ID`; `--background` preserves workspace focus. Legacy `--vertical`
and `--horizontal` flags are accepted as compatibility no-ops.

`artifact view ID` is normally launched by `artifact show`. `--no-wait` emits
one rendered frame for diagnostics without entering the alternate screen.

The bundled `satin-nvim` launcher also uses a protocol-private `open-neovim`
request. It is not a general `satin` command: the launcher validates that it is
a direct interactive shell invocation, supplies the resolved real Neovim
executable and invocation context, and waits until that native session exits.

## Protocol and security

Protocol version 1 is newline-delimited JSON. A request has `version: 1`, a
`command`, and command-specific fields. Responses contain `ok` and either
`result` or an error with stable `code` and human-readable `message` fields.

The socket is local-only, mode `0600`, and accepts peers only when their UID
matches the application. Its parent directory must be owner-only, and a second
instance cannot replace a socket that is still accepting connections. Requests
are limited to 1 MiB, concurrent clients to 32, normal requests to 30 seconds,
and status waits to one hour. The launcher-owned Neovim request lasts for the
editor session so it can restore the original shell and return the exit status.

Artifact payloads do not cross the control socket. Only a validated artifact
selector and bounded control metadata are sent; snapshots remain local files.

This boundary protects against other macOS users, not other processes running
as the same user. Do not move the socket into a shared directory or forward it
to another machine.
