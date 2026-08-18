pub(crate) const MAX_TERMINAL_SCROLL_ANIMATION_ROWS: isize = 24;
const MAX_SATIN_SCROLL_OSC_BYTES: usize = 96;
const SATIN_SCROLL_OSC_PREFIX: &str = "777;SatinScroll;1;";

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
pub(crate) struct TerminalVtScrollRegion {
    pub(crate) top: u16,
    pub(crate) bottom: u16,
    pub(crate) left: u16,
    pub(crate) right: u16,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct TerminalScrollUpdate {
    pub(crate) rows: isize,
    pub(crate) region: Option<TerminalVtScrollRegion>,
}

#[derive(Debug, Default)]
pub(crate) struct TerminalScrollSequenceTracker {
    state: TerminalScrollParseState,
    parameters: [u16; 2],
    parameter_present: [bool; 2],
    parameter_index: usize,
    csi_valid: bool,
    active_scroll_region: Option<TerminalVtScrollRegion>,
    osc_payload: Vec<u8>,
    osc_valid: bool,
}

impl TerminalScrollSequenceTracker {
    pub(crate) fn feed(&mut self, bytes: &[u8]) -> TerminalScrollUpdate {
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
            TerminalScrollParseState::Osc => self.feed_control_string(byte, true),
            TerminalScrollParseState::OscEscape => self.feed_control_string_escape(byte, true),
            TerminalScrollParseState::String => self.feed_control_string(byte, false),
            TerminalScrollParseState::StringEscape => self.feed_control_string_escape(byte, false),
        }
    }

    fn feed_ground(&mut self, byte: u8) -> TerminalScrollUpdate {
        match byte {
            0x1b => self.state = TerminalScrollParseState::Escape,
            0x9b => self.start_csi(),
            0x9d => self.start_osc(),
            0x90 | 0x98 | 0x9e | 0x9f => self.state = TerminalScrollParseState::String,
            _ => {}
        }
        TerminalScrollUpdate::default()
    }

    fn feed_escape(&mut self, byte: u8) {
        match byte {
            b'[' => self.start_csi(),
            b']' => self.start_osc(),
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

    fn start_osc(&mut self) {
        self.state = TerminalScrollParseState::Osc;
        self.osc_payload.clear();
        self.osc_valid = true;
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
        (top > 0 && bottom >= top).then_some(TerminalVtScrollRegion {
            top,
            bottom,
            left: 0,
            right: 0,
        })
    }

    fn feed_control_string(&mut self, byte: u8, osc: bool) -> TerminalScrollUpdate {
        match byte {
            0x07 if osc => return self.finish_osc(),
            0x9c if osc => return self.finish_osc(),
            0x9c => self.state = TerminalScrollParseState::Ground,
            0x1b => {
                self.state = if osc {
                    TerminalScrollParseState::OscEscape
                } else {
                    TerminalScrollParseState::StringEscape
                };
            }
            _ if osc => self.push_osc_byte(byte),
            _ => {}
        }
        TerminalScrollUpdate::default()
    }

    fn feed_control_string_escape(&mut self, byte: u8, osc: bool) -> TerminalScrollUpdate {
        if byte == b'\\' {
            if osc {
                return self.finish_osc();
            }
            self.state = TerminalScrollParseState::Ground;
            return TerminalScrollUpdate::default();
        }
        self.state = if osc {
            self.osc_valid = false;
            TerminalScrollParseState::Osc
        } else {
            TerminalScrollParseState::String
        };
        TerminalScrollUpdate::default()
    }

    fn push_osc_byte(&mut self, byte: u8) {
        if self.osc_payload.len() >= MAX_SATIN_SCROLL_OSC_BYTES {
            self.osc_valid = false;
            return;
        }
        self.osc_payload.push(byte);
    }

    fn finish_osc(&mut self) -> TerminalScrollUpdate {
        self.state = TerminalScrollParseState::Ground;
        let update = self.parse_satin_scroll_osc();
        self.osc_payload.clear();
        self.osc_valid = true;
        update
    }

    fn parse_satin_scroll_osc(&self) -> TerminalScrollUpdate {
        if !self.osc_valid {
            return TerminalScrollUpdate::default();
        }
        let Ok(payload) = std::str::from_utf8(&self.osc_payload) else {
            return TerminalScrollUpdate::default();
        };
        let Some(fields) = payload.strip_prefix(SATIN_SCROLL_OSC_PREFIX) else {
            return TerminalScrollUpdate::default();
        };
        let mut fields = fields.split(';');
        let parsed = (
            fields.next().and_then(|value| value.parse::<isize>().ok()),
            fields.next().and_then(|value| value.parse::<u16>().ok()),
            fields.next().and_then(|value| value.parse::<u16>().ok()),
            fields.next().and_then(|value| value.parse::<u16>().ok()),
            fields.next().and_then(|value| value.parse::<u16>().ok()),
        );
        let (Some(rows), Some(top), Some(bottom), Some(left), Some(right)) = parsed else {
            return TerminalScrollUpdate::default();
        };
        if fields.next().is_some()
            || rows == 0
            || top == 0
            || bottom < top
            || left == 0
            || right < left
        {
            return TerminalScrollUpdate::default();
        }
        TerminalScrollUpdate {
            rows: rows.clamp(
                -MAX_TERMINAL_SCROLL_ANIMATION_ROWS,
                MAX_TERMINAL_SCROLL_ANIMATION_ROWS,
            ),
            region: Some(TerminalVtScrollRegion {
                top,
                bottom,
                left,
                right,
            }),
        }
    }
}
