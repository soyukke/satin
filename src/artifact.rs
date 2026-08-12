use std::{
    env,
    fs::{self, File, OpenOptions},
    io::{self, BufReader, Read, Write},
    os::{
        fd::AsRawFd,
        unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    str::FromStr,
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

mod markdown;

pub const DEFAULT_MAX_COLUMNS: u16 = 80;
pub const DEFAULT_MAX_ROWS: u16 = 32;
const MIN_MAX_COLUMNS: u16 = 40;
const MIN_MAX_ROWS: u16 = 12;
const MAX_MAX_COLUMNS: u16 = 240;
const MAX_MAX_ROWS: u16 = 120;
const MAX_VIEW_COLUMNS: u16 = 512;
const MAX_VIEW_ROWS: u16 = 240;
const STORE_VERSION: u32 = 1;
const MAX_TEXT_BYTES: u64 = 8 * 1024 * 1024;
const MAX_IMAGE_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactKind {
    Text,
    Markdown,
    Table,
    Tree,
    Timeline,
    Diff,
    Image,
}

impl ArtifactKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Markdown => "markdown",
            Self::Table => "table",
            Self::Tree => "tree",
            Self::Timeline => "timeline",
            Self::Diff => "diff",
            Self::Image => "image",
        }
    }
}

impl FromStr for ArtifactKind {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        match value.to_ascii_lowercase().as_str() {
            "text" => Ok(Self::Text),
            "markdown" | "md" => Ok(Self::Markdown),
            "table" => Ok(Self::Table),
            "tree" => Ok(Self::Tree),
            "timeline" => Ok(Self::Timeline),
            "diff" | "patch" => Ok(Self::Diff),
            "image" | "png" => Ok(Self::Image),
            _ => bail!("unsupported artifact kind {value:?}"),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactOverflow {
    #[default]
    Compact,
    Defer,
    Reject,
}

impl FromStr for ArtifactOverflow {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        match value.to_ascii_lowercase().as_str() {
            "compact" => Ok(Self::Compact),
            "defer" => Ok(Self::Defer),
            "reject" => Ok(Self::Reject),
            _ => bail!("overflow must be compact, defer, or reject"),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(default)]
pub struct ArtifactPolicy {
    pub max_columns: u16,
    pub max_rows: u16,
    pub language: String,
    pub overflow: ArtifactOverflow,
}

impl Default for ArtifactPolicy {
    fn default() -> Self {
        Self {
            max_columns: DEFAULT_MAX_COLUMNS,
            max_rows: DEFAULT_MAX_ROWS,
            language: "auto".to_owned(),
            overflow: ArtifactOverflow::Compact,
        }
    }
}

impl ArtifactPolicy {
    pub fn validate(&self) -> Result<()> {
        if !(MIN_MAX_COLUMNS..=MAX_MAX_COLUMNS).contains(&self.max_columns) {
            bail!("max columns must be between {MIN_MAX_COLUMNS} and {MAX_MAX_COLUMNS}");
        }
        if !(MIN_MAX_ROWS..=MAX_MAX_ROWS).contains(&self.max_rows) {
            bail!("max rows must be between {MIN_MAX_ROWS} and {MAX_MAX_ROWS}");
        }
        validate_language(&self.language)
    }

    pub fn resolved_language(&self) -> String {
        if self.language != "auto" {
            return self.language.clone();
        }
        ["LC_ALL", "LC_MESSAGES", "LANG"]
            .iter()
            .find_map(|key| env::var(key).ok())
            .and_then(|locale| normalize_locale(&locale))
            .unwrap_or_else(|| "en-US".to_owned())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactPreviewStatus {
    Ready,
    Compacted,
    Deferred,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ArtifactPreviewSummary {
    pub status: ArtifactPreviewStatus,
    pub source_lines: usize,
    pub omitted_items: usize,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ArtifactManifest {
    pub format_version: u32,
    pub id: String,
    pub version: u32,
    pub kind: ArtifactKind,
    pub title: String,
    pub language: String,
    pub document: String,
    pub source: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub assets: Vec<String>,
    pub origin: String,
    pub source_bytes: u64,
    pub created_at_ms: u64,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner_tab: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner_pane: Option<usize>,
    pub preview: ArtifactPreviewSummary,
}

pub struct RegisterArtifact<'a> {
    pub id: Option<&'a str>,
    pub kind: ArtifactKind,
    pub title: &'a str,
    pub language: Option<&'a str>,
    pub source: &'a Path,
    pub owner_tab: Option<usize>,
    pub owner_pane: Option<usize>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ArtifactListItem {
    pub id: String,
    pub title: String,
    pub kind: ArtifactKind,
    pub language: String,
    pub version: u32,
    pub version_count: usize,
    pub updated_at_ms: u64,
    pub updated_at: String,
    pub preview: String,
    pub directory: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
struct StoredArtifactVersion {
    version: u32,
    created_at_ms: u64,
    document: String,
    source: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    assets: Vec<String>,
    origin: String,
    source_bytes: u64,
    preview: ArtifactPreviewSummary,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
struct StoredArtifact {
    format_version: u32,
    id: String,
    slug: String,
    title: String,
    kind: ArtifactKind,
    language: String,
    created_at_ms: u64,
    updated_at_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    owner_tab: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    owner_pane: Option<usize>,
    versions: Vec<StoredArtifactVersion>,
}

struct ArtifactSource {
    canonical_path: PathBuf,
    bytes: Vec<u8>,
    document: String,
    source_name: String,
    assets: Vec<ArtifactAsset>,
}

struct ArtifactAsset {
    relative_path: PathBuf,
    bytes: Vec<u8>,
}

#[derive(Clone, Debug)]
pub struct RenderedArtifact {
    pub ansi: String,
    pub plain_lines: Vec<String>,
    pub compacted: bool,
    pub omitted_items: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LineStyle {
    Normal,
    Heading,
    Muted,
    Accent,
    Added,
    Removed,
    Warning,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct RgbColor {
    red: u8,
    green: u8,
    blue: u8,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SpanStyle {
    base: LineStyle,
    foreground: Option<RgbColor>,
    background: Option<RgbColor>,
    bold: bool,
    italic: bool,
    underline: bool,
    strikethrough: bool,
}

impl SpanStyle {
    const fn new(base: LineStyle) -> Self {
        Self {
            base,
            foreground: None,
            background: None,
            bold: false,
            italic: false,
            underline: false,
            strikethrough: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct StyledSpan {
    text: String,
    style: SpanStyle,
}

impl StyledSpan {
    fn new(text: impl Into<String>, style: SpanStyle) -> Self {
        Self {
            text: text.into(),
            style,
        }
    }
}

#[derive(Clone, Debug)]
struct StyledLine {
    style: LineStyle,
    spans: Vec<StyledSpan>,
}

impl StyledLine {
    fn plain(text: impl Into<String>, style: LineStyle) -> Self {
        let text = text.into();
        Self {
            spans: vec![StyledSpan::new(text, SpanStyle::new(style))],
            style,
        }
    }
}

struct BodyRender {
    lines: Vec<StyledLine>,
    compacted: bool,
    omitted_items: usize,
    source_lines: usize,
    images: Vec<BodyImage>,
}

struct BodyImage {
    after_line: usize,
    columns: usize,
    rows: usize,
    alt: String,
    bytes: Vec<u8>,
}

pub fn load_policy(socket: &Path) -> Result<ArtifactPolicy> {
    let path = policy_path(socket)?;
    let file = match File::open(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(ArtifactPolicy::default());
        }
        Err(error) => {
            return Err(error).with_context(|| format!("open artifact policy {}", path.display()));
        }
    };
    let policy: ArtifactPolicy = serde_json::from_reader(BufReader::new(file))
        .with_context(|| format!("decode artifact policy {}", path.display()))?;
    policy.validate()?;
    Ok(policy)
}

pub fn save_policy(socket: &Path, policy: &ArtifactPolicy) -> Result<PathBuf> {
    policy.validate()?;
    let path = policy_path(socket)?;
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("artifact policy path has no parent"))?;
    ensure_owner_only_directory(parent)?;
    write_json_atomically(&path, policy)?;
    Ok(path)
}

pub fn register_artifact(
    socket: &Path,
    policy: &ArtifactPolicy,
    request: RegisterArtifact<'_>,
) -> Result<ArtifactManifest> {
    policy.validate()?;
    validate_title(request.title)?;
    let language = request
        .language
        .map(str::to_owned)
        .unwrap_or_else(|| policy.resolved_language());
    validate_language(&language)?;
    let prepared = prepare_artifact_source(request.kind, request.title, request.source)?;
    let created_at_ms = unix_time_ms();
    let mut preview_manifest = registration_preview(
        policy,
        &request,
        &prepared,
        request.id.unwrap_or("preview"),
        1,
        &language,
        created_at_ms,
    )?;
    let _store_lock = lock_artifact_store(socket)?;
    let (id, stored) = registration_target(socket, request.id, request.kind)?;
    let next_version = stored
        .as_ref()
        .and_then(|artifact| artifact.versions.last())
        .map_or(1, |version| version.version.saturating_add(1));
    preview_manifest.id.clone_from(&id);
    preview_manifest.version = next_version;
    if let Some(existing) = stored.as_ref()
        && stored_artifact_matches(socket, existing, request.title, &language, &prepared)?
    {
        return manifest_from_stored(socket, existing, None);
    }
    let directory = registration_directory(socket, stored.as_ref(), &id, request.title)?;
    let stored_version = store_artifact_version(
        &directory,
        next_version,
        created_at_ms,
        &prepared,
        &preview_manifest,
    )?;
    let artifact = updated_stored_artifact(
        stored,
        &request,
        id,
        language,
        created_at_ms,
        stored_version,
    );
    write_json_atomically(&directory.join("metadata.json"), &artifact)?;
    write_marker(socket, &artifact.id, &directory)?;
    write_artifact_documents(&directory, &artifact)?;
    write_artifact_index(socket)?;
    manifest_from_stored(socket, &artifact, None)
}

fn registration_target(
    socket: &Path,
    requested_id: Option<&str>,
    kind: ArtifactKind,
) -> Result<(String, Option<StoredArtifact>)> {
    let Some(id) = requested_id else {
        return Ok((new_artifact_id(socket)?, None));
    };
    validate_artifact_id(id)?;
    let stored = load_stored_artifact(socket, id)?;
    if stored.kind != kind {
        bail!("an artifact version cannot change its kind");
    }
    Ok((id.to_owned(), Some(stored)))
}

fn registration_preview(
    policy: &ArtifactPolicy,
    request: &RegisterArtifact<'_>,
    prepared: &ArtifactSource,
    id: &str,
    version: u32,
    language: &str,
    created_at_ms: u64,
) -> Result<ArtifactManifest> {
    let source = prepared.canonical_path.to_string_lossy().into_owned();
    let mut manifest = ArtifactManifest {
        format_version: STORE_VERSION,
        id: id.to_owned(),
        version,
        kind: request.kind,
        title: request.title.to_owned(),
        language: language.to_owned(),
        document: source.clone(),
        source: source.clone(),
        assets: Vec::new(),
        origin: source,
        source_bytes: prepared.bytes.len().try_into().unwrap_or(u64::MAX),
        created_at_ms,
        created_at: format_timestamp(created_at_ms),
        owner_tab: request.owner_tab,
        owner_pane: request.owner_pane,
        preview: ArtifactPreviewSummary {
            status: ArtifactPreviewStatus::Ready,
            source_lines: 0,
            omitted_items: 0,
        },
    };
    let body = render_body(&manifest, policy, policy.max_columns, policy.max_rows)?;
    manifest.preview = preview_summary(policy.overflow, &body)?;
    Ok(manifest)
}

fn registration_directory(
    socket: &Path,
    stored: Option<&StoredArtifact>,
    id: &str,
    title: &str,
) -> Result<PathBuf> {
    if let Some(stored) = stored {
        return resolve_artifact_directory(socket, &stored.id);
    }
    let root = artifact_root(socket)?;
    ensure_owner_only_directory(&root)?;
    let directory = root.join(format!("{}--{id}", artifact_slug(title)));
    ensure_owner_only_directory(&directory)?;
    Ok(directory)
}

fn store_artifact_version(
    directory: &Path,
    version: u32,
    created_at_ms: u64,
    prepared: &ArtifactSource,
    preview: &ArtifactManifest,
) -> Result<StoredArtifactVersion> {
    let versions_directory = directory.join("versions");
    ensure_owner_only_directory(&versions_directory)?;
    let version_directory = versions_directory.join(format!("v{version:03}"));
    create_owner_only_directory(&version_directory)
        .with_context(|| format!("create artifact version {version}"))?;
    let document_path = version_directory.join("artifact.md");
    write_bytes_atomically(&document_path, prepared.document.as_bytes())?;
    let source_path = if prepared.source_name == "artifact.md" {
        document_path.clone()
    } else {
        let path = version_directory.join(&prepared.source_name);
        write_bytes_atomically(&path, &prepared.bytes)?;
        path
    };
    let mut assets = Vec::with_capacity(prepared.assets.len());
    for asset in &prepared.assets {
        let path = version_directory.join(&asset.relative_path);
        write_bytes_atomically(&path, &asset.bytes)?;
        assets.push(relative_artifact_path(directory, &path)?);
    }
    Ok(StoredArtifactVersion {
        version,
        created_at_ms,
        document: relative_artifact_path(directory, &document_path)?,
        source: relative_artifact_path(directory, &source_path)?,
        assets,
        origin: prepared.canonical_path.to_string_lossy().into_owned(),
        source_bytes: preview.source_bytes,
        preview: preview.preview.clone(),
    })
}

fn updated_stored_artifact(
    stored: Option<StoredArtifact>,
    request: &RegisterArtifact<'_>,
    id: String,
    language: String,
    created_at_ms: u64,
    version: StoredArtifactVersion,
) -> StoredArtifact {
    let mut artifact = stored.unwrap_or_else(|| StoredArtifact {
        format_version: STORE_VERSION,
        id,
        slug: artifact_slug(request.title),
        title: request.title.to_owned(),
        kind: request.kind,
        language: language.clone(),
        created_at_ms,
        updated_at_ms: created_at_ms,
        owner_tab: request.owner_tab,
        owner_pane: request.owner_pane,
        versions: Vec::new(),
    });
    artifact.title = request.title.to_owned();
    artifact.language = language;
    artifact.updated_at_ms = created_at_ms;
    artifact.owner_tab = request.owner_tab.or(artifact.owner_tab);
    artifact.owner_pane = request.owner_pane.or(artifact.owner_pane);
    artifact.versions.push(version);
    artifact
}

pub fn load_manifest(socket: &Path, selector: &str) -> Result<ArtifactManifest> {
    let (id, version) = parse_artifact_selector(selector)?;
    let stored = load_stored_artifact(socket, &id)?;
    manifest_from_stored(socket, &stored, version)
}

pub fn list_artifacts(socket: &Path, limit: Option<usize>) -> Result<Vec<ArtifactListItem>> {
    let root = artifact_root(socket)?;
    let entries = match fs::read_dir(&root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(error).with_context(|| format!("open artifact store {}", root.display()));
        }
    };
    let mut artifacts = Vec::new();
    for entry in entries {
        let entry = entry?;
        if !entry.file_type()?.is_dir() || entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let metadata_path = entry.path().join("metadata.json");
        let file = match File::open(&metadata_path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("open artifact metadata {}", metadata_path.display())
                });
            }
        };
        let stored: StoredArtifact = serde_json::from_reader(BufReader::new(file))
            .with_context(|| format!("decode artifact metadata {}", metadata_path.display()))?;
        validate_stored_artifact(&stored)?;
        let Some(latest) = stored.versions.last() else {
            continue;
        };
        let document = entry.path().join(&latest.document);
        artifacts.push(ArtifactListItem {
            id: stored.id,
            title: stored.title,
            kind: stored.kind,
            language: stored.language,
            version: latest.version,
            version_count: stored.versions.len(),
            updated_at_ms: stored.updated_at_ms,
            updated_at: format_timestamp(stored.updated_at_ms),
            preview: artifact_document_preview(&document)?,
            directory: entry.path().to_string_lossy().into_owned(),
        });
    }
    artifacts.sort_by(|left, right| {
        right
            .updated_at_ms
            .cmp(&left.updated_at_ms)
            .then_with(|| left.title.cmp(&right.title))
    });
    artifacts.truncate(limit.unwrap_or(usize::MAX));
    Ok(artifacts)
}

pub fn render_artifact(
    manifest: &ArtifactManifest,
    policy: &ArtifactPolicy,
    terminal_columns: Option<u16>,
    terminal_rows: Option<u16>,
) -> Result<RenderedArtifact> {
    let columns = terminal_columns
        .map(|columns| columns.min(MAX_VIEW_COLUMNS))
        .unwrap_or(policy.max_columns);
    let rows = terminal_rows
        .map(|rows| rows.min(MAX_VIEW_ROWS))
        .unwrap_or(policy.max_rows);
    if columns < 20 || rows < 8 {
        bail!("artifact pane requires at least 20 columns and 8 rows");
    }
    let body = if policy.overflow == ArtifactOverflow::Defer {
        deferred_body(manifest)
    } else {
        render_body(manifest, policy, columns, rows)?
    };
    Ok(render_document(manifest, columns, rows, body))
}

pub fn view_artifact(socket: &Path, id: &str, wait: bool) -> Result<()> {
    let policy = load_policy(socket)?;
    let manifest = load_manifest(socket, id)?;
    let (columns, rows) = terminal_size();
    let rendered = render_artifact(&manifest, &policy, columns, rows)?;
    let interactive = wait && stdin_is_terminal() && stdout_is_terminal();
    let _terminal = interactive.then(TerminalPresentation::enter).transpose()?;
    let mut stdout = io::stdout().lock();
    if interactive {
        stdout.write_all(b"\x1b[2J\x1b[H\x1b[?25l")?;
    }
    stdout.write_all(rendered.ansi.as_bytes())?;
    stdout.flush()?;
    drop(stdout);
    if interactive {
        wait_until_closed()?;
    }
    Ok(())
}

fn preview_summary(
    overflow: ArtifactOverflow,
    body: &BodyRender,
) -> Result<ArtifactPreviewSummary> {
    if overflow == ArtifactOverflow::Reject && body.compacted {
        bail!(
            "artifact preview exceeds the configured bounds; change the source or overflow policy"
        );
    }
    let status = match overflow {
        ArtifactOverflow::Defer => ArtifactPreviewStatus::Deferred,
        _ if body.compacted => ArtifactPreviewStatus::Compacted,
        _ => ArtifactPreviewStatus::Ready,
    };
    Ok(ArtifactPreviewSummary {
        status,
        source_lines: body.source_lines,
        omitted_items: body.omitted_items,
    })
}

fn render_body(
    manifest: &ArtifactManifest,
    policy: &ArtifactPolicy,
    columns: u16,
    rows: u16,
) -> Result<BodyRender> {
    let inner_width = usize::from(columns).max(1);
    let body_rows = usize::from(rows.saturating_sub(3)).max(1);
    match manifest.kind {
        ArtifactKind::Image => render_image_body(manifest),
        ArtifactKind::Table => render_table_body(manifest, inner_width, body_rows),
        ArtifactKind::Diff => render_diff_body(manifest, inner_width, body_rows),
        ArtifactKind::Markdown => markdown::render_markdown_body(manifest, inner_width, body_rows),
        ArtifactKind::Text => render_text_body(manifest, inner_width, body_rows),
        ArtifactKind::Tree | ArtifactKind::Timeline => {
            render_list_body(manifest, inner_width, body_rows, policy)
        }
    }
}

fn render_text_body(manifest: &ArtifactManifest, width: usize, limit: usize) -> Result<BodyRender> {
    let content = read_text_source(manifest)?;
    let source_lines = content.lines().count();
    let mut all = Vec::new();
    for source_line in content.lines() {
        let trimmed = source_line.trim_end();
        let wrapped = wrap_display(trimmed, width);
        all.extend(
            wrapped
                .into_iter()
                .map(|text| StyledLine::plain(text, LineStyle::Normal)),
        );
    }
    let omitted_items = all.len().saturating_sub(limit);
    all.truncate(limit);
    Ok(BodyRender {
        lines: all,
        compacted: omitted_items > 0,
        omitted_items,
        source_lines,
        images: Vec::new(),
    })
}

fn render_diff_body(manifest: &ArtifactManifest, width: usize, limit: usize) -> Result<BodyRender> {
    let content = read_text_source(manifest)?;
    let source_lines = content.lines().count();
    let mut compacted = false;
    let mut truncated_items = 0;
    let mut lines = content
        .lines()
        .take(limit)
        .map(|line| {
            let text = truncate_display(line, width);
            if text != line {
                compacted = true;
                truncated_items += 1;
            }
            let style = if line.starts_with('+') && !line.starts_with("+++") {
                LineStyle::Added
            } else if line.starts_with('-') && !line.starts_with("---") {
                LineStyle::Removed
            } else if line.starts_with("@@") {
                LineStyle::Accent
            } else if line.starts_with("diff ") || line.starts_with("index ") {
                LineStyle::Heading
            } else {
                LineStyle::Normal
            };
            StyledLine::plain(text, style)
        })
        .collect::<Vec<_>>();
    let omitted_items = source_lines.saturating_sub(lines.len()) + truncated_items;
    compacted |= omitted_items > 0;
    lines.truncate(limit);
    Ok(BodyRender {
        lines,
        compacted,
        omitted_items,
        source_lines,
        images: Vec::new(),
    })
}

fn render_list_body(
    manifest: &ArtifactManifest,
    width: usize,
    limit: usize,
    _policy: &ArtifactPolicy,
) -> Result<BodyRender> {
    let content = read_text_source(manifest)?;
    let source_lines = content.lines().count();
    let prefix = if manifest.kind == ArtifactKind::Timeline {
        "● "
    } else {
        ""
    };
    let mut all = Vec::new();
    for line in content.lines() {
        for wrapped in wrap_display(&format!("{prefix}{}", line.trim_end()), width) {
            all.push(StyledLine::plain(wrapped, LineStyle::Normal));
        }
    }
    let omitted_items = all.len().saturating_sub(limit);
    all.truncate(limit);
    Ok(BodyRender {
        lines: all,
        compacted: omitted_items > 0,
        omitted_items,
        source_lines,
        images: Vec::new(),
    })
}

fn render_table_body(
    manifest: &ArtifactManifest,
    width: usize,
    limit: usize,
) -> Result<BodyRender> {
    let content = read_text_source(manifest)?;
    let source_lines = content.lines().count();
    let (mut headers, rows) = parse_table(&content, Path::new(&manifest.source))?;
    if headers.is_empty() {
        headers.push("value".to_owned());
    }
    let max_columns = table_column_limit(width, headers.len());
    let omitted_columns = headers.len().saturating_sub(max_columns);
    headers.truncate(max_columns);
    let table_chrome = 3;
    let data_limit = limit.saturating_sub(table_chrome);
    let omitted_rows = rows.len().saturating_sub(data_limit);
    let widths = table_widths(width, headers.len());
    let truncated_cells = count_truncated_cells(&headers, &rows, &widths, data_limit);
    let mut lines = Vec::new();
    lines.push(StyledLine::plain(
        table_border('┌', '┬', '┐', &widths),
        LineStyle::Muted,
    ));
    lines.push(StyledLine::plain(
        table_row(&headers, &widths),
        LineStyle::Heading,
    ));
    lines.push(StyledLine::plain(
        table_border('├', '┼', '┤', &widths),
        LineStyle::Muted,
    ));
    for row in rows.iter().take(data_limit) {
        lines.push(StyledLine::plain(
            table_row(row, &widths),
            LineStyle::Normal,
        ));
    }
    lines.truncate(limit);
    Ok(BodyRender {
        lines,
        compacted: omitted_rows > 0 || omitted_columns > 0 || truncated_cells > 0,
        omitted_items: omitted_rows + omitted_columns + truncated_cells,
        source_lines,
        images: Vec::new(),
    })
}

fn count_truncated_cells(
    headers: &[String],
    rows: &[Vec<String>],
    widths: &[usize],
    row_limit: usize,
) -> usize {
    let header_count = headers
        .iter()
        .zip(widths)
        .filter(|(value, width)| UnicodeWidthStr::width(value.as_str()) > **width)
        .count();
    let row_count = rows
        .iter()
        .take(row_limit)
        .flat_map(|row| row.iter().zip(widths))
        .filter(|(value, width)| UnicodeWidthStr::width(value.as_str()) > **width)
        .count();
    header_count + row_count
}

fn render_image_body(manifest: &ArtifactManifest) -> Result<BodyRender> {
    let path = Path::new(&manifest.source);
    validate_png(path)?;
    let image = read_bounded_source(path, MAX_IMAGE_BYTES, "image")?;
    Ok(BodyRender {
        lines: Vec::new(),
        compacted: false,
        omitted_items: 0,
        source_lines: 0,
        images: vec![BodyImage {
            after_line: 0,
            columns: 1,
            rows: 1,
            alt: manifest.title.clone(),
            bytes: image,
        }],
    })
}

fn deferred_body(manifest: &ArtifactManifest) -> BodyRender {
    BodyRender {
        lines: vec![
            StyledLine::plain(
                "Preview generation is deferred by policy.",
                LineStyle::Warning,
            ),
            StyledLine::plain(
                format!("Source: {} bytes", manifest.source_bytes),
                LineStyle::Muted,
            ),
        ],
        compacted: true,
        omitted_items: manifest.preview.omitted_items,
        source_lines: manifest.preview.source_lines,
        images: Vec::new(),
    }
}

fn render_document(
    manifest: &ArtifactManifest,
    columns: u16,
    rows: u16,
    body: BodyRender,
) -> RenderedArtifact {
    if body.lines.is_empty() && body.images.len() == 1 {
        return render_image_document(manifest, columns, rows, &body, &body.images[0].bytes);
    }
    let width = usize::from(columns);
    let body_rows = usize::from(rows.saturating_sub(3)).max(1);
    let mut ansi = String::new();
    let mut plain = Vec::new();
    push_document_line(
        &mut ansi,
        &mut plain,
        &manifest.title,
        width,
        LineStyle::Heading,
    );
    let mut meta = format!(
        "{} · v{} · {} · {}",
        manifest.kind.as_str(),
        manifest.version,
        manifest.language,
        format_bytes(manifest.source_bytes)
    );
    if body.omitted_items > 0 {
        meta.push_str(&format!(" · +{} omitted", body.omitted_items));
    }
    push_document_line(&mut ansi, &mut plain, &meta, width, LineStyle::Muted);
    push_document_line(&mut ansi, &mut plain, "", width, LineStyle::Normal);
    let rendered_rows = push_body_rows(&mut ansi, &mut plain, &body, width, body_rows);
    for _ in rendered_rows..body_rows {
        push_document_line(&mut ansi, &mut plain, "", width, LineStyle::Normal);
    }
    RenderedArtifact {
        ansi,
        plain_lines: plain,
        compacted: body.compacted,
        omitted_items: body.omitted_items,
    }
}

fn push_body_rows(
    ansi: &mut String,
    plain: &mut Vec<String>,
    body: &BodyRender,
    width: usize,
    limit: usize,
) -> usize {
    let mut used = 0;
    let mut image_index = 0;
    for line_index in 0..=body.lines.len() {
        while let Some(image) = body.images.get(image_index)
            && image.after_line == line_index
            && used < limit
        {
            let rows = image.rows.min(limit - used);
            push_document_image(ansi, plain, image, width, rows);
            used += rows;
            image_index += 1;
        }
        if let Some(line) = body.lines.get(line_index)
            && used < limit
        {
            push_document_styled_line(ansi, plain, line, width);
            used += 1;
        }
    }
    used
}

fn push_document_image(
    ansi: &mut String,
    plain: &mut Vec<String>,
    image: &BodyImage,
    width: usize,
    rows: usize,
) {
    if rows == 0 {
        return;
    }
    let diagnostic = format!("[image: {}]", image.alt);
    plain.push(pad_display(&truncate_display(&diagnostic, width), width));
    let columns = image.columns.min(width).max(1);
    let left_padding = width.saturating_sub(columns) / 2;
    let right_padding = width.saturating_sub(columns + left_padding);
    ansi.push_str(style_escape(LineStyle::Normal));
    ansi.push_str(&" ".repeat(left_padding));
    ansi.push_str("\x1b[0m");
    ansi.push_str(&kitty_image(&image.bytes, columns, rows));
    ansi.push_str(style_escape(LineStyle::Normal));
    ansi.push_str(&" ".repeat(columns + right_padding));
    ansi.push_str("\x1b[0m\r\n");
    for _ in 1..rows {
        push_document_line(ansi, plain, "", width, LineStyle::Normal);
    }
}

fn render_image_document(
    manifest: &ArtifactManifest,
    columns: u16,
    rows: u16,
    body: &BodyRender,
    image: &[u8],
) -> RenderedArtifact {
    let width = usize::from(columns);
    let image_rows = usize::from(rows.saturating_sub(2)).max(1);
    let mut ansi = String::new();
    let mut plain = Vec::new();
    push_document_line(
        &mut ansi,
        &mut plain,
        &manifest.title,
        width,
        LineStyle::Heading,
    );
    let meta = format!(
        "{} · v{} · {} · {}",
        manifest.kind.as_str(),
        manifest.version,
        manifest.language,
        format_bytes(manifest.source_bytes)
    );
    push_document_line(&mut ansi, &mut plain, &meta, width, LineStyle::Muted);
    ansi.push_str(&kitty_image(image, width, image_rows));
    plain.extend((0..image_rows).map(|_| String::new()));
    RenderedArtifact {
        ansi,
        plain_lines: plain,
        compacted: body.compacted,
        omitted_items: body.omitted_items,
    }
}

fn push_document_line(
    ansi: &mut String,
    plain: &mut Vec<String>,
    text: &str,
    width: usize,
    style: LineStyle,
) {
    let fitted = pad_display(&truncate_display(text, width), width);
    plain.push(fitted.clone());
    ansi.push_str(style_escape(style));
    ansi.push_str(&fitted);
    ansi.push_str("\x1b[0m\r\n");
}

fn push_document_styled_line(
    ansi: &mut String,
    plain: &mut Vec<String>,
    line: &StyledLine,
    width: usize,
) {
    let spans = truncate_styled_spans(&line.spans, width, line.style);
    let text = spans
        .iter()
        .map(|span| span.text.as_str())
        .collect::<String>();
    let padding = width.saturating_sub(UnicodeWidthStr::width(text.as_str()));
    plain.push(format!("{text}{}", " ".repeat(padding)));

    for span in spans {
        push_span_style(ansi, span.style);
        ansi.push_str(&span.text);
    }
    ansi.push_str("\x1b[0m");
    ansi.push_str(style_escape(line.style));
    ansi.push_str(&" ".repeat(padding));
    ansi.push_str("\x1b[0m\r\n");
}

fn style_escape(style: LineStyle) -> &'static str {
    match style {
        LineStyle::Normal => "\x1b[38;2;220;224;230m",
        LineStyle::Heading => "\x1b[1;38;2;244;247;252m",
        LineStyle::Muted => "\x1b[38;2;132;142;156m",
        LineStyle::Accent => "\x1b[38;2;91;192;235m",
        LineStyle::Added => "\x1b[38;2;126;211;154m",
        LineStyle::Removed => "\x1b[38;2;242;139;130m",
        LineStyle::Warning => "\x1b[1;38;2;240;190;85m",
    }
}

fn push_span_style(ansi: &mut String, style: SpanStyle) {
    ansi.push_str("\x1b[0m");
    ansi.push_str(style_escape(style.base));
    if let Some(color) = style.foreground {
        ansi.push_str(&format!(
            "\x1b[38;2;{};{};{}m",
            color.red, color.green, color.blue
        ));
    }
    if let Some(color) = style.background {
        ansi.push_str(&format!(
            "\x1b[48;2;{};{};{}m",
            color.red, color.green, color.blue
        ));
    }
    if style.bold {
        ansi.push_str("\x1b[1m");
    }
    if style.italic {
        ansi.push_str("\x1b[3m");
    }
    if style.underline {
        ansi.push_str("\x1b[4m");
    }
    if style.strikethrough {
        ansi.push_str("\x1b[9m");
    }
}

fn truncate_styled_spans(
    spans: &[StyledSpan],
    width: usize,
    fallback: LineStyle,
) -> Vec<StyledSpan> {
    let full_width = spans
        .iter()
        .map(|span| UnicodeWidthStr::width(span.text.as_str()))
        .sum::<usize>();
    if full_width <= width {
        return spans.to_vec();
    }
    if width == 0 {
        return Vec::new();
    }

    let target = width.saturating_sub(1);
    let mut output = Vec::new();
    let mut current_width = 0;
    let mut last_style = SpanStyle::new(fallback);
    'outer: for span in spans {
        last_style = span.style;
        for character in span.text.chars() {
            let character_width = UnicodeWidthChar::width(character).unwrap_or(0);
            if current_width + character_width > target {
                break 'outer;
            }
            append_styled_character(&mut output, character, span.style);
            current_width += character_width;
        }
    }
    append_styled_character(&mut output, '…', last_style);
    output
}

fn append_styled_character(spans: &mut Vec<StyledSpan>, character: char, style: SpanStyle) {
    if let Some(last) = spans.last_mut()
        && last.style == style
    {
        last.text.push(character);
        return;
    }
    spans.push(StyledSpan::new(character.to_string(), style));
}

fn parse_table(content: &str, source: &Path) -> Result<(Vec<String>, Vec<Vec<String>>)> {
    if source.extension().and_then(|value| value.to_str()) == Some("json")
        || content.trim_start().starts_with(['[', '{'])
    {
        return parse_json_table(content);
    }
    let delimiter = if source.extension().and_then(|value| value.to_str()) == Some("tsv") {
        '\t'
    } else {
        ','
    };
    let mut lines = content.lines();
    let headers = lines
        .next()
        .map(|line| split_delimited_row(line, delimiter))
        .unwrap_or_default();
    let rows = lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| split_delimited_row(line, delimiter))
        .collect();
    Ok((headers, rows))
}

fn parse_json_table(content: &str) -> Result<(Vec<String>, Vec<Vec<String>>)> {
    let value: Value = serde_json::from_str(content).context("decode table JSON")?;
    match value {
        Value::Array(values) => parse_json_array_table(&values),
        Value::Object(values) => Ok((
            vec!["key".to_owned(), "value".to_owned()],
            values
                .into_iter()
                .map(|(key, value)| vec![key, json_cell(&value)])
                .collect(),
        )),
        value => Ok((vec!["value".to_owned()], vec![vec![json_cell(&value)]])),
    }
}

fn parse_json_array_table(values: &[Value]) -> Result<(Vec<String>, Vec<Vec<String>>)> {
    let Some(first) = values.first() else {
        return Ok((vec!["value".to_owned()], Vec::new()));
    };
    match first {
        Value::Object(_) => {
            let mut headers = Vec::new();
            for value in values {
                if let Value::Object(object) = value {
                    for key in object.keys() {
                        if !headers.contains(key) {
                            headers.push(key.clone());
                        }
                    }
                }
            }
            let rows = values
                .iter()
                .map(|value| object_row(value.as_object(), &headers))
                .collect();
            Ok((headers, rows))
        }
        Value::Array(row) => {
            let width = row.len();
            let headers = (1..=width).map(|index| index.to_string()).collect();
            let rows = values
                .iter()
                .map(|value| {
                    value
                        .as_array()
                        .map(|items| items.iter().map(json_cell).collect())
                        .unwrap_or_else(|| vec![json_cell(value)])
                })
                .collect();
            Ok((headers, rows))
        }
        _ => Ok((
            vec!["value".to_owned()],
            values.iter().map(|value| vec![json_cell(value)]).collect(),
        )),
    }
}

fn object_row(object: Option<&Map<String, Value>>, headers: &[String]) -> Vec<String> {
    headers
        .iter()
        .map(|header| {
            object
                .and_then(|value| value.get(header))
                .map(json_cell)
                .unwrap_or_default()
        })
        .collect()
}

fn json_cell(value: &Value) -> String {
    match value {
        Value::String(value) => sanitize_cell(value),
        Value::Null => "—".to_owned(),
        _ => sanitize_cell(&value.to_string()),
    }
}

fn split_delimited_row(line: &str, delimiter: char) -> Vec<String> {
    line.split(delimiter)
        .map(|value| sanitize_cell(value.trim().trim_matches('"')))
        .collect()
}

fn sanitize_cell(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn table_column_limit(width: usize, columns: usize) -> usize {
    let available = width.saturating_sub(1);
    (1..=columns.min(6))
        .rev()
        .find(|count| available / count >= 7)
        .unwrap_or(1)
}

fn table_widths(width: usize, columns: usize) -> Vec<usize> {
    let columns = columns.max(1);
    let available = width.saturating_sub(columns + 1);
    let base = available / columns;
    let remainder = available % columns;
    (0..columns)
        .map(|index| base + usize::from(index < remainder))
        .collect()
}

fn table_border(left: char, middle: char, right: char, widths: &[usize]) -> String {
    let cells = widths
        .iter()
        .map(|width| "─".repeat(*width))
        .collect::<Vec<_>>()
        .join(&middle.to_string());
    format!("{left}{cells}{right}")
}

fn table_row(values: &[String], widths: &[usize]) -> String {
    let cells = widths
        .iter()
        .enumerate()
        .map(|(index, width)| {
            let value = values.get(index).map_or("", String::as_str);
            pad_display(&truncate_display(value, *width), *width)
        })
        .collect::<Vec<_>>()
        .join("│");
    format!("│{cells}│")
}

fn read_text_source(manifest: &ArtifactManifest) -> Result<String> {
    let path = Path::new(&manifest.source);
    let bytes = read_bounded_source(path, MAX_TEXT_BYTES, "text artifact")?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn read_bounded_source(path: &Path, maximum: u64, label: &str) -> Result<Vec<u8>> {
    let file =
        File::open(path).with_context(|| format!("open {label} source {}", path.display()))?;
    let metadata = file
        .metadata()
        .with_context(|| format!("inspect {label} source {}", path.display()))?;
    if !metadata.is_file() {
        bail!("{label} source must be a regular file");
    }
    if metadata.len() > maximum {
        bail!("{label} source exceeds the {maximum}-byte preview limit");
    }
    let read_limit = maximum
        .checked_add(1)
        .ok_or_else(|| anyhow!("{label} source limit is too large"))?;
    let mut bytes = Vec::with_capacity(metadata.len().try_into().unwrap_or(0));
    file.take(read_limit)
        .read_to_end(&mut bytes)
        .with_context(|| format!("read {label} source {}", path.display()))?;
    if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > maximum {
        bail!("{label} source exceeds the {maximum}-byte preview limit");
    }
    Ok(bytes)
}

fn validate_source_size(kind: ArtifactKind, bytes: u64) -> Result<()> {
    let maximum = if kind == ArtifactKind::Image {
        MAX_IMAGE_BYTES
    } else {
        MAX_TEXT_BYTES
    };
    if bytes > maximum {
        bail!("artifact source exceeds the {maximum}-byte preview limit");
    }
    Ok(())
}

fn validate_png(path: &Path) -> Result<()> {
    let file = File::open(path).with_context(|| format!("open image {}", path.display()))?;
    let mut decoder = png::Decoder::new(BufReader::new(file));
    decoder
        .read_header_info()
        .with_context(|| format!("decode PNG header {}", path.display()))?;
    Ok(())
}

fn prepare_artifact_source(
    kind: ArtifactKind,
    title: &str,
    source: &Path,
) -> Result<ArtifactSource> {
    let canonical_path = source
        .canonicalize()
        .with_context(|| format!("resolve artifact source {}", source.display()))?;
    let metadata = canonical_path
        .metadata()
        .with_context(|| format!("inspect artifact source {}", canonical_path.display()))?;
    if !metadata.is_file() {
        bail!("artifact source must be a regular file");
    }
    validate_source_size(kind, metadata.len())?;
    let maximum = if kind == ArtifactKind::Image {
        MAX_IMAGE_BYTES
    } else {
        MAX_TEXT_BYTES
    };
    let bytes = read_bounded_source(&canonical_path, maximum, "artifact")?;
    if kind == ArtifactKind::Image {
        validate_png(&canonical_path)?;
    }
    let source_name = stored_source_name(kind, &canonical_path);
    let (document, assets) = if kind == ArtifactKind::Image {
        (
            format!("# {title}\n\n![{title}]({source_name})\n"),
            Vec::new(),
        )
    } else {
        let content = std::str::from_utf8(&bytes).with_context(|| {
            format!("artifact source is not UTF-8: {}", canonical_path.display())
        })?;
        let assets = if kind == ArtifactKind::Markdown {
            markdown::snapshot_local_pngs(content, &canonical_path)?
        } else {
            Vec::new()
        };
        (
            artifact_markdown(kind, title, content, &canonical_path)?,
            assets,
        )
    };
    Ok(ArtifactSource {
        canonical_path,
        bytes,
        document,
        source_name,
        assets,
    })
}

fn stored_source_name(kind: ArtifactKind, source: &Path) -> String {
    match kind {
        ArtifactKind::Markdown => "artifact.md".to_owned(),
        ArtifactKind::Image => "image.png".to_owned(),
        ArtifactKind::Table => match source
            .extension()
            .and_then(|extension| extension.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Some("json") => "source.json".to_owned(),
            Some("csv") => "source.csv".to_owned(),
            Some("tsv") => "source.tsv".to_owned(),
            _ => "source.txt".to_owned(),
        },
        ArtifactKind::Diff => "source.diff".to_owned(),
        ArtifactKind::Text | ArtifactKind::Tree | ArtifactKind::Timeline => "source.txt".to_owned(),
    }
}

fn artifact_markdown(
    kind: ArtifactKind,
    title: &str,
    content: &str,
    source: &Path,
) -> Result<String> {
    let content = content.trim_end();
    let document = match kind {
        ArtifactKind::Markdown => format!("{content}\n"),
        ArtifactKind::Text => format!("# {title}\n\n{content}\n"),
        ArtifactKind::Diff => format!("# {title}\n\n```diff\n{content}\n```\n"),
        ArtifactKind::Tree => format!("# {title}\n\n```text\n{content}\n```\n"),
        ArtifactKind::Timeline => {
            let items = content
                .lines()
                .map(|line| format!("- {}", line.trim()))
                .collect::<Vec<_>>()
                .join("\n");
            format!("# {title}\n\n{items}\n")
        }
        ArtifactKind::Table => {
            let (headers, rows) = parse_table(content, source)?;
            let table = markdown_table(&headers, &rows);
            format!("# {title}\n\n{table}")
        }
        ArtifactKind::Image => unreachable!("image Markdown is created without UTF-8 source"),
    };
    Ok(document)
}

fn markdown_table(headers: &[String], rows: &[Vec<String>]) -> String {
    let headers = if headers.is_empty() {
        vec!["value".to_owned()]
    } else {
        headers.to_vec()
    };
    let header = headers
        .iter()
        .map(|value| markdown_table_cell(value))
        .collect::<Vec<_>>()
        .join(" | ");
    let separator = headers
        .iter()
        .map(|_| "---")
        .collect::<Vec<_>>()
        .join(" | ");
    let mut output = format!("| {header} |\n| {separator} |\n");
    for row in rows {
        let cells = (0..headers.len())
            .map(|index| markdown_table_cell(row.get(index).map_or("", String::as_str)))
            .collect::<Vec<_>>()
            .join(" | ");
        output.push_str(&format!("| {cells} |\n"));
    }
    output
}

fn markdown_table_cell(value: &str) -> String {
    sanitize_cell(value).replace('|', "\\|")
}

fn stored_artifact_matches(
    socket: &Path,
    artifact: &StoredArtifact,
    title: &str,
    language: &str,
    prepared: &ArtifactSource,
) -> Result<bool> {
    if artifact.title != title || artifact.language != language {
        return Ok(false);
    }
    let Some(latest) = artifact.versions.last() else {
        return Ok(false);
    };
    let directory = resolve_artifact_directory(socket, &artifact.id)?;
    let document = safe_artifact_join(&directory, &latest.document)?;
    if fs::read(document)? != prepared.document.as_bytes() {
        return Ok(false);
    }
    if prepared.source_name != "artifact.md" {
        let source = safe_artifact_join(&directory, &latest.source)?;
        if fs::read(source)? != prepared.bytes {
            return Ok(false);
        }
    }
    if latest.assets.len() != prepared.assets.len() {
        return Ok(false);
    }
    for (stored, prepared) in latest.assets.iter().zip(&prepared.assets) {
        let path = safe_artifact_join(&directory, stored)?;
        if fs::read(path)? != prepared.bytes {
            return Ok(false);
        }
    }
    Ok(true)
}

fn artifact_document_preview(path: &Path) -> Result<String> {
    let content = fs::read_to_string(path)
        .with_context(|| format!("read artifact document {}", path.display()))?;
    let mut preview = Vec::new();
    let mut frontmatter = content
        .lines()
        .next()
        .is_some_and(|line| line.trim() == "---");
    for (index, line) in content.lines().enumerate() {
        let trimmed = line.trim();
        if frontmatter {
            if index > 0 && trimmed == "---" {
                frontmatter = false;
            }
            continue;
        }
        if trimmed.is_empty()
            || trimmed.starts_with("# ")
            || trimmed.starts_with("| ---")
            || trimmed.starts_with("```")
        {
            continue;
        }
        let line = if let Some(image) = trimmed.strip_prefix("![") {
            let alt = image.split(']').next().unwrap_or("image");
            format!("Image · {alt}")
        } else {
            trimmed.trim_matches('`').to_owned()
        };
        preview.push(line);
        if preview.len() == 2 {
            break;
        }
    }
    Ok(truncate_display(&preview.join(" · "), 120))
}

fn wrap_display(value: &str, width: usize) -> Vec<String> {
    if value.is_empty() {
        return vec![String::new()];
    }
    let mut lines = Vec::new();
    let mut line = String::new();
    let mut line_width = 0;
    for character in value.chars() {
        let character_width = UnicodeWidthChar::width(character).unwrap_or(0);
        if line_width > 0 && line_width + character_width > width {
            lines.push(line.trim_end().to_owned());
            line.clear();
            line_width = 0;
        }
        line.push(character);
        line_width += character_width;
    }
    if !line.is_empty() {
        lines.push(line.trim_end().to_owned());
    }
    lines
}

fn truncate_display(value: &str, width: usize) -> String {
    if UnicodeWidthStr::width(value) <= width {
        return value.to_owned();
    }
    if width == 0 {
        return String::new();
    }
    let target = width.saturating_sub(1);
    let mut output = String::new();
    let mut current = 0;
    for character in value.chars() {
        let character_width = UnicodeWidthChar::width(character).unwrap_or(0);
        if current + character_width > target {
            break;
        }
        output.push(character);
        current += character_width;
    }
    output.push('…');
    output
}

fn pad_display(value: &str, width: usize) -> String {
    let padding = width.saturating_sub(UnicodeWidthStr::width(value));
    format!("{value}{}", " ".repeat(padding))
}

fn kitty_image(image: &[u8], columns: usize, rows: usize) -> String {
    let encoded = base64_encode(image);
    let chunks = encoded.as_bytes().chunks(4096).collect::<Vec<_>>();
    let mut output = String::new();
    for (index, chunk) in chunks.iter().enumerate() {
        let more = usize::from(index + 1 < chunks.len());
        if index == 0 {
            output.push_str(&format!(
                "\x1b_Ga=T,f=100,q=2,C=1,c={columns},r={rows},m={more};"
            ));
        } else {
            output.push_str(&format!("\x1b_Gm={more};"));
        }
        output.push_str(std::str::from_utf8(chunk).unwrap_or_default());
        output.push_str("\x1b\\");
    }
    output
}

fn base64_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let value = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        output.push(char::from(ALPHABET[((value >> 18) & 63) as usize]));
        output.push(char::from(ALPHABET[((value >> 12) & 63) as usize]));
        output.push(if chunk.len() > 1 {
            char::from(ALPHABET[((value >> 6) & 63) as usize])
        } else {
            '='
        });
        output.push(if chunk.len() > 2 {
            char::from(ALPHABET[(value & 63) as usize])
        } else {
            '='
        });
    }
    output
}

fn validate_title(title: &str) -> Result<()> {
    if title.trim().is_empty() || title.chars().any(char::is_control) {
        bail!("artifact title must be non-empty and contain no control characters");
    }
    if title.len() > 512 {
        bail!("artifact title is too long");
    }
    Ok(())
}

fn validate_language(language: &str) -> Result<()> {
    if language.is_empty()
        || language.len() > 32
        || !language
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '-')
    {
        bail!("language must be auto or a BCP 47-style language tag");
    }
    Ok(())
}

fn normalize_locale(locale: &str) -> Option<String> {
    let value = locale.split('.').next()?.split('@').next()?;
    if value == "C" || value == "POSIX" || value.is_empty() {
        return None;
    }
    let mut parts = value.split(['-', '_']);
    let language = parts.next()?.to_ascii_lowercase();
    let region = parts.next().map(str::to_ascii_uppercase);
    Some(region.map_or(language.clone(), |region| format!("{language}-{region}")))
}

fn policy_path(socket: &Path) -> Result<PathBuf> {
    Ok(artifact_root(socket)?.join(".policy.json"))
}

pub fn manifest_path(socket: &Path, id: &str) -> Result<PathBuf> {
    Ok(resolve_artifact_directory(socket, id)?.join("metadata.json"))
}

pub fn artifact_root(socket: &Path) -> Result<PathBuf> {
    let parent = socket_parent(socket)?;
    if parent.file_name().and_then(|name| name.to_str()) == Some("run") {
        let application = parent
            .parent()
            .ok_or_else(|| anyhow!("control run directory has no application parent"))?;
        return Ok(application.join("artifacts"));
    }
    Ok(parent.join("artifacts"))
}

fn parse_artifact_selector(selector: &str) -> Result<(String, Option<u32>)> {
    let Some((id, version)) = selector.split_once('@') else {
        validate_artifact_id(selector)?;
        return Ok((selector.to_owned(), None));
    };
    validate_artifact_id(id)?;
    let version = version.strip_prefix('v').unwrap_or(version);
    let version = version
        .parse::<u32>()
        .with_context(|| format!("invalid artifact version in {selector:?}"))?;
    if version == 0 {
        bail!("artifact versions start at 1");
    }
    Ok((id.to_owned(), Some(version)))
}

fn socket_parent(socket: &Path) -> Result<&Path> {
    if !socket.is_absolute() {
        bail!("control socket path must be absolute");
    }
    socket
        .parent()
        .ok_or_else(|| anyhow!("control socket path has no parent"))
}

fn validate_artifact_id(id: &str) -> Result<()> {
    if id.is_empty()
        || id.len() > 64
        || !id.chars().all(|character| {
            character.is_ascii_lowercase() || character.is_ascii_digit() || character == '-'
        })
    {
        bail!("invalid artifact ID");
    }
    Ok(())
}

fn artifact_slug(title: &str) -> String {
    let mut slug = String::new();
    let mut separator = false;
    for character in title.trim().chars() {
        if character.is_alphanumeric() {
            if separator && !slug.is_empty() {
                slug.push('-');
            }
            separator = false;
            if character.is_ascii() {
                slug.push(character.to_ascii_lowercase());
            } else {
                slug.push(character);
            }
        } else {
            separator = true;
        }
        if slug.chars().count() >= 48 {
            break;
        }
    }
    let slug = slug.trim_matches('-');
    if slug.is_empty() {
        "artifact".to_owned()
    } else {
        slug.to_owned()
    }
}

fn load_stored_artifact(socket: &Path, id: &str) -> Result<StoredArtifact> {
    let path = manifest_path(socket, id)?;
    let file =
        File::open(&path).with_context(|| format!("open artifact metadata {}", path.display()))?;
    let artifact: StoredArtifact = serde_json::from_reader(BufReader::new(file))
        .with_context(|| format!("decode artifact metadata {}", path.display()))?;
    validate_stored_artifact(&artifact)?;
    if artifact.id != id {
        bail!("artifact metadata has the wrong ID");
    }
    Ok(artifact)
}

fn validate_stored_artifact(artifact: &StoredArtifact) -> Result<()> {
    if artifact.format_version != STORE_VERSION {
        bail!("artifact metadata is incompatible");
    }
    validate_artifact_id(&artifact.id)?;
    validate_title(&artifact.title)?;
    validate_language(&artifact.language)?;
    if artifact.versions.is_empty() {
        bail!("artifact metadata contains no versions");
    }
    for (index, version) in artifact.versions.iter().enumerate() {
        let expected = u32::try_from(index + 1).unwrap_or(u32::MAX);
        if version.version != expected {
            bail!("artifact versions must be contiguous and start at 1");
        }
        validate_relative_artifact_path(&version.document)?;
        validate_relative_artifact_path(&version.source)?;
        let version_root = Path::new(&version.document)
            .parent()
            .ok_or_else(|| anyhow!("artifact version document has no parent"))?;
        for asset in &version.assets {
            validate_relative_artifact_path(asset)?;
            if !Path::new(asset).starts_with(version_root) {
                bail!("artifact asset is outside its version directory");
            }
        }
        if !Path::new(&version.origin).is_absolute() {
            bail!("artifact metadata contains a non-absolute origin path");
        }
    }
    Ok(())
}

fn resolve_artifact_directory(socket: &Path, id: &str) -> Result<PathBuf> {
    validate_artifact_id(id)?;
    let root = artifact_root(socket)?;
    let marker = root.join(".index").join(id);
    if let Ok(name) = fs::read_to_string(&marker) {
        let name = name.trim();
        validate_artifact_directory_name(name, id)?;
        let directory = root.join(name);
        validate_existing_artifact_directory(&directory)?;
        return Ok(directory);
    }
    let entries =
        fs::read_dir(&root).with_context(|| format!("open artifact store {}", root.display()))?;
    let suffix = format!("--{id}");
    let mut match_path = None;
    for entry in entries {
        let entry = entry?;
        if entry.file_type()?.is_dir() && entry.file_name().to_string_lossy().ends_with(&suffix) {
            if match_path.is_some() {
                bail!("artifact ID {id} resolves to more than one directory");
            }
            match_path = Some(entry.path());
        }
    }
    match_path.ok_or_else(|| anyhow!("artifact {id} does not exist"))
}

fn validate_artifact_directory_name(name: &str, id: &str) -> Result<()> {
    let path = Path::new(name);
    if name.is_empty()
        || name.starts_with('.')
        || path.components().count() != 1
        || !name.ends_with(&format!("--{id}"))
    {
        bail!("artifact index entry is invalid");
    }
    Ok(())
}

fn validate_existing_artifact_directory(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect artifact directory {}", path.display()))?;
    if !metadata.is_dir()
        || metadata.uid() != effective_uid()
        || metadata.permissions().mode() & 0o077 != 0
    {
        bail!("artifact directory is not owner-only: {}", path.display());
    }
    Ok(())
}

fn write_marker(socket: &Path, id: &str, directory: &Path) -> Result<()> {
    let name = directory
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow!("artifact directory name is not UTF-8"))?;
    validate_artifact_directory_name(name, id)?;
    let index = artifact_root(socket)?.join(".index");
    ensure_owner_only_directory(&index)?;
    write_bytes_atomically(&index.join(id), format!("{name}\n").as_bytes())
}

fn validate_relative_artifact_path(value: &str) -> Result<()> {
    let path = Path::new(value);
    if path.as_os_str().is_empty()
        || path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, std::path::Component::Normal(_)))
    {
        bail!("artifact metadata contains an unsafe relative path");
    }
    Ok(())
}

fn safe_artifact_join(directory: &Path, relative: &str) -> Result<PathBuf> {
    validate_relative_artifact_path(relative)?;
    Ok(directory.join(relative))
}

fn relative_artifact_path(directory: &Path, path: &Path) -> Result<String> {
    let relative = path
        .strip_prefix(directory)
        .with_context(|| format!("{} is outside the artifact directory", path.display()))?;
    let value = relative.to_string_lossy().into_owned();
    validate_relative_artifact_path(&value)?;
    Ok(value)
}

fn manifest_from_stored(
    socket: &Path,
    artifact: &StoredArtifact,
    requested_version: Option<u32>,
) -> Result<ArtifactManifest> {
    validate_stored_artifact(artifact)?;
    let version = requested_version.map_or_else(
        || artifact.versions.last(),
        |number| {
            artifact
                .versions
                .iter()
                .find(|version| version.version == number)
        },
    );
    let version = version.ok_or_else(|| {
        anyhow!(
            "artifact {} has no version {}",
            artifact.id,
            requested_version.unwrap_or_default()
        )
    })?;
    let directory = resolve_artifact_directory(socket, &artifact.id)?;
    let document = safe_artifact_join(&directory, &version.document)?;
    let source = safe_artifact_join(&directory, &version.source)?;
    let assets = version
        .assets
        .iter()
        .map(|asset| safe_artifact_join(&directory, asset))
        .collect::<Result<Vec<_>>>()?;
    Ok(ArtifactManifest {
        format_version: STORE_VERSION,
        id: artifact.id.clone(),
        version: version.version,
        kind: artifact.kind,
        title: artifact.title.clone(),
        language: artifact.language.clone(),
        document: document.to_string_lossy().into_owned(),
        source: source.to_string_lossy().into_owned(),
        assets: assets
            .into_iter()
            .map(|path| path.to_string_lossy().into_owned())
            .collect(),
        origin: version.origin.clone(),
        source_bytes: version.source_bytes,
        created_at_ms: version.created_at_ms,
        created_at: format_timestamp(version.created_at_ms),
        owner_tab: artifact.owner_tab,
        owner_pane: artifact.owner_pane,
        preview: version.preview.clone(),
    })
}

fn write_artifact_documents(directory: &Path, artifact: &StoredArtifact) -> Result<()> {
    let latest = artifact
        .versions
        .last()
        .ok_or_else(|| anyhow!("artifact contains no versions"))?;
    let latest_document = safe_artifact_join(directory, &latest.document)?;
    write_bytes_atomically(&directory.join("current.md"), &fs::read(latest_document)?)?;
    mirror_current_assets(directory, latest)?;

    let mut readme = format!(
        "# {}\n\n- ID: `{}`\n- Kind: `{}`\n- Language: `{}`\n- Current: [v{}]({})\n- Updated: {}\n- Origin: `{}`\n\n## Versions\n\n| Version | Created | Preview |\n| --- | --- | --- |\n",
        artifact.title,
        artifact.id,
        artifact.kind.as_str(),
        artifact.language,
        latest.version,
        latest.document,
        format_timestamp(artifact.updated_at_ms),
        markdown_inline_metadata(&latest.origin),
    );
    for version in artifact.versions.iter().rev() {
        let document = safe_artifact_join(directory, &version.document)?;
        let preview = artifact_document_preview(&document)?.replace('|', "\\|");
        readme.push_str(&format!(
            "| [v{0}]({1}) | {2} | {3} |\n",
            version.version,
            version.document,
            format_timestamp(version.created_at_ms),
            preview,
        ));
    }
    write_bytes_atomically(&directory.join("README.md"), readme.as_bytes())
}

fn mirror_current_assets(directory: &Path, version: &StoredArtifactVersion) -> Result<()> {
    let version_root = Path::new(&version.document)
        .parent()
        .ok_or_else(|| anyhow!("artifact version document has no parent"))?;
    for asset in &version.assets {
        let relative = Path::new(asset)
            .strip_prefix(version_root)
            .with_context(|| format!("artifact asset {asset} is outside its version"))?;
        let relative = relative.to_string_lossy();
        validate_relative_artifact_path(&relative)?;
        let source = safe_artifact_join(directory, asset)?;
        write_bytes_atomically(&directory.join(relative.as_ref()), &fs::read(source)?)?;
    }
    Ok(())
}

fn markdown_inline_metadata(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else if character == '`' {
                '\''
            } else {
                character
            }
        })
        .collect()
}

fn write_artifact_index(socket: &Path) -> Result<()> {
    let artifacts = list_artifacts(socket, None)?;
    let mut index = String::from(
        "# Satin Artifacts\n\n| Artifact | Kind | Version | Updated | Preview |\n| --- | --- | --- | --- | --- |\n",
    );
    for artifact in artifacts {
        let directory = Path::new(&artifact.directory)
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| anyhow!("artifact directory name is not UTF-8"))?;
        index.push_str(&format!(
            "| [{}]({}/current.md) | {} | v{} | {} | {} |\n",
            artifact.title.replace('|', "\\|"),
            directory,
            artifact.kind.as_str(),
            artifact.version,
            format_timestamp(artifact.updated_at_ms),
            artifact.preview.replace('|', "\\|"),
        ));
    }
    write_bytes_atomically(&artifact_root(socket)?.join("INDEX.md"), index.as_bytes())
}

fn format_timestamp(milliseconds: u64) -> String {
    let seconds = milliseconds / 1_000;
    let days = i64::try_from(seconds / 86_400).unwrap_or(i64::MAX);
    let seconds_of_day = seconds % 86_400;
    let z = days + 719_468;
    let era = z / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    format!("{year:04}-{month:02}-{day:02} {hour:02}:{minute:02} UTC")
}

fn ensure_owner_only_directory(path: &Path) -> Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true).mode(0o700);
    builder.create(path)?;
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir()
        || metadata.uid() != effective_uid()
        || metadata.permissions().mode() & 0o077 != 0
    {
        bail!("artifact directory must be owner-only: {}", path.display());
    }
    Ok(())
}

fn create_owner_only_directory(path: &Path) -> Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.mode(0o700);
    builder.create(path)?;
    validate_existing_artifact_directory(path)
}

struct ArtifactStoreLock {
    _file: File,
}

fn lock_artifact_store(socket: &Path) -> Result<ArtifactStoreLock> {
    let root = artifact_root(socket)?;
    ensure_owner_only_directory(&root)?;
    let path = root.join(".register.lock");
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&path)
        .with_context(|| format!("open artifact store lock {}", path.display()))?;
    let metadata = file
        .metadata()
        .with_context(|| format!("inspect artifact store lock {}", path.display()))?;
    if !metadata.is_file()
        || metadata.uid() != effective_uid()
        || metadata.permissions().mode() & 0o077 != 0
    {
        bail!("artifact store lock must be owner-only: {}", path.display());
    }
    // SAFETY: `file` owns a valid descriptor for the lifetime of the returned guard.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(io::Error::last_os_error())
            .with_context(|| format!("lock artifact store {}", root.display()));
    }
    Ok(ArtifactStoreLock { _file: file })
}

fn write_json_atomically(path: &Path, value: &impl Serialize) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("artifact file has no parent"))?;
    let temporary = parent.join(format!(
        ".artifact-{}-{}.tmp",
        std::process::id(),
        unix_time_ns()
    ));
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)?;
    serde_json::to_writer_pretty(&mut file, value)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    fs::rename(&temporary, path)?;
    Ok(())
}

fn write_bytes_atomically(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("artifact file has no parent"))?;
    ensure_owner_only_directory(parent)?;
    let temporary = parent.join(format!(
        ".artifact-{}-{}.tmp",
        std::process::id(),
        unix_time_ns()
    ));
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    fs::rename(&temporary, path)?;
    Ok(())
}

fn new_artifact_id(socket: &Path) -> Result<String> {
    for attempt in 0..32u64 {
        let time = u64::try_from(unix_time_ns()).unwrap_or(u64::MAX);
        let value = time ^ u64::from(std::process::id()).rotate_left(17) ^ attempt.rotate_left(31);
        let id = format!("a{:012x}", value & 0x0000_ffff_ffff_ffff);
        if resolve_artifact_directory(socket, &id).is_err() {
            return Ok(id);
        }
    }
    bail!("could not allocate a unique artifact ID")
}

fn unix_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn unix_time_ns() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn format_bytes(bytes: u64) -> String {
    if bytes >= 1024 * 1024 {
        format!("{:.1} MiB", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{:.1} KiB", bytes as f64 / 1024.0)
    } else {
        format!("{bytes} B")
    }
}

fn terminal_size() -> (Option<u16>, Option<u16>) {
    let mut size = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: `size` is a valid output buffer and stdout is a valid process descriptor.
    let status = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut size) };
    if status == 0 {
        (
            (size.ws_col > 0).then_some(size.ws_col),
            (size.ws_row > 0).then_some(size.ws_row),
        )
    } else {
        (None, None)
    }
}

fn stdin_is_terminal() -> bool {
    // SAFETY: `isatty` accepts any file descriptor and has no ownership effect.
    unsafe { libc::isatty(libc::STDIN_FILENO) == 1 }
}

fn stdout_is_terminal() -> bool {
    // SAFETY: `isatty` accepts any file descriptor and has no ownership effect.
    unsafe { libc::isatty(libc::STDOUT_FILENO) == 1 }
}

struct TerminalPresentation {
    original: libc::termios,
}

impl TerminalPresentation {
    fn enter() -> Result<Self> {
        // SAFETY: zeroed termios is immediately initialized by `tcgetattr` before use.
        let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
        // SAFETY: `original` is a valid output buffer and stdin is not aliased here.
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        let mut raw = original;
        raw.c_lflag &= !(libc::ICANON | libc::ECHO);
        raw.c_cc[libc::VMIN] = 1;
        raw.c_cc[libc::VTIME] = 0;
        // SAFETY: `raw` is initialized and stdin remains open for this process.
        if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        let mut stdout = io::stdout().lock();
        stdout.write_all(b"\x1b[?1049h")?;
        stdout.flush()?;
        Ok(Self { original })
    }
}

impl Drop for TerminalPresentation {
    fn drop(&mut self) {
        // SAFETY: the saved termios came from this stdin descriptor and remains initialized.
        unsafe {
            libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &self.original);
        }
        let _ = io::stdout().write_all(b"\x1b[?25h\x1b[?1049l");
        let _ = io::stdout().flush();
    }
}

fn wait_until_closed() -> Result<()> {
    let mut bytes = [0u8; 64];
    while io::stdin().read(&mut bytes)? != 0 {
        // GUI artifact panes own dismissal through their shared pane close
        // action. Standalone viewers remain interruptible through Ctrl-C.
    }
    Ok(())
}

fn effective_uid() -> u32 {
    // SAFETY: `geteuid` has no preconditions.
    unsafe { libc::geteuid() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new(label: &str) -> Self {
            let path = env::temp_dir().join(format!(
                "satin-artifact-{label}-{}-{}",
                std::process::id(),
                unix_time_ns()
            ));
            fs::create_dir(&path).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
            Self(path)
        }

        fn socket(&self) -> PathBuf {
            self.0.join("control.sock")
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn register_markdown_version(
        directory: &TestDirectory,
        source: &Path,
        id: Option<&str>,
        title: &str,
    ) -> ArtifactManifest {
        register_artifact(
            &directory.socket(),
            &ArtifactPolicy::default(),
            RegisterArtifact {
                id,
                kind: ArtifactKind::Markdown,
                title,
                language: Some("en-US"),
                source,
                owner_tab: Some(1),
                owner_pane: Some(2),
            },
        )
        .unwrap()
    }

    fn write_test_png(path: &Path, red: u8) {
        let file = File::create(path).unwrap();
        let mut encoder = png::Encoder::new(file, 8, 4);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().unwrap();
        let pixel = [red, 120, 220, 255];
        writer.write_image_data(&pixel.repeat(32)).unwrap();
    }

    #[test]
    fn policy_round_trips_next_to_the_socket() {
        let directory = TestDirectory::new("policy");
        let policy = ArtifactPolicy {
            max_columns: 96,
            max_rows: 40,
            language: "ja-JP".to_owned(),
            overflow: ArtifactOverflow::Reject,
        };

        save_policy(&directory.socket(), &policy).unwrap();

        assert_eq!(load_policy(&directory.socket()).unwrap(), policy);
    }

    #[test]
    fn bounded_source_read_enforces_the_limit_on_the_open_file() {
        let directory = TestDirectory::new("bounded-read");
        let source = directory.0.join("source.txt");
        fs::write(&source, b"1234").unwrap();

        assert_eq!(read_bounded_source(&source, 4, "test").unwrap(), b"1234");
        let error = read_bounded_source(&source, 3, "test").unwrap_err();
        assert!(error.to_string().contains("3-byte preview limit"));
    }

    #[test]
    fn artifact_listing_reports_an_unreadable_store() {
        let directory = TestDirectory::new("invalid-store");
        fs::write(directory.0.join("artifacts"), b"not a directory").unwrap();

        let error = list_artifacts(&directory.socket(), None).unwrap_err();
        assert!(error.to_string().contains("open artifact store"));
    }

    #[test]
    fn markdown_preview_obeys_cell_and_row_bounds() {
        let directory = TestDirectory::new("markdown");
        let source = directory.0.join("report.md");
        fs::write(
            &source,
            "# 結論\n日本語の文章を一画面に収めて表示します。\n- 次の操作を確認\n",
        )
        .unwrap();
        let policy = ArtifactPolicy {
            language: "ja-JP".to_owned(),
            ..ArtifactPolicy::default()
        };
        let manifest = register_artifact(
            &directory.socket(),
            &policy,
            RegisterArtifact {
                id: None,
                kind: ArtifactKind::Markdown,
                title: "調査結果",
                language: None,
                source: &source,
                owner_tab: Some(1),
                owner_pane: Some(2),
            },
        )
        .unwrap();
        let rendered = render_artifact(&manifest, &policy, Some(40), Some(12)).unwrap();

        assert_eq!(rendered.plain_lines.len(), 12);
        assert!(
            rendered
                .plain_lines
                .iter()
                .any(|line| line.contains("調査結果"))
        );
        assert!(
            rendered
                .plain_lines
                .iter()
                .all(|line| UnicodeWidthStr::width(line.as_str()) <= 40)
        );
    }

    #[test]
    fn viewer_uses_pane_dimensions_without_card_chrome() {
        let directory = TestDirectory::new("pane-width");
        let source = directory.0.join("wide.txt");
        fs::write(&source, format!("{}\n", "x".repeat(100))).unwrap();
        let policy = ArtifactPolicy::default();
        let manifest = register_artifact(
            &directory.socket(),
            &policy,
            RegisterArtifact {
                id: None,
                kind: ArtifactKind::Text,
                title: "Wide artifact",
                language: Some("en-US"),
                source: &source,
                owner_tab: None,
                owner_pane: None,
            },
        )
        .unwrap();

        let rendered = render_artifact(&manifest, &policy, Some(120), Some(20)).unwrap();
        let screen = rendered.plain_lines.join("\n");

        assert_eq!(rendered.plain_lines.len(), 20);
        assert!(
            rendered
                .plain_lines
                .iter()
                .all(|line| UnicodeWidthStr::width(line.as_str()) == 120)
        );
        assert!(screen.contains(&"x".repeat(100)));
        assert!(!screen.contains("q close"));
        assert!(!screen.contains('╭'));
        assert!(!screen.contains('╰'));
        assert!(
            rendered
                .plain_lines
                .iter()
                .all(|line| !line.starts_with('│') && !line.ends_with('│'))
        );
    }

    #[test]
    fn rich_markdown_snapshots_images_and_renders_structured_blocks() {
        let directory = TestDirectory::new("rich-markdown");
        let source_root = directory.0.join("source");
        let image_root = source_root.join("images");
        fs::create_dir_all(&image_root).unwrap();
        let source = source_root.join("report.md");
        let image = image_root.join("chart.png");
        write_test_png(&image, 40);
        fs::write(
            &source,
            "# Rich report\n\nStatus **first**, *reviewed*, ~~stale~~, run `cargo test`.\n\n| Check | Result |\n|---|---|\n| tests | pass |\n\n```rust\nlet answer = \"yes\";\nassert_eq!(answer, \"yes\");\n```\n\n![Trend](images/chart.png)\n",
        )
        .unwrap();
        let policy = ArtifactPolicy::default();
        let first = register_artifact(
            &directory.socket(),
            &policy,
            RegisterArtifact {
                id: None,
                kind: ArtifactKind::Markdown,
                title: "Rich report",
                language: Some("en-US"),
                source: &source,
                owner_tab: None,
                owner_pane: None,
            },
        )
        .unwrap();
        write_test_png(&image, 200);
        let second = register_markdown_version(&directory, &source, Some(&first.id), "Rich report");
        fs::remove_dir_all(source_root).unwrap();

        assert_eq!(second.version, 2);
        assert_eq!(second.assets.len(), 1);
        assert!(Path::new(&second.assets[0]).exists());
        let artifact_directory = Path::new(&second.document)
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .parent()
            .unwrap();
        assert!(artifact_directory.join("images/chart.png").exists());
        let rendered = render_artifact(&second, &policy, None, None).unwrap();
        let screen = rendered.plain_lines.join("\n");
        assert!(screen.contains("Check"));
        assert!(screen.contains("┌─ rust"));
        assert!(screen.contains("cargo test"));
        assert!(rendered.ansi.contains("\x1b[3m"));
        assert!(rendered.ansi.contains("\x1b[9m"));
        assert!(rendered.ansi.contains("\x1b[48;2;38;48;61m"));
        assert_eq!(rendered.plain_lines.len(), 32);
        assert!(
            rendered
                .plain_lines
                .iter()
                .all(|line| UnicodeWidthStr::width(line.as_str()) <= 80)
        );
        assert!(rendered.ansi.contains("\x1b_Ga=T,f=100"));
    }

    #[test]
    fn table_preview_reports_omitted_rows() {
        let directory = TestDirectory::new("table");
        let source = directory.0.join("results.json");
        let values = (0..40)
            .map(|index| json!({"test": format!("case-{index}"), "status": "passed"}))
            .collect::<Vec<_>>();
        fs::write(&source, serde_json::to_vec(&values).unwrap()).unwrap();
        let policy = ArtifactPolicy::default();
        let manifest = register_artifact(
            &directory.socket(),
            &policy,
            RegisterArtifact {
                id: None,
                kind: ArtifactKind::Table,
                title: "Tests",
                language: Some("en-US"),
                source: &source,
                owner_tab: None,
                owner_pane: None,
            },
        )
        .unwrap();

        assert_eq!(manifest.preview.status, ArtifactPreviewStatus::Compacted);
        assert!(manifest.preview.omitted_items > 0);
    }

    #[test]
    fn table_preview_reports_cells_that_do_not_fit() {
        let directory = TestDirectory::new("wide-table");
        let source = directory.0.join("results.json");
        fs::write(
            &source,
            serde_json::to_vec(&vec![json!({"message": "x".repeat(200)})]).unwrap(),
        )
        .unwrap();
        let manifest = register_artifact(
            &directory.socket(),
            &ArtifactPolicy::default(),
            RegisterArtifact {
                id: None,
                kind: ArtifactKind::Table,
                title: "Wide cell",
                language: Some("en-US"),
                source: &source,
                owner_tab: None,
                owner_pane: None,
            },
        )
        .unwrap();

        assert_eq!(manifest.preview.status, ArtifactPreviewStatus::Compacted);
        assert_eq!(manifest.preview.omitted_items, 1);
    }

    #[test]
    fn versions_are_snapshotted_and_listed_in_human_readable_directories() {
        let directory = TestDirectory::new("versions");
        let source = directory.0.join("report.md");
        fs::write(&source, "# Result\n\nFirst version.\n").unwrap();
        let first = register_markdown_version(&directory, &source, None, "Renderer Notes");
        fs::write(&source, "# Result\n\nSecond version.\n").unwrap();
        let second =
            register_markdown_version(&directory, &source, Some(&first.id), "Renderer Notes");
        let unchanged =
            register_markdown_version(&directory, &source, Some(&first.id), "Renderer Notes");

        assert_eq!(first.version, 1);
        assert_eq!(second.version, 2);
        assert_eq!(unchanged.version, 2);
        assert!(
            fs::read_to_string(&first.document)
                .unwrap()
                .contains("First version")
        );
        assert!(
            fs::read_to_string(&second.document)
                .unwrap()
                .contains("Second version")
        );
        let artifacts = list_artifacts(&directory.socket(), None).unwrap();
        assert_eq!(artifacts.len(), 1);
        assert_eq!(artifacts[0].version_count, 2);
        assert!(
            Path::new(&artifacts[0].directory)
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("renderer-notes--")
        );
        let root = artifact_root(&directory.socket()).unwrap();
        assert!(
            fs::read_to_string(root.join("INDEX.md"))
                .unwrap()
                .contains("Renderer Notes")
        );
        assert!(
            fs::read_to_string(Path::new(&artifacts[0].directory).join("README.md"))
                .unwrap()
                .contains("[v2]")
        );
    }

    #[test]
    fn concurrent_updates_receive_distinct_versions() {
        let directory = TestDirectory::new("concurrent-versions");
        let initial_source = directory.0.join("initial.md");
        fs::write(&initial_source, "# Initial\n").unwrap();
        let initial =
            register_markdown_version(&directory, &initial_source, None, "Concurrent notes");
        let first_source = directory.0.join("first.md");
        let second_source = directory.0.join("second.md");
        fs::write(&first_source, "# First update\n").unwrap();
        fs::write(&second_source, "# Second update\n").unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let spawn_registration = |source: PathBuf| {
            let barrier = barrier.clone();
            let socket = directory.socket();
            let id = initial.id.clone();
            std::thread::spawn(move || {
                barrier.wait();
                register_artifact(
                    &socket,
                    &ArtifactPolicy::default(),
                    RegisterArtifact {
                        id: Some(&id),
                        kind: ArtifactKind::Markdown,
                        title: "Concurrent notes",
                        language: Some("en-US"),
                        source: &source,
                        owner_tab: None,
                        owner_pane: None,
                    },
                )
                .unwrap()
                .version
            })
        };

        let first = spawn_registration(first_source);
        let second = spawn_registration(second_source);
        let mut versions = [first.join().unwrap(), second.join().unwrap()];
        versions.sort_unstable();

        assert_eq!(versions, [2, 3]);
        assert_eq!(
            load_stored_artifact(&directory.socket(), &initial.id)
                .unwrap()
                .versions
                .len(),
            3
        );
    }

    #[test]
    fn table_snapshot_keeps_markdown_and_raw_source() {
        let directory = TestDirectory::new("table-markdown");
        let source = directory.0.join("results.json");
        fs::write(&source, r#"[{"name":"smoke","status":"passed"}]"#).unwrap();
        let manifest = register_artifact(
            &directory.socket(),
            &ArtifactPolicy::default(),
            RegisterArtifact {
                id: None,
                kind: ArtifactKind::Table,
                title: "Test Results",
                language: Some("en-US"),
                source: &source,
                owner_tab: None,
                owner_pane: None,
            },
        )
        .unwrap();
        fs::remove_file(source).unwrap();

        let document = fs::read_to_string(&manifest.document).unwrap();
        assert!(document.contains("| name | status |"));
        assert!(Path::new(&manifest.source).exists());
        assert!(render_artifact(&manifest, &ArtifactPolicy::default(), None, None).is_ok());
    }

    #[test]
    fn reject_policy_does_not_register_an_oversized_preview() {
        let directory = TestDirectory::new("reject");
        let source = directory.0.join("long.txt");
        fs::write(&source, "line\n".repeat(100)).unwrap();
        let policy = ArtifactPolicy {
            overflow: ArtifactOverflow::Reject,
            ..ArtifactPolicy::default()
        };

        let error = register_artifact(
            &directory.socket(),
            &policy,
            RegisterArtifact {
                id: None,
                kind: ArtifactKind::Text,
                title: "Long",
                language: None,
                source: &source,
                owner_tab: None,
                owner_pane: None,
            },
        )
        .unwrap_err();

        assert!(error.to_string().contains("exceeds the configured bounds"));
        assert!(!directory.0.join("artifacts").exists());
    }
}
