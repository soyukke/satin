#[test]
fn tmux_rehydration_scroll_metadata_restarts_animation_every_time() {
    let mut runtime = NativeTerminalRuntime::external(grid_size(8, 16)).unwrap();
    runtime
        .feed_tmux_projection(b"\x1b[?1049h\x1b[2J\x1b[Hinitial")
        .unwrap();
    runtime.renderer_model().unwrap();
    for content in [b"first".as_slice(), b"second".as_slice()] {
        let before = runtime.screen_text().unwrap();
        runtime
            .record_tmux_scroll_metadata(1, Some((1, 7, 0, 0)))
            .unwrap();
        assert_eq!(runtime.screen_text().unwrap(), before);
        runtime.prepare_tmux_hydration().unwrap();

        runtime
            .feed_tmux_projection(b"\x1b[?1049h\x1b[2J\x1b[H")
            .unwrap();
        runtime.feed_tmux_projection(content).unwrap();
        let model = runtime.renderer_model().unwrap();

        assert_eq!(model.windows[0].scroll_position, -1.0);
        assert_eq!(model.windows[0].viewport_margins.bottom, 1);
        assert!(runtime.has_active_renderer_animation());
        assert!(!runtime.advance_renderer_animations(0.3));
    }
}

#[test]
fn tmux_live_output_keeps_split_scroll_sequence_state_between_chunks() {
    let mut runtime = NativeTerminalRuntime::external(grid_size(8, 16)).unwrap();
    runtime
        .feed_tmux_projection(b"\x1b[?1049h\x1b[2J\x1b[Hinitial")
        .unwrap();
    runtime.renderer_model().unwrap();

    for chunk in [
        b"\x1b]777;Satin".as_slice(),
        b"Scroll;1;1;2;7;4;12".as_slice(),
        b"\x07".as_slice(),
    ] {
        runtime.feed_tmux_projection(chunk).unwrap();
    }

    let model = runtime.renderer_model().unwrap();
    assert_eq!(model.windows[0].scroll_position, -1.0);
    assert_eq!(model.windows[0].viewport_margins.top, 1);
    assert_eq!(model.windows[0].viewport_margins.bottom, 1);
    assert_eq!(model.windows[0].viewport_margins.left, 3);
    assert_eq!(model.windows[0].viewport_margins.right, 4);
    assert!(runtime.has_active_renderer_animation());
}

#[test]
fn coalesced_tmux_scrolls_do_not_collapse_to_far_jump_animation() {
    let mut runtime = NativeTerminalRuntime::external(grid_size(8, 16)).unwrap();
    runtime
        .feed_tmux_projection(b"\x1b[?1049h\x1b[2J\x1b[Hinitial")
        .unwrap();
    runtime.renderer_model().unwrap();

    for _ in 0..3 {
        runtime
            .record_tmux_scroll_metadata(3, Some((2, 7, 4, 12)))
            .unwrap();
    }
    let model = runtime.renderer_model().unwrap();

    assert_eq!(model.windows[0].scroll_position, -6.0);
    assert!(runtime.has_active_renderer_animation());
}
