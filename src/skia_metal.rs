// The Skia/Metal boundary follows Neovide's MIT-licensed Metal renderer.
// Copyright (c) 2023 Neovide Contributors.
// See THIRD_PARTY_NOTICES.md for the audited source revision and license.

#[derive(Clone, Copy, Debug)]
pub struct SkiaRenderGeometry {
    pub width: i32,
    pub height: i32,
    pub origin_x: f32,
    pub origin_y: f32,
    pub content_width: f32,
    pub content_height: f32,
    pub cell_width: f32,
    pub cell_height: f32,
}

#[cfg(target_os = "macos")]
mod platform {
    use super::SkiaRenderGeometry;
    use crate::{
        neovide_render::{
            CriticallyDampedSpringAnimation, NeovideLine, NeovideRenderedWindowSnapshot,
            NeovideRendererModelSnapshot, NeovideWindowKind,
        },
        neovide_text::{NeovideTextRenderer, TextGridGeometry},
        neovim_runtime::NativeNeovimRuntime,
        terminal_runtime::{
            KittyImagePlacementSnapshot, NativeTerminalRuntime, TerminalCellSnapshot,
            TerminalCellStyle, TerminalColor, TerminalCursorSnapshot, TerminalUnderlineStyle,
        },
    };
    use skia_safe::{
        AlphaType, Canvas, Color, ColorSpace, ColorType, Data, Image, ImageInfo, Paint, Path,
        PathBuilder, Rect, Surface, SurfaceProps, SurfacePropsFlags,
        canvas::SrcRectConstraint,
        gpu::{
            self, DirectContext, SurfaceOrigin,
            mtl::{BackendContext, TextureInfo},
            surfaces::wrap_backend_render_target,
        },
        images,
    };
    use std::{
        cmp::Ordering,
        collections::{HashMap, HashSet},
        ffi::c_void,
        time::{Duration, Instant},
    };
    use unicode_segmentation::UnicodeSegmentation;
    use unicode_width::UnicodeWidthStr;

    const CURSOR_ANIMATION_LENGTH_SECONDS: f32 = 0.15;
    const CURSOR_SHORT_ANIMATION_LENGTH_SECONDS: f32 = 0.04;
    const CURSOR_BODY_ALPHA: u8 = 199;
    const MESSAGE_SELECTION_ALPHA: u8 = 89;
    const MAX_ANIMATION_DT: f32 = 1.0 / 30.0;

    pub struct NativeSkiaMetalRenderer {
        context: DirectContext,
        _backend: BackendContext,
        primary_font_family: Option<String>,
        runtime_states: HashMap<usize, RuntimeRenderState>,
        kitty_images: HashMap<(usize, u32), CachedKittyImage>,
        reported_kitty_failures: HashSet<usize>,
    }

    impl NativeSkiaMetalRenderer {
        /// # Safety
        ///
        /// `device` and `command_queue` must point to live Metal protocol objects
        /// that outlive the renderer.
        pub unsafe fn new(device: *mut c_void, command_queue: *mut c_void) -> Option<Self> {
            if device.is_null() || command_queue.is_null() {
                return None;
            }
            // SAFETY: Swift passes live MTLDevice and MTLCommandQueue protocol object pointers.
            let backend = unsafe { BackendContext::new(device, command_queue) };
            let context = gpu::direct_contexts::make_metal(&backend, None)?;
            Some(Self {
                context,
                _backend: backend,
                primary_font_family: None,
                runtime_states: HashMap::new(),
                kitty_images: HashMap::new(),
                reported_kitty_failures: HashSet::new(),
            })
        }

        /// # Safety
        ///
        /// `texture` must point to the current drawable MTLTexture and remain valid
        /// until Skia has flushed this frame.
        pub unsafe fn render_nvim(
            &mut self,
            runtime: &mut NativeNeovimRuntime,
            texture: *mut c_void,
            geometry: SkiaRenderGeometry,
            clear: bool,
            preedit: Option<&str>,
        ) -> bool {
            // SAFETY: `texture` is the current drawable texture pointer for this frame.
            let Some(mut surface) = (unsafe { self.surface(texture, geometry) }) else {
                return false;
            };
            let runtime_id = runtime as *const NativeNeovimRuntime as usize;
            let placements = match runtime.kitty_placements() {
                Ok(placements) => {
                    self.reported_kitty_failures.remove(&runtime_id);
                    placements
                }
                Err(error) => {
                    if self.reported_kitty_failures.insert(runtime_id) {
                        log::warn!(
                            target: "renderer",
                            "nvim_kitty_snapshot_failed runtime={runtime_id} error={error:#}"
                        );
                    }
                    Vec::new()
                }
            };
            retain_visible_kitty_images(&mut self.kitty_images, runtime_id, &placements);
            let primary_font_family = self.primary_font_family.as_deref();
            let state = self
                .runtime_states
                .entry(runtime_id)
                .or_insert_with(|| RuntimeRenderState::with_font_family(primary_font_family));
            let dt = state.animation_dt();
            state.scroll_animation_active =
                runtime.advance_renderer_animations(dt) || runtime.has_active_renderer_animation();
            let model = runtime.renderer_model();
            state.cursor_animation.update(&model, geometry, dt);
            state.cursor_blink.update(model.cursor.as_ref());
            state.text_blink_active = model_has_blink(&model);
            let preedit = state.preedit.prepare(
                preedit,
                model.background,
                model.cursor_color,
                preedit_available_columns(&model, geometry),
            );
            draw_model(
                surface.canvas(),
                &mut state.text_renderer,
                &state.cursor_animation,
                state.cursor_blink.should_render(),
                &model,
                geometry,
                ModelRenderOptions {
                    clear,
                    kitty_placements: &placements,
                    kitty_images: &mut self.kitty_images,
                    runtime_id,
                    preedit,
                },
            );
            self.context.flush_and_submit();
            true
        }

        /// # Safety
        ///
        /// `texture` must point to the current drawable MTLTexture and remain valid
        /// until Skia has flushed this frame.
        pub unsafe fn render_terminal(
            &mut self,
            runtime: &mut NativeTerminalRuntime,
            texture: *mut c_void,
            geometry: SkiaRenderGeometry,
            clear: bool,
            preedit: Option<&str>,
        ) -> bool {
            // SAFETY: `texture` is the current drawable texture pointer for this frame.
            let Some(mut surface) = (unsafe { self.surface(texture, geometry) }) else {
                return false;
            };
            let runtime_id = runtime as *const NativeTerminalRuntime as usize;
            let placements = match runtime.kitty_placements() {
                Ok(placements) => {
                    self.reported_kitty_failures.remove(&runtime_id);
                    placements
                }
                Err(error) => {
                    if self.reported_kitty_failures.insert(runtime_id) {
                        log::warn!(
                            target: "renderer",
                            "kitty_snapshot_failed runtime={runtime_id} error={error:#}"
                        );
                    }
                    Vec::new()
                }
            };
            retain_visible_kitty_images(&mut self.kitty_images, runtime_id, &placements);
            let primary_font_family = self.primary_font_family.as_deref();
            let state = self
                .runtime_states
                .entry(runtime_id)
                .or_insert_with(|| RuntimeRenderState::with_font_family(primary_font_family));
            let dt = state.animation_dt();
            let Some(model) = prepare_terminal_renderer_model(state, runtime, dt) else {
                return false;
            };
            state.cursor_animation.update(&model, geometry, dt);
            state.cursor_blink.update(model.cursor.as_ref());
            state.text_blink_active = model_has_blink(&model);
            let preedit = state.preedit.prepare(
                preedit,
                model.background,
                model.cursor_color,
                preedit_available_columns(&model, geometry),
            );
            draw_model(
                surface.canvas(),
                &mut state.text_renderer,
                &state.cursor_animation,
                state.cursor_blink.should_render(),
                &model,
                geometry,
                ModelRenderOptions {
                    clear,
                    kitty_placements: &placements,
                    kitty_images: &mut self.kitty_images,
                    runtime_id,
                    preedit,
                },
            );
            self.context.flush_and_submit();
            true
        }

        pub fn needs_animation_frame(&self) -> bool {
            self.next_frame_delay_ms().is_some()
        }

        pub fn set_font_family(&mut self, family: Option<&str>) {
            self.primary_font_family = family.map(str::to_owned);
            for state in self.runtime_states.values_mut() {
                state.text_renderer.set_primary_font_family(family);
            }
        }

        pub fn forget_runtime(&mut self, runtime_id: usize) {
            self.runtime_states.remove(&runtime_id);
            self.kitty_images
                .retain(|(owner, _), _| *owner != runtime_id);
            self.reported_kitty_failures.remove(&runtime_id);
        }

        pub fn next_frame_delay_ms(&self) -> Option<u64> {
            self.runtime_states
                .values()
                .filter_map(RuntimeRenderState::next_frame_delay_ms)
                .min()
        }

        unsafe fn surface(
            &mut self,
            texture: *mut c_void,
            geometry: SkiaRenderGeometry,
        ) -> Option<Surface> {
            if texture.is_null() || geometry.width <= 0 || geometry.height <= 0 {
                return None;
            }
            // SAFETY: Swift passes the current drawable MTLTexture pointer for this frame.
            let texture_info = unsafe { TextureInfo::new(texture) };
            let backend = gpu::backend_render_targets::make_mtl(
                (geometry.width, geometry.height),
                &texture_info,
            );
            wrap_backend_render_target(
                &mut self.context,
                &backend,
                SurfaceOrigin::TopLeft,
                ColorType::BGRA8888,
                ColorSpace::new_srgb(),
                Some(surface_props()).as_ref(),
            )
        }
    }

    #[derive(Default)]
    struct RuntimeRenderState {
        text_renderer: NeovideTextRenderer,
        preedit: PreeditLineCache,
        cursor_animation: CursorAnimationState,
        cursor_blink: CursorBlinkState,
        last_frame_at: Option<Instant>,
        scroll_animation_active: bool,
        text_blink_active: bool,
    }

    impl RuntimeRenderState {
        fn with_font_family(family: Option<&str>) -> Self {
            let mut state = Self::default();
            state.text_renderer.set_primary_font_family(family);
            state
        }

        fn animation_dt(&mut self) -> f32 {
            let now = Instant::now();
            let dt = self
                .last_frame_at
                .replace(now)
                .map_or(0.0, |previous| now.duration_since(previous).as_secs_f32());
            dt.min(MAX_ANIMATION_DT)
        }

        fn next_frame_delay_ms(&self) -> Option<u64> {
            if self.cursor_animation.needs_animation_frame() || self.scroll_animation_active {
                return Some(0);
            }
            let cursor_delay = self.cursor_blink.next_frame_delay_ms();
            let text_delay = self.text_blink_active.then_some(500);
            match (cursor_delay, text_delay) {
                (Some(cursor), Some(text)) => Some(cursor.min(text)),
                (Some(cursor), None) => Some(cursor),
                (None, Some(text)) => Some(text),
                (None, None) => None,
            }
        }
    }

    fn prepare_terminal_renderer_model(
        state: &mut RuntimeRenderState,
        runtime: &mut NativeTerminalRuntime,
        dt: f32,
    ) -> Option<NeovideRendererModelSnapshot> {
        _ = runtime.advance_renderer_animations(dt);
        // Terminal VT scroll commands are retained until renderer_model builds
        // this frame. Check animation state afterwards so an otherwise idle TUI
        // always schedules the frames needed to finish the scroll spring.
        let model = runtime.renderer_model().ok()?;
        state.scroll_animation_active = runtime.has_active_renderer_animation();
        Some(model)
    }

    fn model_has_blink(model: &NeovideRendererModelSnapshot) -> bool {
        model
            .windows
            .iter()
            .any(|window| window.lines.iter().flatten().any(|line| line.has_blink()))
    }

    struct ModelRenderOptions<'a> {
        clear: bool,
        kitty_placements: &'a [KittyImagePlacementSnapshot],
        kitty_images: &'a mut HashMap<(usize, u32), CachedKittyImage>,
        runtime_id: usize,
        preedit: Option<&'a NeovideLine>,
    }

    fn draw_model(
        canvas: &Canvas,
        text_renderer: &mut NeovideTextRenderer,
        cursor_animation: &CursorAnimationState,
        cursor_visible: bool,
        model: &NeovideRendererModelSnapshot,
        geometry: SkiaRenderGeometry,
        options: ModelRenderOptions<'_>,
    ) {
        text_renderer.update_geometry(text_grid_geometry(geometry));
        if options.clear {
            canvas.clear(color(model.background));
        }
        canvas.save();
        canvas.clip_rect(content_rect(geometry), None, Some(false));
        fill_content(canvas, model.background, geometry);
        draw_kitty_images(
            canvas,
            options.kitty_placements,
            &mut *options.kitty_images,
            options.runtime_id,
            model,
            geometry,
            |z| z < 0,
        );
        let mut floating_layer = Vec::new();
        for window in sorted_windows(&model.windows) {
            match window.window_kind {
                NeovideWindowKind::Float => floating_layer.push(window),
                NeovideWindowKind::Normal | NeovideWindowKind::Message => {
                    draw_floating_layer(
                        canvas,
                        text_renderer,
                        &floating_layer,
                        model.background,
                        geometry,
                    );
                    floating_layer.clear();
                    draw_window(
                        canvas,
                        text_renderer,
                        window,
                        model.background,
                        geometry,
                        true,
                    );
                }
            }
        }
        draw_floating_layer(
            canvas,
            text_renderer,
            &floating_layer,
            model.background,
            geometry,
        );
        draw_kitty_images(
            canvas,
            options.kitty_placements,
            &mut *options.kitty_images,
            options.runtime_id,
            model,
            geometry,
            |z| z >= 0,
        );
        draw_message_selection(canvas, model, geometry);
        draw_cursor(canvas, cursor_animation, cursor_visible, model);
        if let Some(preedit) = options.preedit {
            draw_preedit(canvas, text_renderer, model, geometry, preedit);
        }
        text_renderer.cleanup_font_cache();
        canvas.restore();
    }

    fn draw_preedit(
        canvas: &Canvas,
        text_renderer: &mut NeovideTextRenderer,
        model: &NeovideRendererModelSnapshot,
        geometry: SkiaRenderGeometry,
        line: &NeovideLine,
    ) {
        let Some(cursor) = model.cursor.as_ref() else {
            return;
        };
        let point = cursor_render_point(model, cursor);
        let column = point.x.max(0.0).floor() as usize;
        if line.cells.is_empty() {
            return;
        }
        draw_line_backgrounds(canvas, line, point.y, column, line.cells.len(), geometry);
        text_renderer.draw_line(canvas, line, point.y, column, line.cells.len());
    }

    fn preedit_available_columns(
        model: &NeovideRendererModelSnapshot,
        geometry: SkiaRenderGeometry,
    ) -> usize {
        let Some(cursor) = model.cursor.as_ref() else {
            return 0;
        };
        let column = cursor_render_point(model, cursor).x.max(0.0).floor() as usize;
        let grid_width = (geometry.content_width / geometry.cell_width.max(1.0)).floor() as usize;
        grid_width.saturating_sub(column)
    }

    #[derive(Default)]
    struct PreeditLineCache {
        text: String,
        foreground: Option<TerminalColor>,
        background: Option<TerminalColor>,
        max_columns: usize,
        line: Option<NeovideLine>,
    }

    impl PreeditLineCache {
        fn prepare(
            &mut self,
            text: Option<&str>,
            foreground: TerminalColor,
            background: TerminalColor,
            max_columns: usize,
        ) -> Option<&NeovideLine> {
            let text = text.filter(|value| !value.is_empty())?;
            let changed = self.text != text
                || self.foreground != Some(foreground)
                || self.background != Some(background)
                || self.max_columns != max_columns;
            if changed {
                self.text.clear();
                self.text.push_str(text);
                self.foreground = Some(foreground);
                self.background = Some(background);
                self.max_columns = max_columns;
                self.line = Some(preedit_line(text, foreground, background, max_columns));
            }
            self.line.as_ref()
        }
    }

    fn preedit_line(
        text: &str,
        foreground: TerminalColor,
        background: TerminalColor,
        max_columns: usize,
    ) -> NeovideLine {
        let style = preedit_cell_style(foreground);
        let mut cells = Vec::new();
        for grapheme in text.graphemes(true) {
            let width = UnicodeWidthStr::width(grapheme).max(1);
            if cells.len().saturating_add(width) > max_columns {
                break;
            }
            cells.push(preedit_cell(grapheme, foreground, Some(background), style));
            cells
                .extend((1..width).map(|_| preedit_cell(" ", foreground, Some(background), style)));
        }
        NeovideLine::from_cells(cells)
    }

    fn preedit_cell_style(underline_color: TerminalColor) -> TerminalCellStyle {
        TerminalCellStyle {
            underline: true,
            underline_style: TerminalUnderlineStyle::Single,
            underline_color: Some(underline_color),
            ..TerminalCellStyle::default()
        }
    }

    fn preedit_cell(
        text: &str,
        foreground: TerminalColor,
        background: Option<TerminalColor>,
        style: TerminalCellStyle,
    ) -> TerminalCellSnapshot {
        TerminalCellSnapshot {
            text: text.to_owned(),
            fg: foreground,
            bg: background,
            blend: 0,
            style,
        }
    }

    fn draw_kitty_images(
        canvas: &Canvas,
        placements: &[KittyImagePlacementSnapshot],
        image_cache: &mut HashMap<(usize, u32), CachedKittyImage>,
        runtime_id: usize,
        model: &NeovideRendererModelSnapshot,
        geometry: SkiaRenderGeometry,
        layer: impl Fn(i32) -> bool,
    ) {
        for placement in placements.iter().filter(|placement| layer(placement.z)) {
            let Ok(width) = i32::try_from(placement.image_width) else {
                continue;
            };
            let Ok(height) = i32::try_from(placement.image_height) else {
                continue;
            };
            let key = (runtime_id, placement.image_id);
            if image_cache.get(&key).is_none_or(|cached| {
                cached.image_number != placement.image_number
                    || cached.width != placement.image_width
                    || cached.height != placement.image_height
            }) {
                let info = ImageInfo::new(
                    (width, height),
                    ColorType::RGBA8888,
                    AlphaType::Unpremul,
                    None,
                );
                let Some(image) = images::raster_from_data(
                    &info,
                    Data::new_copy(placement.rgba.as_ref()),
                    usize::try_from(placement.image_width)
                        .unwrap_or(usize::MAX)
                        .saturating_mul(4),
                ) else {
                    continue;
                };
                image_cache.insert(
                    key,
                    CachedKittyImage {
                        image_number: placement.image_number,
                        width: placement.image_width,
                        height: placement.image_height,
                        image,
                    },
                );
            }
            let Some(image) = image_cache.get(&key).map(|cached| &cached.image) else {
                continue;
            };
            let source = Rect::from_xywh(
                placement.source_x as f32,
                placement.source_y as f32,
                placement.source_width as f32,
                placement.source_height as f32,
            );
            let destination = Rect::from_xywh(
                geometry.origin_x
                    + placement.viewport_col as f32 * geometry.cell_width
                    + placement.x_offset as f32,
                geometry.origin_y
                    + animated_kitty_row(model, placement.viewport_row) * geometry.cell_height
                    + placement.y_offset as f32,
                placement.pixel_width as f32,
                placement.pixel_height as f32,
            );
            let paint = Paint::default();
            canvas.draw_image_rect(
                image,
                Some((&source, SrcRectConstraint::Strict)),
                destination,
                &paint,
            );
        }
    }

    fn retain_visible_kitty_images(
        image_cache: &mut HashMap<(usize, u32), CachedKittyImage>,
        runtime_id: usize,
        placements: &[KittyImagePlacementSnapshot],
    ) {
        let visible_image_ids = placements
            .iter()
            .map(|placement| placement.image_id)
            .collect::<HashSet<_>>();
        image_cache.retain(|(owner, image_id), _| {
            *owner != runtime_id || visible_image_ids.contains(image_id)
        });
    }

    fn animated_kitty_row(model: &NeovideRendererModelSnapshot, viewport_row: i32) -> f32 {
        let row = viewport_row as f32;
        let Some(window) = model.windows.iter().find(|window| {
            window.grid_id == 1
                && window.window_kind == crate::neovide_render::NeovideWindowKind::Normal
        }) else {
            return row;
        };
        let inner = window.inner_row_range();
        if viewport_row < i32::try_from(inner.end).unwrap_or(i32::MAX) {
            row - window.scroll_position
        } else {
            row
        }
    }

    struct CachedKittyImage {
        image_number: u32,
        width: u32,
        height: u32,
        image: Image,
    }

    fn text_grid_geometry(geometry: SkiaRenderGeometry) -> TextGridGeometry {
        TextGridGeometry {
            origin_x: geometry.origin_x,
            origin_y: geometry.origin_y,
            cell_width: geometry.cell_width,
            cell_height: geometry.cell_height,
        }
    }

    fn fill_content(canvas: &Canvas, background: TerminalColor, geometry: SkiaRenderGeometry) {
        let rect = content_rect(geometry);
        let mut paint = Paint::default();
        paint.set_color(color(background));
        canvas.draw_rect(rect, &paint);
    }

    fn content_rect(geometry: SkiaRenderGeometry) -> Rect {
        Rect::from_xywh(
            geometry.origin_x,
            geometry.origin_y,
            geometry.content_width,
            geometry.content_height,
        )
    }

    fn sorted_windows(
        windows: &[NeovideRenderedWindowSnapshot],
    ) -> Vec<&NeovideRenderedWindowSnapshot> {
        let mut windows = windows
            .iter()
            .filter(|window| !window.hidden)
            .collect::<Vec<_>>();
        windows.sort_by(window_order);
        windows
    }

    fn window_order(
        left: &&NeovideRenderedWindowSnapshot,
        right: &&NeovideRenderedWindowSnapshot,
    ) -> Ordering {
        (left.zindex, left.compindex, left.grid_id).cmp(&(
            right.zindex,
            right.compindex,
            right.grid_id,
        ))
    }

    fn draw_window(
        canvas: &Canvas,
        text_renderer: &mut NeovideTextRenderer,
        window: &NeovideRenderedWindowSnapshot,
        background: TerminalColor,
        geometry: SkiaRenderGeometry,
        fill_background: bool,
    ) {
        // Normal windows and isolated message layers clear their retained
        // surface before drawing cached lines. This lets a resized foreground
        // window cover root-grid separators that Neovim does not resend.
        if fill_background {
            fill_window_background(canvas, background, window, geometry);
        }
        let inner = window.inner_row_range();
        draw_fixed_lines(canvas, text_renderer, window, 0..inner.start, geometry);
        draw_scrollable_lines(canvas, text_renderer, window, inner.clone(), geometry);
        draw_fixed_lines(
            canvas,
            text_renderer,
            window,
            inner.end..window.height,
            geometry,
        );
    }

    fn draw_floating_layer(
        canvas: &Canvas,
        text_renderer: &mut NeovideTextRenderer,
        windows: &[&NeovideRenderedWindowSnapshot],
        background: TerminalColor,
        geometry: SkiaRenderGeometry,
    ) {
        // Neovide composites overlapping floating grids on one layer. Clear
        // their combined footprint before drawing any grid so a later border
        // grid cannot erase text already drawn by an overlapping content grid
        // (Telescope uses this topology for results, prompt, and preview).
        for window in windows {
            fill_window_background(canvas, background, window, geometry);
        }
        for window in windows {
            draw_window(canvas, text_renderer, window, background, geometry, false);
        }
    }

    fn draw_message_selection(
        canvas: &Canvas,
        model: &NeovideRendererModelSnapshot,
        geometry: SkiaRenderGeometry,
    ) {
        let Some(selection) = model.message_selection else {
            return;
        };
        let Some(window) = model.windows.iter().find(|window| {
            window.grid_id == selection.grid_id
                && !window.hidden
                && window.window_kind == NeovideWindowKind::Message
        }) else {
            return;
        };
        if window.width == 0 || window.height == 0 {
            return;
        }

        let (row_start, row_end) = ordered(
            selection.start.row.min(window.height - 1),
            selection.end.row.min(window.height - 1),
        );
        let (col_start, col_end) = ordered(
            selection.start.col.min(window.width - 1),
            selection.end.col.min(window.width - 1),
        );
        let window_rect = Rect::from_xywh(
            geometry.origin_x + window.left as f32 * geometry.cell_width,
            geometry.origin_y + window.top as f32 * geometry.cell_height,
            window.width as f32 * geometry.cell_width,
            window.height as f32 * geometry.cell_height,
        );
        let mut paint = Paint::default();
        paint.set_anti_alias(false);
        paint.set_color(color_with_alpha(
            model.cursor_color,
            MESSAGE_SELECTION_ALPHA,
        ));

        canvas.save();
        canvas.clip_rect(window_rect, None, Some(false));
        for row in row_start..=row_end {
            let start_col = if row == row_start { col_start } else { 0 };
            let end_col = if row == row_end {
                col_end
            } else {
                window.width - 1
            };
            canvas.draw_rect(
                Rect::from_xywh(
                    geometry.origin_x + (window.left + start_col) as f32 * geometry.cell_width,
                    geometry.origin_y + (window.top + row) as f32 * geometry.cell_height,
                    (end_col - start_col + 1) as f32 * geometry.cell_width,
                    geometry.cell_height,
                ),
                &paint,
            );
        }
        canvas.restore();
    }

    fn ordered(left: usize, right: usize) -> (usize, usize) {
        if left <= right {
            (left, right)
        } else {
            (right, left)
        }
    }

    fn fill_window_background(
        canvas: &Canvas,
        background: TerminalColor,
        window: &NeovideRenderedWindowSnapshot,
        geometry: SkiaRenderGeometry,
    ) {
        let rect = Rect::from_xywh(
            geometry.origin_x + window.left as f32 * geometry.cell_width,
            geometry.origin_y + window.top as f32 * geometry.cell_height,
            window.width as f32 * geometry.cell_width,
            window.height as f32 * geometry.cell_height,
        );
        let mut paint = Paint::default();
        paint.set_color(color(background));
        canvas.draw_rect(rect, &paint);
    }

    fn draw_fixed_lines(
        canvas: &Canvas,
        text_renderer: &mut NeovideTextRenderer,
        window: &NeovideRenderedWindowSnapshot,
        rows: std::ops::Range<usize>,
        geometry: SkiaRenderGeometry,
    ) {
        for row in rows {
            let Some(line) = window.lines.get(row).and_then(Option::as_ref) else {
                continue;
            };
            draw_line(
                canvas,
                text_renderer,
                line,
                window.top as f32 + row as f32,
                window,
                geometry,
            );
        }
    }

    fn draw_scrollable_lines(
        canvas: &Canvas,
        text_renderer: &mut NeovideTextRenderer,
        window: &NeovideRenderedWindowSnapshot,
        inner: std::ops::Range<usize>,
        geometry: SkiaRenderGeometry,
    ) {
        if inner.is_empty() {
            return;
        }

        canvas.save();
        canvas.clip_rect(
            scroll_clip_rect(window, inner.clone(), geometry),
            None,
            Some(false),
        );
        let floor = window.scroll_position.floor();
        canvas.translate((
            0.0,
            scroll_offset_pixels(window.scroll_position, geometry.cell_height),
        ));
        let signed_start = floor as isize;
        for inner_row in 0..=inner.len() {
            let Some(line) = window.scrollback_line(signed_start + inner_row as isize) else {
                continue;
            };
            let row = window.top as f32 + inner.start as f32 + inner_row as f32;
            draw_line(canvas, text_renderer, line, row, window, geometry);
        }
        canvas.restore();
    }

    fn scroll_offset_pixels(scroll_position: f32, cell_height: f32) -> f32 {
        ((scroll_position.floor() - scroll_position) * cell_height).round()
    }

    fn draw_line(
        canvas: &Canvas,
        text_renderer: &mut NeovideTextRenderer,
        line: &crate::neovide_render::NeovideLine,
        row: f32,
        window: &NeovideRenderedWindowSnapshot,
        geometry: SkiaRenderGeometry,
    ) {
        draw_line_backgrounds(canvas, line, row, window.left, window.width, geometry);
        text_renderer.draw_line(canvas, line, row, window.left, window.width);
    }

    fn scroll_clip_rect(
        window: &NeovideRenderedWindowSnapshot,
        inner: std::ops::Range<usize>,
        geometry: SkiaRenderGeometry,
    ) -> Rect {
        Rect::from_xywh(
            geometry.origin_x + window.left as f32 * geometry.cell_width,
            geometry.origin_y + (window.top + inner.start) as f32 * geometry.cell_height,
            window.width as f32 * geometry.cell_width,
            inner.len() as f32 * geometry.cell_height,
        )
    }

    fn draw_line_backgrounds(
        canvas: &Canvas,
        line: &crate::neovide_render::NeovideLine,
        row: f32,
        window_left: usize,
        width: usize,
        geometry: SkiaRenderGeometry,
    ) {
        let y = geometry.origin_y + row * geometry.cell_height;
        for run in line.background_runs() {
            let start_col = run.start_col.min(width);
            let end_col = run.end_col.min(width);
            if start_col >= end_col {
                continue;
            }
            let x = geometry.origin_x + (window_left + start_col) as f32 * geometry.cell_width;
            draw_background_run(
                canvas,
                run.background,
                run.blend,
                x,
                y,
                (end_col - start_col) as f32 * geometry.cell_width,
                geometry.cell_height,
            );
        }
    }

    fn draw_background_run(
        canvas: &Canvas,
        background: TerminalColor,
        blend: u8,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    ) {
        let mut paint = Paint::default();
        paint.set_color(color_with_blend(background, blend));
        canvas.draw_rect(Rect::from_xywh(x, y, width, height), &paint);
    }

    fn draw_cursor(
        canvas: &Canvas,
        cursor_animation: &CursorAnimationState,
        cursor_visible: bool,
        model: &NeovideRendererModelSnapshot,
    ) {
        if model.cursor.is_none() || !cursor_visible {
            return;
        }
        let Some(path) = cursor_animation.path() else {
            return;
        };
        let mut paint = Paint::default();
        paint.set_anti_alias(true);
        paint.set_color(color_with_alpha(model.cursor_color, CURSOR_BODY_ALPHA));
        canvas.draw_path(&path, &paint);
    }

    fn cursor_render_point(
        model: &NeovideRendererModelSnapshot,
        cursor: &TerminalCursorSnapshot,
    ) -> GridPoint {
        adjust_cursor_point_for_scroll(model, GridPoint::from_cursor(cursor))
    }

    fn adjust_cursor_point_for_scroll(
        model: &NeovideRendererModelSnapshot,
        point: GridPoint,
    ) -> GridPoint {
        let Some(parent_grid_id) = model.cursor_parent_grid_id else {
            return point;
        };
        let Some(window) = model
            .windows
            .iter()
            .find(|window| window.grid_id == parent_grid_id && !window.hidden)
        else {
            return point;
        };
        let local_y = point.y - window.top as f32;
        let inner = window.inner_row_range();
        if local_y < inner.start as f32 || local_y >= inner.end as f32 {
            return point;
        }
        let minimum_y = window.top as f32 + inner.start as f32;
        let maximum_y = window.top as f32 + inner.end.saturating_sub(1) as f32;
        GridPoint {
            x: point.x,
            y: (point.y - window.scroll_position).clamp(minimum_y, maximum_y),
        }
    }

    fn surface_props() -> SurfaceProps {
        SurfaceProps::new_with_text_properties(
            SurfacePropsFlags::default(),
            skia_safe::PixelGeometry::RGBH,
            0.0,
            0.0,
        )
    }

    fn color(color: TerminalColor) -> Color {
        Color::from_argb(255, color.r, color.g, color.b)
    }

    fn color_with_alpha(color: TerminalColor, alpha: u8) -> Color {
        Color::from_argb(alpha, color.r, color.g, color.b)
    }

    fn color_with_blend(color: TerminalColor, blend: u8) -> Color {
        let alpha = 255_u16.saturating_mul(100_u16.saturating_sub(blend.min(100) as u16)) / 100;
        Color::from_argb(alpha as u8, color.r, color.g, color.b)
    }

    #[derive(Clone, Copy, Debug, PartialEq)]
    struct GridPoint {
        x: f32,
        y: f32,
    }

    impl GridPoint {
        fn from_cursor(cursor: &TerminalCursorSnapshot) -> Self {
            Self {
                x: cursor.x as f32,
                y: cursor.y as f32,
            }
        }
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    struct CursorBlinkSignature {
        x: u16,
        y: u16,
        style: &'static str,
        cell_percentage: u8,
        blinkwait_ms: u64,
        blinkon_ms: u64,
        blinkoff_ms: u64,
    }

    impl CursorBlinkSignature {
        fn from_cursor(cursor: &TerminalCursorSnapshot) -> Self {
            Self {
                x: cursor.x,
                y: cursor.y,
                style: cursor.style,
                cell_percentage: cursor.cell_percentage,
                blinkwait_ms: cursor.blinkwait_ms,
                blinkon_ms: cursor.blinkon_ms,
                blinkoff_ms: cursor.blinkoff_ms,
            }
        }

        fn is_static(self) -> bool {
            self.blinkon_ms == 0 || self.blinkoff_ms == 0
        }

        fn delay_for(self, phase: CursorBlinkPhase) -> Duration {
            let millis = match phase {
                CursorBlinkPhase::Waiting => self.blinkwait_ms,
                CursorBlinkPhase::On => self.blinkon_ms,
                CursorBlinkPhase::Off => self.blinkoff_ms,
            };
            Duration::from_millis(millis)
        }
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum CursorBlinkPhase {
        Waiting,
        On,
        Off,
    }

    impl CursorBlinkPhase {
        fn next(self) -> Self {
            match self {
                Self::Waiting | Self::Off => Self::On,
                Self::On => Self::Off,
            }
        }
    }

    #[derive(Default)]
    struct CursorBlinkState {
        phase: Option<CursorBlinkPhase>,
        transition_at: Option<Instant>,
        cursor: Option<CursorBlinkSignature>,
    }

    impl CursorBlinkState {
        fn update(&mut self, cursor: Option<&TerminalCursorSnapshot>) {
            self.update_at(Instant::now(), cursor);
        }

        fn update_at(&mut self, now: Instant, cursor: Option<&TerminalCursorSnapshot>) {
            let Some(cursor) = cursor.map(CursorBlinkSignature::from_cursor) else {
                self.clear();
                return;
            };
            if self.cursor != Some(cursor) {
                self.start(now, cursor);
            }
            if cursor.is_static() {
                self.phase = Some(CursorBlinkPhase::Waiting);
                self.transition_at = None;
                return;
            }
            self.advance(now, cursor);
        }

        fn clear(&mut self) {
            self.phase = None;
            self.transition_at = None;
            self.cursor = None;
        }

        fn should_render(&self) -> bool {
            !matches!(self.phase, Some(CursorBlinkPhase::Off))
        }

        fn next_frame_delay_ms(&self) -> Option<u64> {
            let deadline = self.transition_at?;
            let delay = deadline.saturating_duration_since(Instant::now());
            Some(delay.as_millis().min(u64::MAX as u128) as u64)
        }

        fn start(&mut self, now: Instant, cursor: CursorBlinkSignature) {
            self.cursor = Some(cursor);
            let phase = if cursor.blinkwait_ms > 0 {
                CursorBlinkPhase::Waiting
            } else {
                CursorBlinkPhase::On
            };
            self.phase = Some(phase);
            self.transition_at = (!cursor.is_static()).then_some(now + cursor.delay_for(phase));
        }

        fn advance(&mut self, now: Instant, cursor: CursorBlinkSignature) {
            let (Some(mut phase), Some(mut transition_at)) = (self.phase, self.transition_at)
            else {
                return;
            };
            if transition_at > now {
                return;
            }
            phase = phase.next();
            transition_at += cursor.delay_for(phase);
            if transition_at <= now {
                transition_at = now + cursor.delay_for(phase);
            }
            self.phase = Some(phase);
            self.transition_at = Some(transition_at);
        }
    }

    #[derive(Clone, Copy, Debug, Default, PartialEq)]
    struct PixelPoint {
        x: f32,
        y: f32,
    }

    impl PixelPoint {
        fn offset(self, other: Self) -> Self {
            Self {
                x: self.x + other.x,
                y: self.y + other.y,
            }
        }

        fn difference(self, other: Self) -> Self {
            Self {
                x: self.x - other.x,
                y: self.y - other.y,
            }
        }

        fn scale(self, x: f32, y: f32) -> Self {
            Self {
                x: self.x * x,
                y: self.y * y,
            }
        }

        fn normalized(self) -> Self {
            let length = self.x.hypot(self.y);
            if length <= f32::EPSILON {
                return Self::default();
            }
            Self {
                x: self.x / length,
                y: self.y / length,
            }
        }

        fn dot(self, other: Self) -> f32 {
            self.x * other.x + self.y * other.y
        }
    }

    #[derive(Clone)]
    struct CursorCorner {
        current_position: PixelPoint,
        relative_position: PixelPoint,
        previous_destination: Option<PixelPoint>,
        animation_x: CriticallyDampedSpringAnimation,
        animation_y: CriticallyDampedSpringAnimation,
        animation_length: f32,
    }

    impl CursorCorner {
        fn new() -> Self {
            Self {
                current_position: PixelPoint::default(),
                relative_position: PixelPoint::default(),
                previous_destination: None,
                animation_x: CriticallyDampedSpringAnimation::new(),
                animation_y: CriticallyDampedSpringAnimation::new(),
                animation_length: 0.0,
            }
        }

        fn destination(
            &self,
            center_destination: PixelPoint,
            cursor_dimensions: PixelPoint,
        ) -> PixelPoint {
            center_destination.offset(
                self.relative_position
                    .scale(cursor_dimensions.x, cursor_dimensions.y),
            )
        }

        fn direction_alignment(
            &self,
            center_destination: PixelPoint,
            cursor_dimensions: PixelPoint,
        ) -> f32 {
            let destination = self.destination(center_destination, cursor_dimensions);
            destination
                .difference(self.current_position)
                .normalized()
                .dot(self.relative_position.normalized())
        }

        fn jump(
            &mut self,
            center_destination: PixelPoint,
            cursor_dimensions: PixelPoint,
            rank: usize,
        ) {
            let destination = self.destination(center_destination, cursor_dimensions);
            let previous = self.previous_destination.unwrap_or(destination);
            let jump = destination
                .difference(previous)
                .scale(1.0 / cursor_dimensions.x, 1.0 / cursor_dimensions.y);
            self.animation_length = if jump.x.abs() <= 2.001 && jump.y.abs() <= 0.001 {
                CURSOR_SHORT_ANIMATION_LENGTH_SECONDS
            } else {
                match rank {
                    2..=3 => 0.0,
                    1 => CURSOR_ANIMATION_LENGTH_SECONDS / 2.0,
                    _ => CURSOR_ANIMATION_LENGTH_SECONDS,
                }
            };
        }

        fn update(
            &mut self,
            center_destination: PixelPoint,
            cursor_dimensions: PixelPoint,
            dt: f32,
        ) -> bool {
            let destination = self.destination(center_destination, cursor_dimensions);
            if self.previous_destination != Some(destination) {
                let delta = destination.difference(self.current_position);
                self.animation_x.position = delta.x;
                self.animation_y.position = delta.y;
                self.previous_destination = Some(destination);
            }
            let mut animating = self.animation_x.update(dt, self.animation_length);
            animating |= self.animation_y.update(dt, self.animation_length);
            self.current_position = PixelPoint {
                x: destination.x - self.animation_x.position,
                y: destination.y - self.animation_y.position,
            };
            animating
        }

        fn snap(&mut self, center_destination: PixelPoint, cursor_dimensions: PixelPoint) {
            let destination = self.destination(center_destination, cursor_dimensions);
            self.current_position = destination;
            self.previous_destination = Some(destination);
            self.animation_x.reset();
            self.animation_y.reset();
        }
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    struct CursorShapeSignature {
        style: &'static str,
        cell_percentage: u8,
    }

    impl CursorShapeSignature {
        fn from_cursor(cursor: &TerminalCursorSnapshot) -> Self {
            Self {
                style: cursor.style,
                cell_percentage: cursor.cell_percentage,
            }
        }
    }

    struct CursorAnimationState {
        corners: [CursorCorner; 4],
        previous_cursor_position: Option<(Option<i64>, u16, u16)>,
        previous_shape: Option<CursorShapeSignature>,
        initialized: bool,
        animating: bool,
    }

    impl Default for CursorAnimationState {
        fn default() -> Self {
            Self {
                corners: std::array::from_fn(|_| CursorCorner::new()),
                previous_cursor_position: None,
                previous_shape: None,
                initialized: false,
                animating: false,
            }
        }
    }

    impl CursorAnimationState {
        fn update(
            &mut self,
            model: &NeovideRendererModelSnapshot,
            geometry: SkiaRenderGeometry,
            dt: f32,
        ) {
            let Some(cursor) = model.cursor.as_ref() else {
                self.clear();
                return;
            };
            let shape = CursorShapeSignature::from_cursor(cursor);
            if self.previous_shape != Some(shape) {
                self.set_cursor_shape(shape);
                self.previous_shape = Some(shape);
            }

            let point = cursor_render_point(model, cursor);
            let cursor_dimensions = PixelPoint {
                x: geometry.cell_width,
                y: geometry.cell_height,
            };
            let center_destination = PixelPoint {
                x: geometry.origin_x + (point.x + 0.5) * geometry.cell_width,
                y: geometry.origin_y + (point.y + 0.5) * geometry.cell_height,
            };
            let cursor_position = (model.cursor_parent_grid_id, cursor.x, cursor.y);
            let jumped = self.previous_cursor_position != Some(cursor_position);

            if !self.initialized {
                for corner in &mut self.corners {
                    corner.snap(center_destination, cursor_dimensions);
                }
                self.previous_cursor_position = Some(cursor_position);
                self.initialized = true;
                self.animating = false;
                return;
            }

            if jumped {
                let mut alignments = self
                    .corners
                    .iter()
                    .enumerate()
                    .map(|(id, corner)| {
                        (
                            id,
                            corner.direction_alignment(center_destination, cursor_dimensions),
                        )
                    })
                    .collect::<Vec<_>>();
                alignments.sort_by(|left, right| {
                    left.1
                        .partial_cmp(&right.1)
                        .unwrap_or(Ordering::Equal)
                        .then(left.0.cmp(&right.0))
                });
                let mut ranks = [0; 4];
                for (rank, (id, _)) in alignments.into_iter().enumerate() {
                    ranks[id] = rank;
                }
                for (id, corner) in self.corners.iter_mut().enumerate() {
                    corner.jump(center_destination, cursor_dimensions, ranks[id]);
                }
            }

            self.animating = self.corners.iter_mut().fold(false, |animating, corner| {
                corner.update(center_destination, cursor_dimensions, dt) | animating
            });
            self.previous_cursor_position = Some(cursor_position);
        }

        fn set_cursor_shape(&mut self, shape: CursorShapeSignature) {
            let percentage = shape.cell_percentage.clamp(1, 100) as f32 / 100.0;
            let standard = [
                PixelPoint { x: -0.5, y: -0.5 },
                PixelPoint { x: 0.5, y: -0.5 },
                PixelPoint { x: 0.5, y: 0.5 },
                PixelPoint { x: -0.5, y: 0.5 },
            ];
            for (corner, standard) in self.corners.iter_mut().zip(standard) {
                corner.relative_position = match shape.style {
                    "bar" => PixelPoint {
                        x: (standard.x + 0.5) * percentage - 0.5,
                        y: standard.y,
                    },
                    "underline" => PixelPoint {
                        x: standard.x,
                        y: -((-standard.y + 0.5) * percentage - 0.5),
                    },
                    _ => standard,
                };
            }
        }

        fn path(&self) -> Option<Path> {
            if !self.initialized {
                return None;
            }
            let mut builder = PathBuilder::new();
            builder
                .move_to((
                    self.corners[0].current_position.x.round(),
                    self.corners[0].current_position.y.round(),
                ))
                .line_to((
                    self.corners[1].current_position.x.round(),
                    self.corners[1].current_position.y.round(),
                ))
                .line_to((
                    self.corners[2].current_position.x.round(),
                    self.corners[2].current_position.y.round(),
                ))
                .line_to((
                    self.corners[3].current_position.x.round(),
                    self.corners[3].current_position.y.round(),
                ))
                .close();
            Some(builder.detach())
        }

        fn needs_animation_frame(&self) -> bool {
            self.animating
        }

        fn clear(&mut self) {
            self.previous_cursor_position = None;
            self.previous_shape = None;
            self.initialized = false;
            self.animating = false;
        }
    }
    #[cfg(test)]
    mod tests {
        include!("skia_metal_tests.rs");
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::SkiaRenderGeometry;
    use crate::{neovim_runtime::NativeNeovimRuntime, terminal_runtime::NativeTerminalRuntime};
    use std::ffi::c_void;

    pub struct NativeSkiaMetalRenderer;

    impl NativeSkiaMetalRenderer {
        pub unsafe fn new(_device: *mut c_void, _command_queue: *mut c_void) -> Option<Self> {
            None
        }

        pub unsafe fn render_nvim(
            &mut self,
            _runtime: &mut NativeNeovimRuntime,
            _texture: *mut c_void,
            _geometry: SkiaRenderGeometry,
            _clear: bool,
            _preedit: Option<&str>,
        ) -> bool {
            false
        }

        pub unsafe fn render_terminal(
            &mut self,
            _runtime: &mut NativeTerminalRuntime,
            _texture: *mut c_void,
            _geometry: SkiaRenderGeometry,
            _clear: bool,
            _preedit: Option<&str>,
        ) -> bool {
            false
        }

        pub fn needs_animation_frame(&self) -> bool {
            false
        }

        pub fn set_font_family(&mut self, _family: Option<&str>) {}

        pub fn forget_runtime(&mut self, _runtime_id: usize) {}

        pub fn next_frame_delay_ms(&self) -> Option<u64> {
            None
        }
    }
}

pub use platform::NativeSkiaMetalRenderer;
