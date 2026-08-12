use super::{RenderedArtifact, viewer_terminal_output};
use crate::terminal_runtime::{NativeTerminalRuntime, TerminalGridSize};

#[test]
fn full_height_viewer_does_not_scroll_its_heading_offscreen() {
    let rendered = RenderedArtifact {
        ansi: format!("Persistent heading{}\r\n", "\r\n".repeat(11)),
        plain_lines: Vec::new(),
        compacted: false,
        omitted_items: 0,
    };
    let output = viewer_terminal_output(&rendered);
    let mut terminal = NativeTerminalRuntime::external(TerminalGridSize {
        rows: 12,
        cols: 40,
        pixel_width: 400,
        pixel_height: 240,
    })
    .unwrap();

    terminal
        .feed_external(format!("\x1b[2J\x1b[H{output}").as_bytes())
        .unwrap();

    assert_eq!(output.len() + 2, rendered.ansi.len());
    assert!(
        terminal
            .screen_text()
            .unwrap()
            .contains("Persistent heading")
    );
}
