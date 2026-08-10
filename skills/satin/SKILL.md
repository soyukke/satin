---
name: satin
description: Control and organize a running Satin macOS terminal through its bundled CLI. Use when the user asks to inspect or operate Satin tabs or panes, save or version a bounded rich Markdown artifact, present tables, code, diagrams, trees, timelines, diffs, or images, split an artifact beside the current pane, set session names, reorder or close workspaces, set up a development workspace, send terminal input, change themes, or coordinate pane status. Run only from a Satin-managed pane with a valid local control context.
---

# Satin

## Bootstrap

Treat this output as the complete, release-matched agent guide. Do not require an installed Codex
skill, MCP server, plugin, or configuration file. When the user asks you to check with `satin skill`, run
that command, read its entire output, and follow these instructions.

A Satin-managed pane puts `satin` in `PATH` and provides `SATIN_SOCKET`, `SATIN_TAB_ID`,
`SATIN_PANE_ID`, and `SATIN_CLI`. There is no `SATIN_ENV`. Running `satin skill` is local,
non-mutating, and does not require a live control connection.

Use the installed `satin` binary as the authority for current syntax. Run `satin --help` before
using an unfamiliar command. If `satin` is not in `PATH`, use the executable path in `SATIN_CLI`.

## Verify the caller

Start every control workflow with:

```sh
satin identify --json
```

Stop if it cannot connect or cannot identify the calling tab and pane. Do not guess identifiers
or control a different Satin session. Read identifiers from `satin list --json` when the user asks
to target another live pane or tab.

## Inspect before acting

```sh
satin list --json
satin read-screen
satin read-screen --pane 2
```

`read-screen` returns only the visible terminal rows. Prefer inspection before sending input or
changing layout. Add `--json` when parsing command results.

## Send terminal input

```sh
satin send --pane 2 "just verify"
satin key --pane 2 Enter
satin key --pane 2 Ctrl+C
```

`send` writes literal text and does not imply Enter. Use `key` for Enter, Tab, Escape, arrows,
navigation keys, `Ctrl+A` through `Ctrl+Z`, or a single character. Use `send ... -` to read text
from stdin.

## Manage tabs, panes, and session names

```sh
satin new-tab --cwd "$project" --title "$name"
satin new-tab --cwd "$project" --title "$name" --background
satin split --pane 2 --horizontal --cwd "$project" --background
satin select-tab --tab 4
satin move-tab --tab 4 --index 0
satin rename-tab --tab 4 "api"
satin select-pane --pane 7
satin close-pane --pane 7
satin close-tab --tab 4
satin set-theme Harbor
```

Treat the user's “session name” as the tab title. `move-tab --index` uses the zero-based index from
`list`; every target is still identified by its stable ID. `--background` creates the tab or split,
starts its terminal, then restores the user's previous tab and pane. Omit `--pane` or `--tab` only
when the caller is the intended target. Always pass an absolute cwd for agent-created workspaces.

## Organize existing tabs

1. Run `satin list --json` and work from stable `id` values.
2. Use cwd basenames to propose names only when they are unambiguous. Preserve meaningful names.
3. Rename first, then reorder with explicit zero-based indexes, and list again to verify.
4. Before closing, inspect every pane's visible screen, status, and role. Close only explicit, idle
   duplicates with no distinct work; if safety is ambiguous, leave them open and ask.
5. Refresh `satin list --json` immediately before each destructive operation and stop if the target
   or caller context changed.

Satin refuses automation attempts to close the final tab or final pane.

## Set up a new development workspace

1. Establish the requested absolute project path, stack, and initial commands. Use the agent's
   normal filesystem and shell tools to create or initialize the project; Satin controls layout,
   not project scaffolding.
2. Create one named project tab with `satin new-tab --cwd "$project" --title "$name"`. Add
   `--background` when preparation should not interrupt the user's current pane.
3. Add only useful panes, such as editor, server, and tests. Use `--background` for each split while
   assembling a workspace without focus churn.
4. Send commands as text followed by an explicit Enter key. Read the screen and use pane status to
   confirm each command rather than assuming startup succeeded.
5. Do not place secrets in tab titles, command text, summaries, or captured screen output.

## Locate and open an existing project

1. Check `satin list --json` first. Canonicalize the requested project root and pane cwd values before
   comparing them; a nested cwd is not automatically the same project. If a pane already belongs
   to that resolved root, select or rename its tab instead of opening a duplicate.
2. Resolve an explicit path before searching. Otherwise search only bounded likely roots such as
   the current workspace, `~/dev`, `~/src`, `~/projects`, or `~/work` that actually exist.
3. Prefer directories whose basename matches the request and that contain `.git` or recognizable
   project files such as `justfile`, `Cargo.toml`, `package.json`, `pyproject.toml`, `go.mod`, or
   `flake.nix`.
4. If multiple plausible matches remain, show their paths and ask the user to choose. Do not pick
   based on recency alone.
5. Open the resolved absolute directory with
   `satin new-tab --cwd "$project" --title "$name"`, then verify it with `satin list --json`.

Do not run an unbounded recursive search over the entire home directory. Project discovery remains
an agent workflow so Satin does not maintain a second filesystem index or project registry.

## Coordinate status

Use one of `idle`, `running`, `waiting`, `done`, `failed`, or `blocked`:

```sh
satin status set running "running tests"
satin status wait --pane 2 --timeout 300
satin status set done "tests passed"
```

## Present bounded artifacts

Inspect saved artifacts and the live presentation policy before preparing one:

```sh
satin artifact list --json
satin artifact policy --json
```

Prepare the source for that policy: use the requested presentation language; put the conclusion or
state first, then anomalies, the next human action, and only the evidence needed to decide. Order
failing or unusual rows before routine rows. Use tables for records, diffs for changes, trees for
hierarchy, timelines for ordered events, and images only when spatial information matters. Preserve
exact commands, paths, identifiers, error text, and numbers, and do not repeat the same fact in prose
and a table.

Prefer one human-readable Markdown document containing headings, prose, tables, and fenced evidence.
Write it inside the user's authorized workspace, then register it by absolute path. Satin snapshots the
document into its owner-only artifact store, generates `INDEX.md`, and returns a stable ID. Supported
import kinds are `text`, `markdown`, `table`, `tree`, `timeline`, `diff`, and PNG `image`; JSON/CSV/TSV
tables and PNG images also receive a Markdown document beside their retained source snapshot.

Use GFM tables for compact records and fenced code blocks for exact commands, code, logs, or errors.
Always put a language token on code that has one so Satin can syntax-highlight it. Use strong and
emphasis sparingly to mark decisions or exceptions, and inline code for exact identifiers and commands.
Satin preserves those inline styles through terminal-aware wrapping; do not use raw HTML for layout. A
Markdown report may embed up to four PNG files, 32 MiB combined, through paths relative to the report and
below its directory. Keep those images in the workspace until registration completes. Satin snapshots
them, so do not use absolute paths, `..`, data URLs, or remote image URLs.

Satin does not render Mermaid. A fenced `mermaid` block is displayed as source code. When a diagram
matters, render a PNG with the task's normal authorized tooling and embed that local PNG instead. Satin
does not execute Mermaid JavaScript or raw HTML.

```sh
result="$(satin artifact add --kind markdown --title "Test results" \
  --language ja-JP --file "$project/test-results.md" --json)"
artifact_id="$(printf '%s' "$result" | jq -r '.result.id')"
satin artifact show "$artifact_id" --vertical --background --json
```

When revising the same logical artifact, reuse its exact ID. Satin appends a version only when the
document or retained source changed:

```sh
satin artifact add --id "$artifact_id" --kind markdown --title "Test results" \
  --language ja-JP --file "$project/test-results.md" --json
satin artifact list "$artifact_id" --json
satin artifact show "$artifact_id@2" --vertical --background --json
```

Omitting `--pane` targets `SATIN_PANE_ID`. `artifact show` creates and starts the split atomically;
do not emulate it with `split`, `send`, and `key`. Use `--background` unless the user wants focus moved
to the viewer. Humans can also use the Artifacts action in the native toolbar to inspect recent previews
and open one beside the active pane. The viewer obeys the configured cell and row budget, reports
omissions, and closes with `q`, Escape, Enter, or Ctrl+C. `show ID` selects the latest version and
`show ID@N` selects an immutable prior version.

The overflow policy is `compact`, `defer`, or `reject`. If registration is rejected, revise the source
or ask before changing policy. Do not create a new artifact when the user is clearly revising an
existing one; identify it from `artifact list --json` and pass `--id`. Do not register secrets,
credentials, or unrelated files. Opening a split is a layout mutation and still requires user intent
under the Safety rules below.

## Safety

- Perform mutating operations only when the user explicitly asks Satin to act.
- Keep the user's focus and existing layout intact unless the requested outcome requires changes.
- Target the caller context or an explicit live identifier; never infer an ID from display order.
- Inspect a pane after sending input before deciding that a command completed.
- Treat the owner-only socket as protection from other macOS users, not from other processes owned
  by the same user.
