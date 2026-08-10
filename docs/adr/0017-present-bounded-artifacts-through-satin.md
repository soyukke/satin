# 0017: Store versioned Markdown artifacts and present them through Satin

Date: 2026-08-10

Status: Accepted

## Context

Agents can produce correct results that remain expensive for a human to scan in
raw terminal scrollback. Embedding a general browser would add a second runtime
without telling the producer how much information is appropriate. Satin already
has stable pane IDs, an owner-only control socket, atomic splits, Kitty graphics,
and a release-matched embedded agent skill.

## Decision

- An artifact has a stable ID and immutable numbered versions. `artifact add`
  creates an artifact, while `artifact add --id ID` appends a version. Registering
  unchanged content is idempotent. `show ID` selects the latest version and
  `show ID@N` selects a prior version.
- Every version contains a human-readable `artifact.md`. Markdown input is
  snapshotted directly; JSON/CSV/TSV tables, text, trees, timelines, diffs, and
  PNG images are import formats that also produce Markdown. Raw non-Markdown
  input is retained beside the document, so the original path may disappear.
- Markdown presentation uses a CommonMark/GFM event parser rather than raw-line
  heuristics. Headings, paragraphs, nested lists, task markers, blockquotes,
  thematic rules, fenced code, inline code, and GFM tables become bounded
  terminal-native blocks. Inline spans preserve strong, emphasis,
  strikethrough, link, and code styles across CJK-aware wrapping. Fenced code
  uses bundled `syntect` grammars with its pure-Rust regex backend; an unknown
  language falls back to a single restrained code color. Raw HTML is never
  executed.
- A Markdown document may reference up to four relative PNG files rooted below
  its source directory, with a 32 MiB combined limit. Registration snapshots
  them beside every immutable version and mirrors the current assets for direct
  `current.md` inspection. Absolute paths, traversal, remote URLs, and data URLs
  are not fetched. Kitty graphics places retained PNG data inside the Markdown
  flow while preserving its aspect ratio.
- Mermaid is deliberately not rendered. Its fenced source remains visible as a
  code block. Satin does not bundle Chromium or execute Mermaid JavaScript;
  authors should embed a generated local PNG when a diagram is needed.
- The owner-only persistent store normally lives at
  `~/Library/Application Support/Satin/artifacts`. Its directories use a title
  slug plus short ID. Root `INDEX.md`, per-artifact `README.md` and `current.md`,
  and `versions/vNNN/artifact.md` make direct filesystem inspection useful.
  JSON is limited to internal metadata and a hidden ID lookup index.
- The default preview budget is 80 terminal cells by 32 rows. Users can change
  both limits, the BCP 47 presentation language, and an overflow policy of
  `compact`, `defer`, or `reject`. A preview never bypasses its configured bound;
  the original source may be larger.
- Rust owns the store, version validation, readable indexes, policy validation,
  CJK-aware cell measurement, structured formatting, omission accounting, and
  Kitty PNG emission. Swift owns the native recent-artifact popover and split,
  and supplies a validated startup argv to a terminal pane.
- `artifact show` is atomic. Agents do not create a pane and inject a shell
  command in separate control operations. The current pane comes from
  `SATIN_PANE_ID`, and background creation restores the user's prior focus.
- The existing embedded `satin` skill documents artifact discovery and use. A
  separately installed bootstrap skill is not required.
- Text, Markdown, JSON/CSV/TSV tables, trees, timelines, diffs, and PNG images are
  the initial representations. HTML is not the artifact protocol and can be
  added later as one explicitly sandboxed viewer kind.

## Consequences

The native toolbar has one Artifacts action. Its popover shows at most five recent
titles, versions, update times, and short previews. Selecting a row opens the
latest version in a right split and focuses it. This is the only native library
surface in the initial version; searching, tags, thumbnails, diffing versions,
sync, and export are intentionally absent.

The viewer remains a bounded Rust TUI launched as a terminal startup command.
It exercises the existing libghostty-vt and Kitty paths without extending the
AppKit cell renderer. Its CLI and store contracts are independent of that
implementation. A retained native artifact pane may replace the TUI when richer
interaction or accessibility requires it, while preserving artifact IDs,
versions, and CLI selectors.

This renderer is intentionally a presentation profile, not a general Markdown
browser. Links remain text, remote media is not loaded, HTML/CSS is not a layout
escape hatch. Diagram rendering remains outside the initial Markdown surface.
Those constraints keep reports deterministic, offline, and enforceably bounded.

The initial version does not expose removal or garbage collection. Add one
simple recoverable removal operation before treating the store as an unbounded
long-term archive. Do not add tags, search, export, or synchronization merely to
compensate for that lifecycle gap.
