# Page renderer

The page renderer draws one page version the way ADR 0020 describes: Markdown
styled by one Satin stylesheet, with diagrams and charts drawn by bundled
libraries. It is plain HTML, CSS, and JavaScript, so the Mac reader and a phone
client can load the same files in their own `WKWebView`. The Mac reader loads it
from `Resources/PageRenderer` (`NativePageDocument.swift`).

```sh
just page-preview                      # the sample, at the printed URL
just page-preview sample/artifact.md 9000
```

The preview adds a datasheet/paper switch over the page. A page to preview must
lie below `page-renderer`, because the server serves only that directory.

## Files

- `index.html` loads the libraries, the stylesheet, and the script under a
  Content-Security-Policy that allows only the page's own origin and
  `satin-page:`. A page's `<script>` elements and `on*` attributes do not run.
- `satin-page.css` holds both looks as CSS custom properties, with the values
  of `NativePageStyle` in the app.
- `satin-page.js` reads `?page=` (default `artifact.md`), `?look=`
  (`datasheet` or `paper`), and `?lang=`, and exposes
  `satinPage.open(path, lang)`, `satinPage.render(markdown, url)`, and
  `satinPage.setLook(look, colors)` for a host. `colors` overrides tokens, as
  `{"--surface": "#fff"}`; `--sheet` sets the page's background. With `?host`
  the script opens nothing itself and waits for the host.
- `lib/` holds markdown-it, Mermaid, and Chart.js, unmodified and pinned. Their
  versions, hashes, and licenses are in `THIRD_PARTY_NOTICES.md`, and
  `just license-audit` checks the hashes.
- `sample/` is a page that uses every form below.

## What a page can use

- CommonMark with GFM tables, strikethrough, and autolinks.
- `> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, and `[!CAUTION]`
  callouts, titled in the page's language.
- `- [ ]` and `- [x]` task items.
- A ` ```mermaid ` fence, drawn in the current look's colors. A wide diagram
  keeps its type size and scrolls.
- A ` ```chart ` fence holding a Chart.js configuration as JSON. Datasets
  without colors take the look's series colors.
- Text after a fence's language becomes the figure's caption:
  ` ```chart Daily p95 (ms) `.
- Inline `<svg>`, which may use the look's tokens, such as
  `fill="var(--teal)"`, so it follows the look.
- Images by a relative path inside the page's snapshot. Other images are shown
  as their alternative text.
