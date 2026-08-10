use std::{
    collections::BTreeSet,
    io::Cursor,
    path::{Component, Path, PathBuf},
    sync::LazyLock,
};

use anyhow::{Context, Result, anyhow, bail};
use pulldown_cmark::{
    BlockQuoteKind, CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd,
};
use syntect::{
    easy::HighlightLines,
    highlighting::{FontStyle, Style as SyntaxStyle, Theme, ThemeSet},
    parsing::{SyntaxReference, SyntaxSet},
};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use super::{
    ArtifactAsset, ArtifactManifest, BodyImage, BodyRender, LineStyle, MAX_IMAGE_BYTES, RgbColor,
    SpanStyle, StyledLine, StyledSpan, read_bounded_source, read_text_source, table_border,
    table_column_limit, table_row, table_widths, truncate_display, validate_png,
};

const MAX_EMBEDDED_IMAGES: usize = 4;
const MAX_EMBEDDED_IMAGE_BYTES: u64 = 32 * 1024 * 1024;
const MIN_IMAGE_ROWS: usize = 3;
const MAX_IMAGE_ROWS: usize = 10;
const MAX_HIGHLIGHT_LINE_BYTES: usize = 4096;

pub(super) fn snapshot_local_pngs(content: &str, source: &Path) -> Result<Vec<ArtifactAsset>> {
    let parent = source
        .parent()
        .ok_or_else(|| anyhow!("Markdown source has no parent directory"))?
        .canonicalize()
        .with_context(|| format!("resolve Markdown directory for {}", source.display()))?;
    let mut seen = BTreeSet::new();
    let mut assets = Vec::new();
    let mut total_bytes = 0u64;
    for destination in image_destinations(content) {
        let Some(relative_path) = safe_local_png_destination(&destination) else {
            continue;
        };
        if !seen.insert(relative_path.clone()) {
            continue;
        }
        if assets.len() == MAX_EMBEDDED_IMAGES {
            bail!("Markdown artifacts support at most {MAX_EMBEDDED_IMAGES} local PNG images");
        }
        let path = resolve_source_asset(&parent, &relative_path)?;
        validate_png(&path)?;
        let bytes = read_bounded_source(&path, MAX_IMAGE_BYTES, "Markdown image")?;
        total_bytes = total_bytes.saturating_add(bytes.len().try_into().unwrap_or(u64::MAX));
        if total_bytes > MAX_EMBEDDED_IMAGE_BYTES {
            bail!("Markdown image snapshots exceed the 32 MiB combined limit");
        }
        assets.push(ArtifactAsset {
            relative_path,
            bytes,
        });
    }
    Ok(assets)
}

pub(super) fn render_markdown_body(
    manifest: &ArtifactManifest,
    width: usize,
    limit: usize,
) -> Result<BodyRender> {
    let content = read_text_source(manifest)?;
    let source_lines = content.lines().count();
    let blocks = parse_blocks(&content);
    let mut layout = MarkdownLayout::new(width, limit, source_lines);
    let mut first_visible = true;
    for block in blocks {
        if should_skip_duplicate_title(&block, manifest, first_visible) {
            continue;
        }
        if !first_visible {
            layout.separate();
        }
        render_block(&mut layout, manifest, block)?;
        first_visible = false;
    }
    Ok(layout.finish())
}

fn markdown_options() -> Options {
    Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_GFM
        | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS
}

fn image_destinations(content: &str) -> Vec<String> {
    Parser::new_ext(content, markdown_options())
        .filter_map(|event| match event {
            Event::Start(Tag::Image { dest_url, .. }) => Some(dest_url.into_string()),
            _ => None,
        })
        .collect()
}

fn safe_local_png_destination(destination: &str) -> Option<PathBuf> {
    if destination.contains("://")
        || destination.starts_with("data:")
        || destination.starts_with('#')
    {
        return None;
    }
    let raw = destination.split(['?', '#']).next()?.trim();
    let path = Path::new(raw);
    if path.is_absolute()
        || path
            .extension()
            .and_then(|extension| extension.to_str())
            .is_none_or(|extension| !extension.eq_ignore_ascii_case("png"))
    {
        return None;
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(value) => normalized.push(value),
            _ => return None,
        }
    }
    let first = normalized.components().next()?.as_os_str().to_str()?;
    let reserved = [
        "versions",
        "metadata.json",
        "README.md",
        "current.md",
        "INDEX.md",
    ];
    (!first.starts_with('.')
        && !reserved
            .iter()
            .any(|value| first.eq_ignore_ascii_case(value)))
    .then_some(normalized)
}

fn resolve_source_asset(parent: &Path, relative: &Path) -> Result<PathBuf> {
    let path = parent
        .join(relative)
        .canonicalize()
        .with_context(|| format!("resolve Markdown image {}", parent.join(relative).display()))?;
    if !path.starts_with(parent) {
        bail!("Markdown image resolves outside the source directory");
    }
    Ok(path)
}

enum MarkdownBlock {
    Text {
        text: String,
        spans: Vec<StyledSpan>,
        prefix: String,
        style: LineStyle,
    },
    Code {
        language: String,
        source: String,
    },
    Table {
        headers: Vec<String>,
        rows: Vec<Vec<String>>,
    },
    Image {
        alt: String,
        destination: String,
    },
    Rule,
}

fn parse_blocks(content: &str) -> Vec<MarkdownBlock> {
    let mut state = MarkdownParser::default();
    for event in Parser::new_ext(content, markdown_options()) {
        state.handle(event);
    }
    state.finish()
}

#[derive(Default)]
struct MarkdownParser {
    blocks: Vec<MarkdownBlock>,
    text: Option<TextBuffer>,
    code: Option<CodeBuffer>,
    table: Option<TableBuffer>,
    image: Option<ImageBuffer>,
    lists: Vec<ListState>,
    items: Vec<String>,
    quotes: Vec<Option<BlockQuoteKind>>,
    inline: InlineState,
    metadata_depth: usize,
    html_depth: usize,
}

impl MarkdownParser {
    fn handle(&mut self, event: Event<'_>) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(value) => self.append(&value),
            Event::Code(value) => self.append_inline_code(&value),
            Event::InlineMath(value) => self.append_inline_code(&format!("${value}$")),
            Event::DisplayMath(value) => self.push_code("math", &value),
            Event::Html(_) | Event::InlineHtml(_) => {}
            Event::FootnoteReference(value) => self.append(&format!("[{value}]")),
            Event::SoftBreak => self.append(" "),
            Event::HardBreak => self.append("\n"),
            Event::Rule => self.push_rule(),
            Event::TaskListMarker(checked) => self.task_marker(checked),
        }
    }

    fn start(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Paragraph => self.begin_text(LineStyle::Normal, String::new()),
            Tag::Heading { level, .. } => {
                self.begin_text(LineStyle::Heading, heading_prefix(level))
            }
            Tag::BlockQuote(kind) => self.quotes.push(kind),
            Tag::CodeBlock(kind) => self.begin_code(kind),
            Tag::HtmlBlock => self.begin_html(),
            Tag::List(start) => self.lists.push(ListState::new(start)),
            Tag::Item => self.begin_item(),
            Tag::FootnoteDefinition(label) => {
                self.begin_text(LineStyle::Muted, format!("[{label}] "))
            }
            Tag::Table(_) => self.begin_table(),
            Tag::TableHead => self.begin_table_head(),
            Tag::TableRow => self.begin_table_row(),
            Tag::TableCell => self.begin_table_cell(),
            Tag::Image { dest_url, .. } => self.begin_image(dest_url.into_string()),
            Tag::MetadataBlock(_) => self.begin_metadata(),
            Tag::Strong => self.inline.strong = self.inline.strong.saturating_add(1),
            Tag::Emphasis => self.inline.emphasis = self.inline.emphasis.saturating_add(1),
            Tag::Strikethrough => {
                self.inline.strikethrough = self.inline.strikethrough.saturating_add(1);
            }
            Tag::Link { .. } => self.inline.link = self.inline.link.saturating_add(1),
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph | TagEnd::Heading(_) | TagEnd::FootnoteDefinition => {
                self.flush_text()
            }
            TagEnd::BlockQuote(_) => {
                self.flush_text();
                self.quotes.pop();
            }
            TagEnd::CodeBlock => self.finish_code(),
            TagEnd::HtmlBlock => self.finish_html(),
            TagEnd::List(_) => {
                self.flush_text();
                self.lists.pop();
            }
            TagEnd::Item => self.finish_item(),
            TagEnd::Table => self.finish_table(),
            TagEnd::TableHead => self.finish_table_head(),
            TagEnd::TableRow => self.finish_table_row(),
            TagEnd::TableCell => self.finish_table_cell(),
            TagEnd::Image => self.finish_image(),
            TagEnd::MetadataBlock(_) => self.metadata_depth = self.metadata_depth.saturating_sub(1),
            TagEnd::Strong => self.inline.strong = self.inline.strong.saturating_sub(1),
            TagEnd::Emphasis => self.inline.emphasis = self.inline.emphasis.saturating_sub(1),
            TagEnd::Strikethrough => {
                self.inline.strikethrough = self.inline.strikethrough.saturating_sub(1);
            }
            TagEnd::Link => self.inline.link = self.inline.link.saturating_sub(1),
            _ => {}
        }
    }

    fn begin_text(&mut self, style: LineStyle, extra_prefix: String) {
        self.flush_text();
        let prefix = format!(
            "{}{}{}",
            self.quote_prefix(),
            self.item_prefix(),
            extra_prefix
        );
        self.text = Some(TextBuffer {
            spans: Vec::new(),
            prefix,
            style,
        });
    }

    fn append(&mut self, value: &str) {
        if self.metadata_depth > 0 || self.html_depth > 0 {
            return;
        }
        if let Some(code) = self.code.as_mut() {
            code.source.push_str(value);
        } else if let Some(image) = self.image.as_mut() {
            image.alt.push_str(value);
        } else if let Some(table) = self.table.as_mut() {
            table.cell.push_str(value);
        } else {
            self.append_text_span(value, false);
        }
    }

    fn append_inline_code(&mut self, value: &str) {
        if self.metadata_depth > 0 || self.html_depth > 0 {
            return;
        }
        if let Some(code) = self.code.as_mut() {
            code.source.push_str(value);
        } else if let Some(image) = self.image.as_mut() {
            image.alt.push_str(value);
        } else if let Some(table) = self.table.as_mut() {
            table.cell.push_str(&format!("‹{value}›"));
        } else {
            self.append_text_span(value, true);
        }
    }

    fn append_text_span(&mut self, value: &str, inline_code: bool) {
        if self.text.is_none() {
            self.begin_text(LineStyle::Normal, String::new());
        }
        let inline = self.inline;
        if let Some(text) = self.text.as_mut() {
            let style = inline.span_style(text.style, inline_code);
            append_span(&mut text.spans, value, style);
        }
    }

    fn flush_text(&mut self) {
        let Some(mut text) = self.text.take() else {
            return;
        };
        trim_spans(&mut text.spans);
        let text_value = plain_text(&text.spans);
        if !text_value.is_empty() {
            self.blocks.push(MarkdownBlock::Text {
                text: text_value,
                spans: text.spans,
                prefix: text.prefix,
                style: text.style,
            });
        }
    }

    fn begin_code(&mut self, kind: CodeBlockKind<'_>) {
        self.flush_text();
        let language = match kind {
            CodeBlockKind::Indented => String::new(),
            CodeBlockKind::Fenced(value) => {
                value.split_whitespace().next().unwrap_or("").to_owned()
            }
        };
        self.code = Some(CodeBuffer {
            language,
            source: String::new(),
        });
    }

    fn finish_code(&mut self) {
        let Some(code) = self.code.take() else {
            return;
        };
        self.blocks.push(MarkdownBlock::Code {
            language: code.language,
            source: code.source,
        });
    }

    fn push_code(&mut self, language: &str, source: &str) {
        self.flush_text();
        self.blocks.push(MarkdownBlock::Code {
            language: language.to_owned(),
            source: source.to_owned(),
        });
    }

    fn begin_table(&mut self) {
        self.flush_text();
        self.table = Some(TableBuffer::default());
    }

    fn begin_table_head(&mut self) {
        if let Some(table) = self.table.as_mut() {
            table.in_head = true;
            table.row.clear();
        }
    }

    fn finish_table_head(&mut self) {
        if let Some(table) = self.table.as_mut() {
            table.finish_row();
            table.headers = std::mem::take(&mut table.row);
            table.in_head = false;
        }
    }

    fn begin_table_row(&mut self) {
        if let Some(table) = self.table.as_mut() {
            table.row.clear();
        }
    }

    fn finish_table_row(&mut self) {
        if let Some(table) = self.table.as_mut() {
            table.finish_row();
            let row = std::mem::take(&mut table.row);
            if table.in_head {
                table.headers = row;
            } else if !row.is_empty() {
                table.rows.push(row);
            }
        }
    }

    fn begin_table_cell(&mut self) {
        if let Some(table) = self.table.as_mut() {
            table.cell.clear();
        }
    }

    fn finish_table_cell(&mut self) {
        if let Some(table) = self.table.as_mut() {
            table.row.push(table.cell.trim().to_owned());
            table.cell.clear();
        }
    }

    fn finish_table(&mut self) {
        let Some(mut table) = self.table.take() else {
            return;
        };
        table.finish_row();
        if table.headers.is_empty() && !table.rows.is_empty() {
            table.headers = table.rows.remove(0);
        }
        self.blocks.push(MarkdownBlock::Table {
            headers: table.headers,
            rows: table.rows,
        });
    }

    fn begin_image(&mut self, destination: String) {
        let in_table = self.table.is_some();
        if !in_table {
            self.flush_text();
        }
        self.image = Some(ImageBuffer {
            alt: String::new(),
            destination,
            in_table,
        });
    }

    fn finish_image(&mut self) {
        let Some(image) = self.image.take() else {
            return;
        };
        if image.in_table {
            if let Some(table) = self.table.as_mut() {
                table
                    .cell
                    .push_str(&format!("[Image: {}]", image.alt.trim()));
            }
            return;
        }
        self.blocks.push(MarkdownBlock::Image {
            alt: image.alt.trim().to_owned(),
            destination: image.destination,
        });
    }

    fn begin_item(&mut self) {
        self.flush_text();
        let depth = self.lists.len().saturating_sub(1);
        let marker = self
            .lists
            .last_mut()
            .map_or_else(|| "• ".to_owned(), ListState::next_marker);
        self.items.push(format!("{}{marker}", "  ".repeat(depth)));
    }

    fn finish_item(&mut self) {
        self.flush_text();
        self.items.pop();
    }

    fn task_marker(&mut self, checked: bool) {
        let marker = if checked { "☑ " } else { "☐ " };
        if let Some(text) = self.text.as_mut() {
            text.prefix.push_str(marker);
        }
    }

    fn quote_prefix(&self) -> String {
        self.quotes
            .iter()
            .map(|kind| quote_marker(*kind))
            .collect::<Vec<_>>()
            .join("")
    }

    fn item_prefix(&self) -> &str {
        self.items.last().map_or("", String::as_str)
    }

    fn push_rule(&mut self) {
        self.flush_text();
        self.blocks.push(MarkdownBlock::Rule);
    }

    fn begin_metadata(&mut self) {
        self.flush_text();
        self.metadata_depth += 1;
    }

    fn begin_html(&mut self) {
        self.flush_text();
        self.html_depth += 1;
    }

    fn finish_html(&mut self) {
        self.html_depth = self.html_depth.saturating_sub(1);
        self.blocks.push(MarkdownBlock::Text {
            text: "HTML block omitted".to_owned(),
            spans: vec![StyledSpan::new(
                "HTML block omitted",
                SpanStyle::new(LineStyle::Muted),
            )],
            prefix: String::new(),
            style: LineStyle::Muted,
        });
    }

    fn finish(mut self) -> Vec<MarkdownBlock> {
        self.flush_text();
        self.finish_code();
        self.finish_table();
        self.finish_image();
        self.blocks
    }
}

#[derive(Clone, Copy, Default)]
struct InlineState {
    strong: usize,
    emphasis: usize,
    strikethrough: usize,
    link: usize,
}

impl InlineState {
    const fn span_style(self, base: LineStyle, inline_code: bool) -> SpanStyle {
        let mut style = SpanStyle::new(if inline_code || self.link > 0 {
            LineStyle::Accent
        } else {
            base
        });
        style.bold = self.strong > 0;
        style.italic = self.emphasis > 0;
        style.underline = self.link > 0;
        style.strikethrough = self.strikethrough > 0;
        if inline_code {
            style.background = Some(RgbColor {
                red: 38,
                green: 48,
                blue: 61,
            });
        }
        style
    }
}

fn append_span(spans: &mut Vec<StyledSpan>, value: &str, style: SpanStyle) {
    if value.is_empty() {
        return;
    }
    if let Some(last) = spans.last_mut()
        && last.style == style
    {
        last.text.push_str(value);
        return;
    }
    spans.push(StyledSpan::new(value, style));
}

fn trim_spans(spans: &mut Vec<StyledSpan>) {
    while let Some(first) = spans.first_mut() {
        let trimmed = first.text.trim_start().to_owned();
        if trimmed.is_empty() {
            spans.remove(0);
        } else {
            first.text = trimmed;
            break;
        }
    }
    while let Some(last) = spans.last_mut() {
        let trimmed = last.text.trim_end().to_owned();
        if trimmed.is_empty() {
            spans.pop();
        } else {
            last.text = trimmed;
            break;
        }
    }
}

fn plain_text(spans: &[StyledSpan]) -> String {
    spans
        .iter()
        .map(|span| span.text.as_str())
        .collect::<String>()
}

struct TextBuffer {
    spans: Vec<StyledSpan>,
    prefix: String,
    style: LineStyle,
}

struct CodeBuffer {
    language: String,
    source: String,
}

#[derive(Default)]
struct TableBuffer {
    headers: Vec<String>,
    rows: Vec<Vec<String>>,
    row: Vec<String>,
    cell: String,
    in_head: bool,
}

impl TableBuffer {
    fn finish_row(&mut self) {
        if !self.cell.trim().is_empty() {
            self.row.push(self.cell.trim().to_owned());
            self.cell.clear();
        }
    }
}

struct ImageBuffer {
    alt: String,
    destination: String,
    in_table: bool,
}

struct ListState {
    next: Option<u64>,
}

impl ListState {
    const fn new(start: Option<u64>) -> Self {
        Self { next: start }
    }

    fn next_marker(&mut self) -> String {
        let Some(number) = self.next.as_mut() else {
            return "• ".to_owned();
        };
        let marker = format!("{number}. ");
        *number = number.saturating_add(1);
        marker
    }
}

fn heading_prefix(level: HeadingLevel) -> String {
    match level {
        HeadingLevel::H1 | HeadingLevel::H2 => "▌ ".to_owned(),
        HeadingLevel::H3 => "› ".to_owned(),
        _ => "· ".to_owned(),
    }
}

fn quote_marker(kind: Option<BlockQuoteKind>) -> &'static str {
    match kind {
        Some(BlockQuoteKind::Note) => "NOTE │ ",
        Some(BlockQuoteKind::Tip) => "TIP │ ",
        Some(BlockQuoteKind::Important) => "IMPORTANT │ ",
        Some(BlockQuoteKind::Warning) => "WARNING │ ",
        Some(BlockQuoteKind::Caution) => "CAUTION │ ",
        None => "│ ",
    }
}

struct MarkdownLayout {
    width: usize,
    limit: usize,
    used_rows: usize,
    lines: Vec<StyledLine>,
    images: Vec<BodyImage>,
    omitted_items: usize,
    compacted: bool,
    source_lines: usize,
    has_content: bool,
    last_blank: bool,
}

impl MarkdownLayout {
    fn new(width: usize, limit: usize, source_lines: usize) -> Self {
        Self {
            width,
            limit,
            used_rows: 0,
            lines: Vec::new(),
            images: Vec::new(),
            omitted_items: 0,
            compacted: false,
            source_lines,
            has_content: false,
            last_blank: false,
        }
    }

    fn separate(&mut self) {
        if self.has_content && !self.last_blank {
            self.push_line(String::new(), LineStyle::Normal);
        }
    }

    fn push_wrapped(&mut self, text: &str, prefix: &str, style: LineStyle) {
        self.push_wrapped_spans(
            &[StyledSpan::new(text, SpanStyle::new(style))],
            prefix,
            style,
        );
    }

    fn push_wrapped_spans(&mut self, spans: &[StyledSpan], prefix: &str, style: LineStyle) {
        let prefix_width = UnicodeWidthStr::width(prefix);
        let content_width = self.width.saturating_sub(prefix_width).max(1);
        let mut first = true;
        for wrapped in wrap_spans(spans, content_width) {
            let line_prefix = if first {
                prefix.to_owned()
            } else {
                " ".repeat(prefix_width)
            };
            let mut line = Vec::new();
            append_span(&mut line, &line_prefix, SpanStyle::new(style));
            for span in wrapped {
                append_span(&mut line, &span.text, span.style);
            }
            self.push_styled_line(line, style);
            first = false;
        }
    }

    fn push_line(&mut self, text: String, style: LineStyle) {
        self.push_styled_line(vec![StyledSpan::new(text, SpanStyle::new(style))], style);
    }

    fn push_styled_line(&mut self, spans: Vec<StyledSpan>, style: LineStyle) {
        let text = plain_text(&spans);
        let fitted = truncate_display(&text, self.width);
        if fitted != text {
            self.omit(1);
        }
        if self.used_rows < self.limit {
            self.last_blank = fitted.is_empty();
            self.lines.push(StyledLine { style, spans });
            self.used_rows += 1;
            self.has_content = true;
        } else {
            self.omit(1);
        }
    }

    fn push_image(
        &mut self,
        alt: String,
        bytes: Vec<u8>,
        desired_columns: usize,
        desired_rows: usize,
    ) {
        let remaining = self.limit.saturating_sub(self.used_rows);
        if remaining < MIN_IMAGE_ROWS {
            self.omit(desired_rows);
            return;
        }
        let rows = desired_rows.min(remaining);
        let columns = desired_columns
            .saturating_mul(rows)
            .saturating_div(desired_rows)
            .max(1);
        self.images.push(BodyImage {
            after_line: self.lines.len(),
            columns,
            rows,
            alt,
            bytes,
        });
        self.used_rows += rows;
        self.has_content = true;
        self.last_blank = false;
    }

    fn omit(&mut self, count: usize) {
        if count > 0 {
            self.omitted_items = self.omitted_items.saturating_add(count);
            self.compacted = true;
        }
    }

    const fn remaining_rows(&self) -> usize {
        self.limit.saturating_sub(self.used_rows)
    }

    fn finish(self) -> BodyRender {
        BodyRender {
            lines: self.lines,
            compacted: self.compacted,
            omitted_items: self.omitted_items,
            source_lines: self.source_lines,
            images: self.images,
        }
    }
}

fn wrap_spans(spans: &[StyledSpan], width: usize) -> Vec<Vec<StyledSpan>> {
    let mut lines = Vec::new();
    let mut line = Vec::new();
    let mut line_width = 0;
    for span in spans {
        for character in span.text.chars() {
            if character == '\n' {
                trim_spans(&mut line);
                lines.push(std::mem::take(&mut line));
                line_width = 0;
                continue;
            }
            let character_width = UnicodeWidthChar::width(character).unwrap_or(0);
            if line_width > 0 && line_width + character_width > width {
                trim_spans(&mut line);
                lines.push(std::mem::take(&mut line));
                line_width = 0;
            }
            append_span(&mut line, &character.to_string(), span.style);
            line_width += character_width;
        }
    }
    trim_spans(&mut line);
    if !line.is_empty() || lines.is_empty() {
        lines.push(line);
    }
    lines
}

fn should_skip_duplicate_title(
    block: &MarkdownBlock,
    manifest: &ArtifactManifest,
    first_visible: bool,
) -> bool {
    first_visible
        && matches!(
            block,
            MarkdownBlock::Text {
                text,
                style: LineStyle::Heading,
                ..
            } if text.trim() == manifest.title.trim()
        )
}

fn render_block(
    layout: &mut MarkdownLayout,
    manifest: &ArtifactManifest,
    block: MarkdownBlock,
) -> Result<()> {
    match block {
        MarkdownBlock::Text {
            spans,
            prefix,
            style,
            ..
        } => layout.push_wrapped_spans(&spans, &prefix, style),
        MarkdownBlock::Code { language, source } => render_code(layout, &language, &source),
        MarkdownBlock::Table { headers, rows } => render_table(layout, headers, &rows),
        MarkdownBlock::Image { alt, destination } => {
            render_image(layout, manifest, &alt, &destination)?
        }
        MarkdownBlock::Rule => layout.push_line("─".repeat(layout.width), LineStyle::Muted),
    }
    Ok(())
}

fn render_code(layout: &mut MarkdownLayout, language: &str, source: &str) {
    let label = if language.is_empty() {
        "code"
    } else {
        language
    };
    layout.push_line(format!("┌─ {label}"), LineStyle::Muted);
    let lines = code_lines(source);
    let shown = lines.len().min(layout.remaining_rows().saturating_sub(1));
    layout.omit(lines.len().saturating_sub(shown));
    let visible = lines
        .iter()
        .take(shown)
        .map(|line| bounded_code_line(line))
        .collect::<Vec<_>>();
    let highlighted = highlight_code(language, &visible);
    for (index, line) in visible.iter().enumerate() {
        let mut spans = vec![StyledSpan::new("│ ", SpanStyle::new(LineStyle::Muted))];
        if let Some(highlighted) = highlighted.as_ref() {
            for span in &highlighted[index] {
                append_span(&mut spans, &span.text, span.style);
            }
        } else {
            append_span(
                &mut spans,
                line,
                SpanStyle::new(if language.is_empty() {
                    LineStyle::Normal
                } else {
                    LineStyle::Accent
                }),
            );
        }
        layout.push_styled_line(spans, LineStyle::Normal);
    }
    layout.push_line("└─".to_owned(), LineStyle::Muted);
}

static CODE_SYNTAXES: LazyLock<SyntaxSet> = LazyLock::new(SyntaxSet::load_defaults_newlines);
static CODE_THEME: LazyLock<Theme> = LazyLock::new(|| {
    ThemeSet::load_defaults()
        .themes
        .get("base16-ocean.dark")
        .expect("syntect must include base16-ocean.dark")
        .clone()
});

fn code_lines(source: &str) -> Vec<&str> {
    let source = source.trim_end_matches(['\r', '\n']);
    if source.is_empty() {
        vec![""]
    } else {
        source
            .split('\n')
            .map(|line| line.trim_end_matches('\r'))
            .collect()
    }
}

fn bounded_code_line(line: &str) -> String {
    if line.len() <= MAX_HIGHLIGHT_LINE_BYTES {
        return line.to_owned();
    }
    let mut end = MAX_HIGHLIGHT_LINE_BYTES;
    while !line.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &line[..end])
}

fn highlight_code(language: &str, lines: &[String]) -> Option<Vec<Vec<StyledSpan>>> {
    let syntax = code_syntax(language)?;
    let mut highlighter = HighlightLines::new(syntax, &CODE_THEME);
    let mut output = Vec::with_capacity(lines.len());
    for line in lines {
        let line_with_ending = format!("{line}\n");
        let regions = highlighter
            .highlight_line(&line_with_ending, &CODE_SYNTAXES)
            .ok()?;
        let mut highlighted = Vec::new();
        for (style, value) in regions {
            let value = value.trim_end_matches(['\r', '\n']);
            append_span(&mut highlighted, value, syntax_span_style(style));
        }
        output.push(highlighted);
    }
    Some(output)
}

fn code_syntax(language: &str) -> Option<&'static SyntaxReference> {
    let token = language
        .trim()
        .trim_matches(['{', '}', '.'])
        .to_ascii_lowercase();
    if token.is_empty() || matches!(token.as_str(), "text" | "plain" | "plaintext" | "log") {
        return None;
    }
    let alias = match token.as_str() {
        "shell" | "bash" | "zsh" => "sh",
        "javascript" => "js",
        "typescript" => "ts",
        "python" => "py",
        "ruby" => "rb",
        "golang" => "go",
        "c++" => "cpp",
        "objective-c" => "m",
        "markdown" => "md",
        "yml" => "yaml",
        other => other,
    };
    CODE_SYNTAXES
        .find_syntax_by_token(alias)
        .or_else(|| CODE_SYNTAXES.find_syntax_by_extension(alias))
        .or_else(|| {
            CODE_SYNTAXES
                .syntaxes()
                .iter()
                .find(|syntax| syntax.name.eq_ignore_ascii_case(language))
        })
}

fn syntax_span_style(style: SyntaxStyle) -> SpanStyle {
    SpanStyle {
        base: LineStyle::Normal,
        foreground: Some(RgbColor {
            red: style.foreground.r,
            green: style.foreground.g,
            blue: style.foreground.b,
        }),
        background: None,
        bold: style.font_style.contains(FontStyle::BOLD),
        italic: style.font_style.contains(FontStyle::ITALIC),
        underline: style.font_style.contains(FontStyle::UNDERLINE),
        strikethrough: false,
    }
}

fn render_table(layout: &mut MarkdownLayout, mut headers: Vec<String>, rows: &[Vec<String>]) {
    if headers.is_empty() {
        headers.push("value".to_owned());
    }
    let shown = table_column_limit(layout.width, headers.len());
    layout.omit(headers.len().saturating_sub(shown));
    headers.truncate(shown);
    let widths = table_widths(layout.width, headers.len());
    count_table_truncation(layout, &headers, rows, &widths);
    layout.push_line(table_border('┌', '┬', '┐', &widths), LineStyle::Muted);
    layout.push_line(table_row(&headers, &widths), LineStyle::Heading);
    layout.push_line(table_border('├', '┼', '┤', &widths), LineStyle::Muted);
    for row in rows {
        layout.push_line(table_row(row, &widths), LineStyle::Normal);
    }
    layout.push_line(table_border('└', '┴', '┘', &widths), LineStyle::Muted);
}

fn count_table_truncation(
    layout: &mut MarkdownLayout,
    headers: &[String],
    rows: &[Vec<String>],
    widths: &[usize],
) {
    let truncated_headers = headers
        .iter()
        .zip(widths)
        .filter(|(value, width)| UnicodeWidthStr::width(value.as_str()) > **width)
        .count();
    let truncated_rows = rows
        .iter()
        .flat_map(|row| row.iter().zip(widths))
        .filter(|(value, width)| UnicodeWidthStr::width(value.as_str()) > **width)
        .count();
    layout.omit(truncated_headers + truncated_rows);
}

fn render_image(
    layout: &mut MarkdownLayout,
    manifest: &ArtifactManifest,
    alt: &str,
    destination: &str,
) -> Result<()> {
    let caption = if alt.is_empty() { "Image" } else { alt };
    let Some(relative) = safe_local_png_destination(destination) else {
        layout.push_wrapped(
            &format!("Image: {caption} (remote or non-PNG source not fetched)"),
            "▧ ",
            LineStyle::Warning,
        );
        return Ok(());
    };
    let parent = Path::new(&manifest.document)
        .parent()
        .ok_or_else(|| anyhow!("artifact document has no parent directory"))?
        .canonicalize()?;
    let path = resolve_source_asset(&parent, &relative)?;
    validate_png(&path)?;
    let bytes = read_bounded_source(&path, MAX_IMAGE_BYTES, "Markdown image")?;
    let (columns, rows) = image_geometry(&bytes, layout.width)?;
    layout.push_wrapped(caption, "▧ ", LineStyle::Muted);
    layout.push_image(caption.to_owned(), bytes, columns, rows);
    Ok(())
}

fn image_geometry(bytes: &[u8], available_columns: usize) -> Result<(usize, usize)> {
    let mut decoder = png::Decoder::new(Cursor::new(bytes));
    let info = decoder
        .read_header_info()
        .context("decode Markdown PNG header")?;
    if info.width == 0 || info.height == 0 {
        return Ok((available_columns.min(MIN_IMAGE_ROWS * 2), MIN_IMAGE_ROWS));
    }
    let rows = u64::try_from(available_columns)
        .unwrap_or(u64::MAX)
        .saturating_mul(u64::from(info.height))
        .saturating_div(u64::from(info.width).saturating_mul(2))
        .try_into()
        .unwrap_or(MAX_IMAGE_ROWS);
    let rows = rows.clamp(MIN_IMAGE_ROWS, MAX_IMAGE_ROWS);
    let columns = u64::try_from(rows)
        .unwrap_or(u64::MAX)
        .saturating_mul(u64::from(info.width))
        .saturating_mul(2)
        .saturating_div(u64::from(info.height))
        .try_into()
        .unwrap_or(available_columns)
        .clamp(1, available_columns);
    Ok((columns, rows))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parser_recognizes_rich_blocks() {
        let blocks = parse_blocks(
            "# Report\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```rust\nfn main() {}\n```\n",
        );

        assert!(
            blocks
                .iter()
                .any(|block| matches!(block, MarkdownBlock::Table { .. }))
        );
        assert!(blocks.iter().any(
            |block| matches!(block, MarkdownBlock::Code { language, .. } if language == "rust")
        ));
    }

    #[test]
    fn parser_preserves_inline_emphasis_spans() {
        let blocks =
            parse_blocks("plain **bold** *italic* ~~gone~~ and `code` plus ``a ` backtick``");
        let MarkdownBlock::Text { spans, .. } = &blocks[0] else {
            panic!("expected text block");
        };

        assert!(
            spans
                .iter()
                .any(|span| span.text == "bold" && span.style.bold)
        );
        assert!(
            spans
                .iter()
                .any(|span| span.text == "italic" && span.style.italic)
        );
        assert!(
            spans
                .iter()
                .any(|span| span.text == "gone" && span.style.strikethrough)
        );
        assert!(spans.iter().any(|span| {
            span.text == "code"
                && span.style.base == LineStyle::Accent
                && span.style.background.is_some()
        }));
        assert!(spans.iter().any(|span| {
            span.text == "a ` backtick"
                && span.style.base == LineStyle::Accent
                && span.style.background.is_some()
        }));
    }

    #[test]
    fn rust_code_uses_multiple_syntax_styles() {
        let lines = vec!["let answer = \"yes\";".to_owned()];
        let highlighted = highlight_code("rust", &lines).expect("Rust syntax is bundled");
        let colors = highlighted[0]
            .iter()
            .filter_map(|span| span.style.foreground)
            .collect::<BTreeSet<_>>();

        assert!(colors.len() >= 2);
    }

    #[test]
    fn fenced_code_highlighting_obeys_the_row_budget() {
        let mut layout = MarkdownLayout::new(20, 4, 10);
        render_code(
            &mut layout,
            "rust",
            "let a = 1;\nlet b = 2;\nlet c = 3;\nlet d = 4;\n",
        );
        let body = layout.finish();

        assert_eq!(body.lines.len(), 4);
        assert_eq!(body.omitted_items, 2);
    }

    #[test]
    fn syntax_input_is_bounded_without_splitting_utf8() {
        let line = "日".repeat(MAX_HIGHLIGHT_LINE_BYTES);
        let bounded = bounded_code_line(&line);

        assert!(bounded.is_char_boundary(bounded.len()));
        assert!(bounded.ends_with('…'));
        assert!(bounded.len() <= MAX_HIGHLIGHT_LINE_BYTES + '…'.len_utf8());
    }

    #[test]
    fn unsafe_or_remote_images_are_not_snapshotted() {
        assert!(safe_local_png_destination("../secret.png").is_none());
        assert!(safe_local_png_destination("https://example.test/a.png").is_none());
        assert_eq!(
            safe_local_png_destination("images/chart.png"),
            Some(PathBuf::from("images/chart.png"))
        );
    }
}
