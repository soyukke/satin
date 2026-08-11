#[derive(Debug, Default)]
pub(super) struct TmuxDcsPassthroughDecoder {
    state: TmuxDcsPassthroughState,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct DecodedTmuxOutput {
    pub(super) all: Vec<u8>,
    pub(super) passthrough: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum TmuxDcsPassthroughState {
    #[default]
    Ground,
    Escape,
    Prefix {
        matched: usize,
    },
    Body,
    BodyEscape,
}

impl TmuxDcsPassthroughDecoder {
    const PREFIX: &'static [u8] = b"tmux;";

    pub(super) fn decode(&mut self, bytes: &[u8]) -> DecodedTmuxOutput {
        let mut decoded = DecodedTmuxOutput {
            all: Vec::with_capacity(bytes.len()),
            passthrough: Vec::new(),
        };
        for &byte in bytes {
            let mut pending = Some(byte);
            while let Some(current) = pending.take() {
                match self.state {
                    TmuxDcsPassthroughState::Ground => {
                        if current == b'\x1b' {
                            self.state = TmuxDcsPassthroughState::Escape;
                        } else {
                            decoded.all.push(current);
                        }
                    }
                    TmuxDcsPassthroughState::Escape => {
                        if current == b'P' {
                            self.state = TmuxDcsPassthroughState::Prefix { matched: 0 };
                        } else {
                            decoded.all.push(b'\x1b');
                            self.state = TmuxDcsPassthroughState::Ground;
                            pending = Some(current);
                        }
                    }
                    TmuxDcsPassthroughState::Prefix { matched } => {
                        if Self::PREFIX.get(matched) == Some(&current) {
                            if matched + 1 == Self::PREFIX.len() {
                                self.state = TmuxDcsPassthroughState::Body;
                            } else {
                                self.state = TmuxDcsPassthroughState::Prefix {
                                    matched: matched + 1,
                                };
                            }
                        } else {
                            decoded.all.extend_from_slice(b"\x1bP");
                            decoded.all.extend_from_slice(&Self::PREFIX[..matched]);
                            self.state = TmuxDcsPassthroughState::Ground;
                            pending = Some(current);
                        }
                    }
                    TmuxDcsPassthroughState::Body => {
                        if current == b'\x1b' {
                            self.state = TmuxDcsPassthroughState::BodyEscape;
                        } else {
                            decoded.all.push(current);
                            decoded.passthrough.push(current);
                        }
                    }
                    TmuxDcsPassthroughState::BodyEscape => match current {
                        b'\x1b' => {
                            decoded.all.push(b'\x1b');
                            decoded.passthrough.push(b'\x1b');
                            self.state = TmuxDcsPassthroughState::Body;
                        }
                        b'\\' => {
                            self.state = TmuxDcsPassthroughState::Ground;
                        }
                        _ => {
                            decoded.all.extend_from_slice(&[b'\x1b', current]);
                            decoded.passthrough.extend_from_slice(&[b'\x1b', current]);
                            self.state = TmuxDcsPassthroughState::Body;
                        }
                    },
                }
            }
        }
        decoded
    }
}
