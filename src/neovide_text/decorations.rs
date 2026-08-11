use super::{TextGridGeometry, color};
use crate::terminal_runtime::{TerminalCellStyle, TerminalUnderlineStyle};
use skia_safe::{Canvas, Paint};
use std::ops::Range;

pub(super) fn draw(
    canvas: &Canvas,
    columns: Range<usize>,
    style: TerminalCellStyle,
    row: f32,
    paint: &Paint,
    geometry: TextGridGeometry,
) {
    if !style.underline && !style.strikethrough && !style.overline {
        return;
    }
    let start_x = geometry.origin_x + columns.start as f32 * geometry.cell_width;
    let end_x = geometry.origin_x + columns.end as f32 * geometry.cell_width;
    if style.underline {
        let y = decoration_y(geometry, row, 0.86);
        let mut underline_paint = paint.clone();
        if let Some(underline_color) = style.underline_color {
            underline_paint.set_color(color(underline_color));
        }
        draw_underline(
            canvas,
            start_x,
            end_x,
            y,
            style.underline_style,
            &underline_paint,
            geometry,
        );
    }
    if style.strikethrough {
        let y = decoration_y(geometry, row, 0.54);
        canvas.draw_line((start_x, y), (end_x, y), paint);
    }
    if style.overline {
        let y = decoration_y(geometry, row, 0.12);
        canvas.draw_line((start_x, y), (end_x, y), paint);
    }
}

fn draw_underline(
    canvas: &Canvas,
    start_x: f32,
    end_x: f32,
    y: f32,
    style: TerminalUnderlineStyle,
    paint: &Paint,
    geometry: TextGridGeometry,
) {
    match style {
        TerminalUnderlineStyle::Double => {
            canvas.draw_line((start_x, y - 1.5), (end_x, y - 1.5), paint);
            canvas.draw_line((start_x, y + 1.5), (end_x, y + 1.5), paint);
        }
        TerminalUnderlineStyle::Curly => {
            let step = (geometry.cell_width / 3.0).max(2.0);
            let mut x = start_x;
            let mut up = true;
            while x < end_x {
                let next = (x + step).min(end_x);
                let next_y = if up { y - 1.5 } else { y + 1.5 };
                canvas.draw_line((x, y), (next, next_y), paint);
                x = next;
                up = !up;
            }
        }
        TerminalUnderlineStyle::Dotted => {
            let mut x = start_x;
            while x <= end_x {
                canvas.draw_circle((x, y), 0.8, paint);
                x += 3.0;
            }
        }
        TerminalUnderlineStyle::Dashed => {
            let mut x = start_x;
            while x < end_x {
                let dash_end = (x + 4.0).min(end_x);
                canvas.draw_line((x, y), (dash_end, y), paint);
                x += 7.0;
            }
        }
        _ => {
            canvas.draw_line((start_x, y), (end_x, y), paint);
        }
    }
}

fn decoration_y(geometry: TextGridGeometry, row: f32, ratio: f32) -> f32 {
    geometry.origin_y + (row + ratio) * geometry.cell_height
}
