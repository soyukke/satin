use std::{
    cell::{Cell, RefCell},
    collections::{BTreeMap, HashMap, HashSet},
    env,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::Command,
    rc::Rc,
    sync::{
        Arc,
        mpsc::{self, Receiver},
    },
    thread,
    time::Duration,
};

use anyhow::{Result, bail};
use libghostty_vt::{
    RenderState, Terminal, TerminalOptions,
    fmt::Format,
    key::{self, Key, Mods, OptionAsAlt},
    kitty::graphics::{self, ImageFormat, PlacementIterator},
    mouse, paste,
    render::{CellIteration, CellIterator, CursorVisualStyle, RowIteration, RowIterator, Snapshot},
    screen::Screen,
    selection::{FormatOptions, SelectWordOptions, Selection},
    style::{RgbColor, StyleColor, Underline},
    terminal::{Mode, Point, PointCoordinate, ScrollViewport},
};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
use serde::{Deserialize, Serialize};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use crate::neovide_render::{
    NeovideLine, NeovideRenderedWindowCache, NeovideRenderedWindowPlacement,
    NeovideRendererModelSnapshot, NeovideWindowDrawCommand, NeovideWindowKind,
};
use crate::tmux_control::{TmuxControl, TmuxControlEvent};
use crate::wakeup::{WakeupReceiver, WakeupSender};

mod selection;
mod spawn;

use self::selection::TerminalSelectionGesture;
pub(crate) use self::selection::TerminalSelectionInput;
use self::spawn::{
    configure_shell_command, configure_terminal_environment, direct_startup_command,
    startup_command_input,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TerminalGridSize {
    pub rows: u16,
    pub cols: u16,
    pub pixel_width: u16,
    pub pixel_height: u16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum TmuxShellPromptState {
    Unavailable = 0,
    Waiting = 1,
    Ready = 2,
}

const MAX_SEMANTIC_PROMPT_OSC_BYTES: usize = 64;

#[derive(Debug, Default)]
struct SemanticPromptTracker {
    state: SemanticPromptParseState,
    payload: Vec<u8>,
    observed: bool,
    ready_generation: u64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum SemanticPromptParseState {
    #[default]
    Ground,
    Escape,
    Payload,
    PayloadEscape,
}

impl SemanticPromptTracker {
    fn feed(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.feed_byte(byte);
        }
    }

    fn feed_byte(&mut self, byte: u8) {
        self.state = match self.state {
            SemanticPromptParseState::Ground if byte == 0x1b => SemanticPromptParseState::Escape,
            SemanticPromptParseState::Ground => SemanticPromptParseState::Ground,
            SemanticPromptParseState::Escape if byte == b']' => {
                self.payload.clear();
                SemanticPromptParseState::Payload
            }
            SemanticPromptParseState::Escape if byte == 0x1b => SemanticPromptParseState::Escape,
            SemanticPromptParseState::Escape => SemanticPromptParseState::Ground,
            SemanticPromptParseState::Payload if byte == 0x07 => {
                self.finish_payload();
                SemanticPromptParseState::Ground
            }
            SemanticPromptParseState::Payload if byte == 0x1b => {
                SemanticPromptParseState::PayloadEscape
            }
            SemanticPromptParseState::Payload => {
                self.push_payload_byte(byte);
                SemanticPromptParseState::Payload
            }
            SemanticPromptParseState::PayloadEscape if byte == b'\\' => {
                self.finish_payload();
                SemanticPromptParseState::Ground
            }
            SemanticPromptParseState::PayloadEscape if byte == 0x1b => {
                self.push_payload_byte(0x1b);
                SemanticPromptParseState::PayloadEscape
            }
            SemanticPromptParseState::PayloadEscape => {
                self.push_payload_byte(0x1b);
                self.push_payload_byte(byte);
                SemanticPromptParseState::Payload
            }
        };
    }

    fn push_payload_byte(&mut self, byte: u8) {
        if self.payload.len() < MAX_SEMANTIC_PROMPT_OSC_BYTES {
            self.payload.push(byte);
        }
    }

    fn finish_payload(&mut self) {
        let Some(command) = self.payload.strip_prefix(b"133;") else {
            return;
        };
        self.observed = true;
        if command.first() == Some(&b'B') {
            self.ready_generation = self.ready_generation.wrapping_add(1);
        }
    }
}

impl TerminalGridSize {
    fn pty_size(self) -> PtySize {
        PtySize {
            rows: self.rows,
            cols: self.cols,
            pixel_width: self.pixel_width,
            pixel_height: self.pixel_height,
        }
    }

    fn cell_pixel_size(self) -> (u32, u32) {
        (
            u32::from(self.pixel_width) / u32::from(self.cols.max(1)),
            u32::from(self.pixel_height) / u32::from(self.rows.max(1)),
        )
    }
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
pub struct TerminalSpawnConfig {
    pub cwd: Option<PathBuf>,
    pub shell: Option<String>,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    #[serde(default)]
    pub startup_command: Vec<String>,
    #[serde(default)]
    pub direct_startup: bool,
}

pub struct NativeTerminalRuntime {
    pty: Option<RuntimePty>,
    pty_replies: Rc<RefCell<Vec<u8>>>,
    bell_count: Rc<Cell<u64>>,
    terminal: Terminal<'static, 'static>,
    selection_gesture: TerminalSelectionGesture,
    scroll_sequence_tracker: TerminalScrollSequenceTracker,
    key_encoder: key::Encoder<'static>,
    semantic_prompt_tracker: SemanticPromptTracker,
    mouse_encoder: mouse::Encoder<'static>,
    mouse_button_pressed: bool,
    option_as_alt: bool,
    renderer: TerminalFrameRenderer,
    renderer_model: TerminalRendererModel,
    size: TerminalGridSize,
    current_working_directory: Option<PathBuf>,
    last_search: Option<TerminalSearchState>,
    kitty_image_cache: RefCell<HashMap<u32, CachedKittyImage>>,
    tmux_control: TmuxControl,
    exited: bool,
}

impl NativeTerminalRuntime {
    pub fn spawn(size: TerminalGridSize) -> Result<Self> {
        Self::spawn_with_config(size, TerminalSpawnConfig::default())
    }

    pub fn spawn_in_cwd(size: TerminalGridSize, cwd: Option<&Path>) -> Result<Self> {
        Self::spawn_with_config(
            size,
            TerminalSpawnConfig {
                cwd: cwd.map(Path::to_path_buf),
                ..TerminalSpawnConfig::default()
            },
        )
    }

    pub fn spawn_with_config(size: TerminalGridSize, config: TerminalSpawnConfig) -> Result<Self> {
        let pty = RuntimePty::spawn(size, &config)?;
        Self::new(
            size,
            Some(pty),
            config.cwd.or_else(|| env::current_dir().ok()),
        )
    }

    pub fn external(size: TerminalGridSize) -> Result<Self> {
        Self::new(size, None, None)
    }

    fn new(
        size: TerminalGridSize,
        pty: Option<RuntimePty>,
        current_working_directory: Option<PathBuf>,
    ) -> Result<Self> {
        let pty_replies = Rc::new(RefCell::new(Vec::new()));
        let bell_count = Rc::new(Cell::new(0_u64));
        let mut terminal = Terminal::new(TerminalOptions {
            cols: size.cols,
            rows: size.rows,
            max_scrollback: 100_000,
        })?;
        configure_kitty_graphics(&mut terminal)?;

        terminal.on_pty_write({
            let pty_replies = Rc::clone(&pty_replies);
            move |_term, data| {
                pty_replies.borrow_mut().extend_from_slice(data);
            }
        })?;
        terminal.on_bell({
            let bell_count = Rc::clone(&bell_count);
            move |_term| bell_count.set(bell_count.get().saturating_add(1))
        })?;

        let mut runtime = Self {
            pty,
            pty_replies,
            bell_count,
            terminal,
            selection_gesture: TerminalSelectionGesture::new()?,
            scroll_sequence_tracker: TerminalScrollSequenceTracker::default(),
            key_encoder: key::Encoder::new()?,
            semantic_prompt_tracker: SemanticPromptTracker::default(),
            mouse_encoder: mouse::Encoder::new()?,
            mouse_button_pressed: false,
            option_as_alt: true,
            renderer: TerminalFrameRenderer::new()?,
            renderer_model: TerminalRendererModel::new(size),
            size,
            current_working_directory,
            last_search: None,
            kitty_image_cache: RefCell::new(HashMap::new()),
            tmux_control: TmuxControl::default(),
            exited: false,
        };
        runtime.resize_terminal_cells(size)?;
        Ok(runtime)
    }

    pub fn write_all(&mut self, bytes: &[u8]) -> Result<()> {
        self.pty_mut()?.write_all(bytes)
    }

    pub fn write_key(&mut self, input: NativeKeyInput<'_>) -> Result<bool> {
        let Some(encoded) = self.encode_key(input)? else {
            return Ok(false);
        };
        self.pty_mut()?.write_all(&encoded)?;
        self.scroll_to_bottom_after_input();
        Ok(true)
    }

    pub fn encode_key(&mut self, input: NativeKeyInput<'_>) -> Result<Option<Vec<u8>>> {
        let Some(key) = macos_key(input.key_code) else {
            return Ok(None);
        };
        self.key_encoder
            .set_options_from_terminal(&self.terminal)
            .set_macos_option_as_alt(if self.option_as_alt {
                OptionAsAlt::True
            } else {
                OptionAsAlt::False
            });
        let mut event = key::Event::new()?;
        let text = if input.released {
            None
        } else {
            input.text.filter(|text| valid_key_text(text))
        };
        event
            .set_action(if input.released {
                key::Action::Release
            } else if input.repeat {
                key::Action::Repeat
            } else {
                key::Action::Press
            })
            .set_key(key)
            .set_mods(native_key_mods(input.modifiers))
            .set_composing(false)
            .set_utf8(text);
        if let Some(codepoint) = input.unshifted.chars().next() {
            event.set_unshifted_codepoint(codepoint);
        }
        let mut encoded = Vec::with_capacity(32);
        self.key_encoder.encode_to_vec(&event, &mut encoded)?;
        if encoded.is_empty() {
            return Ok(None);
        }
        Ok(Some(encoded))
    }

    pub fn write_text(&mut self, text: &str) -> Result<()> {
        self.pty_mut()?.write_all(text.as_bytes())?;
        self.scroll_to_bottom_after_input();
        Ok(())
    }

    pub fn write_paste(&mut self, text: &str) -> Result<()> {
        let encoded = self.encode_paste(text)?;
        self.pty_mut()?.write_all(&encoded)?;
        self.scroll_to_bottom_after_input();
        Ok(())
    }

    pub fn encode_paste(&mut self, text: &str) -> Result<Vec<u8>> {
        let mut data = text.as_bytes().to_vec();
        let bracketed = self.terminal.mode(Mode::BRACKETED_PASTE).unwrap_or(false);
        let mut encoded = vec![0; data.len().saturating_add(32)];
        let written = match paste::encode(&mut data, bracketed, &mut encoded) {
            Ok(written) => written,
            Err(libghostty_vt::Error::OutOfSpace { required }) => {
                encoded.resize(required, 0);
                paste::encode(&mut data, bracketed, &mut encoded)?
            }
            Err(error) => return Err(error.into()),
        };
        encoded.truncate(written);
        Ok(encoded)
    }

    pub fn write_mouse(&mut self, input: NativeMouseInput) -> Result<bool> {
        let Some(encoded) = self.encode_mouse(input)? else {
            return Ok(false);
        };
        self.pty_mut()?.write_all(&encoded)?;
        Ok(true)
    }

    pub fn encode_mouse(&mut self, input: NativeMouseInput) -> Result<Option<Vec<u8>>> {
        if !self.is_mouse_tracking() {
            return Ok(None);
        }
        self.mouse_encoder
            .set_options_from_terminal(&self.terminal)
            .set_size(mouse::EncoderSize {
                screen_width: self.size.pixel_width.into(),
                screen_height: self.size.pixel_height.into(),
                cell_width: input.cell_width.max(1),
                cell_height: input.cell_height.max(1),
                padding_top: 0,
                padding_bottom: 0,
                padding_right: 0,
                padding_left: 0,
            })
            .set_any_button_pressed(self.mouse_button_pressed);
        let mut event = mouse::Event::new()?;
        event
            .set_action(input.action)
            .set_button(input.button)
            .set_mods(native_key_mods(input.modifiers))
            .set_position(mouse::Position {
                x: input.x,
                y: input.y,
            });
        let mut encoded = Vec::with_capacity(32);
        self.mouse_encoder.encode_to_vec(&event, &mut encoded)?;
        if encoded.is_empty() {
            return Ok(None);
        }
        if input.button.is_some() {
            self.mouse_button_pressed = input.action != mouse::Action::Release;
        }
        Ok(Some(encoded))
    }

    pub fn is_mouse_tracking(&self) -> bool {
        self.terminal.is_mouse_tracking().unwrap_or(false)
    }

    pub fn write_focus(&mut self, focused: bool) -> Result<bool> {
        let Some(encoded) = self.encode_focus(focused)? else {
            return Ok(false);
        };
        self.pty_mut()?.write_all(&encoded)?;
        Ok(true)
    }

    pub fn encode_focus(&self, focused: bool) -> Result<Option<Vec<u8>>> {
        if !self.terminal.mode(Mode::FOCUS_EVENT)? {
            return Ok(None);
        }
        Ok(Some(if focused {
            b"\x1b[I".to_vec()
        } else {
            b"\x1b[O".to_vec()
        }))
    }

    pub fn select_all(&self) -> Result<()> {
        let selection = self.terminal.select_all()?;
        self.terminal.set_selection(selection.as_ref())?;
        Ok(())
    }

    pub fn clear_selection(&self) -> Result<()> {
        self.terminal.set_selection(None)?;
        Ok(())
    }

    pub fn selected_text(&self) -> Result<Option<String>> {
        let bytes = self.terminal.format_selection_alloc(
            None,
            FormatOptions::new()
                .with_emit_format(Format::Plain)
                .with_unwrap(true)
                .with_trim(true),
        )?;
        Ok(bytes.map(|bytes| String::from_utf8_lossy(&bytes).into_owned()))
    }

    pub fn hyperlink_at(&self, point: TerminalPoint) -> Result<Option<String>> {
        let grid_ref = self.viewport_grid_ref(point)?;
        let mut buffer = vec![0; 256];
        let written = match grid_ref.hyperlink_uri(&mut buffer) {
            Ok(0) => 0,
            Ok(written) => written,
            Err(libghostty_vt::Error::OutOfSpace { required }) => {
                buffer.resize(required, 0);
                grid_ref.hyperlink_uri(&mut buffer)?
            }
            Err(error) => return Err(error.into()),
        };
        if written > 0 {
            return Ok(Some(
                String::from_utf8_lossy(&buffer[..written]).into_owned(),
            ));
        }
        let boundaries = [' ', '\t'];
        let Some(selection) = self
            .terminal
            .select_word(SelectWordOptions::new(grid_ref).with_boundary_codepoints(&boundaries))?
        else {
            return Ok(None);
        };
        let value = self.terminal.format_selection_alloc(
            None,
            FormatOptions::new()
                .with_emit_format(Format::Plain)
                .with_unwrap(true)
                .with_trim(true)
                .with_selection(&selection),
        )?;
        Ok(value.and_then(|value| normalize_terminal_url(&String::from_utf8_lossy(&value))))
    }

    pub fn title(&self) -> Option<String> {
        self.terminal
            .title()
            .ok()
            .filter(|title| !title.is_empty())
            .map(str::to_owned)
    }

    pub fn take_bell_count(&self) -> u64 {
        self.bell_count.replace(0)
    }

    pub fn set_option_as_alt(&mut self, enabled: bool) {
        self.option_as_alt = enabled;
    }

    pub fn find(&mut self, query: &str, backwards: bool) -> Result<bool> {
        if query.is_empty() {
            return Ok(false);
        }
        let total_rows = self.terminal.total_rows()?;
        if total_rows == 0 {
            return Ok(false);
        }
        let scrollbar = self.terminal.scrollbar()?;
        let start_row = self.search_start_row(query, backwards, total_rows, scrollbar.offset);
        for offset in 0..total_rows {
            let row = if backwards {
                (start_row + total_rows - offset % total_rows) % total_rows
            } else {
                (start_row + offset) % total_rows
            };
            let Some((start_col, end_col)) = self.find_in_screen_row(row, query)? else {
                continue;
            };
            self.reveal_search_match(row, scrollbar.len)?;
            self.set_screen_selection(row, start_col, end_col)?;
            self.last_search = Some(TerminalSearchState {
                query: query.to_owned(),
                row,
            });
            return Ok(true);
        }
        Ok(false)
    }

    pub fn kitty_placements(&self) -> Result<Vec<KittyImagePlacementSnapshot>> {
        kitty_placements(&self.terminal, &self.kitty_image_cache)
    }

    pub fn resize(&mut self, size: TerminalGridSize) -> Result<()> {
        if self.size == size {
            return Ok(());
        }
        self.resize_terminal_cells(size)?;
        if let Some(pty) = self.pty.as_ref() {
            pty.resize(size)?;
        }
        self.renderer_model.resize(size);
        self.size = size;
        Ok(())
    }

    pub fn drain(&mut self) -> Result<bool> {
        let Some(pty) = self.pty.as_ref() else {
            return Ok(false);
        };
        pty.clear_wakeup();
        let bytes = pty.rx.try_iter().collect::<Vec<_>>();
        let mut changed = false;
        for bytes in bytes {
            let passthrough = self.tmux_control.feed(&bytes)?;
            if !passthrough.is_empty() {
                self.feed_terminal(&passthrough);
                changed = true;
            }
            self.flush_tmux_outgoing()?;
            self.flush_terminal_replies()?;
        }
        let was_exited = self.exited;
        if self.refresh_exited() && !was_exited {
            changed = true;
        }
        Ok(changed)
    }

    pub fn wakeup_fd(&self) -> i32 {
        self.pty.as_ref().map_or(-1, RuntimePty::wakeup_fd)
    }

    pub fn feed_external(&mut self, bytes: &[u8]) -> Result<Vec<u8>> {
        if self.pty.is_some() {
            bail!("cannot externally feed a PTY-backed terminal runtime");
        }
        self.feed_terminal(bytes);
        Ok(std::mem::take(&mut *self.pty_replies.borrow_mut()))
    }

    pub fn feed_tmux_projection(&mut self, bytes: &[u8]) -> Result<()> {
        if self.pty.is_some() {
            bail!("cannot externally feed a PTY-backed terminal runtime");
        }
        self.feed_terminal(bytes);
        self.semantic_prompt_tracker.feed(bytes);
        // tmux is the terminal emulator for the pane PTY and already answers
        // device reports from applications. Replies generated by Satin's
        // display-only projection would be duplicates; a late duplicate can
        // otherwise arrive at the shell after an alternate-screen app exits.
        self.pty_replies.borrow_mut().clear();
        Ok(())
    }

    pub fn tmux_shell_prompt_state(&self) -> Result<TmuxShellPromptState> {
        if self.terminal.active_screen()? != Screen::Primary {
            return Ok(TmuxShellPromptState::Unavailable);
        }
        let cursor_x = self.terminal.cursor_x()?;
        if cursor_x > 0 {
            Ok(TmuxShellPromptState::Ready)
        } else {
            Ok(TmuxShellPromptState::Waiting)
        }
    }

    pub fn tmux_semantic_prompt_seen(&self) -> bool {
        self.semantic_prompt_tracker.observed
    }

    pub fn tmux_prompt_generation(&self) -> u64 {
        self.semantic_prompt_tracker.ready_generation
    }

    pub fn reset_tmux_prompt_tracking(&mut self) {
        self.semantic_prompt_tracker = SemanticPromptTracker::default();
    }

    pub fn take_tmux_event(&mut self) -> Option<TmuxControlEvent> {
        self.tmux_control.take_event()
    }

    pub fn tmux_command(&mut self, command: &str) -> Result<bool> {
        if !self.tmux_control.command(command) {
            return Ok(false);
        }
        self.flush_tmux_outgoing()?;
        Ok(true)
    }

    pub fn tmux_send_bytes(&mut self, pane_id: u32, bytes: &[u8]) -> Result<bool> {
        if bytes.is_empty() || !self.tmux_control.pane_accepts_input(pane_id) {
            return Ok(false);
        }
        for chunk in bytes.chunks(256) {
            let mut command = format!("send-keys -t %{pane_id} -H");
            for byte in chunk {
                use std::fmt::Write as _;
                write!(command, " {byte:02x}")?;
            }
            if !self.tmux_control.command(command) {
                return Ok(false);
            }
        }
        self.flush_tmux_outgoing()?;
        Ok(true)
    }

    pub fn tmux_paste(&mut self, pane_id: u32, bytes: &[u8]) -> Result<bool> {
        if !self.tmux_control.paste(pane_id, bytes) {
            return Ok(false);
        }
        self.flush_tmux_outgoing()?;
        Ok(true)
    }

    pub fn finish_external_input(&mut self) {
        if self.pty.is_none() {
            self.scroll_to_bottom_after_input();
        }
    }

    pub fn is_exited(&mut self) -> bool {
        self.refresh_exited()
    }

    pub fn scroll_delta(&mut self, requested_rows: isize) -> Result<isize> {
        let terminal_rows = bounded_scroll_rows(
            requested_rows,
            self.terminal.scrollbar().ok().map(ScrollbarView::from),
        );
        if terminal_rows != 0 {
            self.terminal
                .scroll_viewport(ScrollViewport::Delta(terminal_rows));
            self.renderer_model.record_scroll_delta(terminal_rows);
        }
        Ok(terminal_rows)
    }

    pub fn frame(&mut self) -> Result<TerminalFrameSnapshot> {
        self.renderer.collect(&mut self.terminal)
    }

    pub fn screen_text(&mut self) -> Result<String> {
        let frame = self.frame()?;
        Ok(frame
            .rows
            .iter()
            .map(|row| {
                row.iter()
                    .map(|cell| cell.text.as_str())
                    .collect::<String>()
                    .trim_end()
                    .to_owned()
            })
            .collect::<Vec<_>>()
            .join("\n"))
    }

    pub fn renderer_model(&mut self) -> Result<NeovideRendererModelSnapshot> {
        let frame = self.frame()?;
        Ok(self.renderer_model.snapshot(&frame))
    }

    pub fn advance_renderer_animations(&mut self, dt: f32) -> bool {
        self.renderer_model.advance_animations(dt)
    }

    pub fn has_active_renderer_animation(&self) -> bool {
        self.renderer_model.has_active_animation()
    }

    pub fn renderer_scroll_position(&self) -> f32 {
        self.renderer_model.scroll_position()
    }

    pub fn cursor_position(&self) -> Result<Option<(u16, u16)>> {
        Ok(Some((self.terminal.cursor_x()?, self.terminal.cursor_y()?)))
    }

    pub fn current_working_directory(&self) -> Option<PathBuf> {
        self.current_working_directory.clone()
    }

    fn viewport_grid_ref(
        &self,
        point: TerminalPoint,
    ) -> Result<libghostty_vt::screen::GridRef<'_>> {
        self.terminal
            .grid_ref(Point::Viewport(self.clamped_viewport_point(point)))
            .map_err(Into::into)
    }

    fn clamped_viewport_point(&self, point: TerminalPoint) -> PointCoordinate {
        PointCoordinate {
            x: point.col.min(self.size.cols.saturating_sub(1)),
            y: point.row.min(u32::from(self.size.rows.saturating_sub(1))),
        }
    }

    fn scroll_to_bottom_after_input(&mut self) {
        self.terminal.scroll_viewport(ScrollViewport::Bottom);
    }

    fn feed_terminal(&mut self, bytes: &[u8]) {
        let scroll_update = self.scroll_sequence_tracker.feed(bytes);
        self.terminal.vt_write(bytes);
        self.renderer_model.record_scroll_update(scroll_update);
        self.update_working_directory_from_terminal();
    }

    fn flush_tmux_outgoing(&mut self) -> Result<()> {
        while let Some(command) = self.tmux_control.take_outgoing() {
            self.pty_mut()?.write_all(&command)?;
        }
        Ok(())
    }

    fn flush_terminal_replies(&mut self) -> Result<()> {
        if self.pty_replies.borrow().is_empty() {
            return Ok(());
        }
        let replies = std::mem::take(&mut *self.pty_replies.borrow_mut());
        self.pty_mut()?.write_all(&replies)
    }

    fn pty_mut(&mut self) -> Result<&mut RuntimePty> {
        self.pty
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("terminal runtime has no PTY"))
    }

    fn resize_terminal_cells(&mut self, size: TerminalGridSize) -> Result<()> {
        resize_kitty_terminal(&mut self.terminal, size)
    }

    fn search_start_row(
        &self,
        query: &str,
        backwards: bool,
        total_rows: usize,
        viewport_top: u64,
    ) -> usize {
        if let Some(search) = self
            .last_search
            .as_ref()
            .filter(|search| search.query == query)
        {
            return if backwards {
                search.row.checked_sub(1).unwrap_or(total_rows - 1)
            } else {
                (search.row + 1) % total_rows
            };
        }
        let top = usize::try_from(viewport_top)
            .unwrap_or(usize::MAX)
            .min(total_rows - 1);
        if backwards {
            top.saturating_add(usize::from(self.size.rows).saturating_sub(1))
                .min(total_rows - 1)
        } else {
            top
        }
    }

    fn find_in_screen_row(&self, row: usize, query: &str) -> Result<Option<(u16, u16)>> {
        let mut text = String::new();
        let mut columns = Vec::new();
        for col in 0..self.size.cols {
            let grid_ref = self.terminal.grid_ref(Point::Screen(PointCoordinate {
                x: col,
                y: u32::try_from(row).unwrap_or(u32::MAX),
            }))?;
            let value = grid_ref_text(&grid_ref)?;
            columns.push((text.len(), col));
            text.push_str(&value);
        }
        let Some(start_byte) = text.find(query) else {
            return Ok(None);
        };
        let start = columns
            .iter()
            .rev()
            .find(|(byte, _)| *byte <= start_byte)
            .map_or(0, |(_, col)| *col);
        let end_byte = start_byte.saturating_add(query.len().saturating_sub(1));
        let end = columns
            .iter()
            .rev()
            .find(|(byte, _)| *byte <= end_byte)
            .map_or(start, |(_, col)| *col);
        Ok(Some((start, end)))
    }

    fn reveal_search_match(&mut self, row: usize, visible_rows: u64) -> Result<()> {
        let scrollbar = self.terminal.scrollbar()?;
        let visible = usize::try_from(visible_rows).unwrap_or(usize::MAX);
        let total = usize::try_from(scrollbar.total).unwrap_or(usize::MAX);
        let max_top = total.saturating_sub(visible);
        let desired = row.saturating_sub(visible / 2).min(max_top);
        let current = isize::try_from(scrollbar.offset).unwrap_or(isize::MAX);
        let desired = isize::try_from(desired).unwrap_or(isize::MAX);
        self.terminal
            .scroll_viewport(ScrollViewport::Delta(desired.saturating_sub(current)));
        Ok(())
    }

    fn set_screen_selection(&self, row: usize, start_col: u16, end_col: u16) -> Result<()> {
        let row = u32::try_from(row).unwrap_or(u32::MAX);
        let start = self.terminal.grid_ref(Point::Screen(PointCoordinate {
            x: start_col,
            y: row,
        }))?;
        let end = self
            .terminal
            .grid_ref(Point::Screen(PointCoordinate { x: end_col, y: row }))?;
        let selection = Selection::new(start, end, false);
        self.terminal.set_selection(Some(&selection))?;
        Ok(())
    }

    fn update_working_directory_from_terminal(&mut self) {
        let Ok(pwd) = self.terminal.pwd() else {
            return;
        };
        if let Some(path) = terminal_pwd_path(pwd) {
            self.current_working_directory = Some(path);
        }
    }

    fn refresh_exited(&mut self) -> bool {
        self.exited = self.exited || self.pty.as_mut().is_some_and(RuntimePty::poll_exited);
        self.exited
    }
}

impl Drop for NativeTerminalRuntime {
    fn drop(&mut self) {
        self.selection_gesture.reset(&self.terminal);
        if let Some(pty) = self.pty.as_mut() {
            let _ = pty.kill();
        }
    }
}

struct RuntimePty {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    rx: Receiver<Vec<u8>>,
    child: Box<dyn Child + Send + Sync>,
    process_group_id: Option<i32>,
    wakeup: WakeupReceiver,
    reader_thread: Option<thread::JoinHandle<()>>,
    reader_done: Receiver<()>,
}

impl RuntimePty {
    fn spawn(size: TerminalGridSize, config: &TerminalSpawnConfig) -> Result<Self> {
        let pty_system = native_pty_system();
        let pair = pty_system.openpty(size.pty_size())?;
        let shell = configured_shell(config.shell.as_deref())?;
        let (mut cmd, startup_input) = if config.direct_startup {
            (direct_startup_command(&config.startup_command)?, None)
        } else {
            let mut cmd = CommandBuilder::new(&shell);
            configure_shell_command(&mut cmd, config, &shell);
            (cmd, startup_command_input(&config.startup_command)?)
        };
        if config.direct_startup {
            configure_terminal_environment(&mut cmd, config, &shell);
        }

        let child = pair.slave.spawn_command(cmd)?;
        let process_group_id = child.process_id().and_then(|pid| i32::try_from(pid).ok());
        let mut reader = pair.master.try_clone_reader()?;
        let mut writer = pair.master.take_writer()?;
        if let Some(input) = startup_input {
            writer.write_all(&input)?;
            writer.flush()?;
        }
        let (tx, rx) = mpsc::channel();
        let (wakeup, wakeup_sender) = crate::wakeup::pipe()?;
        let (done_tx, reader_done) = mpsc::channel();

        let reader_thread = thread::spawn(move || {
            read_pty_loop(&mut reader, tx, &wakeup_sender);
            wakeup_sender.notify();
            let _ = done_tx.send(());
        });

        Ok(Self {
            master: pair.master,
            writer,
            rx,
            child,
            process_group_id,
            wakeup,
            reader_thread: Some(reader_thread),
            reader_done,
        })
    }

    fn resize(&self, size: TerminalGridSize) -> Result<()> {
        self.master.resize(size.pty_size())
    }

    fn write_all(&mut self, bytes: &[u8]) -> Result<()> {
        self.writer.write_all(bytes)?;
        self.writer.flush()?;
        Ok(())
    }

    fn kill(&mut self) -> Result<()> {
        terminate_pty_process_tree(self.child.as_mut(), self.process_group_id);
        if self
            .reader_done
            .recv_timeout(Duration::from_secs(1))
            .is_ok()
            && let Some(reader_thread) = self.reader_thread.take()
        {
            let _ = reader_thread.join();
        }
        Ok(())
    }

    fn wakeup_fd(&self) -> i32 {
        self.wakeup.fd()
    }

    fn clear_wakeup(&self) {
        self.wakeup.clear();
    }

    fn poll_exited(&mut self) -> bool {
        match self.child.try_wait() {
            Ok(Some(_)) => true,
            Ok(None) => false,
            Err(_) => true,
        }
    }
}

fn read_pty_loop(
    reader: &mut Box<dyn Read + Send>,
    tx: mpsc::Sender<Vec<u8>>,
    wakeup: &WakeupSender,
) {
    let mut buffer = [0u8; 16 * 1024];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                if tx.send(buffer[..count].to_vec()).is_err() {
                    break;
                }
                wakeup.notify();
            }
            Err(_) => break,
        }
    }
}

#[cfg(unix)]
fn terminate_pty_process_tree(child: &mut dyn Child, process_group_id: Option<i32>) {
    if let Some(process_group) = process_group_id {
        // SAFETY: portable-pty starts the shell as the leader of this process group.
        unsafe {
            libc::kill(-process_group, libc::SIGTERM);
        }
    }
    for _ in 0..20 {
        if child.try_wait().ok().flatten().is_some() {
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    if let Some(process_group) = process_group_id {
        // SAFETY: portable-pty starts the shell as the leader of this process group.
        unsafe {
            libc::kill(-process_group, libc::SIGKILL);
        }
    }
    if child.try_wait().ok().flatten().is_none() {
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[cfg(not(unix))]
fn terminate_pty_process_tree(child: &mut dyn Child, _process_group_id: Option<i32>) {
    let _ = child.kill();
    let _ = child.wait();
}

#[derive(Clone, Copy, Debug)]
pub struct NativeKeyInput<'a> {
    pub key_code: u16,
    pub modifiers: u32,
    pub text: Option<&'a str>,
    pub unshifted: &'a str,
    pub repeat: bool,
    pub released: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NativeMouseInput {
    pub action: mouse::Action,
    pub button: Option<mouse::Button>,
    pub modifiers: u32,
    pub x: f32,
    pub y: f32,
    pub cell_width: u32,
    pub cell_height: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TerminalPoint {
    pub row: u32,
    pub col: u16,
}

struct TerminalSearchState {
    query: String,
    row: usize,
}

#[derive(Clone, Debug)]
pub struct KittyImagePlacementSnapshot {
    pub image_id: u32,
    pub image_number: u32,
    pub z: i32,
    pub viewport_col: i32,
    pub viewport_row: i32,
    pub x_offset: u32,
    pub y_offset: u32,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub source_x: u32,
    pub source_y: u32,
    pub source_width: u32,
    pub source_height: u32,
    pub image_width: u32,
    pub image_height: u32,
    pub rgba: Arc<[u8]>,
}

pub struct KittyGraphicsBridge {
    terminal: Terminal<'static, 'static>,
    image_cache: RefCell<HashMap<u32, CachedKittyImage>>,
    size: TerminalGridSize,
}

impl KittyGraphicsBridge {
    pub fn new(size: TerminalGridSize) -> Result<Self> {
        let mut terminal = Terminal::new(TerminalOptions {
            cols: size.cols,
            rows: size.rows,
            max_scrollback: 0,
        })?;
        configure_kitty_graphics(&mut terminal)?;
        resize_kitty_terminal(&mut terminal, size)?;
        Ok(Self {
            terminal,
            image_cache: RefCell::new(HashMap::new()),
            size,
        })
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        self.terminal.vt_write(bytes);
    }

    pub fn resize(&mut self, size: TerminalGridSize) -> Result<()> {
        if self.size == size {
            return Ok(());
        }
        resize_kitty_terminal(&mut self.terminal, size)?;
        self.size = size;
        Ok(())
    }

    pub fn placements(&self) -> Result<Vec<KittyImagePlacementSnapshot>> {
        kitty_placements(&self.terminal, &self.image_cache)
    }
}

struct CachedKittyImage {
    image_number: u32,
    rgba: Arc<[u8]>,
}

fn kitty_placements(
    terminal: &Terminal<'static, 'static>,
    image_cache: &RefCell<HashMap<u32, CachedKittyImage>>,
) -> Result<Vec<KittyImagePlacementSnapshot>> {
    let graphics = terminal.kitty_graphics()?;
    let mut iterator = PlacementIterator::new()?;
    let mut placements = iterator.update(&graphics)?;
    let mut output = Vec::new();
    let mut visible_images = HashSet::new();
    while let Some(placement) = placements.next() {
        let image_id = placement.image_id()?;
        visible_images.insert(image_id);
        let Some(image) = graphics.image(image_id) else {
            continue;
        };
        let info = placement.placement_render_info(&image, terminal)?;
        if !info.viewport_visible {
            continue;
        }
        let image_number = image.number()?;
        let rgba = cached_kitty_rgba(image_cache, image_id, image_number, &image)?;
        output.push(KittyImagePlacementSnapshot {
            image_id,
            image_number,
            z: placement.z()?,
            viewport_col: info.viewport_col,
            viewport_row: info.viewport_row,
            x_offset: placement.x_offset()?,
            y_offset: placement.y_offset()?,
            pixel_width: info.pixel_width,
            pixel_height: info.pixel_height,
            source_x: info.source_x,
            source_y: info.source_y,
            source_width: info.source_width,
            source_height: info.source_height,
            image_width: image.width()?,
            image_height: image.height()?,
            rgba,
        });
    }
    image_cache
        .borrow_mut()
        .retain(|image_id, _| visible_images.contains(image_id));
    output.sort_by_key(|placement| placement.z);
    Ok(output)
}

fn cached_kitty_rgba(
    cache: &RefCell<HashMap<u32, CachedKittyImage>>,
    image_id: u32,
    image_number: u32,
    image: &graphics::Image<'_>,
) -> Result<Arc<[u8]>> {
    if let Some(cached) = cache.borrow().get(&image_id)
        && cached.image_number == image_number
    {
        return Ok(Arc::clone(&cached.rgba));
    }
    let rgba: Arc<[u8]> = image_rgba(
        image.data()?,
        image.width()?,
        image.height()?,
        image.format()?,
    )?
    .into();
    cache.borrow_mut().insert(
        image_id,
        CachedKittyImage {
            image_number,
            rgba: Arc::clone(&rgba),
        },
    );
    Ok(rgba)
}

fn configure_kitty_graphics(terminal: &mut Terminal<'static, 'static>) -> Result<()> {
    graphics::set_png_decoder(Some(Box::new(NativePngDecoder::default())))?;
    terminal
        .set_kitty_image_storage_limit(64 * 1024 * 1024)?
        .set_apc_max_bytes_kitty(Some(16 * 1024 * 1024))?
        .set_kitty_image_from_file_allowed(false)?
        .set_kitty_image_from_temp_file_allowed(true)?
        .set_kitty_image_from_shared_mem_allowed(true)?;
    Ok(())
}

fn resize_kitty_terminal(
    terminal: &mut Terminal<'static, 'static>,
    size: TerminalGridSize,
) -> Result<()> {
    let (cell_width, cell_height) = size.cell_pixel_size();
    terminal.resize(size.cols, size.rows, cell_width.max(1), cell_height.max(1))?;
    Ok(())
}

#[derive(Default)]
struct NativePngDecoder {
    buffer: Vec<u8>,
}

impl graphics::DecodePng for NativePngDecoder {
    fn decode_png<'alloc>(
        &mut self,
        alloc: &'alloc libghostty_vt::alloc::Allocator<'_>,
        data: &[u8],
    ) -> Option<graphics::DecodedImage<'alloc>> {
        use std::io::Cursor;

        let mut decoder = png::Decoder::new(Cursor::new(data));
        decoder.set_transformations(png::Transformations::ALPHA | png::Transformations::STRIP_16);
        let mut reader = decoder.read_info().ok()?;
        let size = reader.output_buffer_size()?;
        self.buffer.resize(size, 0);
        let info = reader.next_frame(&mut self.buffer).ok()?;
        let mut bytes =
            libghostty_vt::alloc::Bytes::new_with_alloc(alloc, info.buffer_size()).ok()?;
        bytes.copy_from_slice(&self.buffer[..info.buffer_size()]);
        reader.finish().ok()?;
        Some(graphics::DecodedImage {
            width: info.width,
            height: info.height,
            data: bytes,
        })
    }
}

fn image_rgba(data: &[u8], width: u32, height: u32, format: ImageFormat) -> Result<Vec<u8>> {
    let pixel_count = usize::try_from(width)
        .unwrap_or(usize::MAX)
        .saturating_mul(usize::try_from(height).unwrap_or(usize::MAX));
    let expected = pixel_count.saturating_mul(4);
    let mut output = Vec::with_capacity(expected);
    match format {
        ImageFormat::Rgba => output.extend_from_slice(data),
        ImageFormat::Rgb => {
            for pixel in data.chunks_exact(3).take(pixel_count) {
                output.extend_from_slice(&[pixel[0], pixel[1], pixel[2], 255]);
            }
        }
        ImageFormat::GrayAlpha => {
            for pixel in data.chunks_exact(2).take(pixel_count) {
                output.extend_from_slice(&[pixel[0], pixel[0], pixel[0], pixel[1]]);
            }
        }
        ImageFormat::Gray => {
            for value in data.iter().copied().take(pixel_count) {
                output.extend_from_slice(&[value, value, value, 255]);
            }
        }
        _ => return Err(anyhow::anyhow!("unsupported Kitty image pixel format")),
    }
    if output.len() != expected {
        return Err(anyhow::anyhow!("invalid Kitty image byte length"));
    }
    Ok(output)
}

fn grid_ref_text(grid_ref: &libghostty_vt::screen::GridRef<'_>) -> Result<String> {
    let mut buffer = vec!['\0'; 8];
    let written = match grid_ref.graphemes(&mut buffer) {
        Ok(written) => written,
        Err(libghostty_vt::Error::OutOfSpace { required }) => {
            buffer.resize(required, '\0');
            grid_ref.graphemes(&mut buffer)?
        }
        Err(error) => return Err(error.into()),
    };
    Ok(buffer[..written].iter().collect())
}

fn normalize_terminal_url(value: &str) -> Option<String> {
    let value =
        value.trim_matches(|value: char| value.is_whitespace() || "\"'()[]{}<>,;".contains(value));
    if value.starts_with("https://")
        || value.starts_with("http://")
        || value.starts_with("file://")
        || value.starts_with("mailto:")
    {
        return Some(value.to_owned());
    }
    value
        .starts_with("www.")
        .then(|| format!("https://{value}"))
}

const NATIVE_MOD_SHIFT: u32 = 1 << 0;
const NATIVE_MOD_CONTROL: u32 = 1 << 1;
const NATIVE_MOD_OPTION: u32 = 1 << 2;
const NATIVE_MOD_COMMAND: u32 = 1 << 3;
const NATIVE_MOD_CAPS_LOCK: u32 = 1 << 4;
const NATIVE_MOD_NUM_LOCK: u32 = 1 << 5;
fn native_key_mods(modifiers: u32) -> Mods {
    let mut mods = Mods::empty();
    for (mask, value) in [
        (NATIVE_MOD_SHIFT, Mods::SHIFT),
        (NATIVE_MOD_CONTROL, Mods::CTRL),
        (NATIVE_MOD_OPTION, Mods::ALT),
        (NATIVE_MOD_COMMAND, Mods::SUPER),
        (NATIVE_MOD_CAPS_LOCK, Mods::CAPS_LOCK),
        (NATIVE_MOD_NUM_LOCK, Mods::NUM_LOCK),
    ] {
        if modifiers & mask != 0 {
            mods.insert(value);
        }
    }
    mods
}

fn valid_key_text(text: &str) -> bool {
    !text.is_empty()
        && text
            .chars()
            .all(|value| !value.is_control() && !(('\u{f700}'..='\u{f8ff}').contains(&value)))
}

#[expect(
    clippy::too_many_lines,
    reason = "macOS virtual-key table is intentionally explicit"
)]
fn macos_key(code: u16) -> Option<Key> {
    Some(match code {
        0 => Key::A,
        1 => Key::S,
        2 => Key::D,
        3 => Key::F,
        4 => Key::H,
        5 => Key::G,
        6 => Key::Z,
        7 => Key::X,
        8 => Key::C,
        9 => Key::V,
        11 => Key::B,
        12 => Key::Q,
        13 => Key::W,
        14 => Key::E,
        15 => Key::R,
        16 => Key::Y,
        17 => Key::T,
        18 => Key::Digit1,
        19 => Key::Digit2,
        20 => Key::Digit3,
        21 => Key::Digit4,
        22 => Key::Digit6,
        23 => Key::Digit5,
        24 => Key::Equal,
        25 => Key::Digit9,
        26 => Key::Digit7,
        27 => Key::Minus,
        28 => Key::Digit8,
        29 => Key::Digit0,
        30 => Key::BracketRight,
        31 => Key::O,
        32 => Key::U,
        33 => Key::BracketLeft,
        34 => Key::I,
        35 => Key::P,
        36 => Key::Enter,
        37 => Key::L,
        38 => Key::J,
        39 => Key::Quote,
        40 => Key::K,
        41 => Key::Semicolon,
        42 => Key::Backslash,
        43 => Key::Comma,
        44 => Key::Slash,
        45 => Key::N,
        46 => Key::M,
        47 => Key::Period,
        48 => Key::Tab,
        49 => Key::Space,
        50 => Key::Backquote,
        51 => Key::Backspace,
        53 => Key::Escape,
        55 => Key::MetaLeft,
        56 => Key::ShiftLeft,
        57 => Key::CapsLock,
        58 => Key::AltLeft,
        59 => Key::ControlLeft,
        60 => Key::ShiftRight,
        61 => Key::AltRight,
        62 => Key::ControlRight,
        64 => Key::F17,
        65 => Key::NumpadDecimal,
        67 => Key::NumpadMultiply,
        69 => Key::NumpadAdd,
        71 => Key::NumpadClear,
        75 => Key::NumpadDivide,
        76 => Key::NumpadEnter,
        78 => Key::NumpadSubtract,
        79 => Key::F18,
        80 => Key::F19,
        81 => Key::NumpadEqual,
        82 => Key::Numpad0,
        83 => Key::Numpad1,
        84 => Key::Numpad2,
        85 => Key::Numpad3,
        86 => Key::Numpad4,
        87 => Key::Numpad5,
        88 => Key::Numpad6,
        89 => Key::Numpad7,
        90 => Key::F20,
        91 => Key::Numpad8,
        92 => Key::Numpad9,
        93 => Key::IntlYen,
        96 => Key::F5,
        97 => Key::F6,
        98 => Key::F7,
        99 => Key::F3,
        100 => Key::F8,
        101 => Key::F9,
        102 => Key::NonConvert,
        103 => Key::F11,
        104 => Key::KanaMode,
        105 => Key::F13,
        106 => Key::F16,
        107 => Key::F14,
        109 => Key::F10,
        111 => Key::F12,
        113 => Key::F15,
        114 => Key::Help,
        115 => Key::Home,
        116 => Key::PageUp,
        117 => Key::Delete,
        118 => Key::F4,
        119 => Key::End,
        120 => Key::F2,
        121 => Key::PageDown,
        122 => Key::F1,
        123 => Key::ArrowLeft,
        124 => Key::ArrowRight,
        125 => Key::ArrowDown,
        126 => Key::ArrowUp,
        _ => return None,
    })
}

fn terminal_pwd_path(pwd: &str) -> Option<PathBuf> {
    let pwd = pwd.trim();
    if pwd.is_empty() {
        return None;
    }
    let path = if let Some(rest) = pwd.strip_prefix("file://") {
        rest.find('/').map(|index| &rest[index..])?
    } else if pwd.starts_with('/') {
        pwd
    } else {
        return None;
    };
    percent_decode_path(path).map(PathBuf::from)
}

fn percent_decode_path(path: &str) -> Option<String> {
    let mut output = Vec::with_capacity(path.len());
    let bytes = path.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'%' {
            output.push(bytes[index]);
            index += 1;
            continue;
        }
        let hi = hex_value(*bytes.get(index + 1)?)?;
        let lo = hex_value(*bytes.get(index + 2)?)?;
        output.push((hi << 4) | lo);
        index += 3;
    }
    String::from_utf8(output).ok()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

struct TerminalFrameRenderer {
    state: RenderState<'static>,
    rows: RowIterator<'static>,
    cells: CellIterator<'static>,
}

struct TerminalRendererModel {
    window: NeovideRenderedWindowCache,
    width: usize,
    height: usize,
    pending_scroll: TerminalScrollUpdate,
    last_scrollbar: Option<ScrollbarSnapshot>,
    last_screen: Option<TerminalScreenSnapshot>,
}

const MAX_TERMINAL_SCROLL_ANIMATION_ROWS: isize = 24;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum TerminalScrollParseState {
    #[default]
    Ground,
    Escape,
    Csi,
    Osc,
    OscEscape,
    String,
    StringEscape,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct TerminalVtScrollRegion {
    top: u16,
    bottom: u16,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct TerminalScrollUpdate {
    rows: isize,
    region: Option<TerminalVtScrollRegion>,
}

#[derive(Default)]
struct TerminalScrollSequenceTracker {
    state: TerminalScrollParseState,
    parameters: [u16; 2],
    parameter_present: [bool; 2],
    parameter_index: usize,
    csi_valid: bool,
    active_scroll_region: Option<TerminalVtScrollRegion>,
}

impl TerminalScrollSequenceTracker {
    fn feed(&mut self, bytes: &[u8]) -> TerminalScrollUpdate {
        let mut update = TerminalScrollUpdate::default();
        for &byte in bytes {
            let next = self.feed_byte(byte);
            if next.rows == 0 {
                continue;
            }
            if update.rows == 0 || update.region == next.region {
                update.rows = update.rows.saturating_add(next.rows);
                update.region = next.region;
            } else {
                update = next;
            }
        }
        update
    }

    fn feed_byte(&mut self, byte: u8) -> TerminalScrollUpdate {
        match self.state {
            TerminalScrollParseState::Ground => self.feed_ground(byte),
            TerminalScrollParseState::Escape => {
                self.feed_escape(byte);
                TerminalScrollUpdate::default()
            }
            TerminalScrollParseState::Csi => self.feed_csi(byte),
            TerminalScrollParseState::Osc => {
                self.feed_control_string(byte, true);
                TerminalScrollUpdate::default()
            }
            TerminalScrollParseState::OscEscape => {
                self.feed_control_string_escape(byte, true);
                TerminalScrollUpdate::default()
            }
            TerminalScrollParseState::String => {
                self.feed_control_string(byte, false);
                TerminalScrollUpdate::default()
            }
            TerminalScrollParseState::StringEscape => {
                self.feed_control_string_escape(byte, false);
                TerminalScrollUpdate::default()
            }
        }
    }

    fn feed_ground(&mut self, byte: u8) -> TerminalScrollUpdate {
        match byte {
            0x1b => self.state = TerminalScrollParseState::Escape,
            0x9b => self.start_csi(),
            0x9d => self.state = TerminalScrollParseState::Osc,
            0x90 | 0x98 | 0x9e | 0x9f => self.state = TerminalScrollParseState::String,
            _ => {}
        }
        TerminalScrollUpdate::default()
    }

    fn feed_escape(&mut self, byte: u8) {
        match byte {
            b'[' => self.start_csi(),
            b']' => self.state = TerminalScrollParseState::Osc,
            b'P' | b'X' | b'^' | b'_' => self.state = TerminalScrollParseState::String,
            0x1b => {}
            _ => self.state = TerminalScrollParseState::Ground,
        }
    }

    fn start_csi(&mut self) {
        self.state = TerminalScrollParseState::Csi;
        self.parameters = [0; 2];
        self.parameter_present = [false; 2];
        self.parameter_index = 0;
        self.csi_valid = true;
    }

    fn feed_csi(&mut self, byte: u8) -> TerminalScrollUpdate {
        match byte {
            b'0'..=b'9' if self.parameter_index < self.parameters.len() => {
                self.parameter_present[self.parameter_index] = true;
                self.parameters[self.parameter_index] = self.parameters[self.parameter_index]
                    .saturating_mul(10)
                    .saturating_add(u16::from(byte - b'0'));
                TerminalScrollUpdate::default()
            }
            b';' => {
                self.parameter_index = self.parameter_index.saturating_add(1);
                if self.parameter_index >= self.parameters.len() {
                    self.csi_valid = false;
                }
                TerminalScrollUpdate::default()
            }
            0x20..=0x2f | 0x3a..=0x3f => {
                self.csi_valid = false;
                TerminalScrollUpdate::default()
            }
            0x40..=0x7e => {
                self.state = TerminalScrollParseState::Ground;
                self.update_for_final(byte)
            }
            0x1b => {
                self.state = TerminalScrollParseState::Escape;
                TerminalScrollUpdate::default()
            }
            _ => {
                self.state = TerminalScrollParseState::Ground;
                TerminalScrollUpdate::default()
            }
        }
    }

    fn update_for_final(&mut self, byte: u8) -> TerminalScrollUpdate {
        if !self.csi_valid {
            return TerminalScrollUpdate::default();
        }
        if byte == b'r' {
            self.active_scroll_region = self.parsed_scroll_region();
            return TerminalScrollUpdate::default();
        }
        if self.parameter_index != 0 {
            return TerminalScrollUpdate::default();
        }
        let count = if self.parameter_present[0] && self.parameters[0] != 0 {
            self.parameters[0]
        } else {
            1
        };
        let count = isize::try_from(count)
            .unwrap_or(MAX_TERMINAL_SCROLL_ANIMATION_ROWS)
            .min(MAX_TERMINAL_SCROLL_ANIMATION_ROWS);
        let rows = match byte {
            b'M' | b'S' => count,
            b'L' | b'T' => -count,
            _ => 0,
        };
        TerminalScrollUpdate {
            rows,
            region: self.active_scroll_region,
        }
    }

    fn parsed_scroll_region(&self) -> Option<TerminalVtScrollRegion> {
        if self.parameter_index != 1 || !self.parameter_present[0] || !self.parameter_present[1] {
            return None;
        }
        let top = self.parameters[0];
        let bottom = self.parameters[1];
        (top > 0 && bottom >= top).then_some(TerminalVtScrollRegion { top, bottom })
    }

    fn feed_control_string(&mut self, byte: u8, osc: bool) {
        match byte {
            0x07 if osc => self.state = TerminalScrollParseState::Ground,
            0x9c => self.state = TerminalScrollParseState::Ground,
            0x1b => {
                self.state = if osc {
                    TerminalScrollParseState::OscEscape
                } else {
                    TerminalScrollParseState::StringEscape
                };
            }
            _ => {}
        }
    }

    fn feed_control_string_escape(&mut self, byte: u8, osc: bool) {
        self.state = match byte {
            b'\\' => TerminalScrollParseState::Ground,
            0x1b => self.state,
            _ if osc => TerminalScrollParseState::Osc,
            _ => TerminalScrollParseState::String,
        };
    }
}

impl TerminalRendererModel {
    fn new(size: TerminalGridSize) -> Self {
        let width = size.cols as usize;
        let height = size.rows as usize;
        Self {
            window: NeovideRenderedWindowCache::new(width, height),
            width,
            height,
            pending_scroll: TerminalScrollUpdate::default(),
            last_scrollbar: None,
            last_screen: None,
        }
    }

    fn resize(&mut self, size: TerminalGridSize) {
        self.resize_window(size.cols as usize, size.rows as usize);
        self.last_scrollbar = None;
    }

    fn record_scroll_delta(&mut self, rows: isize) {
        self.record_scroll_update(TerminalScrollUpdate { rows, region: None });
    }

    fn record_scroll_update(&mut self, update: TerminalScrollUpdate) {
        if update.rows == 0 {
            return;
        }
        if self.pending_scroll.rows == 0 || self.pending_scroll.region == update.region {
            self.pending_scroll.rows = self.pending_scroll.rows.saturating_add(update.rows);
            self.pending_scroll.region = update.region;
        } else {
            self.pending_scroll = update;
        }
    }

    fn snapshot(&mut self, frame: &TerminalFrameSnapshot) -> NeovideRendererModelSnapshot {
        let height = frame.rows.len().max(1);
        let width = frame.rows.iter().map(Vec::len).max().unwrap_or(1).max(1);
        let inferred_scroll = self.infer_output_scroll(frame);
        if let Some(rows) = inferred_scroll {
            self.record_scroll_delta(rows);
        }
        self.resize_window(width, height);
        if self.last_screen != Some(frame.active_screen) {
            self.apply_viewport_margins(0, 0);
        }
        self.prepare_pending_scroll_region(height);
        self.window.flush(1);
        for (row, cells) in frame.rows.iter().enumerate() {
            self.window.apply(&NeovideWindowDrawCommand::DrawLine {
                row,
                line: NeovideLine::from_cells(cells.clone()),
            });
        }
        self.apply_pending_scroll_delta();
        self.window.flush(1);
        self.last_scrollbar = Some(frame.scrollbar.clone());
        self.last_screen = Some(frame.active_screen);

        NeovideRendererModelSnapshot {
            schema_version: 1,
            background: frame.background,
            cursor_color: frame.cursor_color,
            cursor: frame.cursor.clone(),
            cursor_parent_grid_id: Some(1),
            message_selection: None,
            scrollbar: Some(frame.scrollbar.clone()),
            scroll_hint: None,
            windows: vec![
                self.window
                    .snapshot(1, NeovideRenderedWindowPlacement::main(width, height)),
            ],
        }
    }

    fn advance_animations(&mut self, dt: f32) -> bool {
        self.window.advance_animation(dt)
    }

    fn has_active_animation(&self) -> bool {
        self.window.has_active_animation()
    }

    fn scroll_position(&self) -> f32 {
        self.window.scroll_position()
    }

    fn apply_position(&mut self, width: usize, height: usize) {
        self.window.apply(&NeovideWindowDrawCommand::Position {
            top: 0,
            left: 0,
            width,
            height,
            window_kind: NeovideWindowKind::Normal,
            zindex: 0,
            compindex: 0,
        });
    }

    fn resize_window(&mut self, width: usize, height: usize) {
        if self.width == width && self.height == height {
            return;
        }
        self.apply_position(width, height);
        self.width = width;
        self.height = height;
    }

    fn apply_viewport_margins(&mut self, top: usize, bottom: usize) {
        self.window
            .apply(&NeovideWindowDrawCommand::ViewportMargins {
                top,
                bottom,
                left: 0,
                right: 0,
            });
    }

    fn prepare_pending_scroll_region(&mut self, height: usize) {
        if self.pending_scroll.rows == 0 {
            return;
        }
        let (top, bottom) = self
            .pending_scroll
            .region
            .and_then(|region| viewport_margins_for_region(region, height))
            .unwrap_or((0, 0));
        self.apply_viewport_margins(top, bottom);
    }

    fn apply_pending_scroll_delta(&mut self) {
        if self.pending_scroll.rows == 0 {
            return;
        }
        self.window.apply(&NeovideWindowDrawCommand::Viewport {
            scroll_delta: self.pending_scroll.rows,
        });
        self.pending_scroll = TerminalScrollUpdate::default();
    }

    fn infer_output_scroll(&self, frame: &TerminalFrameSnapshot) -> Option<isize> {
        if !scrollbar_is_at_bottom(&frame.scrollbar) {
            return None;
        }
        if frame.active_screen != TerminalScreenSnapshot::Primary {
            return None;
        }
        self.infer_primary_output_scroll(frame)
    }

    fn infer_primary_output_scroll(&self, frame: &TerminalFrameSnapshot) -> Option<isize> {
        let previous = self.last_scrollbar.as_ref()?;
        if !scrollbar_is_at_bottom(previous) || frame.scrollbar.total <= previous.total {
            return None;
        }
        let delta = frame.scrollbar.total - previous.total;
        Some(cap_primary_output_scroll_rows(
            delta,
            frame.scrollbar.visible,
        ))
        .filter(|rows| *rows != 0)
    }
}

fn viewport_margins_for_region(
    region: TerminalVtScrollRegion,
    height: usize,
) -> Option<(usize, usize)> {
    let top = usize::from(region.top.saturating_sub(1));
    let bottom_row = usize::from(region.bottom).min(height);
    if top >= bottom_row || top >= height {
        return None;
    }
    Some((top, height.saturating_sub(bottom_row)))
}

fn scrollbar_is_at_bottom(scrollbar: &ScrollbarSnapshot) -> bool {
    scrollbar.total <= scrollbar.visible
        || scrollbar.top.saturating_add(scrollbar.visible) >= scrollbar.total
}

fn cap_primary_output_scroll_rows(rows: u64, visible_rows: u64) -> isize {
    if rows == 0 {
        return 0;
    }
    let capped_rows = if visible_rows > 0 && rows > visible_rows {
        1
    } else {
        rows.min(MAX_TERMINAL_SCROLL_ANIMATION_ROWS as u64)
    };
    capped_rows.min(isize::MAX as u64) as isize
}

impl TerminalFrameRenderer {
    fn new() -> Result<Self> {
        Ok(Self {
            state: RenderState::new()?,
            rows: RowIterator::new()?,
            cells: CellIterator::new()?,
        })
    }

    fn collect(&mut self, terminal: &mut Terminal<'static, '_>) -> Result<TerminalFrameSnapshot> {
        let state = &mut self.state;
        let row_iter = &mut self.rows;
        let cell_iter = &mut self.cells;
        let scrollbar = terminal.scrollbar()?;
        let snapshot = state.update(terminal)?;
        let colors = snapshot.colors()?;
        let background = TerminalColor::from_rgb(colors.background);
        let cursor_color = TerminalColor::from_rgb(colors.cursor.unwrap_or(colors.foreground));
        let cursor = terminal_cursor(&snapshot)?;
        let rows = collect_rows(
            row_iter,
            cell_iter,
            &snapshot,
            colors.foreground,
            background,
        )?;
        snapshot.set_dirty(libghostty_vt::render::Dirty::Clean)?;

        Ok(TerminalFrameSnapshot {
            rows,
            background,
            cursor_color,
            cursor,
            scrollbar: ScrollbarSnapshot {
                top: scrollbar.offset,
                visible: scrollbar.len,
                total: scrollbar.total,
            },
            active_screen: terminal.active_screen()?.into(),
        })
    }
}

fn collect_rows<'alloc>(
    rows: &mut RowIterator<'alloc>,
    cells: &mut CellIterator<'alloc>,
    snapshot: &Snapshot<'alloc, '_>,
    default_fg: RgbColor,
    background: TerminalColor,
) -> Result<Vec<Vec<TerminalCellSnapshot>>> {
    let mut output = Vec::with_capacity(snapshot.rows()? as usize);
    let mut row_iter = rows.update(snapshot)?;
    while let Some(row) = row_iter.next() {
        output.push(collect_cells(cells, row, default_fg, background)?);
        row.set_dirty(false)?;
    }
    Ok(output)
}

fn collect_cells<'alloc>(
    cells: &mut CellIterator<'alloc>,
    row: &RowIteration<'alloc, '_>,
    default_fg: RgbColor,
    background: TerminalColor,
) -> Result<Vec<TerminalCellSnapshot>> {
    let mut output = Vec::new();
    let selection = row.selection()?;
    let mut cell_iter = cells.update(row)?;
    while let Some(cell) = cell_iter.next() {
        let mut snapshot = terminal_cell(cell, default_fg, background)?;
        let col = u16::try_from(output.len()).unwrap_or(u16::MAX);
        if selection.is_some_and(|selection| col >= selection.start_x && col <= selection.end_x) {
            snapshot.bg = Some(selection_color(background));
        }
        output.push(snapshot);
    }
    Ok(output)
}

fn selection_color(background: TerminalColor) -> TerminalColor {
    TerminalColor {
        r: background.r.saturating_add(42),
        g: background.g.saturating_add(68),
        b: background.b.saturating_add(96),
    }
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct TerminalFrameSnapshot {
    pub rows: Vec<Vec<TerminalCellSnapshot>>,
    pub background: TerminalColor,
    pub cursor_color: TerminalColor,
    pub cursor: Option<TerminalCursorSnapshot>,
    pub scrollbar: ScrollbarSnapshot,
    pub active_screen: TerminalScreenSnapshot,
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TerminalScreenSnapshot {
    Primary,
    Alternate,
}

impl From<Screen> for TerminalScreenSnapshot {
    fn from(screen: Screen) -> Self {
        match screen {
            Screen::Primary => Self::Primary,
            Screen::Alternate => Self::Alternate,
        }
    }
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct TerminalCellSnapshot {
    pub text: String,
    pub fg: TerminalColor,
    pub bg: Option<TerminalColor>,
    #[serde(default)]
    pub blend: u8,
    pub style: TerminalCellStyle,
}

#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq, Hash)]
pub struct TerminalCellStyle {
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub underline_style: TerminalUnderlineStyle,
    pub underline_color: Option<TerminalColor>,
    pub faint: bool,
    pub blink: bool,
    pub strikethrough: bool,
    pub overline: bool,
}

#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum TerminalUnderlineStyle {
    #[default]
    None,
    Single,
    Double,
    Curly,
    Dotted,
    Dashed,
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq, Hash)]
pub struct TerminalColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl TerminalColor {
    fn from_rgb(rgb: RgbColor) -> Self {
        Self {
            r: rgb.r,
            g: rgb.g,
            b: rgb.b,
        }
    }
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct TerminalCursorSnapshot {
    pub x: u16,
    pub y: u16,
    pub style: &'static str,
    pub cell_percentage: u8,
    pub blinkwait_ms: u64,
    pub blinkon_ms: u64,
    pub blinkoff_ms: u64,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct ScrollbarSnapshot {
    pub top: u64,
    pub visible: u64,
    pub total: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ScrollbarView {
    top: u64,
    visible: u64,
    total: u64,
}

impl From<libghostty_vt::terminal::Scrollbar> for ScrollbarView {
    fn from(scrollbar: libghostty_vt::terminal::Scrollbar) -> Self {
        Self {
            top: scrollbar.offset,
            visible: scrollbar.len,
            total: scrollbar.total,
        }
    }
}

fn bounded_scroll_rows(requested_rows: isize, scrollbar: Option<ScrollbarView>) -> isize {
    let Some(scrollbar) = scrollbar else {
        return requested_rows;
    };
    if requested_rows == 0 || scrollbar.total <= scrollbar.visible {
        return 0;
    }

    let max_top = scrollbar.total.saturating_sub(scrollbar.visible);
    let available_rows = if requested_rows < 0 {
        scrollbar.top
    } else {
        max_top.saturating_sub(scrollbar.top)
    };
    let requested_abs = requested_rows.unsigned_abs().min(isize::MAX as usize) as u64;
    let moved_rows = requested_abs.min(available_rows).min(isize::MAX as u64) as isize;
    requested_rows.signum() * moved_rows
}

fn terminal_cursor(snapshot: &Snapshot<'_, '_>) -> Result<Option<TerminalCursorSnapshot>> {
    if !snapshot.cursor_visible()? {
        return Ok(None);
    }
    Ok(snapshot
        .cursor_viewport()?
        .map(|cursor| TerminalCursorSnapshot {
            x: cursor.x,
            y: cursor.y,
            style: cursor_style_name(
                snapshot
                    .cursor_visual_style()
                    .unwrap_or(CursorVisualStyle::Block),
            ),
            cell_percentage: 100,
            blinkwait_ms: 0,
            blinkon_ms: 0,
            blinkoff_ms: 0,
        }))
}

fn terminal_cell(
    cell: &CellIteration<'_, '_>,
    default_fg: RgbColor,
    background: TerminalColor,
) -> Result<TerminalCellSnapshot> {
    let style = cell.style()?;
    let mut text = String::new();
    cell.graphemes_utf8(&mut text)?;
    if style.invisible {
        text.clear();
    }

    let mut fg = cell.fg_color()?.unwrap_or(default_fg);
    let mut bg = cell.bg_color()?;
    if style.inverse {
        let inverse_bg = fg;
        fg = bg.unwrap_or(default_fg);
        bg = Some(inverse_bg);
    }
    if style.faint {
        fg = blend_rgb(fg, RgbColor::from(background), 0.55);
    }
    let underline_color = match style.underline_color {
        StyleColor::Rgb(color) => Some(TerminalColor::from_rgb(color)),
        _ => None,
    };

    Ok(TerminalCellSnapshot {
        text,
        fg: TerminalColor::from_rgb(fg),
        bg: bg
            .map(TerminalColor::from_rgb)
            .filter(|color| *color != background),
        blend: 0,
        style: TerminalCellStyle {
            bold: style.bold,
            italic: style.italic,
            underline: style.underline != Underline::None,
            underline_style: terminal_underline_style(style.underline),
            underline_color,
            faint: style.faint,
            blink: style.blink,
            strikethrough: style.strikethrough,
            overline: style.overline,
        },
    })
}

fn terminal_underline_style(underline: Underline) -> TerminalUnderlineStyle {
    match underline {
        Underline::None => TerminalUnderlineStyle::None,
        Underline::Single => TerminalUnderlineStyle::Single,
        Underline::Double => TerminalUnderlineStyle::Double,
        Underline::Curly => TerminalUnderlineStyle::Curly,
        Underline::Dotted => TerminalUnderlineStyle::Dotted,
        Underline::Dashed => TerminalUnderlineStyle::Dashed,
        _ => TerminalUnderlineStyle::Single,
    }
}

fn blend_rgb(foreground: RgbColor, background: RgbColor, amount: f32) -> RgbColor {
    let blend = |foreground: u8, background: u8| {
        (f32::from(foreground) * amount + f32::from(background) * (1.0 - amount))
            .round()
            .clamp(0.0, 255.0) as u8
    };
    RgbColor {
        r: blend(foreground.r, background.r),
        g: blend(foreground.g, background.g),
        b: blend(foreground.b, background.b),
    }
}

impl From<TerminalColor> for RgbColor {
    fn from(value: TerminalColor) -> Self {
        Self {
            r: value.r,
            g: value.g,
            b: value.b,
        }
    }
}

fn cursor_style_name(style: CursorVisualStyle) -> &'static str {
    match style {
        CursorVisualStyle::Bar => "bar",
        CursorVisualStyle::Underline => "underline",
        _ => "block",
    }
}

fn default_shell() -> String {
    env_shell("SATIN_SHELL")
        .or_else(|| env_shell("NVTERM_SHELL"))
        .or_else(login_shell)
        .or_else(|| env_shell("SHELL"))
        .unwrap_or_else(|| "/bin/zsh".to_owned())
}

fn configured_shell(shell: Option<&str>) -> Result<String> {
    let Some(shell) = shell.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(default_shell());
    };
    let path = Path::new(shell);
    if !path.is_absolute() || !is_executable_file(path) {
        bail!("configured shell must be an executable absolute file");
    }
    Ok(shell.to_owned())
}

#[cfg(unix)]
fn is_executable_file(path: &Path) -> bool {
    path.metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable_file(path: &Path) -> bool {
    path.is_file()
}

fn env_shell(key: &str) -> Option<String> {
    env::var(key).ok().filter(|shell| !shell.is_empty())
}

fn login_shell() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        macos_login_shell()
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
fn macos_login_shell() -> Option<String> {
    let user = env::var("USER").ok()?;
    let output = Command::new("/usr/bin/dscl")
        .args([".", "-read", &format!("/Users/{user}"), "UserShell"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let output = String::from_utf8(output.stdout).ok()?;
    output
        .lines()
        .next()?
        .split_whitespace()
        .last()
        .map(str::to_owned)
}

fn terminal_locale() -> String {
    env::var("LANG")
        .ok()
        .filter(|locale| locale.to_ascii_uppercase().contains("UTF-8"))
        .unwrap_or_else(|| "ja_JP.UTF-8".to_owned())
}

#[cfg(test)]
mod terminal_environment_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renderer_collects_plain_text_frame() {
        let mut terminal = Terminal::new(TerminalOptions {
            cols: 8,
            rows: 3,
            max_scrollback: 100,
        })
        .unwrap();
        terminal.vt_write(b"hello");
        let frame = TerminalFrameRenderer::new()
            .unwrap()
            .collect(&mut terminal)
            .unwrap();

        let first_row = frame.rows.first().unwrap();
        let text = first_row
            .iter()
            .map(|cell| cell.text.as_str())
            .collect::<String>();
        assert!(text.starts_with("hello"));
        assert_eq!(frame.cursor.unwrap().x, 5);
        assert_eq!(frame.active_screen, TerminalScreenSnapshot::Primary);
    }

    #[test]
    fn external_runtime_keeps_the_logical_cursor_for_native_input_when_hidden() {
        let mut runtime = NativeTerminalRuntime::external(TerminalGridSize {
            rows: 24,
            cols: 80,
            pixel_width: 800,
            pixel_height: 480,
        })
        .unwrap();
        runtime.feed_external(b"\x1b[3;7H").unwrap();
        assert_eq!(runtime.cursor_position().unwrap(), Some((6, 2)));

        runtime.feed_external(b"\x1b[?25l").unwrap();
        assert_eq!(runtime.cursor_position().unwrap(), Some((6, 2)));
    }

    #[test]
    fn selection_autoscroll_keeps_the_press_anchor_in_scrollback() {
        let mut runtime = NativeTerminalRuntime::external(grid_size(3, 8)).unwrap();
        runtime
            .feed_external(b"one\r\ntwo\r\nthree\r\nfour\r\nfive")
            .unwrap();

        runtime
            .selection_press(TerminalSelectionInput {
                point: TerminalPoint { row: 2, col: 3 },
                x: 39.0,
                y: 50.0,
                cell_width: 10,
            })
            .unwrap();
        runtime
            .selection_drag(
                TerminalSelectionInput {
                    point: TerminalPoint { row: 0, col: 0 },
                    x: 0.0,
                    y: 0.0,
                    cell_width: 10,
                },
                false,
            )
            .unwrap();

        let tick = TerminalSelectionInput {
            point: TerminalPoint { row: 0, col: 0 },
            x: 0.0,
            y: 0.0,
            cell_width: 10,
        };
        assert_eq!(runtime.selection_autoscroll(tick, false).unwrap(), -1);
        assert_eq!(runtime.selection_autoscroll(tick, false).unwrap(), -1);
        runtime.selection_release(Some(tick.point)).unwrap();

        assert_eq!(
            runtime.selected_text().unwrap().as_deref(),
            Some("one\ntwo\nthree\nfour\nfive")
        );
    }

    #[test]
    fn clearing_selection_removes_the_overlay_without_resizing() {
        let mut runtime = NativeTerminalRuntime::external(grid_size(3, 8)).unwrap();
        runtime.feed_external(b"selected").unwrap();
        runtime.select_all().unwrap();

        let selected = runtime.frame().unwrap();
        let selected_color = selection_color(selected.background);
        assert!(
            selected
                .rows
                .iter()
                .flatten()
                .any(|cell| cell.bg == Some(selected_color))
        );
        assert_eq!(
            runtime.selected_text().unwrap().as_deref(),
            Some("selected")
        );

        runtime.clear_selection().unwrap();
        let cleared = runtime.frame().unwrap();
        assert!(
            cleared
                .rows
                .iter()
                .flatten()
                .all(|cell| cell.bg != Some(selected_color))
        );
        assert_eq!(runtime.selected_text().unwrap(), None);
    }

    #[test]
    fn tmux_projection_discards_duplicate_terminal_reports() {
        let mut runtime = NativeTerminalRuntime::external(TerminalGridSize {
            rows: 24,
            cols: 80,
            pixel_width: 800,
            pixel_height: 480,
        })
        .unwrap();

        runtime.feed_tmux_projection(b"\x1b[c").unwrap();

        assert!(runtime.feed_external(b"").unwrap().is_empty());
    }

    #[test]
    fn tmux_prompt_tracker_waits_for_a_completed_semantic_prompt_marker() {
        let mut tracker = SemanticPromptTracker::default();
        tracker.feed(b"\x1b]133;C\x1b\\");
        assert!(tracker.observed);
        assert_eq!(tracker.ready_generation, 0);

        tracker.feed(b"\x1b]133;B");
        assert_eq!(tracker.ready_generation, 0);
        tracker.feed(b"\x1b\\");
        assert_eq!(tracker.ready_generation, 1);

        tracker.feed(b"\x1b]0;133;B\x07");
        assert_eq!(tracker.ready_generation, 1);
        tracker.feed(b"\x1b]133;B;fresh\x07");
        assert_eq!(tracker.ready_generation, 2);
    }

    #[test]
    fn tmux_prompt_state_uses_output_only_as_a_pre_integration_fallback() {
        let mut runtime = NativeTerminalRuntime::external(TerminalGridSize {
            rows: 24,
            cols: 80,
            pixel_width: 800,
            pixel_height: 480,
        })
        .unwrap();

        assert_eq!(
            runtime.tmux_shell_prompt_state().unwrap(),
            TmuxShellPromptState::Waiting
        );
        runtime.feed_tmux_projection(b"prompt> ").unwrap();
        assert_eq!(
            runtime.tmux_shell_prompt_state().unwrap(),
            TmuxShellPromptState::Ready
        );
        runtime
            .feed_tmux_projection(b"\r\n\x1b]133;C\x1b\\")
            .unwrap();
        assert!(runtime.tmux_semantic_prompt_seen());
        assert_eq!(runtime.tmux_prompt_generation(), 0);
        assert_eq!(
            runtime.tmux_shell_prompt_state().unwrap(),
            TmuxShellPromptState::Waiting
        );
        runtime
            .feed_tmux_projection(b"\x1b]133;A\x1b\\next> \x1b]133;B\x1b\\")
            .unwrap();
        assert_eq!(runtime.tmux_prompt_generation(), 1);
        assert_eq!(
            runtime.tmux_shell_prompt_state().unwrap(),
            TmuxShellPromptState::Ready
        );
        runtime.reset_tmux_prompt_tracking();
        assert!(!runtime.tmux_semantic_prompt_seen());
        assert_eq!(runtime.tmux_prompt_generation(), 0);

        runtime.feed_tmux_projection(b"\x1b[?1049h").unwrap();
        assert_eq!(
            runtime.tmux_shell_prompt_state().unwrap(),
            TmuxShellPromptState::Unavailable
        );
    }

    #[test]
    fn renderer_preserves_extended_terminal_styles() {
        let mut terminal = Terminal::new(TerminalOptions {
            cols: 4,
            rows: 2,
            max_scrollback: 0,
        })
        .unwrap();
        terminal.vt_write(b"\x1b[3;9;53;4:3;58:2::12:34:56mX");
        let frame = TerminalFrameRenderer::new()
            .unwrap()
            .collect(&mut terminal)
            .unwrap();
        let style = &frame.rows[0][0].style;

        assert!(style.italic);
        assert!(style.strikethrough);
        assert!(style.overline);
        assert_eq!(style.underline_style, TerminalUnderlineStyle::Curly);
        assert_eq!(
            style.underline_color,
            Some(TerminalColor {
                r: 12,
                g: 34,
                b: 56
            })
        );
    }

    #[test]
    fn libghostty_key_encoder_tracks_application_cursor_mode() {
        let mut terminal = Terminal::new(TerminalOptions {
            cols: 4,
            rows: 2,
            max_scrollback: 0,
        })
        .unwrap();
        let mut encoder = key::Encoder::new().unwrap();
        let mut event = key::Event::new().unwrap();
        event
            .set_action(key::Action::Press)
            .set_key(Key::ArrowUp)
            .set_mods(key::Mods::empty())
            .set_composing(false);

        encoder.set_options_from_terminal(&terminal);
        let mut normal = Vec::new();
        encoder.encode_to_vec(&event, &mut normal).unwrap();
        terminal.vt_write(b"\x1b[?1h");
        encoder.set_options_from_terminal(&terminal);
        let mut application = Vec::new();
        encoder.encode_to_vec(&event, &mut application).unwrap();

        assert_eq!(normal, b"\x1b[A");
        assert_eq!(application, b"\x1bOA");
    }

    #[test]
    fn libghostty_key_encoder_emits_key_release_when_requested() {
        let mut encoder = key::Encoder::new().unwrap();
        encoder.set_kitty_flags(key::KittyKeyFlags::ALL);
        let mut event = key::Event::new().unwrap();
        event
            .set_action(key::Action::Release)
            .set_key(Key::ArrowUp)
            .set_mods(key::Mods::empty())
            .set_composing(false);
        let mut encoded = Vec::new();

        encoder.encode_to_vec(&event, &mut encoded).unwrap();

        assert_eq!(encoded, b"\x1b[1;1:3A");
    }

    #[cfg(unix)]
    #[test]
    fn pty_shutdown_terminates_the_entire_process_group() {
        let pty_system = native_pty_system();
        let pair = pty_system.openpty(grid_size(4, 8).pty_size()).unwrap();
        let mut command = CommandBuilder::new("/bin/sh");
        command.args(["-c", "sleep 30 & wait"]);
        let mut child = pair.slave.spawn_command(command).unwrap();
        let process_group = child
            .process_id()
            .and_then(|pid| i32::try_from(pid).ok())
            .unwrap();

        terminate_pty_process_tree(child.as_mut(), Some(process_group));

        assert!(child.try_wait().unwrap().is_some());
        // SAFETY: signal zero only checks whether the process group still exists.
        assert_eq!(unsafe { libc::kill(-process_group, 0) }, -1);
    }

    #[test]
    fn bracketed_paste_wraps_and_sanitizes_payload() {
        let mut data = b"first\x1b[201~second".to_vec();
        let mut encoded = vec![0; 64];
        let written = paste::encode(&mut data, true, &mut encoded).unwrap();
        let encoded = &encoded[..written];

        assert!(encoded.starts_with(b"\x1b[200~"));
        assert!(encoded.ends_with(b"\x1b[201~"));
        assert_eq!(
            encoded
                .windows(b"\x1b[201~".len())
                .filter(|window| *window == b"\x1b[201~")
                .count(),
            1
        );
    }

    #[test]
    fn kitty_png_is_decoded_and_exposed_as_a_placement() {
        let mut terminal = Terminal::new(TerminalOptions {
            cols: 8,
            rows: 4,
            max_scrollback: 0,
        })
        .unwrap();
        terminal.resize(8, 4, 8, 16).unwrap();
        configure_kitty_graphics(&mut terminal).unwrap();
        terminal.vt_write(
            b"\x1b_Ga=T,f=100,q=0;\
              iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA\
              DUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\
              \x1b\\",
        );

        let graphics = terminal.kitty_graphics().unwrap();
        let mut iterator = PlacementIterator::new().unwrap();
        let mut placements = iterator.update(&graphics).unwrap();
        let placement = placements.next().expect("Kitty placement");
        let image_id = placement.image_id().unwrap();
        let image = graphics.image(image_id).unwrap();
        let cache = RefCell::new(HashMap::new());
        let first = cached_kitty_rgba(&cache, image_id, image.number().unwrap(), &image).unwrap();
        let second = cached_kitty_rgba(&cache, image_id, image.number().unwrap(), &image).unwrap();

        assert_eq!(image.width().unwrap(), 1);
        assert_eq!(image.height().unwrap(), 1);
        assert!(Arc::ptr_eq(&first, &second));
        assert_eq!(
            image_rgba(
                image.data().unwrap(),
                image.width().unwrap(),
                image.height().unwrap(),
                image.format().unwrap()
            )
            .unwrap()
            .len(),
            4
        );
    }

    #[test]
    fn native_nvim_kitty_bridge_tracks_rpc_graphics_without_a_pty() {
        let size = grid_size(8, 4);
        let mut bridge = KittyGraphicsBridge::new(size).unwrap();
        let encoded = base64_encode(&one_pixel_png());
        bridge.feed(b"\x1b[2;3H");
        bridge
            .feed(format!("\x1b_Ga=T,f=100,t=d,i=81,z=0,w=12,h=14,q=2;{encoded}\x1b\\").as_bytes());

        let placements = bridge.placements().unwrap();
        assert_eq!(placements.len(), 1);
        assert_eq!(placements[0].image_id, 81);
        assert_eq!(placements[0].viewport_col, 2);
        assert_eq!(placements[0].viewport_row, 1);
        assert_eq!(placements[0].rgba.as_ref(), &[255, 0, 0, 255]);

        bridge.resize(grid_size(12, 6)).unwrap();
        assert_eq!(bridge.placements().unwrap().len(), 1);
        bridge.feed(b"\x1b_Ga=d,d=I,i=81,q=2\x1b\\");
        assert!(bridge.placements().unwrap().is_empty());
    }

    #[test]
    fn kitty_delete_removes_image_data_and_placement() {
        let mut terminal = kitty_terminal(8, 4, 8);
        transmit_kitty_png(&mut terminal, 31, 0);
        assert_eq!(kitty_placement_summaries(&terminal).len(), 1);

        terminal.vt_write(b"\x1b_Ga=d,d=I,i=31,q=0\x1b\\");

        assert!(kitty_placement_summaries(&terminal).is_empty());
        assert!(terminal.kitty_graphics().unwrap().image(31).is_none());
    }

    #[test]
    fn kitty_placement_tracks_z_order_and_terminal_scroll() {
        let mut terminal = kitty_terminal(8, 4, 16);
        terminal.vt_write(b"\x1b[4;1H");
        transmit_kitty_png(&mut terminal, 41, -3);
        let before = kitty_placement_summaries(&terminal);
        assert_eq!(before, vec![(41, -3, 2, true)]);

        terminal.vt_write(b"\r\none\r\ntwo\r\nthree\r\n");
        let after = kitty_placement_summaries(&terminal);

        assert_eq!(after[0].0, 41);
        assert_eq!(after[0].1, -3);
        assert!(after[0].2 < before[0].2 || !after[0].3);
    }

    #[test]
    fn kitty_placement_survives_resize_with_valid_geometry() {
        let mut terminal = kitty_terminal(8, 4, 8);
        transmit_kitty_png(&mut terminal, 51, 2);

        terminal.resize(12, 6, 10, 20).unwrap();
        let graphics = terminal.kitty_graphics().unwrap();
        let mut iterator = PlacementIterator::new().unwrap();
        let mut placements = iterator.update(&graphics).unwrap();
        let placement = placements.next().unwrap();
        let image = graphics.image(placement.image_id().unwrap()).unwrap();
        let info = placement.placement_render_info(&image, &terminal).unwrap();

        assert!(info.viewport_visible);
        assert_eq!(info.viewport_col, 0);
        assert_eq!(info.viewport_row, 0);
        assert_eq!(info.source_width, 1);
        assert_eq!(info.source_height, 1);
    }

    #[test]
    fn kitty_graphics_state_is_isolated_between_panes() {
        let mut first = kitty_terminal(8, 4, 8);
        let second = kitty_terminal(8, 4, 8);
        transmit_kitty_png(&mut first, 61, 0);

        assert_eq!(kitty_placement_summaries(&first).len(), 1);
        assert!(kitty_placement_summaries(&second).is_empty());
        assert!(second.kitty_graphics().unwrap().image(61).is_none());
    }

    #[test]
    fn kitty_temp_file_transfer_is_consumed_with_safe_transport_policy() {
        let mut terminal = kitty_terminal(8, 4, 8);
        assert!(!terminal.is_kitty_image_from_file_allowed().unwrap());
        assert!(terminal.is_kitty_image_from_temp_file_allowed().unwrap());
        assert!(terminal.is_kitty_image_from_shared_mem_allowed().unwrap());
        let path = std::env::temp_dir().join(format!(
            "tty-graphics-protocol-satin-{}-{}.png",
            std::process::id(),
            71
        ));
        std::fs::write(&path, one_pixel_png()).unwrap();
        let encoded_path = base64_encode(path.to_string_lossy().as_bytes());
        terminal.vt_write(format!("\x1b_Ga=T,f=100,t=t,i=71,q=0;{encoded_path}\x1b\\").as_bytes());

        assert_eq!(kitty_placement_summaries(&terminal).len(), 1);
        assert!(terminal.kitty_graphics().unwrap().image(71).is_some());
        assert!(!path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn kitty_shared_memory_transfer_is_consumed() {
        use std::ffi::CString;

        let mut terminal = kitty_terminal(8, 4, 8);
        let name = CString::new(format!("/satin-kitty-{}-{}", std::process::id(), 72)).unwrap();
        // SAFETY: this only removes a stale object with the test-specific name.
        unsafe {
            libc::shm_unlink(name.as_ptr());
        }
        // SAFETY: the name is a valid NUL-terminated POSIX shared-memory name.
        let fd = unsafe {
            libc::shm_open(
                name.as_ptr(),
                libc::O_CREAT | libc::O_EXCL | libc::O_RDWR,
                0o600,
            )
        };
        assert!(fd >= 0);
        let png = one_pixel_png();
        // SAFETY: `fd` is valid and the requested size is the PNG byte length.
        assert_eq!(unsafe { libc::ftruncate(fd, png.len() as libc::off_t) }, 0);
        // SAFETY: the mapping covers the whole resized shared-memory object.
        let mapping = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                png.len(),
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd,
                0,
            )
        };
        assert_ne!(mapping, libc::MAP_FAILED);
        // SAFETY: both buffers are valid for `png.len()` bytes and do not overlap.
        unsafe {
            std::ptr::copy_nonoverlapping(png.as_ptr(), mapping.cast(), png.len());
            libc::munmap(mapping, png.len());
            libc::close(fd);
        }
        let encoded_name = base64_encode(name.as_bytes());
        terminal.vt_write(format!("\x1b_Ga=T,f=100,t=s,i=72,q=0;{encoded_name}\x1b\\").as_bytes());
        // SAFETY: unlinking this test-owned name is safe whether the parser already did so or not.
        unsafe {
            libc::shm_unlink(name.as_ptr());
        }

        assert_eq!(kitty_placement_summaries(&terminal).len(), 1);
        assert!(terminal.kitty_graphics().unwrap().image(72).is_some());
    }

    #[test]
    fn unsupported_kitty_command_does_not_corrupt_following_text() {
        let mut terminal = kitty_terminal(32, 4, 8);
        terminal.vt_write(b"before\r\n\x1b_Ga=x,q=2;ignored\x1b\\after");
        let frame = TerminalFrameRenderer::new()
            .unwrap()
            .collect(&mut terminal)
            .unwrap();
        let text = frame
            .rows
            .iter()
            .map(|row| {
                row.iter()
                    .map(|cell| cell.text.as_str())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");

        assert!(text.contains("before"));
        assert!(text.contains("after"));
        assert!(kitty_placement_summaries(&terminal).is_empty());
    }

    #[test]
    fn terminal_pwd_path_decodes_osc7_file_uri() {
        assert_eq!(
            terminal_pwd_path("file://localhost/Users/soyukke/dev%20app").unwrap(),
            PathBuf::from("/Users/soyukke/dev app")
        );
        assert_eq!(
            terminal_pwd_path("file:///tmp/satin").unwrap(),
            PathBuf::from("/tmp/satin")
        );
    }

    #[test]
    fn configured_shell_requires_an_executable_absolute_file() {
        assert_eq!(configured_shell(Some("/bin/sh")).unwrap(), "/bin/sh");
        assert!(configured_shell(Some("relative-shell")).is_err());
        let path =
            std::env::temp_dir().join(format!("satin-non-executable-shell-{}", std::process::id()));
        std::fs::write(&path, b"#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();

        assert!(configured_shell(path.to_str()).is_err());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn terminal_pwd_path_accepts_bare_absolute_path() {
        assert_eq!(
            terminal_pwd_path("/Users/soyukke/dev/app").unwrap(),
            PathBuf::from("/Users/soyukke/dev/app")
        );
        assert_eq!(terminal_pwd_path("relative/path"), None);
        assert_eq!(terminal_pwd_path("file://localhost/tmp/%XX"), None);
    }

    #[test]
    fn scroll_rows_are_bounded_to_available_scrollback() {
        let scrollbar = ScrollbarView {
            top: 4,
            visible: 3,
            total: 10,
        };

        assert_eq!(bounded_scroll_rows(-20, Some(scrollbar)), -4);
        assert_eq!(bounded_scroll_rows(20, Some(scrollbar)), 3);
        assert_eq!(bounded_scroll_rows(0, Some(scrollbar)), 0);
    }

    #[test]
    fn terminal_renderer_model_exposes_single_skia_window() {
        let mut model = TerminalRendererModel::new(grid_size(2, 3));
        let snapshot = model.snapshot(&frame(&["abc", "def"]));

        assert_eq!(snapshot.windows.len(), 1);
        let window = &snapshot.windows[0];
        assert_eq!(window.width, 3);
        assert_eq!(window.height, 2);
        assert_eq!(window.lines[0].as_ref().unwrap().text.as_ref(), "abc");
        assert_eq!(snapshot.cursor.unwrap().x, 1);
    }

    #[test]
    fn terminal_renderer_model_records_history_scroll_animation() {
        let mut model = TerminalRendererModel::new(grid_size(3, 3));
        model.snapshot(&frame(&["111", "222", "333"]));

        model.record_scroll_delta(2);
        let snapshot = model.snapshot(&frame(&["333", "444", "555"]));

        assert_eq!(snapshot.windows[0].scroll_position, -2.0);
        assert!(model.has_active_animation());
        assert!(!model.advance_animations(0.3));
        assert!(!model.has_active_animation());
    }

    #[test]
    fn terminal_renderer_model_keeps_resize_scroll_transition_gap_free() {
        let mut model = TerminalRendererModel::new(grid_size(3, 3));
        model.snapshot(&primary_frame_with_scrollbar(
            vec![row("111"), row("222"), row("333")],
            0,
            3,
        ));
        model.snapshot(&primary_frame_with_scrollbar(
            vec![row("222"), row("333"), row("444")],
            1,
            4,
        ));

        let snapshot = model.snapshot(&primary_frame_with_scrollbar(
            vec![row("3333"), row("4444"), row("5555")],
            2,
            5,
        ));
        let window = &snapshot.windows[0];

        assert_eq!(window.scroll_position, -1.0);
        assert!(window.scrollback_line(-1).is_some());
        assert!(window.scrollback_line(0).is_some());
    }

    #[test]
    fn terminal_scroll_tracker_reads_region_delete_line_sequence() {
        let mut tracker = TerminalScrollSequenceTracker::default();

        assert_eq!(
            tracker.feed(b"\x1b[1;22r\x1b[H\x1b["),
            TerminalScrollUpdate::default()
        );
        assert_eq!(
            tracker.feed(b"11M\x1b[r"),
            TerminalScrollUpdate {
                rows: 11,
                region: Some(TerminalVtScrollRegion { top: 1, bottom: 22 }),
            }
        );
    }

    #[test]
    fn terminal_scroll_tracker_ignores_cursor_and_control_string_updates() {
        let mut tracker = TerminalScrollSequenceTracker::default();
        let cursor_update = b"\x1b[?25l\x1b[24;70H\x1b[13A\x1b[?25h";
        let title_with_scroll_text = b"\x1b]2;not-a-scroll-\x1b[8M\x07";

        assert_eq!(tracker.feed(cursor_update), TerminalScrollUpdate::default());
        assert_eq!(
            tracker.feed(title_with_scroll_text),
            TerminalScrollUpdate::default()
        );
    }

    #[test]
    fn terminal_scroll_tracker_reads_scroll_up_and_down_sequences() {
        let mut tracker = TerminalScrollSequenceTracker::default();

        assert_eq!(
            tracker.feed(b"\x1b[3S"),
            TerminalScrollUpdate {
                rows: 3,
                region: None,
            }
        );
        assert_eq!(
            tracker.feed(b"\x1b[2T"),
            TerminalScrollUpdate {
                rows: -2,
                region: None,
            }
        );
        assert_eq!(
            tracker.feed(b"\x1b[L"),
            TerminalScrollUpdate {
                rows: -1,
                region: None,
            }
        );
    }

    #[test]
    fn terminal_renderer_model_keeps_region_scroll_when_fixed_style_changes() {
        let mut model = TerminalRendererModel::new(grid_size(8, 16));
        model.snapshot(&frame_with_rows(vec![
            row("00000001 alpha"),
            row("00000002 beta"),
            row("00000003 gamma"),
            row("00000004 delta"),
            row("00000005 epsilon"),
            row("00000006 zeta"),
            row("00000007 eta"),
            status_row("vim status"),
        ]));

        let mut tracker = TerminalScrollSequenceTracker::default();
        model.record_scroll_update(tracker.feed(b"\x1b[1;7r\x1b[H\x1b[M\x1b[r"));
        let snapshot = model.snapshot(&frame_with_rows(vec![
            row("00000002 beta"),
            row("00000003 gamma"),
            row("00000004 delta"),
            row("00000005 epsilon"),
            row("00000006 zeta"),
            row("00000007 eta"),
            row("00000008 theta"),
            row("vim status"),
        ]));

        let window = &snapshot.windows[0];
        assert_eq!(window.scroll_position, -1.0);
        assert_eq!(window.viewport_margins.bottom, 1);
        assert_eq!(
            window.lines[7].as_ref().unwrap().text.as_ref(),
            "vim status"
        );
    }

    #[test]
    fn terminal_renderer_model_does_not_animate_repeated_one_screen_cursor_redraw() {
        let repeated = vec![
            row("00000001 alpha"),
            row("00000002 beta"),
            row("00000003 gamma"),
            row("00000004 delta"),
            row("00000005 alpha"),
            row("00000006 beta"),
            row("00000007 gamma"),
            row("00000008 delta"),
            row("00000009 alpha"),
            row("00000010 beta"),
            row("00000011 gamma"),
            status_row("vim status"),
        ];
        let redrawn = vec![
            row("00000002 alpha"),
            row("00000001 beta"),
            row("00000002 gamma"),
            row("00000003 delta"),
            row("00000004 alpha"),
            row("00000005 beta"),
            row("00000006 gamma"),
            row("00000007 delta"),
            row("00000008 alpha"),
            row("00000009 beta"),
            row("00000010 gamma"),
            status_row("vim status"),
        ];
        let mut model = TerminalRendererModel::new(grid_size(12, 16));
        model.snapshot(&frame_with_rows(repeated));

        let snapshot = model.snapshot(&frame_with_rows(redrawn));

        assert_eq!(snapshot.windows[0].scroll_position, 0.0);
        assert!(!model.has_active_animation());
    }

    #[test]
    fn terminal_renderer_model_does_not_infer_primary_prompt_redraw() {
        let mut model = TerminalRendererModel::new(grid_size(8, 16));
        model.snapshot(&primary_frame_with_scrollbar(
            vec![
                row("00000001 alpha"),
                row("00000002 beta"),
                row("00000003 gamma"),
                row("00000004 delta"),
                row("00000005 epsilon"),
                row("00000006 zeta"),
                row("00000007 eta"),
                row("prompt>"),
            ],
            8,
            8,
        ));

        let snapshot = model.snapshot(&primary_frame_with_scrollbar(
            vec![
                row("00000002 beta"),
                row("00000003 gamma"),
                row("00000004 delta"),
                row("00000005 epsilon"),
                row("00000006 zeta"),
                row("00000007 eta"),
                row("prompt> a"),
                row(""),
            ],
            8,
            8,
        ));

        assert_eq!(snapshot.windows[0].scroll_position, 0.0);
    }

    #[test]
    fn terminal_renderer_model_animates_primary_scrollback_growth() {
        let mut model = TerminalRendererModel::new(grid_size(4, 16));
        model.snapshot(&primary_frame_with_scrollbar(
            vec![row("one"), row("two"), row("three"), row("prompt>")],
            0,
            4,
        ));

        let snapshot = model.snapshot(&primary_frame_with_scrollbar(
            vec![row("three"), row("four"), row("five"), row("prompt>")],
            2,
            6,
        ));

        assert_eq!(snapshot.windows[0].scroll_position, -2.0);
    }

    fn frame(lines: &[&str]) -> TerminalFrameSnapshot {
        frame_with_rows(lines.iter().map(|line| row(line)).collect())
    }

    fn kitty_terminal(cols: u16, rows: u16, scrollback: usize) -> Terminal<'static, 'static> {
        let mut terminal = Terminal::new(TerminalOptions {
            cols,
            rows,
            max_scrollback: scrollback,
        })
        .unwrap();
        terminal.resize(cols, rows, 8, 16).unwrap();
        configure_kitty_graphics(&mut terminal).unwrap();
        terminal
    }

    fn transmit_kitty_png(terminal: &mut Terminal<'static, 'static>, image_id: u32, z: i32) {
        const PNG: &str = concat!(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA",
            "DUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
        );
        terminal.vt_write(format!("\x1b_Ga=T,f=100,i={image_id},z={z},q=0;{PNG}\x1b\\").as_bytes());
    }

    fn kitty_placement_summaries(
        terminal: &Terminal<'static, 'static>,
    ) -> Vec<(u32, i32, i32, bool)> {
        let graphics = terminal.kitty_graphics().unwrap();
        let mut iterator = PlacementIterator::new().unwrap();
        let mut placements = iterator.update(&graphics).unwrap();
        let mut output = Vec::new();
        while let Some(placement) = placements.next() {
            let image_id = placement.image_id().unwrap();
            let image = graphics.image(image_id).unwrap();
            let info = placement.placement_render_info(&image, terminal).unwrap();
            output.push((
                image_id,
                placement.z().unwrap(),
                info.viewport_row,
                info.viewport_visible,
            ));
        }
        output
    }

    fn one_pixel_png() -> Vec<u8> {
        let mut bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut bytes, 1, 1);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            let mut writer = encoder.write_header().unwrap();
            writer.write_image_data(&[255, 0, 0, 255]).unwrap();
        }
        bytes
    }

    fn base64_encode(bytes: &[u8]) -> String {
        const ALPHABET: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
        for chunk in bytes.chunks(3) {
            let value = (u32::from(chunk[0]) << 16)
                | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
                | u32::from(*chunk.get(2).unwrap_or(&0));
            output.push(char::from(ALPHABET[((value >> 18) & 63) as usize]));
            output.push(char::from(ALPHABET[((value >> 12) & 63) as usize]));
            output.push(if chunk.len() > 1 {
                char::from(ALPHABET[((value >> 6) & 63) as usize])
            } else {
                '='
            });
            output.push(if chunk.len() > 2 {
                char::from(ALPHABET[(value & 63) as usize])
            } else {
                '='
            });
        }
        output
    }

    fn frame_with_rows(rows: Vec<Vec<TerminalCellSnapshot>>) -> TerminalFrameSnapshot {
        let visible = rows.len() as u64;
        frame_with_screen_and_scrollbar(rows, TerminalScreenSnapshot::Alternate, 0, visible)
    }

    fn primary_frame_with_scrollbar(
        rows: Vec<Vec<TerminalCellSnapshot>>,
        top: u64,
        total: u64,
    ) -> TerminalFrameSnapshot {
        frame_with_screen_and_scrollbar(rows, TerminalScreenSnapshot::Primary, top, total)
    }

    fn frame_with_screen_and_scrollbar(
        rows: Vec<Vec<TerminalCellSnapshot>>,
        active_screen: TerminalScreenSnapshot,
        top: u64,
        total: u64,
    ) -> TerminalFrameSnapshot {
        let visible = rows.len() as u64;
        TerminalFrameSnapshot {
            rows,
            background: TerminalColor { r: 0, g: 0, b: 0 },
            cursor_color: TerminalColor {
                r: 220,
                g: 220,
                b: 210,
            },
            cursor: Some(TerminalCursorSnapshot {
                x: 1,
                y: 0,
                style: "block",
                cell_percentage: 100,
                blinkwait_ms: 0,
                blinkon_ms: 0,
                blinkoff_ms: 0,
            }),
            scrollbar: ScrollbarSnapshot {
                top,
                visible,
                total,
            },
            active_screen,
        }
    }

    fn row(text: &str) -> Vec<TerminalCellSnapshot> {
        text.chars()
            .map(|character| TerminalCellSnapshot {
                text: character.to_string(),
                fg: TerminalColor {
                    r: 220,
                    g: 220,
                    b: 210,
                },
                bg: None,
                blend: 0,
                style: TerminalCellStyle::default(),
            })
            .collect()
    }

    fn status_row(text: &str) -> Vec<TerminalCellSnapshot> {
        text.chars()
            .map(|character| TerminalCellSnapshot {
                text: character.to_string(),
                fg: TerminalColor {
                    r: 10,
                    g: 10,
                    b: 10,
                },
                bg: Some(TerminalColor {
                    r: 80,
                    g: 96,
                    b: 112,
                }),
                blend: 0,
                style: TerminalCellStyle::default(),
            })
            .collect()
    }

    fn grid_size(rows: u16, cols: u16) -> TerminalGridSize {
        TerminalGridSize {
            rows,
            cols,
            pixel_width: cols * 10,
            pixel_height: rows * 20,
        }
    }
}
