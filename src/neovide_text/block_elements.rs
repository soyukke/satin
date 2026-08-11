// Native Block Elements rendering follows Neovide's audited box-drawing
// renderer: cell fractions are rounded in absolute pixel coordinates so
// neighboring shapes share the exact same physical boundary.

use super::{TextGridGeometry, blink_text_visible, color, decorations};
use crate::terminal_runtime::TerminalCellSnapshot;
use skia_safe::{BlendMode, Canvas, Paint, PaintStyle, Rect};

const TOP_LEFT: u8 = 1 << 0;
const TOP_RIGHT: u8 = 1 << 1;
const BOTTOM_LEFT: u8 = 1 << 2;
const BOTTOM_RIGHT: u8 = 1 << 3;

#[derive(Clone, Copy)]
struct GridRect {
    left: u8,
    top: u8,
    right: u8,
    bottom: u8,
}

impl GridRect {
    const fn new(left: u8, top: u8, right: u8, bottom: u8) -> Self {
        Self {
            left,
            top,
            right,
            bottom,
        }
    }
}

#[derive(Clone, Copy)]
enum BlockShape {
    Rect(GridRect),
    Quadrants(u8),
}

pub(super) fn is_native(text: &str) -> bool {
    shape(text).is_some()
}

pub(super) fn draw_line(
    canvas: &Canvas,
    cells: &[TerminalCellSnapshot],
    width: usize,
    row: f32,
    window_left: usize,
    geometry: TextGridGeometry,
) {
    for (col, cell) in cells.iter().take(width).enumerate() {
        let Some(shape) = shape(&cell.text) else {
            continue;
        };
        if cell.style.blink && !blink_text_visible() {
            continue;
        }

        let cell_left = geometry.origin_x + (window_left + col) as f32 * geometry.cell_width;
        let cell_top = geometry.origin_y + row * geometry.cell_height;
        let bounds = Rect::from_xywh(
            cell_left,
            cell_top,
            geometry.cell_width,
            geometry.cell_height,
        );
        let mut paint = Paint::default();
        paint.set_style(PaintStyle::Fill);
        paint.set_color(color(cell.fg));
        paint.set_blend_mode(BlendMode::SrcOver);
        paint.set_anti_alias(false);
        draw_shape(canvas, bounds, shape, &paint);
        let absolute_col = window_left + col;
        decorations::draw(
            canvas,
            absolute_col..absolute_col + 1,
            cell.style,
            row,
            &paint,
            geometry,
        );
    }
}

fn draw_shape(canvas: &Canvas, bounds: Rect, shape: BlockShape, paint: &Paint) {
    match shape {
        BlockShape::Rect(rect) => draw_grid_rect(canvas, bounds, rect, paint),
        BlockShape::Quadrants(mask) => {
            let quadrants = [
                (TOP_LEFT, GridRect::new(0, 0, 4, 4)),
                (TOP_RIGHT, GridRect::new(4, 0, 8, 4)),
                (BOTTOM_LEFT, GridRect::new(0, 4, 4, 8)),
                (BOTTOM_RIGHT, GridRect::new(4, 4, 8, 8)),
            ];
            for (bit, rect) in quadrants {
                if mask & bit != 0 {
                    draw_grid_rect(canvas, bounds, rect, paint);
                }
            }
        }
    }
}

fn draw_grid_rect(canvas: &Canvas, bounds: Rect, rect: GridRect, paint: &Paint) {
    let eighth_width = bounds.width() / 8.0;
    let eighth_height = bounds.height() / 8.0;
    let pixel_rect = Rect::from_ltrb(
        (bounds.left + rect.left as f32 * eighth_width).round(),
        (bounds.top + rect.top as f32 * eighth_height).round(),
        (bounds.left + rect.right as f32 * eighth_width).round(),
        (bounds.top + rect.bottom as f32 * eighth_height).round(),
    );
    canvas.draw_rect(pixel_rect, paint);
}

fn shape(text: &str) -> Option<BlockShape> {
    let mut chars = text.chars();
    let character = chars.next()?;
    if chars.next().is_some() {
        return None;
    }
    let rect = |left, top, right, bottom| BlockShape::Rect(GridRect::new(left, top, right, bottom));
    Some(match character {
        '▀' => rect(0, 0, 8, 4),
        '▁' => rect(0, 7, 8, 8),
        '▂' => rect(0, 6, 8, 8),
        '▃' => rect(0, 5, 8, 8),
        '▄' => rect(0, 4, 8, 8),
        '▅' => rect(0, 3, 8, 8),
        '▆' => rect(0, 2, 8, 8),
        '▇' => rect(0, 1, 8, 8),
        '█' => rect(0, 0, 8, 8),
        '▉' => rect(0, 0, 7, 8),
        '▊' => rect(0, 0, 6, 8),
        '▋' => rect(0, 0, 5, 8),
        '▌' => rect(0, 0, 4, 8),
        '▍' => rect(0, 0, 3, 8),
        '▎' => rect(0, 0, 2, 8),
        '▏' => rect(0, 0, 1, 8),
        '▐' => rect(4, 0, 8, 8),
        '▔' => rect(0, 0, 8, 1),
        '▕' => rect(7, 0, 8, 8),
        '▖' => BlockShape::Quadrants(BOTTOM_LEFT),
        '▗' => BlockShape::Quadrants(BOTTOM_RIGHT),
        '▘' => BlockShape::Quadrants(TOP_LEFT),
        '▙' => BlockShape::Quadrants(TOP_LEFT | BOTTOM_LEFT | BOTTOM_RIGHT),
        '▚' => BlockShape::Quadrants(TOP_LEFT | BOTTOM_RIGHT),
        '▛' => BlockShape::Quadrants(TOP_LEFT | TOP_RIGHT | BOTTOM_LEFT),
        '▜' => BlockShape::Quadrants(TOP_LEFT | TOP_RIGHT | BOTTOM_RIGHT),
        '▝' => BlockShape::Quadrants(TOP_RIGHT),
        '▞' => BlockShape::Quadrants(TOP_RIGHT | BOTTOM_LEFT),
        '▟' => BlockShape::Quadrants(TOP_RIGHT | BOTTOM_LEFT | BOTTOM_RIGHT),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_shapes_cover_claude_logo_characters() {
        for character in "▐▛███▜▌▝▘".chars() {
            assert!(is_native(&character.to_string()), "missing {character}");
        }
    }

    #[test]
    fn text_with_more_than_one_character_stays_on_the_shaping_path() {
        assert!(!is_native("█a"));
    }
}
