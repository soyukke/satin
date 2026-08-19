use serde::Serialize;
use std::{ops::Range, sync::Arc};

use crate::terminal_runtime::{TerminalCellSnapshot, TerminalColor, TerminalCursorSnapshot};

pub const SCROLL_ANIMATION_LENGTH_SECONDS: f32 = 0.3;

// Neovide-derived rendering boundary.
//
// The command model, retained window line cache, and critically damped spring
// follow Neovide's MIT-licensed renderer architecture:
// https://github.com/neovide/neovide
// Copyright (c) 2023 Neovide Contributors.

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum NeovideWindowDrawCommand {
    Position {
        top: usize,
        left: usize,
        width: usize,
        height: usize,
        window_kind: NeovideWindowKind,
        zindex: i64,
        compindex: i64,
    },
    DrawLine {
        row: usize,
        line: NeovideLine,
    },
    Scroll {
        top: usize,
        bottom: usize,
        left: usize,
        right: usize,
        rows: isize,
        cols: isize,
    },
    Clear,
    Show,
    Hide,
    Close,
    Viewport {
        scroll_delta: isize,
    },
    ViewportMargins {
        top: usize,
        bottom: usize,
        left: usize,
        right: usize,
    },
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NeovideWindowKind {
    Normal,
    Float,
    Message,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct NeovideLine {
    pub text: Arc<str>,
    pub cells: Arc<[TerminalCellSnapshot]>,
    #[serde(skip)]
    background_runs: Arc<[NeovideBackgroundRun]>,
    #[serde(skip)]
    has_blink: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct NeovideBackgroundRun {
    pub start_col: usize,
    pub end_col: usize,
    pub background: TerminalColor,
    pub blend: u8,
}

impl NeovideLine {
    pub fn from_cells(cells: Vec<TerminalCellSnapshot>) -> Self {
        Self::from_shared_cells(cells.into())
    }

    pub fn from_shared_cells(cells: Arc<[TerminalCellSnapshot]>) -> Self {
        let mut text = String::new();
        let mut background_runs = Vec::new();
        let mut current_background = None;
        let mut has_blink = false;

        for (col, cell) in cells.iter().enumerate() {
            text.push_str(&cell.text);
            has_blink |= cell.style.blink;

            let next_background = cell.bg.map(|background| (background, cell.blend));
            if next_background
                == current_background.map(|(_, background, blend)| (background, blend))
            {
                continue;
            }
            if let Some((start_col, background, blend)) = current_background {
                background_runs.push(NeovideBackgroundRun {
                    start_col,
                    end_col: col,
                    background,
                    blend,
                });
            }
            current_background =
                next_background.map(|(background, blend)| (col, background, blend));
        }
        if let Some((start_col, background, blend)) = current_background {
            background_runs.push(NeovideBackgroundRun {
                start_col,
                end_col: cells.len(),
                background,
                blend,
            });
        }

        Self {
            text: text.into(),
            cells,
            background_runs: background_runs.into(),
            has_blink,
        }
    }

    pub(crate) fn background_runs(&self) -> &[NeovideBackgroundRun] {
        &self.background_runs
    }

    pub(crate) fn has_blink(&self) -> bool {
        self.has_blink
    }
}

#[derive(Clone, Debug)]
pub struct NeovideRenderedWindowCache {
    height: usize,
    width: usize,
    lines: NeovideRingBuffer<Option<NeovideLine>>,
    scrollback_lines: NeovideRingBuffer<Option<NeovideLine>>,
    scroll_delta: isize,
    viewport_margins: NeovideViewportMargins,
    hidden: bool,
    pub scroll_animation: CriticallyDampedSpringAnimation,
}

impl NeovideRenderedWindowCache {
    pub fn new(width: usize, height: usize) -> Self {
        let mut cache = Self {
            height: 0,
            width: 0,
            lines: NeovideRingBuffer::new(0, None),
            scrollback_lines: NeovideRingBuffer::new(0, None),
            scroll_delta: 0,
            viewport_margins: NeovideViewportMargins::default(),
            hidden: false,
            scroll_animation: CriticallyDampedSpringAnimation::new(),
        };
        cache.resize(width, height);
        cache
    }

    pub fn apply(&mut self, command: &NeovideWindowDrawCommand) {
        match command {
            NeovideWindowDrawCommand::Position { width, height, .. } => {
                self.resize(*width, *height);
            }
            NeovideWindowDrawCommand::DrawLine { row, line } => self.draw_line(*row, line.clone()),
            NeovideWindowDrawCommand::Scroll {
                top,
                bottom,
                left,
                right,
                rows,
                cols,
            } => self.scroll(*top, *bottom, *left, *right, *rows, *cols),
            NeovideWindowDrawCommand::Clear => self.clear(),
            NeovideWindowDrawCommand::Show if self.hidden => {
                self.hidden = false;
                self.reset_scroll_animation();
            }
            NeovideWindowDrawCommand::Hide => {
                self.hidden = true;
            }
            NeovideWindowDrawCommand::Viewport { scroll_delta } if *scroll_delta != 0 => {
                self.scroll_delta = *scroll_delta;
            }
            NeovideWindowDrawCommand::ViewportMargins {
                top,
                bottom,
                left,
                right,
            } => {
                self.viewport_margins = NeovideViewportMargins {
                    top: *top,
                    bottom: *bottom,
                    left: *left,
                    right: *right,
                };
            }
            _ => {}
        }
    }

    pub fn flush(&mut self, far_lines: usize) {
        let inner_range = self.inner_row_range();
        let inner_height = inner_range.len();
        if self.scrollback_shape_changed(inner_height) {
            self.reset_scrollback();
            self.scroll_delta = 0;
            self.scroll_animation.reset();
            return;
        }

        let scroll_delta = self.scroll_delta;
        self.rotate_scrollback(scroll_delta);
        self.clone_inner_lines_to_scrollback(inner_range);
        if scroll_delta != 0 {
            let max_delta = self.scrollback_lines.len().saturating_sub(inner_height);
            if scroll_delta.unsigned_abs() > max_delta {
                let far_lines = far_lines.min(self.lines.len()) as isize;
                self.scroll_animation.position = -(far_lines * scroll_delta.signum()) as f32;
                let empty_lines = if scroll_delta > 0 {
                    -far_lines..0
                } else {
                    self.lines.len() as isize..self.lines.len() as isize + far_lines
                };
                for signed_row in empty_lines {
                    self.set_scrollback_line(signed_row, None);
                }
            } else {
                let position = self.scroll_animation.position - scroll_delta as f32;
                self.scroll_animation.position =
                    position.clamp(-(max_delta as f32), max_delta as f32);
            }
        }
        self.scroll_delta = 0;
    }

    pub fn advance_animation(&mut self, dt: f32) -> bool {
        self.scroll_animation
            .update(dt, SCROLL_ANIMATION_LENGTH_SECONDS)
    }

    pub fn has_active_animation(&self) -> bool {
        self.scroll_animation.position != 0.0
    }

    pub fn scroll_position(&self) -> f32 {
        self.scroll_animation.position
    }

    pub(crate) fn reset_scroll_animation(&mut self) {
        self.scroll_delta = 0;
        self.scroll_animation.reset();
    }

    pub fn line(&self, row: usize) -> Option<&NeovideLine> {
        self.lines.get(row)?.as_ref()
    }

    pub fn snapshot(
        &self,
        grid_id: i64,
        placement: NeovideRenderedWindowPlacement,
    ) -> NeovideRenderedWindowSnapshot {
        NeovideRenderedWindowSnapshot {
            grid_id,
            top: placement.top,
            left: placement.left,
            width: placement.width,
            height: placement.height,
            window_kind: placement.window_kind,
            zindex: placement.zindex,
            compindex: placement.compindex,
            hidden: placement.hidden,
            scroll_position: self.scroll_animation.position,
            viewport_margins: self.viewport_margins,
            scrollback_zero_index: self.scrollback_zero_index(),
            scrollback_lines: self.scrollback_lines.elements.clone(),
            lines: self.lines.logical_elements(),
        }
    }

    fn resize(&mut self, width: usize, height: usize) {
        let width = width.max(1);
        let height = height.max(1);
        if self.width == width && self.height == height {
            return;
        }
        // Retained rows stay vertically compatible across width-only multigrid
        // updates, so keep the active scroll spring as Neovide does.
        let height_changed = self.height != height;
        self.width = width;
        if !height_changed {
            return;
        }
        self.height = height;
        self.lines.resize(self.height, None);
        self.reset_scroll_animation();
        self.scrollback_lines
            .resize(scrollback_len(self.height), None);
        self.scrollback_lines
            .clone_from_iter(self.lines.logical_elements());
    }

    fn draw_line(&mut self, row: usize, line: NeovideLine) {
        if let Some(slot) = self.lines.get_mut(row) {
            *slot = Some(line);
        }
    }

    fn scroll(
        &mut self,
        top: usize,
        bottom: usize,
        left: usize,
        right: usize,
        rows: isize,
        cols: isize,
    ) {
        if top == 0 && bottom == self.height && left == 0 && right == self.width && cols == 0 {
            self.rotate_visible_rows(rows);
        }
    }

    fn rotate_visible_rows(&mut self, rows: isize) {
        self.lines.rotate(rows);
    }

    fn clear(&mut self) {
        self.lines.fill(None);
        self.reset_scroll_animation();
        self.reset_scrollback();
    }

    fn reset_scrollback(&mut self) {
        let inner_range = self.inner_row_range();
        let inner_height = inner_range.len();
        self.scrollback_lines = NeovideRingBuffer::new(scrollback_len(inner_height), None);
        self.clone_inner_lines_to_scrollback(inner_range);
    }

    fn scrollback_shape_changed(&self, inner_height: usize) -> bool {
        self.scrollback_lines.len() != scrollback_len(inner_height)
    }

    fn clone_inner_lines_to_scrollback(&mut self, inner_range: std::ops::Range<usize>) {
        for (inner_row, source_row) in inner_range.enumerate() {
            let line = self.lines.get(source_row).cloned().flatten();
            self.set_scrollback_line(inner_row as isize, line);
        }
    }

    fn rotate_scrollback(&mut self, scroll_delta: isize) {
        self.scrollback_lines.rotate(scroll_delta);
    }

    fn set_scrollback_line(&mut self, signed_row: isize, line: Option<NeovideLine>) {
        let Some(index) = self.scrollback_index(signed_row) else {
            return;
        };
        self.scrollback_lines.elements[index] = line;
    }

    fn scrollback_index(&self, signed_row: isize) -> Option<usize> {
        self.scrollback_lines.array_index(signed_row)
    }

    fn scrollback_zero_index(&self) -> usize {
        self.scrollback_lines.array_index(0).unwrap_or(0)
    }

    fn inner_row_range(&self) -> std::ops::Range<usize> {
        let top = self.viewport_margins.top.min(self.height);
        let bottom_margin = self
            .viewport_margins
            .bottom
            .min(self.height.saturating_sub(top));
        top..self.height.saturating_sub(bottom_margin)
    }
}

fn scrollback_len(inner_height: usize) -> usize {
    inner_height * 2
}

fn ring_index(len: usize, zero: usize, signed_row: isize) -> Option<usize> {
    let len = i128::try_from(len).ok().filter(|len| *len > 0)?;
    let zero = i128::try_from(zero).ok()?;
    let signed_row = signed_row as i128;
    usize::try_from((zero + signed_row).rem_euclid(len)).ok()
}

#[derive(Clone, Debug)]
struct NeovideRingBuffer<T> {
    elements: Vec<T>,
    current_index: isize,
}

impl<T: Clone> NeovideRingBuffer<T> {
    fn new(size: usize, default_value: T) -> Self {
        Self {
            elements: vec![default_value; size],
            current_index: 0,
        }
    }

    fn len(&self) -> usize {
        self.elements.len()
    }

    fn resize(&mut self, new_size: usize, default_value: T) {
        if new_size > 0 && !self.elements.is_empty() {
            let zero = self.array_index(0).unwrap_or(0);
            self.elements.rotate_left(zero);
        }
        self.elements.resize(new_size, default_value);
        self.current_index = 0;
    }

    fn rotate(&mut self, rows: isize) {
        let Some(index) = ring_index(self.len(), self.current_index as usize, rows) else {
            self.current_index = 0;
            return;
        };
        self.current_index = isize::try_from(index).unwrap_or(0);
    }

    fn array_index(&self, signed_row: isize) -> Option<usize> {
        ring_index(self.len(), self.current_index as usize, signed_row)
    }

    fn get(&self, logical_index: usize) -> Option<&T> {
        let array_index = self.array_index(isize::try_from(logical_index).ok()?)?;
        self.elements.get(array_index)
    }

    fn get_mut(&mut self, logical_index: usize) -> Option<&mut T> {
        let array_index = self.array_index(isize::try_from(logical_index).ok()?)?;
        self.elements.get_mut(array_index)
    }

    fn fill(&mut self, value: T) {
        self.elements.fill(value);
    }

    fn clone_from_iter<I>(&mut self, iter: I)
    where
        I: IntoIterator<Item = T>,
    {
        for (logical_index, value) in iter.into_iter().take(self.len()).enumerate() {
            if let Some(slot) = self.get_mut(logical_index) {
                *slot = value;
            }
        }
    }

    fn logical_elements(&self) -> Vec<T> {
        (0..self.len())
            .filter_map(|logical_index| self.get(logical_index).cloned())
            .collect()
    }
}

#[derive(Clone, Debug)]
pub struct CriticallyDampedSpringAnimation {
    pub position: f32,
    velocity: f32,
}

impl CriticallyDampedSpringAnimation {
    pub fn new() -> Self {
        Self {
            position: 0.0,
            velocity: 0.0,
        }
    }

    pub fn update(&mut self, dt: f32, animation_length: f32) -> bool {
        if animation_length <= dt {
            self.reset();
            return false;
        }
        if self.position == 0.0 {
            return false;
        }

        let omega = 4.0 / animation_length;
        let start = self.position;
        let velocity = self.position * omega + self.velocity;
        let decay = (-omega * dt).exp();

        self.position = (start + velocity * dt) * decay;
        self.velocity = decay * (-start * omega - velocity * dt * omega + velocity);
        if self.position.abs() < 0.01 {
            self.reset();
            return false;
        }
        true
    }

    pub fn reset(&mut self) {
        self.position = 0.0;
        self.velocity = 0.0;
    }
}

impl Default for CriticallyDampedSpringAnimation {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct NeovideRendererModelSnapshot {
    pub schema_version: u32,
    pub background: TerminalColor,
    pub cursor_color: TerminalColor,
    pub cursor: Option<TerminalCursorSnapshot>,
    pub cursor_parent_grid_id: Option<i64>,
    pub message_selection: Option<NeovideMessageSelection>,
    pub scrollbar: Option<crate::terminal_runtime::ScrollbarSnapshot>,
    pub scroll_hint: Option<NeovideScrollHint>,
    pub windows: Vec<NeovideRenderedWindowSnapshot>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct NeovideUiStateSnapshot {
    pub cursor: Option<TerminalCursorSnapshot>,
    pub scroll_hint: Option<NeovideScrollHint>,
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
pub struct NeovideMessageSelection {
    pub grid_id: i64,
    pub start: NeovideGridPosition,
    pub end: NeovideGridPosition,
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
pub struct NeovideGridPosition {
    pub row: usize,
    pub col: usize,
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
pub struct NeovideScrollHint {
    pub start_row: usize,
    pub end_row: usize,
    pub start_col: usize,
    pub end_col: usize,
    pub rows: isize,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct NeovideRenderedWindowSnapshot {
    pub grid_id: i64,
    pub top: usize,
    pub left: usize,
    pub width: usize,
    pub height: usize,
    pub window_kind: NeovideWindowKind,
    pub zindex: i64,
    pub compindex: i64,
    pub hidden: bool,
    pub scroll_position: f32,
    pub viewport_margins: NeovideViewportMargins,
    pub scrollback_zero_index: usize,
    pub scrollback_lines: Vec<Option<NeovideLine>>,
    pub lines: Vec<Option<NeovideLine>>,
}

impl NeovideRenderedWindowSnapshot {
    pub fn scrollback_line(&self, signed_row: isize) -> Option<&NeovideLine> {
        let index = ring_index(
            self.scrollback_lines.len(),
            self.scrollback_zero_index,
            signed_row,
        )?;
        self.scrollback_lines.get(index)?.as_ref()
    }

    pub fn inner_row_range(&self) -> Range<usize> {
        let margin = &self.viewport_margins;
        let start = margin.top.min(self.height);
        let end = self.height - margin.bottom.min(self.height - start);
        start..end
    }

    pub fn inner_col_range(&self) -> Range<usize> {
        let margin = &self.viewport_margins;
        let start = margin.left.min(self.width);
        let end = self.width - margin.right.min(self.width - start);
        start..end
    }

    pub fn line_text_range(&self, row: usize, start_col: usize, end_col: usize) -> Option<String> {
        let cells = &self.lines.get(row)?.as_ref()?.cells;
        if cells.is_empty() {
            return Some(String::new());
        }
        let max_col = cells.len().saturating_sub(1);
        let start = start_col.min(max_col);
        let end = end_col.min(max_col);
        let (start, end) = if start <= end {
            (start, end)
        } else {
            (end, start)
        };
        let mut text = cells[start..=end]
            .iter()
            .map(|cell| cell.text.as_str())
            .collect::<String>();
        text.truncate(text.trim_end_matches(' ').len());
        Some(text)
    }
}

#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq)]
pub struct NeovideViewportMargins {
    pub top: usize,
    pub bottom: usize,
    pub left: usize,
    pub right: usize,
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
pub struct NeovideRenderedWindowPlacement {
    pub top: usize,
    pub left: usize,
    pub width: usize,
    pub height: usize,
    pub window_kind: NeovideWindowKind,
    pub zindex: i64,
    pub compindex: i64,
    pub hidden: bool,
}

impl NeovideRenderedWindowPlacement {
    pub fn main(width: usize, height: usize) -> Self {
        Self {
            top: 0,
            left: 0,
            width,
            height,
            window_kind: NeovideWindowKind::Normal,
            zindex: 0,
            compindex: 0,
            hidden: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal_runtime::{TerminalCellStyle, TerminalColor};

    include!("neovide_render_regression_tests.rs");

    #[test]
    fn retained_line_prepares_background_runs_and_blink_metadata() {
        let red = TerminalColor {
            r: 200,
            g: 20,
            b: 30,
        };
        let blue = TerminalColor {
            r: 10,
            g: 40,
            b: 180,
        };
        let mut cells = vec![
            background_cell(None, 0),
            background_cell(Some(red), 0),
            background_cell(Some(red), 0),
            background_cell(Some(red), 20),
            background_cell(None, 0),
            background_cell(Some(blue), 0),
        ];
        cells[3].style.blink = true;

        let line = NeovideLine::from_cells(cells);

        assert_eq!(
            line.background_runs(),
            [
                NeovideBackgroundRun {
                    start_col: 1,
                    end_col: 3,
                    background: red,
                    blend: 0,
                },
                NeovideBackgroundRun {
                    start_col: 3,
                    end_col: 4,
                    background: red,
                    blend: 20,
                },
                NeovideBackgroundRun {
                    start_col: 5,
                    end_col: 6,
                    background: blue,
                    blend: 0,
                },
            ]
        );
        assert!(line.has_blink());
    }

    #[test]
    fn retained_line_metadata_does_not_change_serialized_protocol() {
        let line = NeovideLine::from_cells(vec![background_cell(
            Some(TerminalColor { r: 1, g: 2, b: 3 }),
            10,
        )]);

        let value = serde_json::to_value(line).unwrap();

        assert!(value.get("background_runs").is_none());
        assert!(value.get("has_blink").is_none());
    }

    #[test]
    fn rendered_window_keeps_line_cache_and_scrolls_like_neovide() {
        let mut window = NeovideRenderedWindowCache::new(3, 3);
        window.apply(&NeovideWindowDrawCommand::DrawLine {
            row: 0,
            line: NeovideLine::from_cells(row("aaa")),
        });
        window.apply(&NeovideWindowDrawCommand::DrawLine {
            row: 1,
            line: NeovideLine::from_cells(row("bbb")),
        });
        window.apply(&NeovideWindowDrawCommand::DrawLine {
            row: 2,
            line: NeovideLine::from_cells(row("ccc")),
        });

        window.apply(&NeovideWindowDrawCommand::Scroll {
            top: 0,
            bottom: 3,
            left: 0,
            right: 3,
            rows: 1,
            cols: 0,
        });

        assert_eq!(window.line(0).map(|line| line.text.as_ref()), Some("bbb"));
        assert_eq!(window.line(1).map(|line| line.text.as_ref()), Some("ccc"));
        assert_eq!(window.line(2).map(|line| line.text.as_ref()), Some("aaa"));
    }

    #[test]
    fn rendered_window_snapshot_exposes_scrollback_for_scroll_animation() {
        let mut window = NeovideRenderedWindowCache::new(3, 3);
        set_window_rows(&mut window, ["aaa", "bbb", "ccc"]);
        window.flush(1);

        window.apply(&NeovideWindowDrawCommand::Scroll {
            top: 0,
            bottom: 3,
            left: 0,
            right: 3,
            rows: 1,
            cols: 0,
        });
        window.apply(&NeovideWindowDrawCommand::DrawLine {
            row: 2,
            line: NeovideLine::from_cells(row("ddd")),
        });
        window.apply(&NeovideWindowDrawCommand::Viewport { scroll_delta: 1 });
        window.flush(1);

        let snapshot = window.snapshot(1, NeovideRenderedWindowPlacement::main(3, 3));

        assert_eq!(snapshot.scroll_position, -1.0);
        assert_eq!(
            snapshot.scrollback_line(-1).map(|line| line.text.as_ref()),
            Some("aaa")
        );
        assert_eq!(
            snapshot.scrollback_line(0).map(|line| line.text.as_ref()),
            Some("bbb")
        );
        assert_eq!(
            snapshot.scrollback_line(1).map(|line| line.text.as_ref()),
            Some("ccc")
        );
        assert_eq!(
            snapshot.scrollback_line(2).map(|line| line.text.as_ref()),
            Some("ddd")
        );
    }

    #[test]
    fn upward_scroll_preserves_old_and_new_rows_across_ring_boundary() {
        let mut window = NeovideRenderedWindowCache::new(3, 3);
        set_window_rows(&mut window, ["aaa", "bbb", "ccc"]);
        window.flush(1);

        window.apply(&NeovideWindowDrawCommand::Scroll {
            top: 0,
            bottom: 3,
            left: 0,
            right: 3,
            rows: -2,
            cols: 0,
        });
        window.apply(&NeovideWindowDrawCommand::DrawLine {
            row: 0,
            line: NeovideLine::from_cells(row("xxx")),
        });
        window.apply(&NeovideWindowDrawCommand::DrawLine {
            row: 1,
            line: NeovideLine::from_cells(row("yyy")),
        });
        window.apply(&NeovideWindowDrawCommand::Viewport { scroll_delta: -2 });
        window.flush(1);

        let snapshot = window.snapshot(1, NeovideRenderedWindowPlacement::main(3, 3));
        assert_eq!(snapshot.scroll_position, 2.0);
        let rows = (0..=4)
            .map(|signed_row| {
                snapshot
                    .scrollback_line(signed_row)
                    .map(|line| line.text.as_ref())
            })
            .collect::<Vec<_>>();
        assert_eq!(
            rows,
            vec![
                Some("xxx"),
                Some("yyy"),
                Some("aaa"),
                Some("bbb"),
                Some("ccc"),
            ]
        );
    }

    #[test]
    fn repeated_position_keeps_retained_scroll_animation() {
        let mut window = NeovideRenderedWindowCache::new(3, 3);
        set_window_rows(&mut window, ["aaa", "bbb", "ccc"]);
        window.flush(1);

        window.apply(&NeovideWindowDrawCommand::Viewport { scroll_delta: 1 });
        window.flush(1);
        window.apply(&NeovideWindowDrawCommand::Position {
            top: 0,
            left: 0,
            width: 3,
            height: 3,
            window_kind: NeovideWindowKind::Normal,
            zindex: 0,
            compindex: 0,
        });

        let snapshot = window.snapshot(1, NeovideRenderedWindowPlacement::main(3, 3));

        assert_eq!(snapshot.scroll_position, -1.0);
        assert_eq!(
            snapshot.scrollback_line(0).map(|line| line.text.as_ref()),
            Some("aaa")
        );
    }

    #[test]
    fn width_only_resize_keeps_retained_scroll_animation() {
        let mut window = NeovideRenderedWindowCache::new(3, 3);
        set_window_rows(&mut window, ["aaa", "bbb", "ccc"]);
        window.flush(1);
        window.apply(&NeovideWindowDrawCommand::Viewport { scroll_delta: 1 });
        window.flush(1);
        assert!(window.has_active_animation());

        window.apply(&NeovideWindowDrawCommand::Position {
            top: 0,
            left: 0,
            width: 4,
            height: 3,
            window_kind: NeovideWindowKind::Normal,
            zindex: 0,
            compindex: 0,
        });

        let snapshot = window.snapshot(1, NeovideRenderedWindowPlacement::main(4, 3));
        assert_eq!(snapshot.scroll_position, -1.0);
        assert!(window.has_active_animation());
    }

    #[test]
    fn zero_viewport_delta_keeps_retained_scroll_animation() {
        let mut window = NeovideRenderedWindowCache::new(8, 6);
        window.apply(&NeovideWindowDrawCommand::Viewport { scroll_delta: 2 });
        window.flush(1);
        assert_eq!(window.scroll_position(), -2.0);
        window.apply(&NeovideWindowDrawCommand::Viewport { scroll_delta: 0 });
        window.flush(1);
        assert_eq!(window.scroll_position(), -2.0);
        assert!(window.has_active_animation());
    }

    #[test]
    fn viewport_margins_keep_fixed_rows_out_of_scrollback() {
        let mut window = NeovideRenderedWindowCache::new(3, 4);
        set_window_rows(&mut window, ["top", "aaa", "bbb", "bot"]);
        window.apply(&NeovideWindowDrawCommand::ViewportMargins {
            top: 1,
            bottom: 1,
            left: 0,
            right: 0,
        });
        window.flush(1);
        let snapshot = window.snapshot(1, NeovideRenderedWindowPlacement::main(3, 4));
        assert_eq!(snapshot.inner_row_range(), 1..3);
        assert!(snapshot.scrollback_line(-1).is_none());
        assert_eq!(
            snapshot.scrollback_line(0).map(|line| line.text.as_ref()),
            Some("aaa")
        );
        assert_eq!(
            snapshot.scrollback_line(1).map(|line| line.text.as_ref()),
            Some("bbb")
        );
        assert!(snapshot.scrollback_line(2).is_none());
    }

    #[test]
    fn spring_animation_converges_to_zero() {
        let mut animation = CriticallyDampedSpringAnimation::new();
        animation.position = 5.0;

        for _ in 0..60 {
            animation.update(1.0 / 60.0, 0.3);
        }

        assert_eq!(animation.position, 0.0);
    }

    #[test]
    fn rendered_window_snapshot_exposes_retained_lines() {
        let mut window = NeovideRenderedWindowCache::new(3, 2);
        window.apply(&NeovideWindowDrawCommand::DrawLine {
            row: 1,
            line: NeovideLine::from_cells(row("abc")),
        });

        let snapshot = window.snapshot(7, NeovideRenderedWindowPlacement::main(3, 2));

        assert_eq!(snapshot.grid_id, 7);
        assert_eq!(snapshot.width, 3);
        assert_eq!(snapshot.height, 2);
        assert_eq!(
            snapshot.lines[1].as_ref().map(|line| line.text.as_ref()),
            Some("abc")
        );
        let second = window.snapshot(7, NeovideRenderedWindowPlacement::main(3, 2));
        assert!(Arc::ptr_eq(
            &snapshot.lines[1].as_ref().unwrap().cells,
            &second.lines[1].as_ref().unwrap().cells,
        ));
    }

    fn row(text: &str) -> Vec<TerminalCellSnapshot> {
        text.chars()
            .map(|char| TerminalCellSnapshot {
                text: char.to_string(),
                fg: TerminalColor { r: 1, g: 2, b: 3 },
                bg: None,
                blend: 0,
                style: TerminalCellStyle::default(),
            })
            .collect()
    }

    fn background_cell(bg: Option<TerminalColor>, blend: u8) -> TerminalCellSnapshot {
        TerminalCellSnapshot {
            text: " ".to_owned(),
            fg: TerminalColor { r: 0, g: 0, b: 0 },
            bg,
            blend,
            style: TerminalCellStyle::default(),
        }
    }

    fn set_window_rows<const N: usize>(window: &mut NeovideRenderedWindowCache, rows: [&str; N]) {
        for (row_index, text) in rows.into_iter().enumerate() {
            window.apply(&NeovideWindowDrawCommand::DrawLine {
                row: row_index,
                line: NeovideLine::from_cells(row(text)),
            });
        }
    }
}
