// Font shaping, fallback, and cache structure adapted from Neovide's
// MIT-licensed renderer. Copyright (c) 2023 Neovide Contributors.
// See THIRD_PARTY_NOTICES.md for the audited source revision and license.

mod block_elements;
#[cfg(test)]
mod block_elements_regression_tests;
mod decorations;

use crate::{
    neovide_render::NeovideLine,
    terminal_runtime::{TerminalCellSnapshot, TerminalCellStyle, TerminalColor},
};
use lru::LruCache;
use skia_safe::{
    Canvas, Color, Data, Font, FontHinting as SkiaHinting, FontMgr, FontStyle, Paint, Point,
    TextBlob, TextBlobBuilder, Typeface,
    font::Edging as SkiaEdging,
    graphics::{font_cache_limit, font_cache_used, set_font_cache_limit},
};
use std::{
    collections::HashSet,
    env, fs,
    hash::{Hash, Hasher},
    num::NonZeroUsize,
    rc::Rc,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use swash::{
    Metrics,
    shape::ShapeContext,
    text::{
        Script,
        cluster::{CharCluster, Parser, Status, Token},
    },
};

const DEFAULT_FONT: &[u8] = include_bytes!("../assets/fonts/FiraCodeNerdFont-Regular.ttf");
const LAST_RESORT_FONT: &[u8] = include_bytes!("../assets/fonts/LastResort-Regular.ttf");
const FONT_CACHE_SIZE: usize = 8 * 1024 * 1024;
const SHAPE_CACHE_ENTRIES: usize = 10_000;
const PREPARED_LINE_CACHE_ENTRIES: usize = 1_024;
const FONT_SIZE_RATIO: f32 = 0.82;
const FLOAT_EPSILON: f32 = 0.01;

#[derive(Clone, Copy, Debug, Default)]
pub struct TextGridGeometry {
    pub origin_x: f32,
    pub origin_y: f32,
    pub cell_width: f32,
    pub cell_height: f32,
}

pub struct NeovideTextRenderer {
    shaper: CachingShaper,
    geometry: TextGridGeometry,
    prepared_lines: LruCache<PreparedLineKey, Vec<PreparedTextRun>>,
}

impl NeovideTextRenderer {
    pub fn new() -> Self {
        Self {
            shaper: CachingShaper::new(),
            geometry: TextGridGeometry::default(),
            prepared_lines: LruCache::new(NonZeroUsize::new(PREPARED_LINE_CACHE_ENTRIES).unwrap()),
        }
    }

    pub fn update_geometry(&mut self, geometry: TextGridGeometry) {
        let grid_changed = !same_float(self.geometry.cell_width, geometry.cell_width)
            || !same_float(self.geometry.cell_height, geometry.cell_height);
        self.geometry = geometry;
        self.shaper
            .update_grid(font_size(geometry), geometry.cell_width);
        if grid_changed {
            self.prepared_lines.clear();
        }
    }

    pub fn set_primary_font_family(&mut self, family: Option<&str>) {
        if self.shaper.set_primary_font_family(family) {
            self.prepared_lines.clear();
        }
    }

    pub fn draw_line(
        &mut self,
        canvas: &Canvas,
        line: &NeovideLine,
        row: f32,
        window_left: usize,
        width: usize,
    ) {
        let key = PreparedLineKey::new(line, width);
        let baseline = self.shaper.baseline_offset();
        let geometry = self.geometry;
        block_elements::draw_line(canvas, &line.cells, key.width, row, window_left, geometry);
        if let Some(runs) = self.prepared_lines.get(&key) {
            for run in runs {
                Self::draw_run(canvas, run, row, window_left, baseline, geometry);
            }
            return;
        }

        let prepared = self.prepare_line(&line.cells, key.width);
        for run in &prepared {
            Self::draw_run(canvas, run, row, window_left, baseline, geometry);
        }
        self.prepared_lines.put(key, prepared);
    }

    pub fn cleanup_font_cache(&self) {
        self.shaper.cleanup_font_cache();
    }

    fn prepare_line(
        &mut self,
        cells: &[TerminalCellSnapshot],
        width: usize,
    ) -> Vec<PreparedTextRun> {
        collect_text_runs(cells, width)
            .into_iter()
            .map(|run| {
                let cell_count = run.key.cells.len();
                let blobs = self.shaper.shape_cached(&run.key);
                PreparedTextRun {
                    start_col: run.start_col,
                    foreground: run.foreground,
                    style: run.style,
                    cell_count,
                    blobs,
                }
            })
            .collect()
    }

    fn draw_run(
        canvas: &Canvas,
        run: &PreparedTextRun,
        row: f32,
        window_left: usize,
        baseline: f32,
        geometry: TextGridGeometry,
    ) {
        if run.style.blink && !blink_text_visible() {
            return;
        }
        let origin = Self::run_origin(geometry, row, window_left + run.start_col, baseline);
        let mut paint = Paint::default();
        paint.set_anti_alias(false);
        paint.set_color(color(run.foreground));
        for blob in run.blobs.iter() {
            canvas.draw_text_blob(blob, origin, &paint);
        }
        let start_col = window_left + run.start_col;
        decorations::draw(
            canvas,
            start_col..start_col + run.cell_count,
            run.style,
            row,
            &paint,
            geometry,
        );
    }

    fn run_origin(geometry: TextGridGeometry, row: f32, col: usize, baseline: f32) -> Point {
        Point::new(
            geometry.origin_x + col as f32 * geometry.cell_width,
            geometry.origin_y + row * geometry.cell_height + baseline,
        )
    }
}

impl Default for NeovideTextRenderer {
    fn default() -> Self {
        Self::new()
    }
}

fn font_size(geometry: TextGridGeometry) -> f32 {
    (geometry.cell_height * FONT_SIZE_RATIO).max(1.0)
}

fn color(color: TerminalColor) -> Color {
    Color::from_argb(255, color.r, color.g, color.b)
}

fn blink_text_visible() -> bool {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(true, |duration| duration.as_millis() % 1_000 < 500)
}

#[derive(Debug, PartialEq, Eq)]
struct TextRun {
    start_col: usize,
    foreground: TerminalColor,
    style: TerminalCellStyle,
    key: ShapeKey,
}

#[derive(Clone, Debug)]
struct PreparedLineKey {
    cells: Arc<[TerminalCellSnapshot]>,
    width: usize,
}

impl PreparedLineKey {
    fn new(line: &NeovideLine, width: usize) -> Self {
        Self {
            cells: Arc::clone(&line.cells),
            width: width.min(line.cells.len()),
        }
    }
}

impl Hash for PreparedLineKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        (Arc::as_ptr(&self.cells) as *const TerminalCellSnapshot).hash(state);
        self.width.hash(state);
    }
}

impl PartialEq for PreparedLineKey {
    fn eq(&self, other: &Self) -> bool {
        self.width == other.width && Arc::ptr_eq(&self.cells, &other.cells)
    }
}

impl Eq for PreparedLineKey {}

struct PreparedTextRun {
    start_col: usize,
    foreground: TerminalColor,
    style: TerminalCellStyle,
    cell_count: usize,
    blobs: Arc<[TextBlob]>,
}

fn collect_text_runs(cells: &[TerminalCellSnapshot], width: usize) -> Vec<TextRun> {
    let mut runs = Vec::new();
    let mut current = TextRunBuilder::default();
    for (col, cell) in cells.iter().take(width).enumerate() {
        if cell.text.is_empty() || block_elements::is_native(&cell.text) {
            current.flush(&mut runs);
        } else {
            current.push(col, cell, &mut runs);
        }
    }
    current.flush(&mut runs);
    runs
}

#[derive(Default)]
struct TextRunBuilder {
    start_col: usize,
    foreground: Option<TerminalColor>,
    style: TerminalCellStyle,
    cells: Vec<String>,
}

impl TextRunBuilder {
    fn push(&mut self, col: usize, cell: &TerminalCellSnapshot, runs: &mut Vec<TextRun>) {
        if self.foreground != Some(cell.fg) || self.style != cell.style {
            self.flush(runs);
            self.start_col = col;
            self.foreground = Some(cell.fg);
            self.style = cell.style;
        }
        self.cells.push(cell.text.clone());
    }

    fn flush(&mut self, runs: &mut Vec<TextRun>) {
        let Some(foreground) = self.foreground.take() else {
            return;
        };
        let cells = std::mem::take(&mut self.cells);
        runs.push(TextRun {
            start_col: self.start_col,
            foreground,
            style: self.style,
            key: ShapeKey::new(cells, CoarseStyle::from_cell_style(self.style)),
        });
    }
}

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
struct ShapeKey {
    cells: Vec<String>,
    style: CoarseStyle,
}

impl ShapeKey {
    fn new(cells: Vec<String>, style: CoarseStyle) -> Self {
        Self { cells, style }
    }

    fn tokens(&self) -> Vec<Token> {
        self.cells
            .iter()
            .enumerate()
            .flat_map(|(cell_index, cell)| {
                cell.char_indices()
                    .map(move |(offset, character)| token(cell_index, offset, character))
            })
            .collect()
    }
}

fn token(cell_index: usize, offset: usize, character: char) -> Token {
    Token {
        ch: character,
        offset: offset as u32,
        len: character.len_utf8() as u8,
        info: character.into(),
        data: cell_index as u32,
    }
}

struct CachingShaper {
    primary_font_family: Option<String>,
    primary_font_path: Option<String>,
    font_loader: FontLoader,
    blob_cache: LruCache<ShapeKey, Arc<[TextBlob]>>,
    shape_context: ShapeContext,
    font_size: f32,
    cell_width: f32,
    font_metrics: Option<Metrics>,
}

impl CachingShaper {
    fn new() -> Self {
        let font_size = 14.0;
        Self {
            primary_font_family: None,
            primary_font_path: env::var("SATIN_FONT")
                .or_else(|_| env::var("NVTERM_FONT"))
                .ok(),
            font_loader: FontLoader::new(font_size),
            blob_cache: LruCache::new(NonZeroUsize::new(SHAPE_CACHE_ENTRIES).unwrap()),
            shape_context: ShapeContext::new(),
            font_size,
            cell_width: 8.0,
            font_metrics: None,
        }
    }

    fn update_grid(&mut self, font_size: f32, cell_width: f32) {
        if same_float(self.font_size, font_size) && same_float(self.cell_width, cell_width) {
            return;
        }
        self.font_size = font_size;
        self.cell_width = cell_width;
        self.reset_font_loader();
    }

    fn set_primary_font_family(&mut self, family: Option<&str>) -> bool {
        let family = family
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        if self.primary_font_family == family {
            return false;
        }
        self.primary_font_family = family;
        self.reset_font_loader();
        true
    }

    fn baseline_offset(&mut self) -> f32 {
        self.metrics().map_or(self.font_size * 0.78, |metrics| {
            metrics.ascent + metrics.leading / 2.0
        })
    }

    fn shape_cached(&mut self, key: &ShapeKey) -> Arc<[TextBlob]> {
        if let Some(blobs) = self.blob_cache.get(key) {
            return Arc::clone(blobs);
        }
        let blobs: Arc<[TextBlob]> = self.shape(key).into();
        self.blob_cache.put(key.clone(), Arc::clone(&blobs));
        blobs
    }

    fn cleanup_font_cache(&self) {
        let limit = font_cache_limit();
        let used = font_cache_used();
        if used <= limit * 9 / 10 {
            return;
        }
        set_font_cache_limit(FONT_CACHE_SIZE / 2);
        set_font_cache_limit(FONT_CACHE_SIZE);
    }

    fn reset_font_loader(&mut self) {
        self.font_loader = FontLoader::new(self.font_size);
        self.blob_cache.clear();
        self.font_metrics = None;
    }

    fn metrics(&mut self) -> Option<Metrics> {
        if self.font_metrics.is_some() {
            return self.font_metrics;
        }
        let font_pair = self.current_font_pair()?;
        let mut shaper = self
            .shape_context
            .builder(font_pair.swash_font.as_ref())
            .size(self.font_size)
            .build();
        shaper.add_str("M");
        let metrics = shaper.metrics();
        self.font_metrics = Some(metrics);
        Some(metrics)
    }

    fn current_font_pair(&mut self) -> Option<Rc<FontPair>> {
        for key in self.primary_font_keys(CoarseStyle::default()) {
            if let Some(font_pair) = self.font_loader.get_or_load(&key) {
                return Some(font_pair);
            }
        }
        None
    }

    fn shape(&mut self, key: &ShapeKey) -> Vec<TextBlob> {
        let mut blobs = Vec::new();
        for (clusters, font_pair) in self.build_cluster_groups(key) {
            let Some(blob) = self.shape_cluster_group(clusters, &font_pair) else {
                continue;
            };
            blobs.push(blob);
        }
        blobs
    }

    fn shape_cluster_group(
        &mut self,
        clusters: Vec<CharCluster>,
        font_pair: &FontPair,
    ) -> Option<TextBlob> {
        let mut shaper = self
            .shape_context
            .builder(font_pair.swash_font.as_ref())
            .size(self.font_size)
            .build();
        add_clusters_to_shaper(clusters, font_pair, &mut shaper);
        let glyph_data = collect_glyph_positions(shaper, self.cell_width);
        build_text_blob(font_pair, &glyph_data)
    }

    fn build_cluster_groups(&mut self, key: &ShapeKey) -> Vec<(Vec<CharCluster>, Rc<FontPair>)> {
        let mapped = parse_clusters(key)
            .into_iter()
            .map(|cluster| self.map_cluster_to_font(cluster, key.style))
            .collect::<Vec<_>>();
        group_clusters_by_font(mapped)
    }

    fn map_cluster_to_font(
        &mut self,
        mut cluster: CharCluster,
        style: CoarseStyle,
    ) -> (CharCluster, Rc<FontPair>) {
        if let Some(font) = self.primary_font_for_cluster(&mut cluster, style) {
            return (cluster, font);
        }
        if let Some(font) = self.loaded_font_for_cluster(&mut cluster) {
            return (cluster, font);
        }
        let font = self.character_fallback_font(&cluster, style);
        map_cluster(&mut cluster, &font);
        (cluster, font)
    }

    fn primary_font_for_cluster(
        &mut self,
        cluster: &mut CharCluster,
        style: CoarseStyle,
    ) -> Option<Rc<FontPair>> {
        let mut best = None;
        for key in self.primary_font_keys(style) {
            let Some(font) = self.font_loader.get_or_load(&key) else {
                continue;
            };
            match map_cluster(cluster, &font) {
                Status::Complete => return Some(font),
                Status::Keep => best = Some(font),
                Status::Discard => {}
            }
        }
        best
    }

    fn loaded_font_for_cluster(&mut self, cluster: &mut CharCluster) -> Option<Rc<FontPair>> {
        let mut best = None;
        for font in self.font_loader.loaded_fonts() {
            match map_cluster(cluster, &font) {
                Status::Complete => {
                    self.font_loader.refresh(&font);
                    return Some(font);
                }
                Status::Keep => best = Some(font),
                Status::Discard => {}
            }
        }
        best
    }

    fn character_fallback_font(
        &mut self,
        cluster: &CharCluster,
        style: CoarseStyle,
    ) -> Rc<FontPair> {
        let character = cluster.chars().first().map_or('\u{FFFD}', |ch| ch.ch);
        self.font_loader
            .load_font_for_character(style, character)
            .or_else(|| self.font_loader.get_or_load_last_resort())
            .expect("bundled LastResort font must load")
    }

    fn primary_font_keys(&self, style: CoarseStyle) -> Vec<FontKey> {
        let mut keys = Vec::new();
        if let Some(family) = &self.primary_font_family {
            keys.push(FontKey::Family {
                family: family.clone(),
                style,
            });
        }
        if let Some(path) = &self.primary_font_path {
            keys.push(FontKey::Path(path.clone()));
        }
        keys.push(FontKey::BundledDefault(style));
        keys
    }
}

fn same_float(left: f32, right: f32) -> bool {
    (left - right).abs() < FLOAT_EPSILON
}

fn parse_clusters(key: &ShapeKey) -> Vec<CharCluster> {
    let mut parser = Parser::new(Script::Latin, key.tokens().into_iter());
    let mut cluster = CharCluster::new();
    let mut clusters = Vec::new();
    while parser.next(&mut cluster) {
        clusters.push(cluster.to_owned());
    }
    clusters
}

fn map_cluster(cluster: &mut CharCluster, font_pair: &FontPair) -> Status {
    let charmap = font_pair.swash_font.as_ref().charmap();
    cluster.map(|ch| charmap.map(ch))
}

fn group_clusters_by_font(
    mapped: Vec<(CharCluster, Rc<FontPair>)>,
) -> Vec<(Vec<CharCluster>, Rc<FontPair>)> {
    let mut grouped = Vec::new();
    let mut current_clusters = Vec::new();
    let mut current_font = None;
    for (cluster, font) in mapped {
        if current_font
            .as_ref()
            .is_some_and(|current| current != &font)
        {
            flush_cluster_group(&mut grouped, &mut current_clusters, &mut current_font);
        }
        current_clusters.push(cluster);
        current_font = Some(font);
    }
    flush_cluster_group(&mut grouped, &mut current_clusters, &mut current_font);
    grouped
}

fn flush_cluster_group(
    grouped: &mut Vec<(Vec<CharCluster>, Rc<FontPair>)>,
    clusters: &mut Vec<CharCluster>,
    font: &mut Option<Rc<FontPair>>,
) {
    let Some(font) = font.take() else {
        return;
    };
    if !clusters.is_empty() {
        grouped.push((std::mem::take(clusters), font));
    }
}

fn add_clusters_to_shaper(
    clusters: Vec<CharCluster>,
    font_pair: &FontPair,
    shaper: &mut swash::shape::Shaper<'_>,
) {
    let charmap = font_pair.swash_font.as_ref().charmap();
    for mut cluster in clusters {
        cluster.map(|ch| charmap.map(ch));
        shaper.add_cluster(&cluster);
    }
}

fn collect_glyph_positions(shaper: swash::shape::Shaper<'_>, cell_width: f32) -> Vec<(u16, Point)> {
    let mut glyph_data = Vec::new();
    shaper.shape_with(|glyph_cluster| {
        let mut x_offset = cell_width * glyph_cluster.data as f32;
        for glyph in glyph_cluster.glyphs {
            glyph_data.push((glyph.id, Point::new(x_offset + glyph.x, -glyph.y)));
            x_offset += glyph.advance;
        }
    });
    glyph_data
}

fn build_text_blob(font_pair: &FontPair, glyph_data: &[(u16, Point)]) -> Option<TextBlob> {
    if glyph_data.is_empty() {
        return None;
    }
    let mut blob_builder = TextBlobBuilder::new();
    let (glyphs, positions) =
        blob_builder.alloc_run_pos(&font_pair.skia_font, glyph_data.len(), None);
    for (index, (glyph_id, position)) in glyph_data.iter().enumerate() {
        glyphs[index] = *glyph_id;
        positions[index] = *position;
    }
    blob_builder.make()
}

struct FontLoader {
    font_mgr: FontMgr,
    cache: LruCache<FontKey, Rc<FontPair>>,
    failed_fonts: HashSet<FontKey>,
    font_size: f32,
}

impl FontLoader {
    fn new(font_size: f32) -> Self {
        Self {
            font_mgr: FontMgr::new(),
            cache: LruCache::new(NonZeroUsize::new(24).unwrap()),
            failed_fonts: HashSet::new(),
            font_size,
        }
    }

    fn get_or_load(&mut self, key: &FontKey) -> Option<Rc<FontPair>> {
        if let Some(font_pair) = self.cache.get(key) {
            return Some(font_pair.clone());
        }
        if self.failed_fonts.contains(key) {
            return None;
        }
        let font = self.load(key.clone())?;
        let font_pair = Rc::new(font);
        self.cache.put(key.clone(), font_pair.clone());
        self.failed_fonts.remove(key);
        Some(font_pair)
    }

    fn load_font_for_character(
        &mut self,
        style: CoarseStyle,
        character: char,
    ) -> Option<Rc<FontPair>> {
        let typeface =
            self.font_mgr
                .match_family_style_character("", style.into(), &[], character as i32)?;
        let family = typeface.family_name();
        let key = FontKey::Family { family, style };
        let font_pair = Rc::new(FontPair::new(
            key.clone(),
            Font::from_typeface(typeface, self.font_size),
        )?);
        self.cache.put(key, font_pair.clone());
        Some(font_pair)
    }

    fn get_or_load_last_resort(&mut self) -> Option<Rc<FontPair>> {
        self.get_or_load(&FontKey::LastResort)
    }

    fn loaded_fonts(&self) -> Vec<Rc<FontPair>> {
        self.cache
            .iter()
            .map(|(_, font_pair)| font_pair.clone())
            .collect()
    }

    fn refresh(&mut self, font_pair: &FontPair) {
        let _ = self.cache.get(&font_pair.key);
    }

    fn load(&mut self, key: FontKey) -> Option<FontPair> {
        let typeface = match &key {
            FontKey::Path(path) => typeface_from_path(&self.font_mgr, path)?,
            FontKey::Family { family, style } => {
                self.font_mgr.match_family_style(family, (*style).into())?
            }
            FontKey::BundledDefault(_) => typeface_from_bytes(&self.font_mgr, DEFAULT_FONT)?,
            FontKey::LastResort => typeface_from_bytes(&self.font_mgr, LAST_RESORT_FONT)?,
        };
        FontPair::new(key, Font::from_typeface(typeface, self.font_size))
    }
}

fn typeface_from_path(font_mgr: &FontMgr, path: &str) -> Option<Typeface> {
    let bytes = fs::read(path).ok()?;
    let data = Data::new_copy(&bytes);
    font_mgr.new_from_data(&data, 0)
}

fn typeface_from_bytes(font_mgr: &FontMgr, bytes: &[u8]) -> Option<Typeface> {
    let data = Data::new_copy(bytes);
    font_mgr.new_from_data(&data, 0)
}

struct FontPair {
    key: FontKey,
    skia_font: Font,
    swash_font: SwashFont,
}

impl FontPair {
    fn new(key: FontKey, mut skia_font: Font) -> Option<Self> {
        skia_font.set_subpixel(true);
        skia_font.set_baseline_snap(true);
        skia_font.set_hinting(SkiaHinting::Full);
        skia_font.set_edging(SkiaEdging::AntiAlias);
        let typeface = skia_font.typeface();
        let (font_data, index) = typeface.to_font_data()?;
        let swash_font = SwashFont::from_data(font_data, index & 0xFFFF)?;
        Some(Self {
            key,
            skia_font,
            swash_font,
        })
    }
}

impl PartialEq for FontPair {
    fn eq(&self, other: &Self) -> bool {
        self.swash_font.key == other.swash_font.key
    }
}

impl Eq for FontPair {}

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
enum FontKey {
    Path(String),
    Family { family: String, style: CoarseStyle },
    BundledDefault(CoarseStyle),
    LastResort,
}

#[derive(Clone, Copy, Debug, Default, Hash, PartialEq, Eq)]
struct CoarseStyle {
    bold: bool,
    italic: bool,
}

impl CoarseStyle {
    fn from_cell_style(style: TerminalCellStyle) -> Self {
        Self {
            bold: style.bold,
            italic: style.italic,
        }
    }
}

impl From<CoarseStyle> for FontStyle {
    fn from(style: CoarseStyle) -> Self {
        match (style.bold, style.italic) {
            (true, true) => FontStyle::bold_italic(),
            (true, false) => FontStyle::bold(),
            (false, true) => FontStyle::italic(),
            (false, false) => FontStyle::normal(),
        }
    }
}

struct SwashFont {
    data: Vec<u8>,
    offset: u32,
    key: swash::CacheKey,
}

impl SwashFont {
    fn from_data(data: Vec<u8>, index: usize) -> Option<Self> {
        let font = swash::FontRef::from_index(&data, index)?;
        let offset = font.offset;
        let key = font.key;
        Some(Self { data, offset, key })
    }

    fn as_ref(&self) -> swash::FontRef<'_> {
        swash::FontRef {
            data: &self.data,
            offset: self.offset,
            key: self.key,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell(text: &str, fg: TerminalColor) -> TerminalCellSnapshot {
        styled_cell(text, fg, TerminalCellStyle::default())
    }

    fn styled_cell(
        text: &str,
        fg: TerminalColor,
        style: TerminalCellStyle,
    ) -> TerminalCellSnapshot {
        TerminalCellSnapshot {
            text: text.to_owned(),
            fg,
            bg: None,
            blend: 0,
            style,
        }
    }

    fn red() -> TerminalColor {
        TerminalColor { r: 255, g: 0, b: 0 }
    }

    fn blue() -> TerminalColor {
        TerminalColor { r: 0, g: 0, b: 255 }
    }

    fn bold() -> TerminalCellStyle {
        TerminalCellStyle {
            bold: true,
            ..TerminalCellStyle::default()
        }
    }

    #[test]
    fn text_runs_split_on_empty_cells_and_color_changes() {
        let cells = vec![
            cell("a", red()),
            cell("b", red()),
            cell("", red()),
            cell("c", red()),
            cell("d", blue()),
        ];
        let runs = collect_text_runs(&cells, cells.len());

        assert_eq!(runs.len(), 3);
        assert_eq!(runs[0].start_col, 0);
        assert_eq!(runs[0].key.cells, vec!["a", "b"]);
        assert_eq!(runs[1].start_col, 3);
        assert_eq!(runs[1].key.cells, vec!["c"]);
        assert_eq!(runs[2].start_col, 4);
        assert_eq!(runs[2].foreground, blue());
    }

    #[test]
    fn text_runs_split_on_style_changes() {
        let cells = vec![cell("a", red()), styled_cell("b", red(), bold())];
        let runs = collect_text_runs(&cells, cells.len());

        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].key.style, CoarseStyle::default());
        assert_eq!(runs[1].key.style, CoarseStyle::from_cell_style(bold()));
    }

    #[test]
    fn prepared_lines_are_reused_and_invalidated_with_grid_geometry() {
        let cells = vec![cell("a", red()), styled_cell("b", blue(), bold())];
        let first = NeovideLine::from_cells(cells);
        let equivalent = first.clone();
        let mut renderer = NeovideTextRenderer::new();
        renderer.update_geometry(TextGridGeometry {
            origin_x: 0.0,
            origin_y: 0.0,
            cell_width: 8.0,
            cell_height: 16.0,
        });
        let mut surface = skia_safe::surfaces::raster_n32_premul((80, 32)).unwrap();

        renderer.draw_line(surface.canvas(), &first, 0.0, 0, 2);
        renderer.draw_line(surface.canvas(), &equivalent, 1.0, 0, 2);

        assert_eq!(renderer.prepared_lines.len(), 1);

        renderer.update_geometry(TextGridGeometry {
            origin_x: 0.0,
            origin_y: 0.0,
            cell_width: 9.0,
            cell_height: 18.0,
        });

        assert!(renderer.prepared_lines.is_empty());
    }

    #[test]
    fn shaper_returns_blobs_for_latin_cjk_nerd_and_combining_text() {
        let mut shaper = CachingShaper::new();
        shaper.update_grid(14.0, 8.0);
        for cells in [
            vec!["A".to_owned()],
            vec!["日".to_owned()],
            vec!["\u{e0b0}".to_owned()],
            vec!["e\u{301}".to_owned()],
        ] {
            assert!(
                !shaper
                    .shape_cached(&ShapeKey::new(cells, CoarseStyle::default()))
                    .is_empty()
            );
        }
    }
}
