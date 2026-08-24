use anyhow::{Result, bail};
use serde::Serialize;

const SESSION_FIELD_COUNT: usize = 5;
const SESSION_FIELD_SEPARATOR: u8 = b'|';

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct TmuxSessionSummary {
    pub session_id: u32,
    pub name: String,
    pub window_count: u32,
    pub socket_path: String,
    pub server_pid: u32,
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
            session_id: parse_prefixed_u32(&fields[0], b'$')?,
            name: String::from_utf8(fields[1].clone())?,
            window_count: std::str::from_utf8(&fields[2])?.parse()?,
            socket_path: String::from_utf8(fields[3].clone())?,
            server_pid: std::str::from_utf8(&fields[4])?.parse()?,
        });
    }
    sessions.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(sessions)
}

fn parse_prefixed_u32(value: &[u8], prefix: u8) -> Result<u32> {
    let Some(value) = value.strip_prefix(&[prefix]) else {
        bail!("tmux session id omitted its prefix");
    };
    Ok(std::str::from_utf8(value)?.parse()?)
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
            parse_session_summaries(
                &[b"$7|name\\|with\\ space|2|/tmp/tmux\\ socket|4242".to_vec()],
            )
            .unwrap();
        assert_eq!(
            sessions,
            [TmuxSessionSummary {
                session_id: 7,
                name: "name|with space".to_owned(),
                window_count: 2,
                socket_path: "/tmp/tmux socket".to_owned(),
                server_pid: 4242,
            }]
        );
        assert!(parse_session_summaries(&[b"$0|broken|1|path\\".to_vec()]).is_err());
    }
}
