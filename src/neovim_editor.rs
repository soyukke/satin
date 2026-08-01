use std::collections::HashMap;

use crate::{
    neovide_render::{
        NeovideLine, NeovideRenderedWindowCache, NeovideRenderedWindowPlacement,
        NeovideRenderedWindowSnapshot, NeovideRendererModelSnapshot, NeovideScrollHint,
        NeovideWindowDrawCommand, NeovideWindowKind,
    },
    terminal_runtime::{
        TerminalCellSnapshot, TerminalCellStyle, TerminalColor, TerminalCursorSnapshot,
    },
};
use rmpv::Value;

const DEFAULT_GRID: i64 = 1;

pub struct NeovimEditor {
    grids: HashMap<i64, NeovimGrid>,
    windows: HashMap<i64, NeovimWindow>,
    highlights: HashMap<i64, NeovimHighlight>,
    default_fg: TerminalColor,
    default_bg: TerminalColor,
    cursor: Option<NeovimCursor>,
    cursor_style_enabled: bool,
    cursor_modes: Vec<NeovimCursorModeInfo>,
    current_mode_idx: Option<usize>,
    popupmenu: Option<NeovimPopupmenu>,
    layout_changed: bool,
    rendered_windows: HashMap<i64, NeovideRenderedWindowCache>,
    pending_event_scroll_hints: Vec<NeovideScrollHint>,
}

impl NeovimEditor {
    pub fn new(cols: u16, rows: u16) -> Self {
        let default_fg = TerminalColor {
            r: 229,
            g: 229,
            b: 229,
        };
        let default_bg = TerminalColor {
            r: 20,
            g: 22,
            b: 26,
        };
        let mut grids = HashMap::new();
        grids.insert(
            DEFAULT_GRID,
            NeovimGrid::new(cols, rows, default_cell(default_fg)),
        );
        let mut rendered_windows = HashMap::new();
        rendered_windows.insert(
            DEFAULT_GRID,
            NeovideRenderedWindowCache::new(cols as usize, rows as usize),
        );
        Self {
            grids,
            windows: HashMap::new(),
            highlights: HashMap::new(),
            default_fg,
            default_bg,
            cursor: None,
            cursor_style_enabled: false,
            cursor_modes: Vec::new(),
            current_mode_idx: None,
            popupmenu: None,
            layout_changed: true,
            rendered_windows,
            pending_event_scroll_hints: Vec::new(),
        }
    }

    pub fn resize_screen(&mut self, cols: u16, rows: u16) {
        let fill = self.default_cell();
        self.grid_mut(DEFAULT_GRID).resize(cols, rows, fill);
        self.queue_position_for_grid(DEFAULT_GRID);
        self.layout_changed = true;
    }

    pub fn handle_event(&mut self, event: &str, args: &Value) -> bool {
        match event {
            "default_colors_set" => self.handle_default_colors(args),
            "hl_attr_define" => self.handle_highlight(args),
            "grid_resize" => self.handle_grid_resize(args),
            "grid_clear" => self.handle_grid_clear(args),
            "grid_destroy" => self.handle_grid_destroy(args),
            "grid_cursor_goto" => self.handle_cursor(args),
            "mode_info_set" => self.handle_mode_info(args),
            "mode_change" => self.handle_mode_change(args),
            "popupmenu_show" => self.handle_popupmenu_show(args),
            "popupmenu_select" => self.handle_popupmenu_select(args),
            "popupmenu_hide" => self.handle_popupmenu_hide(),
            "grid_line" => self.handle_grid_line(args),
            "grid_scroll" => self.handle_grid_scroll(args),
            "win_pos" => self.handle_window_position(args),
            "win_float_pos" => self.handle_float_position(args),
            "msg_set_pos" => self.handle_message_position(args),
            "win_hide" => self.handle_window_hide(args),
            "win_close" => self.handle_window_close(args),
            "win_viewport" => self.handle_viewport(args),
            "win_viewport_margins" => self.handle_viewport_margins(args),
            _ => false,
        }
    }

    pub fn renderer_model(&self) -> NeovideRendererModelSnapshot {
        self.renderer_model_with_scroll_hint(None)
    }

    pub fn renderer_model_with_pending_scroll(&mut self) -> NeovideRendererModelSnapshot {
        let scroll_hint = self.take_scroll_hint();
        self.renderer_model_with_scroll_hint(scroll_hint)
    }

    fn renderer_model_with_scroll_hint(
        &self,
        scroll_hint: Option<NeovideScrollHint>,
    ) -> NeovideRendererModelSnapshot {
        let mut windows = self
            .rendered_windows
            .iter()
            .map(|(grid_id, window)| {
                window.snapshot(*grid_id, self.rendered_window_placement(*grid_id))
            })
            .collect::<Vec<_>>();
        if let Some(popupmenu) = self.popupmenu_window_snapshot() {
            windows.push(popupmenu);
        }
        windows.sort_by_key(|window| window.grid_id);
        NeovideRendererModelSnapshot {
            schema_version: 1,
            background: self.default_bg,
            cursor_color: self.default_fg,
            cursor: self.cursor_snapshot(),
            cursor_parent_grid_id: self.cursor.map(|cursor| cursor.grid),
            scrollbar: None,
            scroll_hint,
            windows,
        }
    }

    pub fn flush_renderer(&mut self) {
        for window in self.rendered_windows.values_mut() {
            window.flush(1);
        }
    }

    pub fn advance_renderer_animations(&mut self, dt: f32) -> bool {
        let mut changed = false;
        for window in self.rendered_windows.values_mut() {
            changed = window.advance_animation(dt) || changed;
        }
        changed
    }

    pub fn has_active_renderer_animation(&self) -> bool {
        self.rendered_windows
            .values()
            .any(NeovideRenderedWindowCache::has_active_animation)
    }

    fn handle_default_colors(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        if let Some(color) = args.first().and_then(value_color) {
            self.default_fg = color;
        }
        if let Some(color) = args.get(1).and_then(value_color) {
            self.default_bg = color;
        }
        self.layout_changed = true;
        true
    }

    fn handle_highlight(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(id) = args.first().and_then(Value::as_i64) else {
            return false;
        };
        let highlight = args
            .get(1)
            .map(|value| NeovimHighlight::from_value(value, self.default_bg))
            .unwrap_or_default();
        self.highlights.insert(id, highlight);
        false
    }

    fn handle_grid_resize(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        let width = value_u16(args.get(1)).unwrap_or(1);
        let height = value_u16(args.get(2)).unwrap_or(1);
        let fill = self.default_cell();
        self.grid_mut(grid).resize(width, height, fill);
        self.queue_position_for_grid(grid);
        self.layout_changed = true;
        true
    }

    fn handle_grid_clear(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        let fill = self.default_cell();
        self.grid_mut(grid).clear(fill);
        self.queue_window_command(grid, NeovideWindowDrawCommand::Clear);
        self.layout_changed = true;
        true
    }

    fn handle_grid_destroy(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        self.queue_window_command(grid, NeovideWindowDrawCommand::Close);
        self.grids.remove(&grid);
        self.windows.remove(&grid);
        self.rendered_windows.remove(&grid);
        self.layout_changed = true;
        true
    }

    fn handle_cursor(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        let row = value_u16(args.get(1)).unwrap_or(0);
        let col = value_u16(args.get(2)).unwrap_or(0);
        self.cursor = Some(NeovimCursor { grid, row, col });
        true
    }

    fn handle_mode_info(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        self.cursor_style_enabled = args.first().and_then(Value::as_bool).unwrap_or(false);
        self.cursor_modes = args
            .get(1)
            .and_then(Value::as_array)
            .map(|modes| modes.iter().map(NeovimCursorModeInfo::from_value).collect())
            .unwrap_or_default();
        true
    }

    fn handle_mode_change(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        self.current_mode_idx = value_usize(args.get(1));
        true
    }

    fn handle_popupmenu_show(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(items) = args.first().and_then(Value::as_array) else {
            return false;
        };
        self.popupmenu = Some(NeovimPopupmenu {
            items: items.iter().map(NeovimPopupmenuItem::from_value).collect(),
            selected: selected_index(args.get(1)),
            row: value_usize(args.get(2)).unwrap_or(0),
            col: value_usize(args.get(3)).unwrap_or(0),
            grid: value_i64(args.get(4)).unwrap_or(DEFAULT_GRID),
        });
        true
    }

    fn handle_popupmenu_select(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(popupmenu) = &mut self.popupmenu else {
            return false;
        };
        popupmenu.selected = selected_index(args.first());
        true
    }

    fn handle_popupmenu_hide(&mut self) -> bool {
        let visible = self.popupmenu.is_some();
        self.popupmenu = None;
        visible
    }

    fn handle_grid_line(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        let row = value_usize(args.get(1)).unwrap_or(0);
        let col = value_usize(args.get(2)).unwrap_or(0);
        let Some(cells) = args.get(3).and_then(Value::as_array) else {
            return false;
        };
        self.apply_grid_line(grid, row, col, cells);
        true
    }

    fn handle_grid_scroll(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        let Some(region) = scroll_region(args) else {
            return false;
        };
        let fill = self.default_cell();
        self.grid_mut(grid).scroll(region, fill);
        self.queue_grid_scroll(grid, region);
        true
    }

    fn handle_window_position(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        let position = WindowPosition {
            top: value_usize(args.get(2)).unwrap_or(0),
            left: value_usize(args.get(3)).unwrap_or(0),
            width: value_usize(args.get(4)).unwrap_or(1),
            height: value_usize(args.get(5)).unwrap_or(1),
        };
        self.show_window(grid, position, WindowKind::Normal, WindowSort::default());
        true
    }

    fn handle_float_position(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        let grid_size = self.grid_size(grid);
        let Some((top, left)) = self.float_window_top_left(args, grid_size) else {
            return false;
        };
        let position = WindowPosition {
            top,
            left,
            width: grid_size.0 as usize,
            height: grid_size.1 as usize,
        };
        let sort = WindowSort {
            zindex: value_i64(args.get(7)).unwrap_or(0),
            compindex: value_i64(args.get(8)).unwrap_or(0),
        };
        self.show_window(grid, position, WindowKind::Float, sort);
        true
    }

    fn float_window_top_left(
        &self,
        args: &[Value],
        grid_size: (u16, u16),
    ) -> Option<(usize, usize)> {
        // Neovim's composed multigrid extension appends comp_index,
        // screen_row, and screen_col. Prefer those absolute coordinates when
        // present, as Neovide does.
        if let (Some(top), Some(left)) = (
            value_usize_rounded(args.get(9)),
            value_usize_rounded(args.get(10)),
        ) {
            return Some((top, left));
        }

        let anchor = FloatWindowAnchor::from_value(args.get(2)?)?;
        let anchor_grid = value_i64(args.get(3))?;
        let anchor_top = value_f64(args.get(4))?;
        let anchor_left = value_f64(args.get(5))?;
        let (mut left, mut top) =
            anchor.top_left(anchor_left, anchor_top, grid_size.0, grid_size.1);
        if let Some(parent) = self.grid_screen_offset(anchor_grid) {
            left += parent.left as f64;
            top += parent.top as f64;
        }
        Some((nonnegative_rounded(top), nonnegative_rounded(left)))
    }

    fn handle_message_position(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        // Neovim 0.11.3+ may emit a duplicate msg_set_pos for grid 0. Neovide
        // ignores it because the actual message grid always has a nonzero id.
        if grid == 0 {
            return false;
        }
        let position = WindowPosition {
            top: value_usize(args.get(1)).unwrap_or(0),
            left: 0,
            width: self.screen_width(),
            height: self.grid_size(grid).1 as usize,
        };
        let sort = WindowSort {
            zindex: value_i64(args.get(4)).unwrap_or(200),
            compindex: value_i64(args.get(5)).unwrap_or(0),
        };
        self.show_window(grid, position, WindowKind::Message, sort);
        true
    }

    fn handle_window_hide(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        self.window_mut(grid).hidden = true;
        self.queue_window_command(grid, NeovideWindowDrawCommand::Hide);
        self.layout_changed = true;
        true
    }

    fn handle_window_close(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        self.queue_window_command(grid, NeovideWindowDrawCommand::Close);
        self.windows.remove(&grid);
        self.rendered_windows.remove(&grid);
        self.layout_changed = true;
        true
    }

    fn handle_viewport(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        let Some(rows) = value_f64(args.get(7)).map(|value| value.round() as isize) else {
            return false;
        };
        if rows != 0 {
            self.window_mut(grid).pending_scroll_rows += rows;
        }
        self.queue_window_command(
            grid,
            NeovideWindowDrawCommand::Viewport { scroll_delta: rows },
        );
        true
    }

    fn handle_viewport_margins(&mut self, args: &Value) -> bool {
        let Some(args) = args.as_array() else {
            return false;
        };
        let Some(grid) = grid_id(args) else {
            return false;
        };
        let margins = ViewportMargins {
            top: value_usize(args.get(2)).unwrap_or(0),
            bottom: value_usize(args.get(3)).unwrap_or(0),
            left: value_usize(args.get(4)).unwrap_or(0),
            right: value_usize(args.get(5)).unwrap_or(0),
        };
        self.window_mut(grid).margins = margins;
        self.queue_window_command(
            grid,
            NeovideWindowDrawCommand::ViewportMargins {
                top: margins.top,
                bottom: margins.bottom,
                left: margins.left,
                right: margins.right,
            },
        );
        true
    }
}

impl NeovimEditor {
    fn apply_grid_line(&mut self, grid: i64, row: usize, col_start: usize, cells: &[Value]) {
        let mut col = col_start;
        let mut highlight_id = 0;
        for cell in cells {
            let Some(items) = cell.as_array() else {
                continue;
            };
            let text = items.first().and_then(Value::as_str).unwrap_or(" ");
            if let Some(id) = items.get(1).and_then(Value::as_i64) {
                highlight_id = id;
            }
            let repeat = items.get(2).and_then(Value::as_u64).unwrap_or(1);
            let snapshot = self.snapshot_cell(text, highlight_id);
            for _ in 0..repeat {
                self.grid_mut(grid).set(row, col, snapshot.clone());
                col += 1;
            }
        }
        if let Some(line) = self.grids.get(&grid).and_then(|grid| grid.line(row)) {
            self.queue_window_command(grid, NeovideWindowDrawCommand::DrawLine { row, line });
        }
    }

    fn snapshot_cell(&self, text: &str, highlight_id: i64) -> TerminalCellSnapshot {
        let highlight = self
            .highlights
            .get(&highlight_id)
            .copied()
            .unwrap_or_default()
            .resolve(self.default_fg, self.default_bg);
        TerminalCellSnapshot {
            text: text.to_owned(),
            fg: highlight.fg,
            bg: highlight.bg,
            blend: highlight.blend,
            style: highlight.style,
        }
    }

    fn cursor_snapshot(&self) -> Option<TerminalCursorSnapshot> {
        let cursor = self.cursor?;
        let mode = self.cursor_mode_info();
        if cursor.grid == DEFAULT_GRID {
            return Some(cursor.snapshot_at(0, 0, mode));
        }
        let window = self.windows.get(&cursor.grid)?;
        if !window.is_visible_layer() {
            return None;
        }
        Some(cursor.snapshot_at(window.position.left, window.position.top, mode))
    }

    fn cursor_mode_info(&self) -> NeovimCursorModeInfo {
        if !self.cursor_style_enabled {
            return NeovimCursorModeInfo::default();
        }
        self.current_mode_idx
            .and_then(|index| self.cursor_modes.get(index))
            .copied()
            .unwrap_or_default()
    }

    fn take_scroll_hint(&mut self) -> Option<NeovideScrollHint> {
        let suppress = self.layout_changed;
        let screen = ScreenSize {
            cols: self.screen_width(),
            rows: self.screen_height(),
        };
        let hints = self.take_scroll_hints(screen);
        self.layout_changed = false;
        if suppress || hints.len() != 1 {
            return None;
        }
        hints.into_iter().next()
    }

    fn take_scroll_hints(&mut self, screen: ScreenSize) -> Vec<NeovideScrollHint> {
        let hints = std::mem::take(&mut self.pending_event_scroll_hints);
        if hints.len() == 1 {
            return hints;
        }
        let viewport_hints = self.take_window_scroll_hints(screen);
        if !viewport_hints.is_empty() {
            return viewport_hints;
        }
        hints
    }

    fn take_window_scroll_hints(&mut self, screen: ScreenSize) -> Vec<NeovideScrollHint> {
        let mut hints = Vec::new();
        for window in self.windows.values_mut() {
            if let Some(hint) = window.take_scroll_hint(screen) {
                hints.push(hint);
            }
        }
        hints
    }

    fn show_window(
        &mut self,
        grid: i64,
        position: WindowPosition,
        kind: WindowKind,
        sort: WindowSort,
    ) {
        {
            let window = self.window_mut(grid);
            window.position = position;
            window.kind = kind;
            window.sort = sort;
            window.hidden = false;
        }
        self.queue_position_for_grid(grid);
        self.queue_window_command(grid, NeovideWindowDrawCommand::Show);
        self.layout_changed = true;
    }

    fn queue_grid_scroll(&mut self, grid: i64, region: ScrollRegion) {
        self.queue_window_command(
            grid,
            NeovideWindowDrawCommand::Scroll {
                top: region.top,
                bottom: region.bot,
                left: region.left,
                right: region.right,
                rows: region.rows,
                cols: region.cols,
            },
        );
        if let Some(hint) = self.scroll_hint_for_grid_region(grid, region) {
            self.pending_event_scroll_hints.push(hint);
        }
    }

    fn queue_position_for_grid(&mut self, grid: i64) {
        let grid_size = self.grid_size(grid);
        let position = self
            .windows
            .get(&grid)
            .map(|window| window.position)
            .unwrap_or(WindowPosition {
                top: 0,
                left: 0,
                width: grid_size.0 as usize,
                height: grid_size.1 as usize,
            });
        let (kind, sort) = self
            .windows
            .get(&grid)
            .map(|window| (window.kind, window.sort))
            .unwrap_or((WindowKind::Normal, WindowSort::default()));
        self.queue_window_command(grid, position_command(position, grid_size, kind, sort));
    }

    fn queue_window_command(&mut self, grid: i64, command: NeovideWindowDrawCommand) {
        let (width, height) = self.grid_size(grid);
        self.rendered_windows
            .entry(grid)
            .or_insert_with(|| NeovideRenderedWindowCache::new(width as usize, height as usize))
            .apply(&command);
    }

    fn rendered_window_placement(&self, grid: i64) -> NeovideRenderedWindowPlacement {
        let (width, height) = self.grid_size(grid);
        if grid == DEFAULT_GRID {
            return NeovideRenderedWindowPlacement::main(width as usize, height as usize);
        }
        self.windows
            .get(&grid)
            .map(NeovimWindow::render_placement)
            .unwrap_or(NeovideRenderedWindowPlacement {
                top: 0,
                left: 0,
                width: width as usize,
                height: height as usize,
                window_kind: NeovideWindowKind::Normal,
                zindex: 0,
                compindex: 0,
                hidden: true,
            })
    }

    fn popupmenu_window_snapshot(&self) -> Option<NeovideRenderedWindowSnapshot> {
        let popupmenu = self.popupmenu.as_ref()?.visible()?;
        let position = self.popupmenu_position(popupmenu);
        let lines = popupmenu.lines(self.default_fg);
        Some(NeovideRenderedWindowSnapshot {
            grid_id: -1,
            top: position.top,
            left: position.left,
            width: position.width,
            height: position.height,
            window_kind: NeovideWindowKind::Float,
            zindex: 250,
            compindex: 0,
            hidden: false,
            scroll_position: 0.0,
            viewport_margins: Default::default(),
            scrollback_zero_index: 0,
            scrollback_lines: lines.clone(),
            lines,
        })
    }

    fn popupmenu_position(&self, popupmenu: &NeovimPopupmenu) -> WindowPosition {
        let base = self.grid_screen_offset(popupmenu.grid).unwrap_or_default();
        WindowPosition {
            top: base.top.saturating_add(popupmenu.row),
            left: base.left.saturating_add(popupmenu.col),
            width: popupmenu.width(),
            height: popupmenu.items.len(),
        }
    }

    fn scroll_hint_for_grid_region(
        &self,
        grid: i64,
        region: ScrollRegion,
    ) -> Option<NeovideScrollHint> {
        if region.rows == 0 || region.cols != 0 {
            return None;
        }
        let offset = self.grid_screen_offset(grid)?;
        let screen = ScreenSize {
            cols: self.screen_width(),
            rows: self.screen_height(),
        };
        let scroll_region = ScrollHintRegion::new(
            offset.top.saturating_add(region.top),
            offset.top.saturating_add(region.bot),
            offset.left.saturating_add(region.left),
            offset.left.saturating_add(region.right),
            screen,
        )?;
        let rows = clamp_scroll_rows(region.rows, scroll_region.height());
        (rows != 0).then(|| scroll_region.to_scroll_hint(rows))
    }

    fn grid_screen_offset(&self, grid: i64) -> Option<WindowPosition> {
        if grid == DEFAULT_GRID {
            return Some(WindowPosition::default());
        }
        let window = self.windows.get(&grid)?;
        window.is_visible_layer().then_some(window.position)
    }

    fn screen_width(&self) -> usize {
        self.grid_size(DEFAULT_GRID).0 as usize
    }

    fn screen_height(&self) -> usize {
        self.grid_size(DEFAULT_GRID).1 as usize
    }

    fn grid_size(&self, grid: i64) -> (u16, u16) {
        self.grids
            .get(&grid)
            .map(|grid| (grid.width, grid.height))
            .unwrap_or((1, 1))
    }

    fn grid_mut(&mut self, grid: i64) -> &mut NeovimGrid {
        let fill = self.default_cell();
        let (width, height) = if grid == DEFAULT_GRID {
            self.grid_size(DEFAULT_GRID)
        } else {
            (1, 1)
        };
        self.grids
            .entry(grid)
            .or_insert_with(|| NeovimGrid::new(width, height, fill))
    }

    fn window_mut(&mut self, grid: i64) -> &mut NeovimWindow {
        self.windows
            .entry(grid)
            .or_insert_with(|| NeovimWindow::hidden(grid))
    }

    fn default_cell(&self) -> TerminalCellSnapshot {
        default_cell(self.default_fg)
    }
}

#[derive(Clone)]
struct NeovimGrid {
    width: u16,
    height: u16,
    rows: Vec<Vec<TerminalCellSnapshot>>,
}

impl NeovimGrid {
    fn new(width: u16, height: u16, fill: TerminalCellSnapshot) -> Self {
        let mut grid = Self {
            width: width.max(1),
            height: height.max(1),
            rows: Vec::new(),
        };
        grid.clear(fill);
        grid
    }

    fn resize(&mut self, width: u16, height: u16, fill: TerminalCellSnapshot) {
        self.width = width.max(1);
        self.height = height.max(1);
        self.rows.resize_with(self.height as usize, || {
            vec![fill.clone(); self.width as usize]
        });
        for row in &mut self.rows {
            row.resize(self.width as usize, fill.clone());
        }
    }

    fn clear(&mut self, fill: TerminalCellSnapshot) {
        self.rows = vec![vec![fill; self.width as usize]; self.height as usize];
    }

    fn set(&mut self, row: usize, col: usize, cell: TerminalCellSnapshot) {
        let Some(target_row) = self.rows.get_mut(row) else {
            return;
        };
        let Some(target_cell) = target_row.get_mut(col) else {
            return;
        };
        *target_cell = cell;
    }

    fn scroll(&mut self, region: ScrollRegion, fill: TerminalCellSnapshot) {
        let previous = self.rows.clone();
        for row in region.top..region.bot {
            for col in region.left..region.right {
                let Some((source_row, source_col)) = region.source_cell(row, col) else {
                    self.set(row, col, fill.clone());
                    continue;
                };
                let Some(cell) = previous.get(source_row).and_then(|row| row.get(source_col))
                else {
                    self.set(row, col, fill.clone());
                    continue;
                };
                self.set(row, col, cell.clone());
            }
        }
    }

    fn line(&self, row: usize) -> Option<NeovideLine> {
        self.rows.get(row).cloned().map(NeovideLine::from_cells)
    }
}

#[derive(Clone, Copy)]
struct ScrollRegion {
    top: usize,
    bot: usize,
    left: usize,
    right: usize,
    rows: isize,
    cols: isize,
}

impl ScrollRegion {
    fn source_cell(self, row: usize, col: usize) -> Option<(usize, usize)> {
        let source_row = row.checked_add_signed(self.rows)?;
        let source_col = col.checked_add_signed(self.cols)?;
        if source_row < self.top || source_row >= self.bot {
            return None;
        }
        if source_col < self.left || source_col >= self.right {
            return None;
        }
        Some((source_row, source_col))
    }
}

struct NeovimPopupmenu {
    items: Vec<NeovimPopupmenuItem>,
    selected: Option<usize>,
    row: usize,
    col: usize,
    grid: i64,
}

impl NeovimPopupmenu {
    fn visible(&self) -> Option<&Self> {
        (!self.items.is_empty()).then_some(self)
    }

    fn width(&self) -> usize {
        self.items
            .iter()
            .map(|item| item.text().chars().count())
            .max()
            .unwrap_or(1)
            .max(1)
    }

    fn lines(&self, foreground: TerminalColor) -> Vec<Option<NeovideLine>> {
        let width = self.width();
        self.items
            .iter()
            .enumerate()
            .map(|(index, item)| {
                Some(NeovideLine::from_cells(popupmenu_cells(
                    &item.text(),
                    width,
                    self.selected == Some(index),
                    foreground,
                )))
            })
            .collect()
    }
}

struct NeovimPopupmenuItem {
    word: String,
    kind: String,
    menu: String,
}

impl NeovimPopupmenuItem {
    fn from_value(value: &Value) -> Self {
        let fields = value.as_array();
        Self {
            word: popupmenu_field(fields, 0),
            kind: popupmenu_field(fields, 1),
            menu: popupmenu_field(fields, 2),
        }
    }

    fn text(&self) -> String {
        let mut parts = Vec::new();
        if !self.word.is_empty() {
            parts.push(self.word.as_str());
        }
        if !self.kind.is_empty() {
            parts.push(self.kind.as_str());
        }
        if !self.menu.is_empty() {
            parts.push(self.menu.as_str());
        }
        parts.join(" ")
    }
}

#[derive(Clone, Copy)]
struct NeovimWindow {
    grid: i64,
    position: WindowPosition,
    kind: WindowKind,
    sort: WindowSort,
    margins: ViewportMargins,
    hidden: bool,
    pending_scroll_rows: isize,
}

impl NeovimWindow {
    fn hidden(grid: i64) -> Self {
        Self {
            grid,
            position: WindowPosition::default(),
            kind: WindowKind::Normal,
            sort: WindowSort::default(),
            margins: ViewportMargins::default(),
            hidden: true,
            pending_scroll_rows: 0,
        }
    }

    fn is_visible_layer(self) -> bool {
        !self.hidden && self.grid != DEFAULT_GRID && self.position.has_area()
    }

    fn render_placement(&self) -> NeovideRenderedWindowPlacement {
        NeovideRenderedWindowPlacement {
            top: self.position.top,
            left: self.position.left,
            width: self.position.width,
            height: self.position.height,
            window_kind: neovide_window_kind(self.kind),
            zindex: self.sort.zindex,
            compindex: self.sort.compindex,
            hidden: self.hidden,
        }
    }

    fn take_scroll_hint(&mut self, screen: ScreenSize) -> Option<NeovideScrollHint> {
        let rows = self.take_pending_scroll_rows()?;
        if !self.is_visible_layer() {
            return None;
        }
        let region = self.scrollable_region(screen)?;
        let rows = clamp_scroll_rows(rows, region.height());
        if rows == 0 {
            return None;
        }
        Some(region.to_scroll_hint(rows))
    }

    fn take_pending_scroll_rows(&mut self) -> Option<isize> {
        let rows = self.pending_scroll_rows;
        self.pending_scroll_rows = 0;
        (rows != 0).then_some(rows)
    }

    fn scrollable_region(self, screen: ScreenSize) -> Option<ScrollHintRegion> {
        let start_row = self.position.top.saturating_add(self.margins.top);
        let start_col = self.position.left.saturating_add(self.margins.left);
        let bottom = self.position.bottom().saturating_sub(self.margins.bottom);
        let right = self.position.right().saturating_sub(self.margins.right);
        ScrollHintRegion::new(start_row, bottom, start_col, right, screen)
    }
}

#[derive(Clone, Copy, Default)]
struct WindowPosition {
    top: usize,
    left: usize,
    width: usize,
    height: usize,
}

impl WindowPosition {
    fn has_area(self) -> bool {
        self.width > 0 && self.height > 0
    }

    fn bottom(self) -> usize {
        self.top.saturating_add(self.height)
    }

    fn right(self) -> usize {
        self.left.saturating_add(self.width)
    }
}

#[derive(Clone, Copy)]
enum WindowKind {
    Normal,
    Float,
    Message,
}

#[derive(Clone, Copy)]
enum FloatWindowAnchor {
    NorthWest,
    NorthEast,
    SouthWest,
    SouthEast,
}

impl FloatWindowAnchor {
    fn from_value(value: &Value) -> Option<Self> {
        match value.as_str()? {
            "NW" => Some(Self::NorthWest),
            "NE" => Some(Self::NorthEast),
            "SW" => Some(Self::SouthWest),
            "SE" => Some(Self::SouthEast),
            _ => None,
        }
    }

    fn top_left(self, anchor_left: f64, anchor_top: f64, width: u16, height: u16) -> (f64, f64) {
        match self {
            Self::NorthWest => (anchor_left, anchor_top),
            Self::NorthEast => (anchor_left - f64::from(width), anchor_top),
            Self::SouthWest => (anchor_left, anchor_top - f64::from(height)),
            Self::SouthEast => (
                anchor_left - f64::from(width),
                anchor_top - f64::from(height),
            ),
        }
    }
}

#[derive(Clone, Copy, Default)]
struct WindowSort {
    zindex: i64,
    compindex: i64,
}

#[derive(Clone, Copy, Default)]
struct ViewportMargins {
    top: usize,
    bottom: usize,
    left: usize,
    right: usize,
}

#[derive(Clone, Copy)]
struct ScreenSize {
    cols: usize,
    rows: usize,
}

struct ScrollHintRegion {
    start_row: usize,
    end_row: usize,
    start_col: usize,
    end_col: usize,
}

impl ScrollHintRegion {
    fn new(
        start_row: usize,
        bottom: usize,
        start_col: usize,
        right: usize,
        screen: ScreenSize,
    ) -> Option<Self> {
        let end_row = bottom.min(screen.rows).checked_sub(1)?;
        let end_col = right.min(screen.cols).checked_sub(1)?;
        if start_row > end_row || start_col > end_col {
            return None;
        }
        Some(Self {
            start_row,
            end_row,
            start_col,
            end_col,
        })
    }

    fn height(&self) -> usize {
        self.end_row - self.start_row + 1
    }

    fn to_scroll_hint(&self, rows: isize) -> NeovideScrollHint {
        NeovideScrollHint {
            start_row: self.start_row,
            end_row: self.end_row,
            start_col: self.start_col,
            end_col: self.end_col,
            rows,
        }
    }
}

#[derive(Clone, Copy)]
struct NeovimCursor {
    grid: i64,
    row: u16,
    col: u16,
}

impl NeovimCursor {
    fn snapshot_at(
        self,
        left: usize,
        top: usize,
        mode: NeovimCursorModeInfo,
    ) -> TerminalCursorSnapshot {
        TerminalCursorSnapshot {
            x: saturating_u16(left.saturating_add(self.col as usize)),
            y: saturating_u16(top.saturating_add(self.row as usize)),
            style: mode.shape.style_name(),
            cell_percentage: mode.cell_percentage,
            blinkwait_ms: mode.blinkwait_ms,
            blinkon_ms: mode.blinkon_ms,
            blinkoff_ms: mode.blinkoff_ms,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct NeovimCursorModeInfo {
    shape: NeovimCursorShape,
    cell_percentage: u8,
    blinkwait_ms: u64,
    blinkon_ms: u64,
    blinkoff_ms: u64,
}

impl NeovimCursorModeInfo {
    fn from_value(value: &Value) -> Self {
        let mut info = Self::default();
        let Some(entries) = value.as_map() else {
            return info;
        };
        for (key, value) in entries {
            match key.as_str() {
                Some("cursor_shape") => info.shape = NeovimCursorShape::from_value(value),
                Some("cell_percentage") => {
                    info.cell_percentage = value_u8_clamped(value, 100).unwrap_or(100);
                }
                Some("blinkwait") => info.blinkwait_ms = value_u64(value).unwrap_or(0),
                Some("blinkon") => info.blinkon_ms = value_u64(value).unwrap_or(0),
                Some("blinkoff") => info.blinkoff_ms = value_u64(value).unwrap_or(0),
                _ => {}
            }
        }
        info
    }
}

impl Default for NeovimCursorModeInfo {
    fn default() -> Self {
        Self {
            shape: NeovimCursorShape::Block,
            cell_percentage: 100,
            blinkwait_ms: 0,
            blinkon_ms: 0,
            blinkoff_ms: 0,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NeovimCursorShape {
    Block,
    Horizontal,
    Vertical,
}

impl NeovimCursorShape {
    fn from_value(value: &Value) -> Self {
        match value.as_str() {
            Some("horizontal") => Self::Horizontal,
            Some("vertical") => Self::Vertical,
            _ => Self::Block,
        }
    }

    fn style_name(self) -> &'static str {
        match self {
            Self::Block => "block",
            Self::Horizontal => "underline",
            Self::Vertical => "bar",
        }
    }
}

#[derive(Clone, Copy, Default)]
struct NeovimHighlight {
    fg: Option<TerminalColor>,
    bg: Option<TerminalColor>,
    blend: u8,
    reverse: bool,
    style: TerminalCellStyle,
}

impl NeovimHighlight {
    fn from_value(value: &Value, _default_bg: TerminalColor) -> Self {
        let mut highlight = Self::default();
        let Some(entries) = value.as_map() else {
            return highlight;
        };
        for (key, value) in entries {
            match key.as_str() {
                Some("foreground") => highlight.fg = value_color(value),
                Some("background") => highlight.bg = value_color(value),
                Some("blend") => highlight.blend = value_u8_clamped(value, 100).unwrap_or(0),
                Some("reverse") => highlight.reverse = value.as_bool().unwrap_or(false),
                Some("bold") => highlight.style.bold = value.as_bool().unwrap_or(false),
                Some("italic") => highlight.style.italic = value.as_bool().unwrap_or(false),
                Some("underline" | "undercurl") => {
                    highlight.style.underline = value.as_bool().unwrap_or(false);
                }
                Some("strikethrough") => {
                    highlight.style.strikethrough = value.as_bool().unwrap_or(false);
                }
                _ => {}
            }
        }
        highlight
    }

    fn resolve(self, default_fg: TerminalColor, default_bg: TerminalColor) -> ResolvedHighlight {
        let mut fg = self.fg.unwrap_or(default_fg);
        let mut bg = self
            .bg
            .filter(|color| *color != default_bg || self.blend > 0);
        if self.reverse {
            let next_fg = bg.unwrap_or(default_bg);
            bg = Some(fg);
            fg = next_fg;
        }
        ResolvedHighlight {
            fg,
            bg,
            blend: self.blend,
            style: self.style,
        }
    }
}

struct ResolvedHighlight {
    fg: TerminalColor,
    bg: Option<TerminalColor>,
    blend: u8,
    style: TerminalCellStyle,
}

fn grid_id(args: &[Value]) -> Option<i64> {
    args.first()?.as_i64()
}

fn scroll_region(args: &[Value]) -> Option<ScrollRegion> {
    Some(ScrollRegion {
        top: value_usize(args.get(1))?,
        bot: value_usize(args.get(2))?,
        left: value_usize(args.get(3))?,
        right: value_usize(args.get(4))?,
        rows: value_i64(args.get(5))? as isize,
        cols: value_i64(args.get(6)).unwrap_or(0) as isize,
    })
}

fn value_color(value: &Value) -> Option<TerminalColor> {
    let raw = value.as_i64()?;
    if raw < 0 {
        return None;
    }
    let raw = raw as u32;
    Some(TerminalColor {
        r: ((raw >> 16) & 0xff) as u8,
        g: ((raw >> 8) & 0xff) as u8,
        b: (raw & 0xff) as u8,
    })
}

fn value_i64(value: Option<&Value>) -> Option<i64> {
    value?
        .as_i64()
        .or_else(|| value?.as_u64().map(|value| value as i64))
}

fn value_u64(value: &Value) -> Option<u64> {
    value.as_u64().or_else(|| {
        value
            .as_i64()
            .and_then(|value| (value >= 0).then_some(value as u64))
    })
}

fn value_usize(value: Option<&Value>) -> Option<usize> {
    value?.as_u64().map(|value| value as usize)
}

fn selected_index(value: Option<&Value>) -> Option<usize> {
    let value = value_i64(value)?;
    (value >= 0).then_some(value as usize)
}

fn value_u16(value: Option<&Value>) -> Option<u16> {
    value_usize(value).map(saturating_u16)
}

fn value_u8_clamped(value: &Value, max: u8) -> Option<u8> {
    let raw = value_u64(value)?;
    Some(raw.min(max as u64) as u8)
}

fn value_f64(value: Option<&Value>) -> Option<f64> {
    value?
        .as_f64()
        .or_else(|| value?.as_i64().map(|value| value as f64))
        .or_else(|| value?.as_u64().map(|value| value as f64))
}

fn value_usize_rounded(value: Option<&Value>) -> Option<usize> {
    let value = value_f64(value)?.round();
    (value >= 0.0).then_some(value as usize)
}

fn nonnegative_rounded(value: f64) -> usize {
    value.round().max(0.0) as usize
}

fn saturating_u16(value: usize) -> u16 {
    value.min(u16::MAX as usize) as u16
}

fn clamp_scroll_rows(rows: isize, height: usize) -> isize {
    let max_rows = height.saturating_sub(1) as isize;
    rows.clamp(-max_rows, max_rows)
}

fn position_command(
    position: WindowPosition,
    grid_size: (u16, u16),
    kind: WindowKind,
    sort: WindowSort,
) -> NeovideWindowDrawCommand {
    NeovideWindowDrawCommand::Position {
        top: position.top,
        left: position.left,
        width: grid_size.0 as usize,
        height: grid_size.1 as usize,
        window_kind: neovide_window_kind(kind),
        zindex: sort.zindex,
        compindex: sort.compindex,
    }
}

fn neovide_window_kind(kind: WindowKind) -> NeovideWindowKind {
    match kind {
        WindowKind::Normal => NeovideWindowKind::Normal,
        WindowKind::Float => NeovideWindowKind::Float,
        WindowKind::Message => NeovideWindowKind::Message,
    }
}

fn default_cell(fg: TerminalColor) -> TerminalCellSnapshot {
    TerminalCellSnapshot {
        text: " ".to_owned(),
        fg,
        bg: None,
        blend: 0,
        style: TerminalCellStyle::default(),
    }
}

fn popupmenu_field(fields: Option<&Vec<Value>>, index: usize) -> String {
    fields
        .and_then(|fields| fields.get(index))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned()
}

fn popupmenu_cells(
    text: &str,
    width: usize,
    selected: bool,
    foreground: TerminalColor,
) -> Vec<TerminalCellSnapshot> {
    let background = selected.then_some(TerminalColor {
        r: 80,
        g: 96,
        b: 112,
    });
    let mut cells = text
        .chars()
        .map(|character| TerminalCellSnapshot {
            text: character.to_string(),
            fg: foreground,
            bg: background,
            blend: 0,
            style: TerminalCellStyle::default(),
        })
        .collect::<Vec<_>>();
    cells.resize(width, popupmenu_blank_cell(foreground, background));
    cells
}

fn popupmenu_blank_cell(
    foreground: TerminalColor,
    background: Option<TerminalColor>,
) -> TerminalCellSnapshot {
    TerminalCellSnapshot {
        text: " ".to_owned(),
        fg: foreground,
        bg: background,
        blend: 0,
        style: TerminalCellStyle::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grid_scroll_moves_rows_up() {
        let mut grid = NeovimGrid::new(3, 3, blank());
        set_row(&mut grid, 0, "aaa");
        set_row(&mut grid, 1, "bbb");
        set_row(&mut grid, 2, "ccc");

        grid.scroll(
            ScrollRegion {
                top: 0,
                bot: 3,
                left: 0,
                right: 3,
                rows: 1,
                cols: 0,
            },
            blank(),
        );

        assert_eq!(row_text(&grid.rows[0]), "bbb");
        assert_eq!(row_text(&grid.rows[1]), "ccc");
    }

    #[test]
    fn multiple_grid_scroll_hints_fall_back_to_viewport_hint() {
        let mut editor = NeovimEditor::new(10, 6);
        editor.grid_mut(2).resize(10, 6, blank());
        editor.show_window(
            2,
            WindowPosition {
                top: 0,
                left: 0,
                width: 10,
                height: 6,
            },
            WindowKind::Normal,
            WindowSort::default(),
        );
        editor.layout_changed = false;
        editor.pending_event_scroll_hints = vec![
            NeovideScrollHint {
                start_row: 0,
                end_row: 5,
                start_col: 0,
                end_col: 9,
                rows: 1,
            },
            NeovideScrollHint {
                start_row: 0,
                end_row: 5,
                start_col: 0,
                end_col: 9,
                rows: 1,
            },
        ];
        editor.window_mut(2).pending_scroll_rows = 18;

        let hint = editor
            .renderer_model_with_pending_scroll()
            .scroll_hint
            .unwrap();

        assert_eq!(hint.rows, 5);
    }

    #[test]
    fn viewport_scroll_hint_uses_window_margins_and_columns() {
        let mut editor = NeovimEditor::new(10, 6);
        editor.grid_mut(2).resize(6, 4, blank());
        editor.show_window(
            2,
            WindowPosition {
                top: 1,
                left: 2,
                width: 6,
                height: 4,
            },
            WindowKind::Normal,
            WindowSort::default(),
        );
        editor.window_mut(2).margins = ViewportMargins {
            top: 1,
            bottom: 1,
            left: 1,
            right: 1,
        };
        editor.layout_changed = false;
        editor.window_mut(2).pending_scroll_rows = 2;

        let hint = editor
            .renderer_model_with_pending_scroll()
            .scroll_hint
            .unwrap();

        assert_eq!(hint.start_row, 2);
        assert_eq!(hint.end_row, 3);
        assert_eq!(hint.start_col, 3);
        assert_eq!(hint.end_col, 6);
        assert_eq!(hint.rows, 1);
    }

    #[test]
    fn win_viewport_event_records_scroll_delta_argument() {
        let mut editor = NeovimEditor::new(10, 6);
        editor.grid_mut(2).resize(10, 6, blank());
        editor.show_window(
            2,
            WindowPosition {
                top: 0,
                left: 0,
                width: 10,
                height: 6,
            },
            WindowKind::Normal,
            WindowSort::default(),
        );
        editor.layout_changed = false;

        editor.handle_event(
            "win_viewport",
            &Value::Array(vec![
                2.into(),
                1000.into(),
                20.into(),
                55.into(),
                21.into(),
                0.into(),
                300.into(),
                18.into(),
            ]),
        );

        let hint = editor
            .renderer_model_with_pending_scroll()
            .scroll_hint
            .unwrap();

        assert_eq!(hint.rows, 5);
    }

    #[test]
    fn one_screen_viewport_event_uses_neovim_scroll_delta() {
        let mut editor = NeovimEditor::new(10, 6);
        editor.grid_mut(2).resize(10, 6, blank());
        editor.show_window(
            2,
            WindowPosition {
                top: 0,
                left: 0,
                width: 10,
                height: 6,
            },
            WindowKind::Normal,
            WindowSort::default(),
        );
        editor.layout_changed = false;
        editor.handle_event(
            "win_viewport",
            &Value::Array(vec![
                2.into(),
                1000.into(),
                0.into(),
                5.into(),
                1.into(),
                0.into(),
                5.into(),
                3.into(),
            ]),
        );
        editor.flush_renderer();

        let model = editor.renderer_model_with_pending_scroll();
        let window = model
            .windows
            .iter()
            .find(|window| window.grid_id == 2)
            .unwrap();
        assert_eq!(window.scroll_position, -3.0);
        assert_eq!(model.scroll_hint.unwrap().rows, 3);
    }

    #[test]
    fn zero_viewport_delta_does_not_cancel_scroll_animation() {
        let mut editor = NeovimEditor::new(10, 6);
        editor.grid_mut(2).resize(10, 6, blank());
        editor.show_window(
            2,
            WindowPosition {
                top: 0,
                left: 0,
                width: 10,
                height: 6,
            },
            WindowKind::Normal,
            WindowSort::default(),
        );
        editor.layout_changed = false;
        editor.queue_window_command(2, NeovideWindowDrawCommand::Viewport { scroll_delta: 2 });
        editor.flush_renderer();

        editor.handle_event(
            "win_viewport",
            &Value::Array(vec![
                2.into(),
                1000.into(),
                0.into(),
                5.into(),
                1.into(),
                0.into(),
                5.into(),
                0.into(),
            ]),
        );
        editor.flush_renderer();

        let model = editor.renderer_model_with_pending_scroll();
        let window = model
            .windows
            .iter()
            .find(|window| window.grid_id == 2)
            .unwrap();
        assert_eq!(window.scroll_position, -2.0);
        assert!(model.scroll_hint.is_none());
    }

    #[test]
    fn duplicate_zero_message_grid_is_ignored() {
        let mut editor = NeovimEditor::new(10, 6);

        assert!(!editor.handle_event(
            "msg_set_pos",
            &Value::Array(vec![0.into(), 5.into(), false.into(), " ".into(), 0.into()]),
        ));
        assert!(
            editor
                .renderer_model()
                .windows
                .iter()
                .all(|window| window.grid_id != 0)
        );
    }

    #[test]
    fn renderer_model_consumes_pending_scroll_hint() {
        let mut editor = NeovimEditor::new(10, 6);
        editor.grid_mut(2).resize(10, 6, blank());
        editor.show_window(
            2,
            WindowPosition {
                top: 0,
                left: 3,
                width: 7,
                height: 6,
            },
            WindowKind::Normal,
            WindowSort::default(),
        );
        editor.layout_changed = false;
        editor.window_mut(2).pending_scroll_rows = 2;

        let model = editor.renderer_model_with_pending_scroll();

        let hint = model.scroll_hint.unwrap();
        assert_eq!(hint.rows, 2);
        assert_eq!(hint.start_col, 3);
        assert!(
            editor
                .renderer_model_with_pending_scroll()
                .scroll_hint
                .is_none()
        );
    }

    #[test]
    fn layout_change_suppresses_scroll_hint() {
        let mut editor = NeovimEditor::new(8, 4);
        editor.grid_mut(2).resize(8, 4, blank());
        editor.show_window(
            2,
            WindowPosition {
                top: 0,
                left: 0,
                width: 8,
                height: 4,
            },
            WindowKind::Normal,
            WindowSort::default(),
        );
        editor.window_mut(2).pending_scroll_rows = 1;

        assert!(
            editor
                .renderer_model_with_pending_scroll()
                .scroll_hint
                .is_none()
        );
    }

    #[test]
    fn renderer_model_exposes_retained_window_cache() {
        let mut editor = NeovimEditor::new(3, 2);
        editor.handle_event(
            "grid_line",
            &Value::Array(vec![
                DEFAULT_GRID.into(),
                1.into(),
                0.into(),
                Value::Array(vec![Value::Array(vec!["x".into(), 0.into(), 3.into()])]),
            ]),
        );

        let model = editor.renderer_model();

        assert_eq!(model.schema_version, 1);
        assert_eq!(model.background, editor.default_bg);
        assert_eq!(model.windows[0].grid_id, DEFAULT_GRID);
        let line = model.windows[0].lines[1].as_ref().unwrap();
        assert_eq!(line.text, "xxx");
        assert_eq!(
            line.cells[0].fg,
            TerminalColor {
                r: 229,
                g: 229,
                b: 229
            }
        );
    }

    #[test]
    fn grid_resize_preserves_initial_lines_when_viewport_margins_arrive_first() {
        let mut editor = NeovimEditor::new(80, 35);
        let grid = 5;

        editor.handle_event(
            "win_viewport_margins",
            &Value::Array(vec![
                grid.into(),
                1000.into(),
                0.into(),
                0.into(),
                0.into(),
                0.into(),
            ]),
        );
        editor.handle_event(
            "grid_resize",
            &Value::Array(vec![grid.into(), 30.into(), 35.into()]),
        );
        for row in 0..35 {
            editor.handle_event(
                "grid_line",
                &Value::Array(vec![
                    grid.into(),
                    row.into(),
                    0.into(),
                    Value::Array(vec![Value::Array(vec![
                        format!("row-{row:02}").into(),
                        0.into(),
                    ])]),
                ]),
            );
        }
        editor.handle_event(
            "win_pos",
            &Value::Array(vec![
                grid.into(),
                1000.into(),
                0.into(),
                0.into(),
                30.into(),
                35.into(),
            ]),
        );

        let model = editor.renderer_model();
        let window = model
            .windows
            .iter()
            .find(|window| window.grid_id == grid)
            .unwrap();

        assert_eq!(window.lines.len(), 35);
        assert_eq!(
            window
                .lines
                .iter()
                .filter(|line| line
                    .as_ref()
                    .is_some_and(|line| !line.text.trim().is_empty()))
                .count(),
            35
        );
        assert!(
            window.lines[34]
                .as_ref()
                .is_some_and(|line| line.text.starts_with("row-34"))
        );
    }

    #[test]
    fn renderer_model_exposes_window_placement() {
        let mut editor = NeovimEditor::new(10, 4);
        editor.grid_mut(2).resize(4, 2, blank());
        editor.show_window(
            2,
            WindowPosition {
                top: 1,
                left: 3,
                width: 4,
                height: 2,
            },
            WindowKind::Float,
            WindowSort {
                zindex: 50,
                compindex: 2,
            },
        );

        let model = editor.renderer_model();
        let window = model
            .windows
            .iter()
            .find(|window| window.grid_id == 2)
            .unwrap();

        assert_eq!(window.top, 1);
        assert_eq!(window.left, 3);
        assert_eq!(window.window_kind, NeovideWindowKind::Float);
        assert_eq!(window.zindex, 50);
        assert!(!window.hidden);
    }

    #[test]
    fn float_position_uses_anchor_coordinates_without_composed_extension() {
        let mut editor = NeovimEditor::new(40, 12);
        editor.grid_mut(2).resize(4, 2, blank());

        assert!(editor.handle_event(
            "win_float_pos",
            &Value::Array(vec![
                2.into(),
                100.into(),
                "NW".into(),
                1.into(),
                3.0.into(),
                20.0.into(),
                true.into(),
                50.into(),
            ]),
        ));

        let model = editor.renderer_model();
        let window = model
            .windows
            .iter()
            .find(|window| window.grid_id == 2)
            .unwrap();
        assert_eq!((window.top, window.left), (3, 20));
    }

    #[test]
    fn float_position_prefers_composed_screen_coordinates() {
        let mut editor = NeovimEditor::new(40, 12);
        editor.grid_mut(2).resize(4, 2, blank());

        assert!(editor.handle_event(
            "win_float_pos",
            &Value::Array(vec![
                2.into(),
                100.into(),
                "SE".into(),
                1.into(),
                3.0.into(),
                20.0.into(),
                true.into(),
                50.into(),
                4.into(),
                6.into(),
                7.into(),
            ]),
        ));

        let model = editor.renderer_model();
        let window = model
            .windows
            .iter()
            .find(|window| window.grid_id == 2)
            .unwrap();
        assert_eq!((window.top, window.left), (6, 7));
        assert_eq!(window.compindex, 4);
    }

    fn set_row(grid: &mut NeovimGrid, row: usize, text: &str) {
        for (col, char) in text.chars().enumerate() {
            grid.set(
                row,
                col,
                TerminalCellSnapshot {
                    text: char.to_string(),
                    fg: TerminalColor { r: 1, g: 2, b: 3 },
                    bg: None,
                    blend: 0,
                    style: TerminalCellStyle::default(),
                },
            );
        }
    }

    fn blank() -> TerminalCellSnapshot {
        TerminalCellSnapshot {
            text: " ".to_owned(),
            fg: TerminalColor { r: 1, g: 2, b: 3 },
            bg: None,
            blend: 0,
            style: TerminalCellStyle::default(),
        }
    }

    #[test]
    fn snapshot_cell_preserves_highlight_style() {
        let mut editor = NeovimEditor::new(10, 2);
        editor.highlights.insert(
            7,
            NeovimHighlight {
                style: TerminalCellStyle {
                    bold: true,
                    italic: true,
                    underline: true,
                    strikethrough: true,
                    ..TerminalCellStyle::default()
                },
                ..NeovimHighlight::default()
            },
        );

        let cell = editor.snapshot_cell("x", 7);

        assert!(cell.style.bold);
        assert!(cell.style.italic);
        assert!(cell.style.underline);
        assert!(cell.style.strikethrough);
    }

    #[test]
    fn snapshot_cell_preserves_highlight_blend() {
        let mut editor = NeovimEditor::new(10, 2);
        editor.highlights.insert(
            9,
            NeovimHighlight {
                bg: Some(editor.default_bg),
                blend: 35,
                ..NeovimHighlight::default()
            },
        );

        let cell = editor.snapshot_cell(" ", 9);

        assert_eq!(cell.bg, Some(editor.default_bg));
        assert_eq!(cell.blend, 35);
    }

    #[test]
    fn grid_line_preserves_highlight_blend_from_event() {
        let mut editor = NeovimEditor::new(4, 1);
        editor.handle_event(
            "hl_attr_define",
            &Value::Array(vec![
                9.into(),
                Value::Map(vec![
                    ("background".into(), 0x506070.into()),
                    ("blend".into(), 35.into()),
                ]),
            ]),
        );

        editor.handle_event(
            "grid_line",
            &Value::Array(vec![
                DEFAULT_GRID.into(),
                0.into(),
                0.into(),
                Value::Array(vec![Value::Array(vec![" ".into(), 9.into(), 1.into()])]),
            ]),
        );

        let model = editor.renderer_model();
        let cell = &model.windows[0].lines[0].as_ref().unwrap().cells[0];

        assert_eq!(
            cell.bg,
            Some(TerminalColor {
                r: 80,
                g: 96,
                b: 112
            })
        );
        assert_eq!(cell.blend, 35);
    }

    #[test]
    fn mode_info_sets_cursor_shape_and_blink_timing() {
        let mut editor = NeovimEditor::new(4, 1);
        editor.handle_event(
            "mode_info_set",
            &Value::Array(vec![
                true.into(),
                Value::Array(vec![Value::Map(vec![
                    ("cursor_shape".into(), "vertical".into()),
                    ("cell_percentage".into(), 25.into()),
                    ("blinkwait".into(), 300.into()),
                    ("blinkon".into(), 200.into()),
                    ("blinkoff".into(), 150.into()),
                ])]),
            ]),
        );
        editor.handle_event(
            "mode_change",
            &Value::Array(vec!["insert".into(), 0.into()]),
        );
        editor.handle_event(
            "grid_cursor_goto",
            &Value::Array(vec![DEFAULT_GRID.into(), 0.into(), 2.into()]),
        );

        let cursor = editor.renderer_model().cursor.unwrap();

        assert_eq!(cursor.style, "bar");
        assert_eq!(cursor.cell_percentage, 25);
        assert_eq!(cursor.blinkwait_ms, 300);
        assert_eq!(cursor.blinkon_ms, 200);
        assert_eq!(cursor.blinkoff_ms, 150);
    }

    #[test]
    fn mode_info_maps_horizontal_cursor_to_underline() {
        let mut editor = NeovimEditor::new(4, 1);
        editor.handle_event(
            "mode_info_set",
            &Value::Array(vec![
                true.into(),
                Value::Array(vec![Value::Map(vec![
                    ("cursor_shape".into(), "horizontal".into()),
                    ("cell_percentage".into(), 20.into()),
                ])]),
            ]),
        );
        editor.handle_event(
            "mode_change",
            &Value::Array(vec!["replace".into(), 0.into()]),
        );
        editor.handle_event(
            "grid_cursor_goto",
            &Value::Array(vec![DEFAULT_GRID.into(), 0.into(), 2.into()]),
        );

        let cursor = editor.renderer_model().cursor.unwrap();

        assert_eq!(cursor.style, "underline");
        assert_eq!(cursor.cell_percentage, 20);
    }

    #[test]
    fn popupmenu_events_expose_float_renderer_window() {
        let mut editor = NeovimEditor::new(24, 8);
        editor.handle_event("popupmenu_show", &popupmenu_show_event(2, 4, 0));

        let model = editor.renderer_model();
        let popup = model
            .windows
            .iter()
            .find(|window| window.grid_id == -1)
            .unwrap();

        assert_eq!(popup.top, 2);
        assert_eq!(popup.left, 4);
        assert_eq!(popup.window_kind, NeovideWindowKind::Float);
        assert!(
            popup.lines[0]
                .as_ref()
                .unwrap()
                .text
                .starts_with("POPUPONE")
        );
        assert!(popup.lines[0].as_ref().unwrap().cells[0].bg.is_some());

        editor.handle_event("popupmenu_select", &Value::Array(vec![1.into()]));
        let model = editor.renderer_model();
        let popup = model
            .windows
            .iter()
            .find(|window| window.grid_id == -1)
            .unwrap();
        assert!(popup.lines[1].as_ref().unwrap().cells[0].bg.is_some());

        assert!(editor.handle_event("popupmenu_hide", &Value::Array(vec![])));
        assert!(
            editor
                .renderer_model()
                .windows
                .iter()
                .all(|window| window.grid_id != -1)
        );
    }

    fn popupmenu_show_event(row: u64, col: u64, selected: i64) -> Value {
        Value::Array(vec![
            Value::Array(vec![
                Value::Array(vec![
                    "POPUPONE".into(),
                    "k".into(),
                    "menu".into(),
                    "".into(),
                ]),
                Value::Array(vec![
                    "POPUPTWO".into(),
                    "k".into(),
                    "menu".into(),
                    "".into(),
                ]),
            ]),
            selected.into(),
            row.into(),
            col.into(),
            DEFAULT_GRID.into(),
        ])
    }

    fn row_text(row: &[TerminalCellSnapshot]) -> String {
        row.iter().map(|cell| cell.text.as_str()).collect()
    }
}
