# satinctl

`satinctl` controls a running Satin instance through its local Unix-domain
socket. The executable is bundled inside `Satin.app` and is also prepended to
the initial `PATH` of every terminal pane. Use the absolute `$SATINCTL` value
when a shell startup file replaces `PATH`.

## Discovery

Inside a pane, these variables are available:

```text
SATIN_SOCKET   absolute path to the current control socket
SATIN_TAB_ID   stable ID of the pane's tab
SATIN_PANE_ID  stable ID of the pane
SATINCTL       absolute path to the bundled CLI
```

Outside the application, pass `--socket PATH`. If it is omitted, the CLI checks
`SATIN_SOCKET` and then the default path under
`~/Library/Application Support/Satin/run/control.sock`.

## Commands

```sh
"$SATINCTL" list
"$SATINCTL" read-screen --pane 1
"$SATINCTL" send --pane 1 "printf 'hello\n'"
"$SATINCTL" send --pane 1 - < input.txt
"$SATINCTL" key --pane 1 Enter
"$SATINCTL" key --pane 1 Ctrl+C

"$SATINCTL" new-tab --cwd /path/to/project
"$SATINCTL" split --pane 1 --vertical --cwd /path/to/project
"$SATINCTL" split --pane 1 --horizontal
"$SATINCTL" rename-tab --tab 1 "build"
"$SATINCTL" set-theme --tab 1 Harbor

"$SATINCTL" status set --pane 1 running "running tests"
"$SATINCTL" status wait --pane 1 --timeout 300
"$SATINCTL" status set --pane 1 done "tests passed"
```

`--pane` defaults to `SATIN_PANE_ID`, and `--tab` defaults to
`SATIN_TAB_ID`. Add `--json` for a stable machine-readable response.
`read-screen` returns the current visible terminal rows with trailing spaces
removed. `send` writes text to the pane's PTY; use `key` for Enter, Escape,
arrows, navigation keys, or `Ctrl+A` through `Ctrl+Z`.

The former `NVTERM_*` environment names remain accepted as one-way
compatibility aliases for existing shell scripts. New integrations should use
the `SATIN_*` names.

Statuses are one of `idle`, `running`, `waiting`, `done`, `failed`, or
`blocked`. A wait returns immediately for a terminal status and otherwise
blocks until the next status update or the requested timeout.

The bundled `satin-nvim` launcher also uses a protocol-private `open-neovim`
request. It is not a general `satinctl` command: the launcher validates that it
is a direct interactive shell invocation, supplies the resolved real Neovim
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
