use super::*;

#[test]
fn adjacent_full_blocks_fill_the_cell_run_without_seams() {
    let foreground = TerminalColor {
        r: 222,
        g: 128,
        b: 128,
    };
    let cell = TerminalCellSnapshot {
        text: "█".to_owned(),
        fg: foreground,
        bg: None,
        blend: 0,
        style: TerminalCellStyle::default(),
    };
    let cell_count = 8;
    let line = NeovideLine::from_cells(vec![cell; cell_count]);
    let geometry = TextGridGeometry {
        origin_x: 0.0,
        origin_y: 0.0,
        cell_width: 18.544_922,
        cell_height: 35.332_03,
    };
    let mut renderer = NeovideTextRenderer::new();
    renderer.update_geometry(geometry);
    let mut surface = skia_safe::surfaces::raster_n32_premul((160, 48)).unwrap();
    surface.canvas().clear(Color::BLACK);

    renderer.draw_line(surface.canvas(), &line, 0.0, 0, cell_count);

    let pixels = surface.peek_pixels().unwrap();
    let expected = color(foreground);
    let run_right = (cell_count as f32 * geometry.cell_width).round() as i32;
    for x in 0..run_right {
        assert_eq!(
            pixels.get_color((x, 18)),
            expected,
            "foreground block seam at physical x={x}"
        );
    }
}
