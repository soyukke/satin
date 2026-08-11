use anyhow::{Result, bail};
use serde::Serialize;

const SESSION_FIELD_COUNT: usize = 3;
const SESSION_FIELD_SEPARATOR: u8 = b'|';

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct TmuxSessionSummary {
    pub name: String,
    pub window_count: u32,
    pub socket_path: String,
}

pub(super) fn parse_session_summaries(lines: &[Vec<u8>]) -> Result<Vec<TmuxSessionSummary>> {
    let mut sessions = Vec::with_capacity(lines.len());
    for line in lines {
        let fields = parse_fields(line)?;
        if fields.len() != SESSION_FIELD_COUNT {
            bail!(
                "tmux session row has {} fields, expected {SESSION_FIELD_COUNT}",
                fields.len()
            );
        }
        sessions.push(TmuxSessionSummary {
            name: String::from_utf8(fields[0].clone())?,
            window_count: std::str::from_utf8(&fields[1])?.parse()?,
            socket_path: String::from_utf8(fields[2].clone())?,
        });
    }
    sessions.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(sessions)
}

fn parse_fields(line: &[u8]) -> Result<Vec<Vec<u8>>> {
    let mut fields = Vec::with_capacity(SESSION_FIELD_COUNT);
    let mut field = Vec::new();
    let mut escaped = false;
    for &byte in line {
        if escaped {
            field.push(byte);
            escaped = false;
        } else if byte == b'\\' {
            escaped = true;
        } else if byte == SESSION_FIELD_SEPARATOR {
            fields.push(std::mem::take(&mut field));
        } else {
            field.push(byte);
        }
    }
    if escaped {
        bail!("tmux session row ended inside an escaped field");
    }
    fields.push(field);
    Ok(fields)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_fields_decode_tmux_q_escapes() {
        let sessions =
            parse_session_summaries(&[b"name\\|with\\ space|2|/tmp/tmux\\ socket".to_vec()])
                .unwrap();
        assert_eq!(
            sessions,
            [TmuxSessionSummary {
                name: "name|with space".to_owned(),
                window_count: 2,
                socket_path: "/tmp/tmux socket".to_owned(),
            }]
        );
        assert!(parse_session_summaries(&[b"broken|1|path\\".to_vec()]).is_err());
    }
}
