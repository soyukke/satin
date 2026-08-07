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
be closed through automation.

The former `NVTERM_*` environment names remain accepted as one-way
compatibility aliases for existing shell scripts. New integrations should use
the `SATIN_*` names.

Statuses are one of `idle`, `running`, `waiting`, `done`, `failed`, or
`blocked`. A wait returns immediately for a terminal status and otherwise
blocks until the next status update or the requested timeout.

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

This boundary protects against other macOS users, not other processes running
as the same user. Do not move the socket into a shared directory or forward it
to another machine.
