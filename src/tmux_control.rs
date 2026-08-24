use std::collections::{HashMap, HashSet, VecDeque};

use anyhow::{Result, bail};
use serde::Serialize;

use crate::terminal_scroll::TerminalScrollSequenceTracker;

mod admission;
mod passthrough;
mod protocol;
mod session;

use admission::{SESSION_CLIENT_SUBSCRIPTION, session_clients_changed};
use passthrough::TmuxDcsPassthroughDecoder;
use protocol::{CommandResponse, PendingCommand, response_lines_lossy, topology_notification};
pub use session::TmuxSessionSummary;
use session::parse_session_summaries;

const CONTROL_START: &[u8] = b"\x1bP1000p";
const CONTROL_END: &[u8] = b"\x1b\\";
const MAX_CONTROL_LINE_BYTES: usize = 8 * 1024 * 1024;
const MAX_COMMAND_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const MAX_HYDRATION_HISTORY_LINES: u32 = 100_000;
const MAX_HYDRATION_CAPTURE_BYTES: usize = 8 * 1024 * 1024;
const MAX_REHYDRATION_PASSTHROUGH_BYTES: usize = 16 * 1024 * 1024;
const FLOW_CONTROL_PAUSE_AFTER_SECONDS: u8 = 5;
const PANE_TITLE_SUBSCRIPTION: &str = "satin-pane-title:%*:#{q:pane_title}";
const SESSION_LIST_COMMAND: &str = "list-sessions -F '#{q:session_id}|#{q:session_name}|#{session_windows}|#{q:socket_path}|#{pid}'";
const SNAPSHOT_FIELD_COUNT: usize = 41;
const SYNC_FORMAT: &str = concat!(
    "#{q:session_id}\t#{q:session_name}\t#{q:socket_path}\t#{q:window_id}\t",
    "#{q:window_index}\t#{q:window_name}\t#{q:window_active}\t",
    "#{q:window_visible_layout}\t#{q:window_zoomed_flag}\t",
    "#{q:pane_id}\t#{q:pane_index}\t#{q:pane_active}\t#{q:pane_current_path}\t",
    "#{q:pane_width}\t#{q:pane_height}\t#{q:cursor_x}\t#{q:cursor_y}\t",
    "#{q:cursor_flag}\t#{q:cursor_shape}\t#{q:cursor_blinking}\t",
    "#{q:history_size}\t#{q:alternate_on}\t#{q:insert_flag}\t",
    "#{q:keypad_cursor_flag}\t#{q:keypad_flag}\t#{q:origin_flag}\t#{q:wrap_flag}\t",
    "#{q:mouse_standard_flag}\t#{q:mouse_button_flag}\t#{q:mouse_any_flag}\t",
    "#{q:mouse_utf8_flag}\t#{q:mouse_sgr_flag}\t#{q:pane_input_off}\t",
    "#{q:scroll_region_upper}\t#{q:scroll_region_lower}\t#{q:pid}\t",
    "#{q:pane_private_modes}\t#{q:pane_key_mode}\t#{q:pane_current_command}\t",
    "#{q:pane_title}\t",
    "#{q:allow-passthrough}"
);

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TmuxControlEvent {
    Entered,
    PaneOutput {
        pane_id: u32,
        data: Vec<u8>,
    },
    PaneScrollMetadata {
        pane_id: u32,
        rows: isize,
        region_top: Option<u16>,
        region_bottom: Option<u16>,
        region_left: Option<u16>,
        region_right: Option<u16>,
    },
    PaneHydration {
        pane_id: u32,
        data: Vec<u8>,
    },
    Snapshot {
        snapshot: TmuxSnapshot,
    },
    Sessions {
        sessions: Vec<TmuxSessionSummary>,
        session_error: Option<String>,
    },
    CommandError {
        message: String,
    },
    ProtocolError {
        message: String,
    },
    Exited {
        reason: Option<String>,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct TmuxSnapshot {
    pub session_id: u32,
    pub session_name: String,
    pub socket_path: String,
    pub server_pid: u32,
    pub active_window_id: u32,
    pub windows: Vec<TmuxWindowSnapshot>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct TmuxWindowSnapshot {
    pub window_id: u32,
    pub index: u32,
    pub name: String,
    pub active_pane_id: u32,
    pub zoomed: bool,
    pub layout: TmuxLayoutSnapshot,
    pub panes: Vec<TmuxPaneSnapshot>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct TmuxPaneSnapshot {
    pub pane_id: u32,
    pub index: u32,
    pub active: bool,
    pub current_path: String,
    pub cols: u16,
    pub rows: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub cursor_visible: bool,
    pub cursor_shape: String,
    pub cursor_blinking: bool,
    pub history_size: u32,
    pub alternate_on: bool,
    pub insert_mode: bool,
    pub application_cursor: bool,
    pub application_keypad: bool,
    pub origin_mode: bool,
    pub wrap_mode: bool,
    pub mouse_standard: bool,
    pub mouse_button: bool,
    pub mouse_any: bool,
    pub mouse_utf8: bool,
    pub mouse_sgr: bool,
    pub input_off: bool,
    pub scroll_region_upper: u16,
    pub scroll_region_lower: u16,
    pub private_modes: Vec<u16>,
    pub key_mode: String,
    pub current_command: String,
    pub title: String,
    pub allow_passthrough: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct TmuxLayoutSnapshot {
    pub kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane_id: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub axis: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ratio: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first: Option<Box<TmuxLayoutSnapshot>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub second: Option<Box<TmuxLayoutSnapshot>>,
}

#[derive(Debug, Default)]
pub struct TmuxControl {
    active: bool,
    closing: bool,
    probe: Vec<u8>,
    line: Vec<u8>,
    events: VecDeque<TmuxControlEvent>,
    outgoing: VecDeque<Vec<u8>>,
    pending_commands: VecDeque<PendingCommand>,
    response: Option<CommandResponse>,
    sync_pending: bool,
    sync_requested_while_pending: bool,
    flow_control_configured: bool,
    control_client_admitted: bool,
    control_client_check_pending: bool,
    hydrated_panes: HashSet<u32>,
    capture_pending: HashSet<u32>,
    rehydrating_panes: HashSet<u32>,
    recapture_panes: HashSet<u32>,
    latest_panes: HashMap<u32, TmuxPaneSnapshot>,
    alternate_backings: HashMap<u32, Vec<Vec<u8>>>,
    passthrough_attempted_panes: HashSet<u32>,
    passthrough_decoders: HashMap<u32, TmuxDcsPassthroughDecoder>,
    scroll_sequence_trackers: HashMap<u32, TerminalScrollSequenceTracker>,
    rehydration_passthrough: HashMap<u32, Vec<u8>>,
    dropped_rehydration_passthrough: HashSet<u32>,
    paste_sequence: u64,
    terminal_after_control: Vec<u8>,
}

impl TmuxControl {
    pub fn is_active(&self) -> bool {
        self.active
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Result<Vec<u8>> {
        let mut passthrough = Vec::new();
        for &byte in bytes {
            if self.active {
                if let Err(error) = self.feed_control_byte(byte, &mut passthrough) {
                    self.fail_control(error.to_string());
                }
            } else {
                self.feed_terminal_byte(byte, &mut passthrough);
            }
        }
        Ok(passthrough)
    }

    pub fn take_event(&mut self) -> Option<TmuxControlEvent> {
        self.events.pop_front()
    }

    pub fn take_outgoing(&mut self) -> Option<Vec<u8>> {
        self.outgoing.pop_front()
    }

    pub fn command(&mut self, command: impl Into<String>) -> bool {
        if !self.active || self.closing || !self.control_client_admitted {
            return false;
        }
        let command = command.into();
        let kind = if command == SESSION_LIST_COMMAND {
            PendingCommand::Sessions
        } else {
            PendingCommand::Ignore
        };
        self.queue_command(command, kind);
        true
    }

    pub fn pane_accepts_input(&self, pane_id: u32) -> bool {
        self.active
            && !self.closing
            && self
                .latest_panes
                .get(&pane_id)
                .is_some_and(|pane| !pane.input_off)
    }

    pub fn paste(&mut self, pane_id: u32, bytes: &[u8]) -> bool {
        if bytes.is_empty() || !self.pane_accepts_input(pane_id) {
            return false;
        }
        self.paste_sequence = self.paste_sequence.wrapping_add(1);
        let buffer = format!("satin-{pane_id}-{}", self.paste_sequence);
        for (index, chunk) in bytes.chunks(1024).enumerate() {
            let append = if index == 0 { "" } else { " -a" };
            self.queue_command(
                format!(
                    "set-buffer{append} -b {buffer} \"{}\"",
                    tmux_octal_argument(chunk)
                ),
                PendingCommand::Ignore,
            );
        }
        self.queue_command(
            format!("paste-buffer -dpr -b {buffer} -t %{pane_id}"),
            PendingCommand::Ignore,
        );
        true
    }

    fn feed_terminal_byte(&mut self, byte: u8, passthrough: &mut Vec<u8>) {
        if byte == CONTROL_START[self.probe.len()] {
            self.probe.push(byte);
            if self.probe.len() == CONTROL_START.len() {
                self.probe.clear();
                self.active = true;
                self.events.push_back(TmuxControlEvent::Entered);
            }
            return;
        }
        passthrough.append(&mut self.probe);
        if byte == CONTROL_START[0] {
            self.probe.push(byte);
        } else {
            passthrough.push(byte);
        }
    }

    fn feed_control_byte(&mut self, byte: u8, passthrough: &mut Vec<u8>) -> Result<()> {
        if self.closing {
            return self.feed_control_end_byte(byte, passthrough);
        }
        if byte == b'\n' {
            let line = std::mem::take(&mut self.line);
            let line = line.strip_suffix(b"\r").unwrap_or(&line);
            self.handle_line(line)?;
            return Ok(());
        }
        if self.line.len() >= MAX_CONTROL_LINE_BYTES {
            bail!("tmux control line exceeded {MAX_CONTROL_LINE_BYTES} bytes");
        }
        self.line.push(byte);
        Ok(())
    }

    fn feed_control_end_byte(&mut self, byte: u8, passthrough: &mut Vec<u8>) -> Result<()> {
        if byte == CONTROL_END[self.probe.len()] {
            self.probe.push(byte);
            if self.probe.len() == CONTROL_END.len() {
                self.finish_control_mode(passthrough);
            }
            return Ok(());
        }
        self.probe.clear();
        if byte == CONTROL_END[0] {
            self.probe.push(byte);
        }
        Ok(())
    }

    fn finish_control_mode(&mut self, passthrough: &mut Vec<u8>) {
        self.active = false;
        self.closing = false;
        self.probe.clear();
        self.line.clear();
        self.pending_commands.clear();
        self.response = None;
        self.sync_pending = false;
        self.sync_requested_while_pending = false;
        self.flow_control_configured = false;
        self.control_client_admitted = false;
        self.control_client_check_pending = false;
        self.hydrated_panes.clear();
        self.capture_pending.clear();
        self.rehydrating_panes.clear();
        self.recapture_panes.clear();
        self.latest_panes.clear();
        self.alternate_backings.clear();
        self.passthrough_attempted_panes.clear();
        self.passthrough_decoders.clear();
        self.scroll_sequence_trackers.clear();
        self.rehydration_passthrough.clear();
        self.dropped_rehydration_passthrough.clear();
        self.paste_sequence = 0;
        passthrough.append(&mut self.terminal_after_control);
    }

    fn handle_line(&mut self, line: &[u8]) -> Result<()> {
        if let Some(response) = self.response.as_ref() {
            if line.strip_prefix(b"%end ") == Some(response.guard.as_slice()) {
                self.finish_response(true)?;
                return Ok(());
            }
            if line.strip_prefix(b"%error ") == Some(response.guard.as_slice()) {
                self.finish_response(false)?;
                return Ok(());
            }
            self.push_response_line(line)?;
            return Ok(());
        }
        if let Some(guard) = line.strip_prefix(b"%begin ") {
            let kind = self
                .pending_commands
                .pop_front()
                .unwrap_or(PendingCommand::Initial);
            self.response = Some(CommandResponse {
                kind,
                guard: guard.to_vec(),
                lines: Vec::new(),
                bytes: 0,
            });
            return Ok(());
        }
        if let Some(payload) = line.strip_prefix(b"%output ") {
            self.handle_output(payload)?;
            return Ok(());
        }
        if let Some(payload) = line.strip_prefix(b"%extended-output ") {
            self.handle_extended_output(payload)?;
            return Ok(());
        }
        if let Some(reason) = line.strip_prefix(b"%exit") {
            let reason = trim_ascii(reason);
            self.events.push_back(TmuxControlEvent::Exited {
                reason: (!reason.is_empty()).then(|| String::from_utf8_lossy(reason).into_owned()),
            });
            self.closing = true;
            self.probe.clear();
            return Ok(());
        }
        if let Some(pane) = line.strip_prefix(b"%pause ") {
            self.resume_paused_pane(parse_prefixed_id_bytes(trim_ascii(pane), b'%')?);
            return Ok(());
        }
        if session_clients_changed(line) {
            self.recheck_control_clients();
            return Ok(());
        }
        if line.starts_with(b"%") {
            if topology_notification(line) {
                self.request_sync();
            }
            return Ok(());
        }
        Ok(())
    }

    fn push_response_line(&mut self, line: &[u8]) -> Result<()> {
        let Some(response) = self.response.as_mut() else {
            return Ok(());
        };
        response.bytes = response
            .bytes
            .checked_add(line.len() + 1)
            .filter(|bytes| *bytes <= MAX_COMMAND_RESPONSE_BYTES)
            .ok_or_else(|| anyhow::anyhow!("tmux command response exceeded byte limit"))?;
        response.lines.push(line.to_vec());
        Ok(())
    }

    fn handle_output(&mut self, payload: &[u8]) -> Result<()> {
        let Some(space) = payload.iter().position(|byte| *byte == b' ') else {
            bail!("malformed tmux output record");
        };
        let pane_id = parse_prefixed_id_bytes(&payload[..space], b'%')?;
        self.push_output(pane_id, decode_tmux_bytes(&payload[space + 1..])?);
        Ok(())
    }

    fn handle_extended_output(&mut self, payload: &[u8]) -> Result<()> {
        let Some(separator) = find_bytes(payload, b" : ") else {
            bail!("malformed tmux extended-output record");
        };
        let metadata = &payload[..separator];
        let Some(space) = metadata.iter().position(u8::is_ascii_whitespace) else {
            bail!("tmux extended-output record omitted pane id");
        };
        let pane_id = parse_prefixed_id_bytes(&metadata[..space], b'%')?;
        self.push_output(pane_id, decode_tmux_bytes(&payload[separator + 3..])?);
        Ok(())
    }

    fn push_output(&mut self, pane_id: u32, data: Vec<u8>) {
        let decoded = self
            .passthrough_decoders
            .entry(pane_id)
            .or_default()
            .decode(&data);
        let scroll_update = self
            .scroll_sequence_trackers
            .entry(pane_id)
            .or_default()
            .feed(&decoded.all);
        if self.rehydrating_panes.contains(&pane_id) {
            if scroll_update.rows != 0 {
                self.events.push_back(TmuxControlEvent::PaneScrollMetadata {
                    pane_id,
                    rows: scroll_update.rows,
                    region_top: scroll_update.region.map(|region| region.top),
                    region_bottom: scroll_update.region.map(|region| region.bottom),
                    region_left: scroll_update
                        .region
                        .filter(|region| region.left > 0)
                        .map(|region| region.left),
                    region_right: scroll_update
                        .region
                        .filter(|region| region.right > 0)
                        .map(|region| region.right),
                });
            }
            if decoded.passthrough.is_empty()
                || self.dropped_rehydration_passthrough.contains(&pane_id)
            {
                return;
            }
            let buffered = self.rehydration_passthrough.entry(pane_id).or_default();
            let Some(next_len) = buffered.len().checked_add(decoded.passthrough.len()) else {
                self.drop_rehydration_passthrough(pane_id);
                return;
            };
            if next_len > MAX_REHYDRATION_PASSTHROUGH_BYTES {
                self.drop_rehydration_passthrough(pane_id);
                return;
            }
            buffered.extend_from_slice(&decoded.passthrough);
            return;
        }
        let data = decoded.all;
        if data.is_empty() {
            return;
        }
        self.events
            .push_back(TmuxControlEvent::PaneOutput { pane_id, data });
    }

    fn drop_rehydration_passthrough(&mut self, pane_id: u32) {
        self.rehydration_passthrough.remove(&pane_id);
        if self.dropped_rehydration_passthrough.insert(pane_id) {
            self.events.push_back(TmuxControlEvent::CommandError {
                message: format!(
                    "tmux pane %{pane_id} buffered more than \
                     {MAX_REHYDRATION_PASSTHROUGH_BYTES} passthrough bytes during hydration"
                ),
            });
        }
    }

    fn flush_rehydration_passthrough(&mut self, pane_id: u32) {
        self.dropped_rehydration_passthrough.remove(&pane_id);
        let Some(data) = self.rehydration_passthrough.remove(&pane_id) else {
            return;
        };
        if !data.is_empty() {
            self.events
                .push_back(TmuxControlEvent::PaneOutput { pane_id, data });
        }
    }

    fn fail_control(&mut self, message: String) {
        if self.closing {
            return;
        }
        self.events.push_back(TmuxControlEvent::ProtocolError {
            message: message.clone(),
        });
        self.terminal_after_control
            .extend_from_slice(b"\r\nSatin tmux integration stopped: ");
        self.terminal_after_control
            .extend_from_slice(message.as_bytes());
        self.terminal_after_control.extend_from_slice(b"\r\n");
        self.outgoing.push_back(b"detach-client\n".to_vec());
        self.pending_commands.clear();
        self.response = None;
        self.line.clear();
        self.probe.clear();
        self.sync_pending = false;
        self.sync_requested_while_pending = false;
        self.closing = true;
    }

    fn request_sync(&mut self) {
        if self.closing {
            return;
        }
        if !self.control_client_admitted {
            self.sync_requested_while_pending = true;
            return;
        }
        if self.sync_pending {
            // A topology notification can arrive while list-panes is queued or
            // running. Remember it so the last reported layout is never stale.
            self.sync_requested_while_pending = true;
            return;
        }
        self.sync_pending = true;
        self.queue_command(
            format!("list-panes -s -F '{SYNC_FORMAT}'"),
            PendingCommand::Snapshot,
        );
    }

    fn configure_flow_control(&mut self) {
        if self.flow_control_configured || self.closing {
            return;
        }
        self.flow_control_configured = true;
        self.queue_command(
            format!(
                "refresh-client -f pause-after={FLOW_CONTROL_PAUSE_AFTER_SECONDS} \
                 -B '{PANE_TITLE_SUBSCRIPTION}' -B '{SESSION_CLIENT_SUBSCRIPTION}'"
            ),
            PendingCommand::Ignore,
        );
    }

    fn resume_paused_pane(&mut self, pane_id: u32) {
        if self.closing || !self.rehydrating_panes.insert(pane_id) {
            return;
        }
        self.queue_command(
            format!("refresh-client -A %{pane_id}:continue"),
            PendingCommand::Resume { pane_id },
        );
    }

    fn queue_command(&mut self, mut command: String, kind: PendingCommand) {
        command.push('\n');
        self.pending_commands.push_back(kind);
        self.outgoing.push_back(command.into_bytes());
    }

    fn finish_response(&mut self, succeeded: bool) -> Result<()> {
        let Some(response) = self.response.take() else {
            return Ok(());
        };
        match response.kind {
            PendingCommand::Initial => {
                self.finish_initial_response(succeeded, &response.lines);
            }
            PendingCommand::ControlClientCheck => {
                self.finish_control_client_check(succeeded, &response.lines);
            }
            PendingCommand::Snapshot => {
                self.finish_snapshot_response(succeeded, &response.lines)?;
            }
            PendingCommand::Sessions => {
                let result = succeeded
                    .then(|| parse_session_summaries(&response.lines))
                    .transpose();
                let (sessions, session_error) = match result {
                    Ok(Some(sessions)) => (sessions, None),
                    Ok(None) => (
                        Vec::new(),
                        Some(response_lines_lossy(
                            &response.lines,
                            "tmux session discovery failed",
                        )),
                    ),
                    Err(error) => (Vec::new(), Some(error.to_string())),
                };
                self.events.push_back(TmuxControlEvent::Sessions {
                    sessions,
                    session_error,
                });
            }
            PendingCommand::Resume { pane_id } => {
                if succeeded {
                    if let Some(pane) = self.latest_panes.get(&pane_id).cloned() {
                        self.queue_pane_capture(pane);
                    } else {
                        self.rehydrating_panes.remove(&pane_id);
                        self.request_sync();
                    }
                } else {
                    self.rehydrating_panes.remove(&pane_id);
                    self.flush_rehydration_passthrough(pane_id);
                }
            }
            PendingCommand::AlternateBacking { pane } => {
                if succeeded {
                    self.alternate_backings.insert(pane.pane_id, response.lines);
                }
            }
            PendingCommand::Capture { pane } => {
                self.finish_capture_response(succeeded, &response.lines, pane)?;
            }
            PendingCommand::Ignore => {
                if !succeeded {
                    let message = response_lines_lossy(&response.lines, "tmux command failed");
                    self.events
                        .push_back(TmuxControlEvent::CommandError { message });
                }
            }
        }
        Ok(())
    }

    fn finish_snapshot_response(&mut self, succeeded: bool, lines: &[Vec<u8>]) -> Result<()> {
        self.sync_pending = false;
        let resync_requested = std::mem::take(&mut self.sync_requested_while_pending);
        if !succeeded {
            if resync_requested {
                self.request_sync();
            }
            return Ok(());
        }
        let snapshot = parse_snapshot(lines)?;
        for pane in snapshot.windows.iter().flat_map(|window| &window.panes) {
            if let Some(previous) = self.latest_panes.get(&pane.pane_id) {
                let hydration_changed = pane_hydration_state_changed(previous, pane);
                if self.capture_pending.contains(&pane.pane_id) && hydration_changed {
                    self.hydrated_panes.remove(&pane.pane_id);
                    self.recapture_panes.insert(pane.pane_id);
                } else if pane_requires_live_recapture(previous, pane) {
                    self.hydrated_panes.remove(&pane.pane_id);
                }
            }
        }
        self.latest_panes = snapshot
            .windows
            .iter()
            .flat_map(|window| window.panes.iter().cloned())
            .map(|pane| (pane.pane_id, pane))
            .collect();
        self.queue_pane_hydrations(&snapshot);
        self.events
            .push_back(TmuxControlEvent::Snapshot { snapshot });
        if resync_requested {
            self.request_sync();
        }
        Ok(())
    }

    fn finish_capture_response(
        &mut self,
        succeeded: bool,
        lines: &[Vec<u8>],
        pane: TmuxPaneSnapshot,
    ) -> Result<()> {
        self.capture_pending.remove(&pane.pane_id);
        if self.recapture_panes.remove(&pane.pane_id) {
            self.alternate_backings.remove(&pane.pane_id);
            self.hydrated_panes.remove(&pane.pane_id);
            self.rehydrating_panes.remove(&pane.pane_id);
            if let Some(latest) = self.latest_panes.get(&pane.pane_id).cloned() {
                self.queue_pane_capture(latest);
            }
            return Ok(());
        }
        if succeeded {
            let backing = self.alternate_backings.remove(&pane.pane_id);
            let data = build_pane_hydration(lines, backing.as_deref(), &pane)?;
            self.hydrated_panes.insert(pane.pane_id);
            self.events.push_back(TmuxControlEvent::PaneHydration {
                pane_id: pane.pane_id,
                data,
            });
        }
        self.rehydrating_panes.remove(&pane.pane_id);
        self.flush_rehydration_passthrough(pane.pane_id);
        self.request_sync();
        Ok(())
    }

    fn queue_pane_hydrations(&mut self, snapshot: &TmuxSnapshot) {
        let current_panes = snapshot
            .windows
            .iter()
            .flat_map(|window| window.panes.iter())
            .map(|pane| pane.pane_id)
            .collect::<HashSet<_>>();
        self.hydrated_panes
            .retain(|pane_id| current_panes.contains(pane_id));
        self.capture_pending
            .retain(|pane_id| current_panes.contains(pane_id));
        self.rehydrating_panes
            .retain(|pane_id| current_panes.contains(pane_id));
        self.recapture_panes
            .retain(|pane_id| current_panes.contains(pane_id));
        self.alternate_backings
            .retain(|pane_id, _| current_panes.contains(pane_id));
        self.passthrough_attempted_panes
            .retain(|pane_id| current_panes.contains(pane_id));
        self.passthrough_decoders
            .retain(|pane_id, _| current_panes.contains(pane_id));
        self.scroll_sequence_trackers
            .retain(|pane_id, _| current_panes.contains(pane_id));
        self.rehydration_passthrough
            .retain(|pane_id, _| current_panes.contains(pane_id));
        self.dropped_rehydration_passthrough
            .retain(|pane_id| current_panes.contains(pane_id));
        for pane in snapshot.windows.iter().flat_map(|window| &window.panes) {
            if self.hydrated_panes.contains(&pane.pane_id)
                || self.capture_pending.contains(&pane.pane_id)
            {
                continue;
            }
            self.queue_pane_capture(pane.clone());
        }
    }

    fn queue_pane_capture(&mut self, pane: TmuxPaneSnapshot) {
        if !self.capture_pending.insert(pane.pane_id) {
            return;
        }
        self.rehydrating_panes.insert(pane.pane_id);
        if pane.allow_passthrough == "off" && self.passthrough_attempted_panes.insert(pane.pane_id)
        {
            self.queue_command(
                format!("set-option -p -t %{} allow-passthrough on", pane.pane_id),
                PendingCommand::Ignore,
            );
        }
        if pane.alternate_on {
            self.queue_command(
                format!("capture-pane -p -e -C -a -t %{}", pane.pane_id),
                PendingCommand::AlternateBacking { pane: pane.clone() },
            );
        }
        let history = hydration_history_lines(&pane);
        self.queue_command(
            format!("capture-pane -p -e -C -S -{history} -t %{}", pane.pane_id),
            PendingCommand::Capture { pane },
        );
    }

    fn queue_terminal_error(&mut self, lines: &[Vec<u8>]) {
        if lines.is_empty() {
            return;
        }
        self.terminal_after_control.extend_from_slice(b"\r\n");
        for line in lines {
            self.terminal_after_control.extend_from_slice(line);
            self.terminal_after_control.extend_from_slice(b"\r\n");
        }
    }
}

fn parse_quoted_rows(lines: &[Vec<u8>], field_count: usize) -> Result<Vec<Vec<Vec<u8>>>> {
    let mut rows = Vec::new();
    let mut fields = Vec::with_capacity(field_count);
    let mut field = Vec::new();
    let mut escaped = false;
    for line in lines {
        for &byte in line {
            if escaped {
                field.push(byte);
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'\t' {
                fields.push(std::mem::take(&mut field));
            } else {
                field.push(byte);
            }
        }
        if escaped {
            field.push(b'\n');
            escaped = false;
            continue;
        }
        fields.push(std::mem::take(&mut field));
        if fields.len() != field_count {
            bail!(
                "tmux topology row has {} fields, expected {field_count}",
                fields.len()
            );
        }
        rows.push(std::mem::take(&mut fields));
    }
    if escaped || !field.is_empty() || !fields.is_empty() {
        bail!("tmux topology response ended inside an escaped row");
    }
    Ok(rows)
}

fn parse_snapshot(lines: &[Vec<u8>]) -> Result<TmuxSnapshot> {
    let mut session_id = None;
    let mut session_name = None;
    let mut socket_path = None;
    let mut server_pid = None;
    let mut active_window_id = None;
    let mut windows = Vec::<WindowBuilder>::new();
    let mut indexes = HashMap::<u32, usize>::new();
    for fields in parse_quoted_rows(lines, SNAPSHOT_FIELD_COUNT)? {
        let fields = fields
            .iter()
            .map(|field| std::str::from_utf8(field).map_err(Into::into))
            .collect::<Result<Vec<_>>>()?;
        let row_session_id = parse_prefixed_id(fields[0], '$')?;
        let window_id = parse_prefixed_id(fields[3], '@')?;
        session_id.get_or_insert(row_session_id);
        session_name.get_or_insert_with(|| fields[1].to_owned());
        socket_path.get_or_insert_with(|| fields[2].to_owned());
        server_pid.get_or_insert(fields[35].parse()?);
        if parse_flag(fields[6])? {
            active_window_id = Some(window_id);
        }
        let window_index = if let Some(index) = indexes.get(&window_id) {
            *index
        } else {
            let index = windows.len();
            indexes.insert(window_id, index);
            windows.push(WindowBuilder {
                window_id,
                index: fields[4].parse()?,
                name: fields[5].to_owned(),
                layout: parse_layout(fields[7])?,
                zoomed: parse_flag(fields[8])?,
                panes: Vec::new(),
            });
            index
        };
        windows[window_index]
            .panes
            .push(parse_pane_snapshot(&fields)?);
    }
    if windows.is_empty() {
        bail!("tmux topology response contained no panes");
    }
    windows.sort_by_key(|window| window.index);
    let windows = windows
        .into_iter()
        .map(WindowBuilder::finish)
        .collect::<Result<Vec<_>>>()?;
    let active_window_id = active_window_id.unwrap_or(windows[0].window_id);
    Ok(TmuxSnapshot {
        session_id: session_id.unwrap_or_default(),
        session_name: session_name.unwrap_or_default(),
        socket_path: socket_path.unwrap_or_default(),
        server_pid: server_pid.unwrap_or_default(),
        active_window_id,
        windows,
    })
}

fn parse_pane_snapshot(fields: &[&str]) -> Result<TmuxPaneSnapshot> {
    Ok(TmuxPaneSnapshot {
        pane_id: parse_prefixed_id(fields[9], '%')?,
        index: fields[10].parse()?,
        active: parse_flag(fields[11])?,
        current_path: fields[12].to_owned(),
        cols: fields[13].parse()?,
        rows: fields[14].parse()?,
        cursor_x: fields[15].parse()?,
        cursor_y: fields[16].parse()?,
        cursor_visible: parse_flag(fields[17])?,
        cursor_shape: fields[18].to_owned(),
        cursor_blinking: parse_flag(fields[19])?,
        history_size: fields[20].parse()?,
        alternate_on: parse_flag(fields[21])?,
        insert_mode: parse_flag(fields[22])?,
        application_cursor: parse_flag(fields[23])?,
        application_keypad: parse_flag(fields[24])?,
        origin_mode: parse_flag(fields[25])?,
        wrap_mode: parse_flag(fields[26])?,
        mouse_standard: parse_flag(fields[27])?,
        mouse_button: parse_flag(fields[28])?,
        mouse_any: parse_flag(fields[29])?,
        mouse_utf8: parse_flag(fields[30])?,
        mouse_sgr: parse_flag(fields[31])?,
        input_off: parse_flag(fields[32])?,
        scroll_region_upper: fields[33].parse()?,
        scroll_region_lower: fields[34].parse()?,
        private_modes: parse_private_modes(fields[36])?,
        key_mode: fields[37].to_owned(),
        current_command: fields[38].to_owned(),
        title: fields[39].to_owned(),
        allow_passthrough: fields[40].to_owned(),
    })
}

fn parse_private_modes(value: &str) -> Result<Vec<u16>> {
    if value.is_empty() {
        return Ok(Vec::new());
    }
    value
        .split(',')
        .map(str::parse)
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(Into::into)
}

struct WindowBuilder {
    window_id: u32,
    index: u32,
    name: String,
    layout: TmuxLayoutSnapshot,
    zoomed: bool,
    panes: Vec<TmuxPaneSnapshot>,
}

impl WindowBuilder {
    fn finish(mut self) -> Result<TmuxWindowSnapshot> {
        self.panes.sort_by_key(|pane| pane.index);
        let active_pane_id = self
            .panes
            .iter()
            .find(|pane| pane.active)
            .or_else(|| self.panes.first())
            .map(|pane| pane.pane_id)
            .ok_or_else(|| anyhow::anyhow!("tmux window contains no panes"))?;
        Ok(TmuxWindowSnapshot {
            window_id: self.window_id,
            index: self.index,
            name: self.name,
            active_pane_id,
            zoomed: self.zoomed,
            layout: self.layout,
            panes: self.panes,
        })
    }
}

#[derive(Debug)]
struct ParsedLayout {
    width: u32,
    height: u32,
    snapshot: TmuxLayoutSnapshot,
}

fn parse_layout(value: &str) -> Result<TmuxLayoutSnapshot> {
    let Some((_, layout)) = value.split_once(',') else {
        bail!("tmux layout omitted checksum");
    };
    let mut parser = LayoutParser::new(layout);
    let parsed = parser.parse_node()?;
    if !parser.is_empty() {
        bail!("tmux layout has trailing input");
    }
    Ok(parsed.snapshot)
}

struct LayoutParser<'a> {
    input: &'a [u8],
    cursor: usize,
}

impl<'a> LayoutParser<'a> {
    fn new(input: &'a str) -> Self {
        Self {
            input: input.as_bytes(),
            cursor: 0,
        }
    }

    fn is_empty(&self) -> bool {
        self.cursor == self.input.len()
    }

    fn parse_node(&mut self) -> Result<ParsedLayout> {
        let width = self.number()?;
        self.expect(b'x')?;
        let height = self.number()?;
        self.expect(b',')?;
        let _x = self.number()?;
        self.expect(b',')?;
        let _y = self.number()?;
        match self.peek() {
            Some(b',') => {
                self.cursor += 1;
                let pane_id = self.number()?;
                Ok(ParsedLayout {
                    width,
                    height,
                    snapshot: TmuxLayoutSnapshot {
                        kind: "leaf",
                        pane_id: Some(pane_id),
                        axis: None,
                        ratio: None,
                        first: None,
                        second: None,
                    },
                })
            }
            Some(open @ (b'{' | b'[')) => self.parse_children(width, height, open),
            _ => bail!("tmux layout node omitted pane id or children"),
        }
    }

    fn parse_children(&mut self, width: u32, height: u32, open: u8) -> Result<ParsedLayout> {
        self.cursor += 1;
        let close = if open == b'{' { b'}' } else { b']' };
        let axis = if open == b'{' {
            "vertical"
        } else {
            "horizontal"
        };
        let mut children = vec![self.parse_node()?];
        while self.peek() == Some(b',') {
            self.cursor += 1;
            children.push(self.parse_node()?);
        }
        self.expect(close)?;
        if children.len() < 2 {
            bail!("tmux layout container has fewer than two children");
        }
        let snapshot = fold_layout_children(children, axis)?;
        Ok(ParsedLayout {
            width,
            height,
            snapshot,
        })
    }

    fn number(&mut self) -> Result<u32> {
        let start = self.cursor;
        while self.peek().is_some_and(|byte| byte.is_ascii_digit()) {
            self.cursor += 1;
        }
        if start == self.cursor {
            bail!("tmux layout expected a number");
        }
        Ok(std::str::from_utf8(&self.input[start..self.cursor])?.parse()?)
    }

    fn peek(&self) -> Option<u8> {
        self.input.get(self.cursor).copied()
    }

    fn expect(&mut self, expected: u8) -> Result<()> {
        if self.peek() != Some(expected) {
            bail!("tmux layout expected byte {expected}");
        }
        self.cursor += 1;
        Ok(())
    }
}

fn fold_layout_children(
    mut children: Vec<ParsedLayout>,
    axis: &'static str,
) -> Result<TmuxLayoutSnapshot> {
    let first = children.remove(0);
    let first_extent = if axis == "vertical" {
        first.width
    } else {
        first.height
    };
    let remaining_extent = children.iter().try_fold(0_u32, |total, child| {
        total
            .checked_add(if axis == "vertical" {
                child.width
            } else {
                child.height
            })
            .ok_or_else(|| anyhow::anyhow!("tmux layout dimensions overflow"))
    })?;
    let ratio = f64::from(first_extent) / f64::from(first_extent + remaining_extent);
    let second = if children.len() == 1 {
        children.remove(0).snapshot
    } else {
        fold_layout_children(children, axis)?
    };
    Ok(TmuxLayoutSnapshot {
        kind: "split",
        pane_id: None,
        axis: Some(axis),
        ratio: Some(ratio),
        first: Some(Box::new(first.snapshot)),
        second: Some(Box::new(second)),
    })
}

fn parse_prefixed_id(value: &str, prefix: char) -> Result<u32> {
    let Some(value) = value.strip_prefix(prefix) else {
        bail!("tmux id {value:?} omitted {prefix:?} prefix");
    };
    Ok(value.parse()?)
}

fn parse_flag(value: &str) -> Result<bool> {
    match value {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => bail!("invalid tmux boolean {value:?}"),
    }
}

fn parse_prefixed_id_bytes(value: &[u8], prefix: u8) -> Result<u32> {
    let Some(value) = value.strip_prefix(&[prefix]) else {
        bail!("tmux id omitted expected prefix");
    };
    Ok(std::str::from_utf8(value)?.parse()?)
}

fn trim_ascii(mut value: &[u8]) -> &[u8] {
    while value.first().is_some_and(u8::is_ascii_whitespace) {
        value = &value[1..];
    }
    while value.last().is_some_and(u8::is_ascii_whitespace) {
        value = &value[..value.len() - 1];
    }
    value
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn tmux_octal_argument(bytes: &[u8]) -> String {
    use std::fmt::Write as _;

    let mut encoded = String::with_capacity(bytes.len().saturating_mul(4));
    for byte in bytes {
        let _ = write!(encoded, "\\{byte:03o}");
    }
    encoded
}

fn decode_tmux_bytes(bytes: &[u8]) -> Result<Vec<u8>> {
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'\\' {
            decoded.push(bytes[index]);
            index += 1;
            continue;
        }
        if index + 3 >= bytes.len()
            || !bytes[index + 1..=index + 3]
                .iter()
                .all(|byte| matches!(byte, b'0'..=b'7'))
        {
            bail!("invalid tmux output escape");
        }
        decoded.push(decode_octal(&bytes[index + 1..index + 4]));
        index += 4;
    }
    Ok(decoded)
}

fn decode_octal(bytes: &[u8]) -> u8 {
    (bytes[0] - b'0') * 64 + (bytes[1] - b'0') * 8 + (bytes[2] - b'0')
}

fn hydration_history_lines(pane: &TmuxPaneSnapshot) -> u32 {
    if pane.alternate_on {
        return 0;
    }
    let escaped_row_bytes = usize::from(pane.cols).saturating_mul(4).saturating_add(1);
    let byte_limited = MAX_HYDRATION_CAPTURE_BYTES / escaped_row_bytes.max(1);
    pane.history_size
        .min(MAX_HYDRATION_HISTORY_LINES)
        .min(u32::try_from(byte_limited).unwrap_or(u32::MAX))
}

fn pane_requires_live_recapture(previous: &TmuxPaneSnapshot, current: &TmuxPaneSnapshot) -> bool {
    previous.cols != current.cols || previous.rows != current.rows
}

fn pane_hydration_state_changed(previous: &TmuxPaneSnapshot, current: &TmuxPaneSnapshot) -> bool {
    previous.cols != current.cols
        || previous.rows != current.rows
        || previous.alternate_on != current.alternate_on
        || previous.insert_mode != current.insert_mode
        || previous.application_cursor != current.application_cursor
        || previous.application_keypad != current.application_keypad
        || previous.origin_mode != current.origin_mode
        || previous.wrap_mode != current.wrap_mode
        || previous.mouse_standard != current.mouse_standard
        || previous.mouse_button != current.mouse_button
        || previous.mouse_any != current.mouse_any
        || previous.mouse_utf8 != current.mouse_utf8
        || previous.mouse_sgr != current.mouse_sgr
        || previous.private_modes != current.private_modes
        || previous.key_mode != current.key_mode
        || previous.scroll_region_upper != current.scroll_region_upper
        || previous.scroll_region_lower != current.scroll_region_lower
}

fn build_pane_hydration(
    lines: &[Vec<u8>],
    alternate_backing: Option<&[Vec<u8>]>,
    pane: &TmuxPaneSnapshot,
) -> Result<Vec<u8>> {
    let mut hydration = Vec::new();
    hydration.extend_from_slice(b"\x1bc\x1b[?25l");
    if let Some(backing) = alternate_backing {
        append_capture(&mut hydration, backing, pane.rows, false)?;
        hydration.extend_from_slice(b"\x1b[?1049h");
    }
    append_capture(
        &mut hydration,
        lines,
        pane.rows,
        !pane.alternate_on && hydration_history_lines(pane) > 0,
    )?;
    hydration.extend_from_slice(
        format!(
            "\x1b[{};{}r\x1b[?6l\x1b[{};{}H",
            pane.scroll_region_upper.saturating_add(1),
            pane.scroll_region_lower.saturating_add(1),
            pane.cursor_y.saturating_add(1),
            pane.cursor_x.saturating_add(1)
        )
        .as_bytes(),
    );
    append_bool_mode(&mut hydration, 1, pane.application_cursor);
    append_bool_mode(&mut hydration, 6, pane.origin_mode);
    append_bool_mode(&mut hydration, 7, pane.wrap_mode);
    hydration.extend_from_slice(if pane.insert_mode {
        b"\x1b[4h"
    } else {
        b"\x1b[4l"
    });
    hydration.extend_from_slice(if pane.application_keypad {
        b"\x1b="
    } else {
        b"\x1b>"
    });
    for mode in [1000, 1002, 1003, 1005, 1006] {
        append_bool_mode(&mut hydration, mode, false);
    }
    append_bool_mode(&mut hydration, 1000, pane.mouse_standard);
    append_bool_mode(&mut hydration, 1002, pane.mouse_button);
    append_bool_mode(&mut hydration, 1003, pane.mouse_any);
    append_bool_mode(&mut hydration, 1005, pane.mouse_utf8);
    append_bool_mode(&mut hydration, 1006, pane.mouse_sgr);
    for mode in [1004, 2004, 2026, 2031] {
        append_bool_mode(&mut hydration, mode, pane.private_modes.contains(&mode));
    }
    hydration.extend_from_slice(match pane.key_mode.as_str() {
        "Ext 1" => b"\x1b[>4;1m",
        "Ext 2" => b"\x1b[>4;2m",
        _ => b"\x1b[>4;0m",
    });
    hydration.extend_from_slice(cursor_shape_sequence(pane));
    if pane.cursor_visible {
        hydration.extend_from_slice(b"\x1b[?25h");
    }
    Ok(hydration)
}

fn append_capture(
    hydration: &mut Vec<u8>,
    lines: &[Vec<u8>],
    visible_rows: u16,
    includes_history: bool,
) -> Result<()> {
    for (index, line) in lines.iter().enumerate() {
        hydration.extend_from_slice(&decode_capture_bytes(line)?);
        if index + 1 < lines.len() {
            hydration.extend_from_slice(b"\r\n");
        }
    }
    hydration.extend_from_slice(b"\x1b[0m\x1b[2J");
    let visible_count = usize::from(visible_rows).min(lines.len());
    let visible_start = if includes_history {
        lines.len().saturating_sub(visible_count)
    } else {
        0
    };
    for (row, line) in lines[visible_start..visible_start + visible_count]
        .iter()
        .enumerate()
    {
        hydration.extend_from_slice(format!("\x1b[{};1H", row + 1).as_bytes());
        hydration.extend_from_slice(&decode_capture_bytes(line)?);
    }
    Ok(())
}

fn append_bool_mode(output: &mut Vec<u8>, mode: u16, enabled: bool) {
    use std::fmt::Write as _;

    let mut sequence = String::new();
    let _ = write!(sequence, "\x1b[?{mode}{}", if enabled { 'h' } else { 'l' });
    output.extend_from_slice(sequence.as_bytes());
}

fn cursor_shape_sequence(pane: &TmuxPaneSnapshot) -> &'static [u8] {
    match (pane.cursor_shape.as_str(), pane.cursor_blinking) {
        ("block", true) => b"\x1b[1 q",
        ("block", false) => b"\x1b[2 q",
        ("underline", true) => b"\x1b[3 q",
        ("underline", false) => b"\x1b[4 q",
        ("bar", true) => b"\x1b[5 q",
        ("bar", false) => b"\x1b[6 q",
        _ => b"\x1b[0 q",
    }
}

fn decode_capture_bytes(bytes: &[u8]) -> Result<Vec<u8>> {
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'\\' {
            decoded.push(bytes[index]);
            index += 1;
            continue;
        }
        if bytes.get(index + 1) == Some(&b'\\') {
            decoded.push(b'\\');
            index += 2;
            continue;
        }
        if index + 3 >= bytes.len()
            || !bytes[index + 1..=index + 3]
                .iter()
                .all(|byte| matches!(byte, b'0'..=b'7'))
        {
            bail!("invalid tmux capture escape");
        }
        decoded.push(decode_octal(&bytes[index + 1..index + 4]));
        index += 4;
    }
    Ok(decoded)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal_runtime::{NativeTerminalRuntime, TerminalGridSize};

    fn snapshot_row(path: &str, history_size: u32, alternate_on: bool, zoomed: bool) -> String {
        [
            "$0",
            "satin",
            "/tmp/tmux.sock",
            "@2",
            "0",
            "main",
            "1",
            "b25f,80x24,0,0,7",
            if zoomed { "1" } else { "0" },
            "%7",
            "0",
            "1",
            path,
            "80",
            "24",
            "18",
            "4",
            "1",
            "block",
            "1",
            &history_size.to_string(),
            if alternate_on { "1" } else { "0" },
            "0",
            if alternate_on { "1" } else { "0" },
            if alternate_on { "1" } else { "0" },
            "0",
            "1",
            "0",
            if alternate_on { "1" } else { "0" },
            if alternate_on { "1" } else { "0" },
            "0",
            if alternate_on { "1" } else { "0" },
            "0",
            "0",
            "23",
            "4242",
            if alternate_on {
                "1,7,1002,1003,1006,2004"
            } else {
                "7,1004"
            },
            if alternate_on { "Ext 2" } else { "VT10x" },
            "zsh",
            "⠹ satin",
            "off",
        ]
        .join("\t")
    }

    fn acknowledge_passthrough_setup(control: &mut TmuxControl, guard: &str) {
        assert_eq!(
            control.take_outgoing().unwrap(),
            b"set-option -p -t %7 allow-passthrough on\n"
        );
        control
            .feed(format!("%begin {guard}\n%end {guard}\n").as_bytes())
            .unwrap();
    }

    #[test]
    fn detects_incremental_control_boundaries_and_restores_passthrough() {
        let mut control = TmuxControl::default();
        assert_eq!(control.feed(b"shell\x1bP10").unwrap(), b"shell");
        assert_eq!(
            control.feed(b"00p%exit done\n\x1b\\prompt").unwrap(),
            b"prompt"
        );
        assert_eq!(control.take_event(), Some(TmuxControlEvent::Entered));
        assert_eq!(
            control.take_event(),
            Some(TmuxControlEvent::Exited {
                reason: Some("done".to_owned())
            })
        );
        assert!(!control.is_active());
    }

    #[test]
    fn returns_initial_attach_error_to_the_terminal_after_control_mode() {
        let mut control = TmuxControl::default();
        let bytes = concat!(
            "\x1bP1000p%begin 1 2 0\n",
            "can't find session: missing\n",
            "%error 1 2 0\n%exit\n\x1b\\prompt"
        );
        assert_eq!(
            control.feed(bytes.as_bytes()).unwrap(),
            b"\r\ncan't find session: missing\r\nprompt"
        );
    }

    #[test]
    fn decodes_pane_output_octal_escapes() {
        assert_eq!(
            decode_tmux_bytes(br"hello\015\012\033\134").unwrap(),
            b"hello\r\n\x1b\\"
        );
        assert_eq!(decode_tmux_bytes(b"\xff\\000").unwrap(), b"\xff\0");
    }

    #[test]
    fn unwraps_fragmented_tmux_dcs_passthrough_without_losing_other_output() {
        let mut decoder = TmuxDcsPassthroughDecoder::default();
        assert_eq!(decoder.decode(b"before\x1bPtmu").all, b"before");
        assert_eq!(
            decoder.decode(b"x;\x1b\x1b_Ga=T,i=42;AAAA\x1b").all,
            b"\x1b_Ga=T,i=42;AAAA"
        );
        let decoded = decoder.decode(b"\x1b\\\x1b\\after");
        assert_eq!(decoded.all, b"\x1b\\after");
        assert_eq!(decoded.passthrough, b"\x1b\\");
    }

    #[test]
    fn preserves_non_tmux_dcs_and_reconsiders_a_mismatched_escape() {
        let mut decoder = TmuxDcsPassthroughDecoder::default();
        assert_eq!(
            decoder
                .decode(b"\x1bP1;2|payload\x1b\\plain\x1b\x1b[31mred")
                .all,
            b"\x1bP1;2|payload\x1b\\plain\x1b\x1b[31mred"
        );
    }

    #[test]
    fn parses_nested_layout_and_split_ratios() {
        let layout =
            parse_layout("8f06,80x24,0,0{40x24,0,0[40x12,0,0,0,40x11,0,13,2],39x24,41,0,1}")
                .unwrap();
        assert_eq!(layout.axis, Some("vertical"));
        assert_eq!(layout.ratio, Some(40.0 / 79.0));
        let left = layout.first.unwrap();
        assert_eq!(left.axis, Some("horizontal"));
        assert_eq!(left.ratio, Some(12.0 / 23.0));
        assert_eq!(left.first.unwrap().pane_id, Some(0));
        assert_eq!(left.second.unwrap().pane_id, Some(2));
        assert_eq!(layout.second.unwrap().pane_id, Some(1));
    }

    #[test]
    fn hydrates_initial_pane_content_before_following_live_output() {
        let mut control = TmuxControl::default();
        control
            .feed(b"\x1bP1000p%session-changed $0 satin\n")
            .unwrap();
        assert!(control.take_outgoing().is_none());
        admit_control_client(&mut control);
        assert!(control.take_outgoing().is_some());
        let row = snapshot_row("/tmp", 20, false, false);
        control
            .feed(format!("%begin 1 2 0\n{row}\n%end 1 2 0\n").as_bytes())
            .unwrap();
        acknowledge_passthrough_setup(&mut control, "1 3 0");
        assert_eq!(
            control.take_outgoing().unwrap(),
            b"capture-pane -p -e -C -S -20 -t %7\n"
        );
        let capture = concat!(
            "%begin 1 3 0\n",
            "\\033[31mRESTORED\\\\PATH\\033[39m\n",
            "%output %999 remains capture text\n",
            "%end fake\n",
            "%end 1 3 0\n",
            "%output %7 LIVE\n"
        );
        control.feed(capture.as_bytes()).unwrap();
        assert_eq!(control.take_event(), Some(TmuxControlEvent::Entered));
        assert!(matches!(
            control.take_event(),
            Some(TmuxControlEvent::Snapshot { .. })
        ));
        let Some(TmuxControlEvent::PaneHydration { pane_id, data }) = control.take_event() else {
            panic!("expected pane hydration");
        };
        assert_eq!(pane_id, 7);
        assert!(data.starts_with(b"\x1bc\x1b[?25l\x1b[31mRESTORED\\PATH\x1b[39m"));
        assert!(
            data.windows(b"%output %999 remains capture text".len())
                .any(|window| { window == b"%output %999 remains capture text" })
        );
        assert!(
            data.windows(b"\x1b[1;24r\x1b[?6l\x1b[5;19H".len())
                .any(|window| window == b"\x1b[1;24r\x1b[?6l\x1b[5;19H")
        );
        assert!(data.ends_with(b"\x1b[1 q\x1b[?25h"));
        assert!(data.windows(8).any(|window| window == b"\x1b[?1004h"));
        assert!(data.windows(7).any(|window| window == b"\x1b[>4;0m"));
        assert_eq!(
            control.take_event(),
            Some(TmuxControlEvent::PaneOutput {
                pane_id: 7,
                data: b"LIVE".to_vec(),
            })
        );
    }

    #[test]
    fn parses_escaped_tabs_and_newlines_in_topology_fields() {
        let fields = parse_quoted_rows(
            &[b"one\ttwo\\\tthree\tfour\\".to_vec(), b"five".to_vec()],
            3,
        )
        .unwrap();
        assert_eq!(fields[0][1], b"two\tthree");
        assert_eq!(fields[0][2], b"four\nfive");

        let row = snapshot_row("/tmp/tab\\\tline\\\npath", 0, false, true);
        let lines = row
            .split('\n')
            .map(|line| line.as_bytes().to_vec())
            .collect::<Vec<_>>();
        let snapshot = parse_snapshot(&lines).unwrap();
        assert_eq!(
            snapshot.windows[0].panes[0].current_path,
            "/tmp/tab\tline\npath"
        );
        assert!(snapshot.windows[0].zoomed);
    }

    #[test]
    fn pause_continues_and_forces_a_fresh_capture() {
        let mut control = TmuxControl::default();
        control
            .feed(b"\x1bP1000p%session-changed $0 satin\n")
            .unwrap();
        assert!(control.take_outgoing().is_none());
        admit_control_client(&mut control);
        assert!(control.take_outgoing().is_some());
        let row = snapshot_row("/tmp", 3, false, false);
        control
            .feed(format!("%begin 1 2 0\n{row}\n%end 1 2 0\n").as_bytes())
            .unwrap();
        acknowledge_passthrough_setup(&mut control, "1 3 0");
        assert!(control.take_outgoing().is_some());
        control
            .feed(b"%begin 1 3 0\nready\n%end 1 3 0\n%pause %7\n")
            .unwrap();
        assert!(
            String::from_utf8(control.take_outgoing().unwrap())
                .unwrap()
                .starts_with("list-panes -s")
        );
        assert_eq!(
            control.take_outgoing().unwrap(),
            b"refresh-client -A %7:continue\n"
        );
        control
            .feed(format!("%begin 1 4 0\n{row}\n%end 1 4 0\n").as_bytes())
            .unwrap();
        control.feed(b"%begin 1 5 0\n%end 1 5 0\n").unwrap();
        assert_eq!(
            control.take_outgoing().unwrap(),
            b"capture-pane -p -e -C -S -3 -t %7\n"
        );
    }

    #[test]
    fn topology_change_during_capture_discards_stale_hydration_and_recaptures() {
        let old_row = snapshot_row("/tmp", 0, false, false);
        let old_snapshot = parse_snapshot(&[old_row.clone().into_bytes()]).unwrap();
        let old_pane = old_snapshot.windows[0].panes[0].clone();
        let changed_row = old_row.replacen("\t80\t24\t", "\t120\t40\t", 1);
        let mut control = TmuxControl {
            active: true,
            latest_panes: [(old_pane.pane_id, old_pane.clone())].into(),
            capture_pending: [old_pane.pane_id].into(),
            rehydrating_panes: [old_pane.pane_id].into(),
            response: Some(CommandResponse {
                kind: PendingCommand::Snapshot,
                guard: Vec::new(),
                lines: vec![changed_row.into_bytes()],
                bytes: 0,
            }),
            ..Default::default()
        };
        control.finish_response(true).unwrap();
        assert!(control.recapture_panes.contains(&old_pane.pane_id));

        control.response = Some(CommandResponse {
            kind: PendingCommand::Capture {
                pane: old_pane.clone(),
            },
            guard: Vec::new(),
            lines: vec![b"STALE".to_vec()],
            bytes: 0,
        });
        control.finish_response(true).unwrap();
        assert!(control.capture_pending.contains(&old_pane.pane_id));
        assert!(!control.events.iter().any(|event| {
            matches!(event, TmuxControlEvent::PaneHydration { pane_id, .. } if *pane_id == old_pane.pane_id)
        }));
        assert_eq!(
            control.outgoing.back().unwrap(),
            b"capture-pane -p -e -C -S -0 -t %7\n"
        );
    }

    #[test]
    fn live_alternate_screen_transitions_do_not_queue_capture() {
        let primary_row = snapshot_row("/tmp", 0, false, false);
        let alternate_row = snapshot_row("/tmp", 0, true, false);
        let primary = parse_snapshot(&[primary_row.clone().into_bytes()]).unwrap();
        let primary_pane = primary.windows[0].panes[0].clone();
        let pane_id = primary_pane.pane_id;
        let mut control = TmuxControl {
            active: true,
            hydrated_panes: [pane_id].into(),
            latest_panes: [(pane_id, primary_pane)].into(),
            response: Some(CommandResponse {
                kind: PendingCommand::Snapshot,
                guard: Vec::new(),
                lines: vec![alternate_row.into_bytes()],
                bytes: 0,
            }),
            ..Default::default()
        };

        control.finish_response(true).unwrap();
        assert!(control.hydrated_panes.contains(&pane_id));
        assert!(!control.capture_pending.contains(&pane_id));
        assert!(!control.recapture_panes.contains(&pane_id));
        assert!(control.outgoing.is_empty());
        control.events.clear();
        control.push_output(pane_id, b"LIVE_ALT".to_vec());
        assert_eq!(
            control.take_event(),
            Some(TmuxControlEvent::PaneOutput {
                pane_id,
                data: b"LIVE_ALT".to_vec(),
            })
        );

        control.response = Some(CommandResponse {
            kind: PendingCommand::Snapshot,
            guard: Vec::new(),
            lines: vec![primary_row.into_bytes()],
            bytes: 0,
        });
        control.finish_response(true).unwrap();
        assert!(control.hydrated_panes.contains(&pane_id));
        assert!(!control.capture_pending.contains(&pane_id));
        assert!(!control.recapture_panes.contains(&pane_id));
        assert!(control.outgoing.is_empty());
        control.events.clear();
        control.push_output(pane_id, b"LIVE_PRIMARY".to_vec());
        assert_eq!(
            control.take_event(),
            Some(TmuxControlEvent::PaneOutput {
                pane_id,
                data: b"LIVE_PRIMARY".to_vec(),
            })
        );
    }

    #[test]
    fn protocol_errors_are_visible_and_detach_the_control_client() {
        let mut control = TmuxControl::default();
        control.feed(b"\x1bP1000p%output invalid\n").unwrap();
        assert!(matches!(
            control.take_event(),
            Some(TmuxControlEvent::Entered)
        ));
        assert!(matches!(
            control.take_event(),
            Some(TmuxControlEvent::ProtocolError { .. })
        ));
        assert_eq!(control.take_outgoing().unwrap(), b"detach-client\n");
    }

    #[test]
    fn rejected_tmux_commands_are_reported_without_detaching() {
        let mut control = TmuxControl {
            active: true,
            control_client_admitted: true,
            ..Default::default()
        };
        assert!(control.command("not-a-command"));
        control
            .feed(b"%begin 1 2 0\nunknown command: not-a-command\n%error 1 2 0\n")
            .unwrap();
        assert_eq!(
            control.take_event(),
            Some(TmuxControlEvent::CommandError {
                message: "unknown command: not-a-command".to_owned(),
            })
        );
        assert!(control.is_active());
    }

    #[test]
    fn session_discovery_uses_the_existing_control_client() {
        let mut control = TmuxControl {
            active: true,
            control_client_admitted: true,
            ..Default::default()
        };
        assert!(control.command(SESSION_LIST_COMMAND));
        assert_eq!(
            control.take_outgoing().unwrap(),
            format!("{SESSION_LIST_COMMAND}\n").as_bytes()
        );
        control
            .feed(
                b"%begin 1 2 0\n$0|alpha|2|/tmp/tmux.sock|4242\n\
                  $1|beta|1|/tmp/tmux.sock|4242\n%end 1 2 0\n",
            )
            .unwrap();
        assert_eq!(
            control.take_event(),
            Some(TmuxControlEvent::Sessions {
                sessions: vec![
                    TmuxSessionSummary {
                        session_id: 0,
                        name: "alpha".to_owned(),
                        window_count: 2,
                        socket_path: "/tmp/tmux.sock".to_owned(),
                        server_pid: 4242,
                    },
                    TmuxSessionSummary {
                        session_id: 1,
                        name: "beta".to_owned(),
                        window_count: 1,
                        socket_path: "/tmp/tmux.sock".to_owned(),
                        server_pid: 4242,
                    },
                ],
                session_error: None,
            })
        );
    }

    #[test]
    fn paste_uses_a_binary_safe_private_tmux_buffer() {
        let row = snapshot_row("/tmp", 0, false, false);
        let snapshot = parse_snapshot(&[row.into_bytes()]).unwrap();
        let pane = snapshot.windows[0].panes[0].clone();
        let mut control = TmuxControl {
            active: true,
            latest_panes: [(pane.pane_id, pane)].into(),
            ..Default::default()
        };
        assert!(control.paste(7, b"a\n'\\\0"));
        assert_eq!(
            control.take_outgoing().unwrap(),
            b"set-buffer -b satin-7-1 \"\\141\\012\\047\\134\\000\"\n"
        );
        assert_eq!(
            control.take_outgoing().unwrap(),
            b"paste-buffer -dpr -b satin-7-1 -t %7\n"
        );
    }

    #[test]
    fn alternate_hydration_keeps_the_first_visible_row_after_resize() {
        let row = snapshot_row("/tmp", 0, true, false);
        let snapshot = parse_snapshot(&[row.into_bytes()]).unwrap();
        let pane = &snapshot.windows[0].panes[0];
        let mut lines = vec![b"ALT_MARKER".to_vec()];
        lines.extend((0..22).map(|_| b"~".to_vec()));
        lines.push(b"[No Name] [+]".to_vec());
        let backing = vec![b"PRIMARY_MARKER".to_vec()];
        let hydration = build_pane_hydration(&lines, Some(&backing), pane).unwrap();
        assert!(hydration.windows(8).any(|window| window == b"\x1b[?2004h"));
        assert!(hydration.windows(7).any(|window| window == b"\x1b[>4;2m"));
        let mut runtime = NativeTerminalRuntime::external(TerminalGridSize {
            rows: 24,
            cols: 80,
            pixel_width: 800,
            pixel_height: 480,
        })
        .unwrap();
        runtime
            .resize(TerminalGridSize {
                rows: 63,
                cols: 193,
                pixel_width: 1_930,
                pixel_height: 1_260,
            })
            .unwrap();
        runtime.feed_external(&hydration).unwrap();
        assert!(runtime.screen_text().unwrap().contains("ALT_MARKER"));
    }

    include!("tmux_control_regression_tests.rs");
}
