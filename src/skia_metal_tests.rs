use super::*;

fn render_model_pixel(
    model: &NeovideRendererModelSnapshot,
    geometry: SkiaRenderGeometry,
    point: (i32, i32),
) -> Color {
    let pixels = render_model_pixels(model, geometry, None);
    pixels[(point.1 * geometry.width + point.0) as usize]
}

fn render_model_pixels(
    model: &NeovideRendererModelSnapshot,
    geometry: SkiaRenderGeometry,
    preedit: Option<&str>,
) -> Vec<Color> {
    let mut surface =
        skia_safe::surfaces::raster_n32_premul((geometry.width, geometry.height)).unwrap();
    let mut text_renderer = NeovideTextRenderer::new();
    let mut images = HashMap::new();
    let mut preedit_cache = PreeditLineCache::default();
    let preedit = preedit_cache.prepare(
        preedit,
        model.background,
        model.cursor_color,
        preedit_available_columns(model, geometry),
    );
    draw_model(
        surface.canvas(),
        &mut text_renderer,
        &CursorAnimationState::default(),
        false,
        model,
        geometry,
        ModelRenderOptions {
            clear: true,
            kitty_placements: &[],
            kitty_images: &mut images,
            runtime_id: 1,
            preedit,
        },
    );
    let pixels = surface.peek_pixels().unwrap();
    let mut colors = Vec::with_capacity((geometry.width * geometry.height) as usize);
    for y in 0..geometry.height {
        for x in 0..geometry.width {
            colors.push(pixels.get_color((x, y)));
        }
    }
    colors
}

#[test]
fn ime_preedit_matches_committed_japanese_text_pixels() {
    let geometry = SkiaRenderGeometry {
        width: 80,
        height: 60,
        origin_x: 0.0,
        origin_y: 0.0,
        content_width: 80.0,
        content_height: 60.0,
        cell_width: 10.0,
        cell_height: 20.0,
    };
    let mut preedit_model = renderer_model(8, 3);
    preedit_model.background = TerminalColor { r: 3, g: 5, b: 7 };
    preedit_model.cursor_color = TerminalColor {
        r: 210,
        g: 220,
        b: 230,
    };
    preedit_model.cursor = Some(cursor(2, 1, "block", 100, 0, 0, 0));

    let mut committed_model = preedit_model.clone();
    committed_model.cursor = None;
    let style = preedit_cell_style(committed_model.background);
    let mut cells = vec![preedit_cell(
        " ",
        committed_model.cursor_color,
        None,
        TerminalCellStyle::default(),
    ); 8];
    cells[2] = preedit_cell(
        "日",
        committed_model.background,
        Some(committed_model.cursor_color),
        style,
    );
    cells[3] = preedit_cell(
        " ",
        committed_model.background,
        Some(committed_model.cursor_color),
        style,
    );
    cells[4] = preedit_cell(
        "本",
        committed_model.background,
        Some(committed_model.cursor_color),
        style,
    );
    cells[5] = preedit_cell(
        " ",
        committed_model.background,
        Some(committed_model.cursor_color),
        style,
    );
    let committed_line = crate::neovide_render::NeovideLine::from_cells(cells);
    committed_model.windows[0].lines[1] = Some(committed_line.clone());
    committed_model.windows[0].scrollback_lines[1] = Some(committed_line);

    let committed = render_model_pixels(&committed_model, geometry, None);
    let preedit = render_model_pixels(&preedit_model, geometry, Some("日本"));
    assert_eq!(preedit, committed);
}

#[test]
fn ime_preedit_cells_keep_graphemes_and_terminal_width() {
    let foreground = TerminalColor { r: 3, g: 5, b: 7 };
    let background = TerminalColor {
        r: 210,
        g: 220,
        b: 230,
    };
    let line = preedit_line("日本e\u{301}", foreground, background, 5);
    let text = line
        .cells
        .iter()
        .map(|cell| cell.text.as_str())
        .collect::<Vec<_>>();

    assert_eq!(text, ["日", " ", "本", " ", "e\u{301}"]);
    assert!(line.cells.iter().all(|cell| cell.style.underline));
}

#[test]
fn ime_preedit_reuses_its_retained_line_until_content_changes() {
    let foreground = TerminalColor { r: 3, g: 5, b: 7 };
    let background = TerminalColor {
        r: 210,
        g: 220,
        b: 230,
    };
    let mut cache = PreeditLineCache::default();
    let first = cache
        .prepare(Some("日本"), foreground, background, 8)
        .unwrap()
        .cells
        .clone();
    let retained = cache
        .prepare(Some("日本"), foreground, background, 8)
        .unwrap()
        .cells
        .clone();
    let changed = cache
        .prepare(Some("日本語"), foreground, background, 8)
        .unwrap()
        .cells
        .clone();

    assert!(std::sync::Arc::ptr_eq(&first, &retained));
    assert!(!std::sync::Arc::ptr_eq(&retained, &changed));
}

fn floating_window(
    grid_id: i64,
    top: usize,
    left: usize,
    width: usize,
    height: usize,
    compindex: i64,
) -> NeovideRenderedWindowSnapshot {
    crate::neovide_render::NeovideRenderedWindowCache::new(width, height).snapshot(
        grid_id,
        crate::neovide_render::NeovideRenderedWindowPlacement {
            top,
            left,
            width,
            height,
            window_kind: NeovideWindowKind::Float,
            zindex: 50,
            compindex,
            hidden: false,
        },
    )
}

#[test]
fn terminal_vt_scroll_schedules_its_own_animation_frames() {
    let mut runtime =
        NativeTerminalRuntime::external(crate::terminal_runtime::TerminalGridSize {
            rows: 8,
            cols: 16,
            pixel_width: 160,
            pixel_height: 160,
        })
        .unwrap();
    runtime.feed_tmux_projection(b"\x1b[?1049h").unwrap();
    let mut state = RuntimeRenderState::default();
    let _ = prepare_terminal_renderer_model(&mut state, &mut runtime, 0.0).unwrap();
    assert!(!state.scroll_animation_active);

    runtime
        .feed_tmux_projection(b"\x1b[1;7r\x1b[H\x1b[M\x1b[r")
        .unwrap();
    let model = prepare_terminal_renderer_model(&mut state, &mut runtime, 0.0).unwrap();

    assert_eq!(model.windows[0].scroll_position, -1.0);
    assert!(state.scroll_animation_active);
    assert_eq!(state.next_frame_delay_ms(), Some(0));
}

#[test]
fn hidden_runtime_animation_does_not_keep_the_visible_frame_loop_alive() {
    let mut hidden = RuntimeRenderState {
        scroll_animation_active: true,
        last_render_frame_id: 41,
        ..RuntimeRenderState::default()
    };
    let mut visible = RuntimeRenderState {
        last_render_frame_id: 42,
        ..RuntimeRenderState::default()
    };
    let mut states = HashMap::from([(1, hidden), (2, visible)]);

    assert_eq!(next_frame_delay_ms_for_runtime_states(&states, 42), None);

    hidden = states.remove(&1).unwrap();
    visible = states.remove(&2).unwrap();
    visible.scroll_animation_active = true;
    states.insert(1, hidden);
    states.insert(2, visible);
    assert_eq!(next_frame_delay_ms_for_runtime_states(&states, 42), Some(0));
}

#[test]
fn foreground_window_background_masks_stale_root_grid_cells() {
    let background = TerminalColor { r: 3, g: 5, b: 7 };
    let stale = TerminalColor {
        r: 220,
        g: 210,
        b: 200,
    };
    let stale_line =
        crate::neovide_render::NeovideLine::from_cells(vec![TerminalCellSnapshot {
            text: " ".to_owned(),
            fg: stale,
            bg: Some(stale),
            blend: 0,
            style: Default::default(),
        }]);
    let mut root = crate::neovide_render::NeovideRenderedWindowCache::new(2, 1).snapshot(
        1,
        crate::neovide_render::NeovideRenderedWindowPlacement::main(2, 1),
    );
    root.lines[0] = Some(stale_line.clone());
    root.scrollback_lines[0] = Some(stale_line);
    let foreground = crate::neovide_render::NeovideRenderedWindowCache::new(2, 1).snapshot(
        2,
        crate::neovide_render::NeovideRenderedWindowPlacement::main(2, 1),
    );
    let model = NeovideRendererModelSnapshot {
        schema_version: 1,
        background,
        cursor_color: background,
        cursor: None,
        cursor_parent_grid_id: None,
        message_selection: None,
        scrollbar: None,
        scroll_hint: None,
        windows: vec![root, foreground],
    };
    let geometry = SkiaRenderGeometry {
        width: 20,
        height: 10,
        origin_x: 0.0,
        origin_y: 0.0,
        content_width: 20.0,
        content_height: 10.0,
        cell_width: 10.0,
        cell_height: 10.0,
    };
    let mut surface = skia_safe::surfaces::raster_n32_premul((20, 10)).unwrap();
    let mut text_renderer = NeovideTextRenderer::new();
    let mut images = HashMap::new();

    draw_model(
        surface.canvas(),
        &mut text_renderer,
        &CursorAnimationState::default(),
        false,
        &model,
        geometry,
        ModelRenderOptions {
            clear: true,
            kitty_placements: &[],
            kitty_images: &mut images,
            runtime_id: 1,
            preedit: None,
        },
    );

    let pixels = surface.peek_pixels().unwrap();
    assert_eq!(pixels.get_color((5, 5)), color(background));
}

#[test]
fn overlapping_float_border_keeps_content_grid_visible() {
    let background = TerminalColor { r: 3, g: 5, b: 7 };
    let result_background = TerminalColor {
        r: 180,
        g: 40,
        b: 70,
    };
    let result_line =
        crate::neovide_render::NeovideLine::from_cells(vec![TerminalCellSnapshot {
            text: " ".to_owned(),
            fg: result_background,
            bg: Some(result_background),
            blend: 0,
            style: Default::default(),
        }]);
    let root = crate::neovide_render::NeovideRenderedWindowCache::new(3, 3).snapshot(
        1,
        crate::neovide_render::NeovideRenderedWindowPlacement::main(3, 3),
    );
    let mut results = floating_window(2, 1, 1, 1, 1, 0);
    results.lines[0] = Some(result_line.clone());
    results.scrollback_lines[0] = Some(result_line);
    let border = floating_window(3, 0, 0, 3, 3, 1);
    let model = NeovideRendererModelSnapshot {
        schema_version: 1,
        background,
        cursor_color: background,
        cursor: None,
        cursor_parent_grid_id: None,
        message_selection: None,
        scrollbar: None,
        scroll_hint: None,
        windows: vec![root, results, border],
    };
    let geometry = SkiaRenderGeometry {
        width: 30,
        height: 30,
        origin_x: 0.0,
        origin_y: 0.0,
        content_width: 30.0,
        content_height: 30.0,
        cell_width: 10.0,
        cell_height: 10.0,
    };
    assert_eq!(
        render_model_pixel(&model, geometry, (15, 15)),
        color(result_background)
    );
}

#[test]
fn message_selection_overlay_only_covers_selected_cells() {
    let background = TerminalColor { r: 0, g: 0, b: 0 };
    let foreground = TerminalColor {
        r: 255,
        g: 255,
        b: 255,
    };
    let window = crate::neovide_render::NeovideRenderedWindowCache::new(4, 2).snapshot(
        2,
        crate::neovide_render::NeovideRenderedWindowPlacement {
            top: 0,
            left: 0,
            width: 4,
            height: 2,
            window_kind: NeovideWindowKind::Message,
            zindex: 200,
            compindex: 0,
            hidden: false,
        },
    );
    let model = NeovideRendererModelSnapshot {
        schema_version: 1,
        background,
        cursor_color: foreground,
        cursor: None,
        cursor_parent_grid_id: None,
        message_selection: Some(crate::neovide_render::NeovideMessageSelection {
            grid_id: 2,
            start: crate::neovide_render::NeovideGridPosition { row: 0, col: 1 },
            end: crate::neovide_render::NeovideGridPosition { row: 1, col: 2 },
        }),
        scrollbar: None,
        scroll_hint: None,
        windows: vec![window],
    };
    let geometry = SkiaRenderGeometry {
        width: 40,
        height: 20,
        origin_x: 0.0,
        origin_y: 0.0,
        content_width: 40.0,
        content_height: 20.0,
        cell_width: 10.0,
        cell_height: 10.0,
    };
    let mut surface = skia_safe::surfaces::raster_n32_premul((40, 20)).unwrap();
    let mut text_renderer = NeovideTextRenderer::new();
    let mut images = HashMap::new();

    draw_model(
        surface.canvas(),
        &mut text_renderer,
        &CursorAnimationState::default(),
        false,
        &model,
        geometry,
        ModelRenderOptions {
            clear: true,
            kitty_placements: &[],
            kitty_images: &mut images,
            runtime_id: 1,
            preedit: None,
        },
    );

    let pixels = surface.peek_pixels().unwrap();
    assert_eq!(pixels.get_color((5, 5)), color(background));
    assert_ne!(pixels.get_color((15, 5)), color(background));
    assert_ne!(pixels.get_color((5, 15)), color(background));
    assert_ne!(pixels.get_color((25, 15)), color(background));
    assert_eq!(pixels.get_color((35, 15)), color(background));
}

#[test]
fn cursor_blink_waits_then_toggles_off_and_on() {
    let now = Instant::now();
    let cursor = cursor(0, 0, "bar", 25, 300, 200, 150);
    let mut blink = CursorBlinkState::default();

    blink.update_at(now, Some(&cursor));
    assert!(blink.should_render());

    blink.update_at(now + Duration::from_millis(300), Some(&cursor));
    assert!(blink.should_render());

    blink.update_at(now + Duration::from_millis(500), Some(&cursor));
    assert!(!blink.should_render());

    blink.update_at(now + Duration::from_millis(650), Some(&cursor));
    assert!(blink.should_render());
}

#[test]
fn cursor_blink_static_when_on_or_off_duration_is_zero() {
    let now = Instant::now();
    let cursor = cursor(0, 0, "bar", 25, 300, 0, 150);
    let mut blink = CursorBlinkState::default();

    blink.update_at(now, Some(&cursor));

    assert!(blink.should_render());
    assert!(blink.next_frame_delay_ms().is_none());
}

#[test]
fn cursor_blink_resets_visible_when_cursor_changes() {
    let now = Instant::now();
    let first_cursor = cursor(0, 0, "bar", 25, 0, 200, 150);
    let moved = cursor(1, 0, "bar", 25, 0, 200, 150);
    let mut blink = CursorBlinkState::default();
    blink.update_at(now, Some(&first_cursor));
    blink.update_at(now + Duration::from_millis(200), Some(&first_cursor));
    assert!(!blink.should_render());

    blink.update_at(now + Duration::from_millis(200), Some(&moved));

    assert!(blink.should_render());
}

#[test]
fn kitty_row_uses_the_same_scroll_animation_as_terminal_text() {
    let mut model = renderer_model(8, 6);
    model.windows[0].scroll_position = -2.0;

    assert_eq!(animated_kitty_row(&model, 3, 2), 5.0);
    model.windows[0].scroll_position = -1.0;
    assert_eq!(animated_kitty_row(&model, 3, 2), 4.0);
    model.windows[0].scroll_position = 0.0;
    assert_eq!(animated_kitty_row(&model, 3, 2), 3.0);

    model.windows[0].scroll_position = -2.0;
    model.windows[0].viewport_margins.left = 3;
    assert_eq!(animated_kitty_row(&model, 3, 2), 3.0);
    assert_eq!(animated_kitty_row(&model, 3, 3), 5.0);
}

#[test]
fn text_scroll_offset_is_rounded_to_device_pixels_like_neovide() {
    assert_eq!(scroll_offset_pixels(0.0, 20.0), 0.0);
    assert_eq!(scroll_offset_pixels(-0.55, 20.0), -9.0);
    assert_eq!(scroll_offset_pixels(-0.017, 20.0), -20.0);
}

#[test]
fn rectangular_scroll_clip_excludes_neighboring_split_columns() {
    let mut model = renderer_model(8, 6);
    model.windows[0].viewport_margins = crate::neovide_render::NeovideViewportMargins {
        top: 1,
        bottom: 1,
        left: 3,
        right: 1,
    };
    let rect = scroll_clip_rect(&model.windows[0], 1..5, geometry());

    assert_eq!(rect.left(), 40.0);
    assert_eq!(rect.top(), 40.0);
    assert_eq!(rect.width(), 40.0);
    assert_eq!(rect.height(), 80.0);
}

#[test]
fn cursor_uses_parent_window_scroll_and_stays_inside_viewport() {
    let mut model = renderer_model(8, 8);
    model.cursor_parent_grid_id = Some(1);
    model.windows[0].scroll_position = -2.0;
    model.windows[0].viewport_margins = crate::neovide_render::NeovideViewportMargins {
        top: 1,
        bottom: 1,
        left: 0,
        right: 0,
    };

    let point = cursor_render_point(&model, &cursor(4, 3, "block", 100, 0, 0, 0));
    assert_eq!(point, GridPoint { x: 4.0, y: 5.0 });

    let border = cursor_render_point(&model, &cursor(4, 0, "block", 100, 0, 0, 0));
    assert_eq!(border, GridPoint { x: 4.0, y: 0.0 });

    model.windows[0].viewport_margins.left = 5;
    let fixed_column = cursor_render_point(&model, &cursor(4, 3, "block", 100, 0, 0, 0));
    assert_eq!(fixed_column, GridPoint { x: 4.0, y: 3.0 });
    model.windows[0].viewport_margins.left = 0;

    model.windows[0].scroll_position = -20.0;
    let clamped = cursor_render_point(&model, &cursor(4, 3, "block", 100, 0, 0, 0));
    assert_eq!(clamped, GridPoint { x: 4.0, y: 6.0 });
}

#[test]
fn vertical_cursor_move_deforms_neovide_corners_instead_of_drawing_a_trail() {
    let geometry = geometry();
    let mut model = renderer_model(8, 8);
    model.cursor_parent_grid_id = Some(1);
    model.cursor = Some(cursor(4, 2, "block", 100, 0, 0, 0));
    let mut animation = CursorAnimationState::default();
    animation.update(&model, geometry, 0.0);

    model.cursor = Some(cursor(4, 3, "block", 100, 0, 0, 0));
    animation.update(&model, geometry, 1.0 / 60.0);

    let target_top = geometry.origin_y + 3.0 * geometry.cell_height;
    let target_bottom = target_top + geometry.cell_height;
    assert!(animation.corners[0].current_position.y < target_top);
    assert!(animation.corners[1].current_position.y < target_top);
    assert_eq!(animation.corners[2].current_position.y, target_bottom);
    assert_eq!(animation.corners[3].current_position.y, target_bottom);
    assert!(animation.needs_animation_frame());

    for _ in 0..60 {
        animation.update(&model, geometry, 1.0 / 60.0);
    }
    assert!(!animation.needs_animation_frame());
    assert_eq!(animation.corners[0].current_position.y, target_top);
    assert_eq!(animation.corners[1].current_position.y, target_top);
}

fn geometry() -> SkiaRenderGeometry {
    SkiaRenderGeometry {
        width: 800,
        height: 600,
        origin_x: 10.0,
        origin_y: 20.0,
        content_width: 780.0,
        content_height: 560.0,
        cell_width: 10.0,
        cell_height: 20.0,
    }
}

fn renderer_model(width: usize, height: usize) -> NeovideRendererModelSnapshot {
    NeovideRendererModelSnapshot {
        schema_version: 1,
        background: TerminalColor { r: 0, g: 0, b: 0 },
        cursor_color: TerminalColor { r: 0, g: 0, b: 0 },
        cursor: None,
        cursor_parent_grid_id: None,
        message_selection: None,
        scrollbar: None,
        scroll_hint: None,
        windows: vec![
            crate::neovide_render::NeovideRenderedWindowCache::new(width, height).snapshot(
                1,
                crate::neovide_render::NeovideRenderedWindowPlacement::main(width, height),
            ),
        ],
    }
}

fn cursor(
    x: u16,
    y: u16,
    style: &'static str,
    cell_percentage: u8,
    blinkwait_ms: u64,
    blinkon_ms: u64,
    blinkoff_ms: u64,
) -> TerminalCursorSnapshot {
    TerminalCursorSnapshot {
        x,
        y,
        style,
        cell_percentage,
        blinkwait_ms,
        blinkon_ms,
        blinkoff_ms,
    }
}
