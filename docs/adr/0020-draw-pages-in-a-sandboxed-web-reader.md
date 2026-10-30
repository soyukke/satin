# 0020: Draw pages in a sandboxed web reader

Date: 2026-10-30

Status: Proposed

## Context

ADR 0017 made pages bounded, offline, and deterministic Markdown. That keeps
reports small, but an agent cannot show a diagram, a chart, or a comparison
except as a PNG it renders itself, and Mermaid stays a code block. The reader
has since become a native document over the middle of the window
(`NativePageDocument.swift`), so the 80 by 32 cell budget and the four-image cap,
which were sized for a terminal sidebar, no longer match what the reader can
show.

Two things lower the cost of reading an agent's report: richer forms such as
diagrams and charts, and forms that look the same from page to page. A free
HTML page gives the first and loses the second. Markdown gives the second and
is cheaper for an agent to write and readable in the store without Satin.

## Decision

Keep Markdown as the page source and draw every page in a WebKit reader that
loads only the page's own snapshot and the libraries Satin bundles.

- The reader hosts a `WKWebView` with a non-persistent data store. A
  `WKURLSchemeHandler` for `satin-page:` serves the selected version's files and
  the bundled libraries; every other load, including `file:` and network
  schemes, is refused, and the page's Content-Security-Policy names only
  `satin-page:`. JavaScript runs. No script message handler is installed, so a
  page cannot call into Satin. A clicked link is cancelled in the reader and
  opened by the system, as Command-click opens it in a terminal.
- A Markdown page is converted in the reader by a bundled Markdown parser and
  styled by one Satin stylesheet. The reader injects the current look's colors
  and fonts as CSS custom properties and updates them when the look or paper
  mode changes.
- Fenced blocks form a small vocabulary that the stylesheet and bundled scripts
  draw: `mermaid` with Mermaid, `chart` with a JSON Chart.js configuration, and
  GFM alerts (`> [!NOTE]`, `> [!WARNING]`) as callouts. Inline `<svg>` and
  relative PNG, JPEG, and SVG images are drawn. New fences are added to this
  vocabulary rather than left to each page's own markup.
- `--kind html` registers one self-contained HTML file, or with `--assets DIR`
  the files below `DIR`, for a page that Markdown cannot express, such as an
  interactive table. It is drawn under the same sandbox and stylesheet
  variables.
- The bundled libraries (the Markdown parser, Mermaid, and Chart.js) are pinned,
  shipped in the app bundle, served at `satin-page://reader/lib/`, and listed in
  `THIRD_PARTY_NOTICES.md`. No library is fetched at run time.
- The cell budget and the overflow policy are removed. `page policy set` keeps
  `--language`; `--max-columns`, `--max-rows`, and `--overflow` are accepted as
  no-ops. The four-image cap is removed. One version, with every asset, is
  limited to 64 MiB.
- `page remove ID` moves a page to `artifacts/.trash/` and `page restore ID`
  moves it back. Satin never empties the trash itself.
- The stylesheet, the bundled libraries, and the script that turns a version's
  files into a document form one page renderer kept in this repository. The
  Mac reader and a phone client that reads the store over SSH both load it in
  their own `WKWebView` with their own `satin-page:` handler, so a page looks
  the same on both. `page files ID@N --json` lists a version's files, so a
  client without the store on disk can fetch them.
- `page view`, the terminal program that drew a page as text and Kitty images
  inside a pane, is removed with the core's Markdown renderer. The reader no
  longer keeps a terminal pane behind the document: `read-screen` on the reader
  returns the document's text and `close-pane` closes it.

This supersedes ADR 0017 where it never executes HTML, does not render Mermaid,
does not bundle a browser engine, caps embedded images at four, and bounds
registration by a cell budget. Its store layout, immutable versions, read marks,
and CLI selectors are kept.

## Consequences

Easier:

- An agent can put a diagram or a chart in a report by writing a fenced block,
  with no rendering step of its own.
- Pages share one look, set by Satin, and follow the current look and paper
  mode.
- One renderer draws Markdown and HTML pages on the Mac and on a phone; the
  AppKit Markdown document and the core's terminal page renderer are removed.

Harder or lost:

- WebKit runs in the app with JavaScript on. The scheme handler, the policy, and
  the absent message handler are the boundary, and a mistake in any of them
  reaches the network or the file system.
- Satin ships and updates several megabytes of third-party JavaScript, Mermaid
  being the largest.
- A version may be up to 64 MiB, and pages are kept until the user removes
  them, so the store can grow large.
- The reader's keys (Esc, Space, arrows) must be taken before WebKit consumes
  them, including inside an HTML page that handles keys itself.
- A page can no longer be read inside a plain terminal except as the
  Markdown files in the store.
- A phone client must fetch every file of a version over SSH before drawing
  it, and ships the same renderer as the Mac.
