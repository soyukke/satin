use super::{PendingCommand, TmuxControl, trim_ascii};

pub(super) const CONTROL_CLIENT_CHECK_COMMAND: &str =
    "list-clients -t '' -F '#{client_control_mode}' -f '#{client_control_mode}'";
pub(super) const SESSION_CLIENT_SUBSCRIPTION: &str =
    "satin-session-clients::#{session_attached_list}";

pub(super) fn session_clients_changed(line: &[u8]) -> bool {
    line.starts_with(b"%subscription-changed satin-session-clients ")
}

impl TmuxControl {
    pub(super) fn finish_initial_response(&mut self, succeeded: bool, lines: &[Vec<u8>]) {
        if succeeded {
            self.queue_control_client_check();
        } else {
            self.queue_terminal_error(lines);
        }
    }

    pub(super) fn finish_control_client_check(&mut self, succeeded: bool, lines: &[Vec<u8>]) {
        self.control_client_check_pending = false;
        let only_client = succeeded && lines.len() == 1 && trim_ascii(&lines[0]) == b"1";
        if only_client {
            if !self.control_client_admitted {
                self.control_client_admitted = true;
                self.sync_requested_while_pending = false;
                self.configure_flow_control();
                self.request_sync();
            }
        } else {
            self.fail_control(
                "this tmux session already has another control-mode client".to_owned(),
            );
        }
    }

    pub(super) fn recheck_control_clients(&mut self) {
        if self.control_client_admitted {
            self.queue_control_client_check();
        }
    }

    fn queue_control_client_check(&mut self) {
        if self.closing || self.control_client_check_pending {
            return;
        }
        self.control_client_check_pending = true;
        self.queue_command(
            CONTROL_CLIENT_CHECK_COMMAND.to_owned(),
            PendingCommand::ControlClientCheck,
        );
    }
}
