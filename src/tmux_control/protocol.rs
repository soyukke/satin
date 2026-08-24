use super::TmuxPaneSnapshot;

#[derive(Clone, Debug, PartialEq)]
pub(super) enum PendingCommand {
    Initial,
    ControlClientCheck,
    Ignore,
    Snapshot,
    Sessions,
    Resume { pane_id: u32 },
    AlternateBacking { pane: TmuxPaneSnapshot },
    Capture { pane: TmuxPaneSnapshot },
}

#[derive(Debug)]
pub(super) struct CommandResponse {
    pub(super) kind: PendingCommand,
    pub(super) guard: Vec<u8>,
    pub(super) lines: Vec<Vec<u8>>,
    pub(super) bytes: usize,
}

pub(super) fn response_lines_lossy(lines: &[Vec<u8>], fallback: &str) -> String {
    if lines.is_empty() {
        return fallback.to_owned();
    }
    lines
        .iter()
        .map(|line| String::from_utf8_lossy(line))
        .collect::<Vec<_>>()
        .join("\n")
}

pub(super) fn topology_notification(line: &[u8]) -> bool {
    if line.starts_with(b"%subscription-changed satin-pane-title ") {
        return true;
    }
    [
        b"%session-changed ".as_slice(),
        b"%session-renamed ",
        b"%session-window-changed ",
        b"%sessions-changed",
        b"%window-add ",
        b"%window-close ",
        b"%window-renamed ",
        b"%window-pane-changed ",
        b"%layout-change ",
        b"%pane-exited ",
        b"%pane-mode-changed ",
    ]
    .iter()
    .any(|prefix| line.starts_with(prefix))
}
