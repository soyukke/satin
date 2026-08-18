#[test]
fn hidden_window_drops_stale_scroll_animation_when_shown() {
    let mut window = NeovideRenderedWindowCache::new(8, 6);
    window.apply(&NeovideWindowDrawCommand::Viewport { scroll_delta: 2 });
    window.flush(1);
    assert!(window.has_active_animation());

    window.apply(&NeovideWindowDrawCommand::Hide);
    window.apply(&NeovideWindowDrawCommand::Show);

    assert_eq!(window.scroll_position(), 0.0);
    assert!(!window.has_active_animation());
}

#[test]
fn zero_viewport_delta_keeps_pending_scroll_before_flush() {
    let mut window = NeovideRenderedWindowCache::new(8, 6);
    window.apply(&NeovideWindowDrawCommand::Viewport { scroll_delta: 2 });
    window.apply(&NeovideWindowDrawCommand::Viewport { scroll_delta: 0 });
    window.flush(1);

    assert_eq!(window.scroll_position(), -2.0);
    assert!(window.has_active_animation());
}

#[test]
fn viewport_margins_use_inner_height_as_scrollback_capacity() {
    let mut window = NeovideRenderedWindowCache::new(8, 8);
    window.apply(&NeovideWindowDrawCommand::ViewportMargins {
        top: 2,
        bottom: 2,
        left: 0,
        right: 0,
    });
    window.flush(1);
    window.apply(&NeovideWindowDrawCommand::Viewport { scroll_delta: 3 });
    window.flush(1);

    assert_eq!(window.scroll_position(), -3.0);
}
