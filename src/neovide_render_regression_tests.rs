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
