use anyhow::Result;
use libghostty_vt::{
    Terminal,
    screen::GridRef,
    selection::{
        Selection,
        gesture::{AutoscrollTickEvent, DragEvent, Geometry, Gesture, PressEvent, ReleaseEvent},
    },
    terminal::{Point, PointCoordinate},
};

use super::{NativeTerminalRuntime, TerminalPoint};

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct TerminalSelectionInput {
    pub point: TerminalPoint,
    pub x: f32,
    pub y: f32,
    pub cell_width: u32,
}

pub(super) struct TerminalSelectionGesture {
    gesture: Gesture<'static>,
    press: PressEvent<'static>,
    drag: DragEvent<'static>,
    release: ReleaseEvent<'static>,
    autoscroll: AutoscrollTickEvent<'static>,
}

impl TerminalSelectionGesture {
    pub(super) fn new() -> Result<Self> {
        Ok(Self {
            gesture: Gesture::new()?,
            press: PressEvent::new()?,
            drag: DragEvent::new()?,
            release: ReleaseEvent::new()?,
            autoscroll: AutoscrollTickEvent::new()?,
        })
    }

    fn press<'t>(
        &mut self,
        terminal: &'t Terminal<'_, '_>,
        grid_ref: GridRef<'t>,
        input: TerminalSelectionInput,
    ) -> Result<Option<Selection<'t>>> {
        self.press
            .set_position(f64::from(input.x), f64::from(input.y))?;
        Ok(self.press.apply(&mut self.gesture, terminal, grid_ref)?)
    }

    fn drag<'t>(
        &mut self,
        terminal: &'t Terminal<'_, '_>,
        grid_ref: GridRef<'t>,
        input: TerminalSelectionInput,
        rectangular: bool,
        geometry: Geometry,
    ) -> Result<Option<Selection<'t>>> {
        self.drag
            .set_position(f64::from(input.x), f64::from(input.y))?
            .set_rectangle(rectangular)?;
        Ok(self
            .drag
            .apply(&mut self.gesture, terminal, grid_ref, geometry)?)
    }

    fn autoscroll<'t>(
        &mut self,
        terminal: &'t Terminal<'_, '_>,
        viewport: PointCoordinate,
        input: TerminalSelectionInput,
        rectangular: bool,
        geometry: Geometry,
    ) -> Result<Option<Selection<'t>>> {
        self.autoscroll
            .set_position(f64::from(input.x), f64::from(input.y))?
            .set_rectangle(rectangular)?;
        Ok(self
            .autoscroll
            .apply(&mut self.gesture, terminal, viewport, geometry)?)
    }

    fn release<'t>(
        &mut self,
        terminal: &'t Terminal<'_, '_>,
        grid_ref: Option<GridRef<'t>>,
    ) -> Result<()> {
        Ok(self.release.apply(&mut self.gesture, terminal, grid_ref)?)
    }

    pub(super) fn reset(&mut self, terminal: &Terminal<'_, '_>) {
        self.gesture.reset(terminal);
    }
}

impl NativeTerminalRuntime {
    pub(crate) fn selection_press(&mut self, input: TerminalSelectionInput) -> Result<()> {
        let point = self.clamped_viewport_point(input.point);
        let terminal = &self.terminal;
        let grid_ref = terminal.grid_ref(Point::Viewport(point))?;
        let selection = self.selection_gesture.press(terminal, grid_ref, input)?;
        terminal.set_selection(selection.as_ref())?;
        Ok(())
    }

    pub(crate) fn selection_drag(
        &mut self,
        input: TerminalSelectionInput,
        rectangular: bool,
    ) -> Result<()> {
        let geometry = self.selection_geometry(input.cell_width);
        let point = self.clamped_viewport_point(input.point);
        let terminal = &self.terminal;
        let grid_ref = terminal.grid_ref(Point::Viewport(point))?;
        let selection =
            self.selection_gesture
                .drag(terminal, grid_ref, input, rectangular, geometry)?;
        if let Some(selection) = selection.as_ref() {
            terminal.set_selection(Some(selection))?;
        }
        Ok(())
    }

    pub(crate) fn selection_autoscroll(
        &mut self,
        input: TerminalSelectionInput,
        rectangular: bool,
    ) -> Result<isize> {
        let geometry = self.selection_geometry(input.cell_width);
        let point = self.clamped_viewport_point(input.point);
        let terminal = &self.terminal;
        let before = terminal.scrollbar()?.offset;
        let selection =
            self.selection_gesture
                .autoscroll(terminal, point, input, rectangular, geometry)?;
        let after = terminal.scrollbar()?.offset;
        if let Some(selection) = selection.as_ref() {
            terminal.set_selection(Some(selection))?;
        }
        let moved_rows = signed_delta(before, after);
        if moved_rows != 0 {
            self.renderer_model.record_scroll_delta(moved_rows);
        }
        Ok(moved_rows)
    }

    pub(crate) fn selection_release(&mut self, point: Option<TerminalPoint>) -> Result<()> {
        let point = point.map(|point| self.clamped_viewport_point(point));
        let terminal = &self.terminal;
        let grid_ref = point
            .map(|point| terminal.grid_ref(Point::Viewport(point)))
            .transpose()?;
        self.selection_gesture.release(terminal, grid_ref)
    }

    pub(crate) fn cancel_selection_gesture(&mut self) {
        self.selection_gesture.reset(&self.terminal);
    }

    fn selection_geometry(&self, cell_width: u32) -> Geometry {
        Geometry {
            columns: u32::from(self.size.cols.max(1)),
            cell_width: cell_width.max(1),
            padding_left: 0,
            screen_height: u32::from(self.size.pixel_height.max(1)),
        }
    }
}

fn signed_delta(before: u64, after: u64) -> isize {
    if after >= before {
        after.saturating_sub(before).min(isize::MAX as u64) as isize
    } else {
        -(before.saturating_sub(after).min(isize::MAX as u64) as isize)
    }
}
