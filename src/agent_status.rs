use anyhow::{Result, bail};
use serde::Deserialize;
use serde_json::Value;

pub const MAX_AGENT_EVENT_BYTES: usize = 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentPaneStatus {
    pub status: &'static str,
    pub summary: &'static str,
}

#[derive(Debug, Deserialize)]
struct ClaudeHookEvent {
    hook_event_name: String,
    #[serde(default)]
    background_tasks: Vec<Value>,
    #[serde(default)]
    session_crons: Vec<Value>,
}

pub fn agent_pane_status(agent: &str, input: &[u8]) -> Result<AgentPaneStatus> {
    if input.len() > MAX_AGENT_EVENT_BYTES {
        bail!("agent event exceeds {MAX_AGENT_EVENT_BYTES} bytes");
    }
    match agent {
        "claude" => claude_pane_status(serde_json::from_slice(input)?),
        _ => bail!("unsupported agent {agent:?}"),
    }
}

fn claude_pane_status(event: ClaudeHookEvent) -> Result<AgentPaneStatus> {
    let status = match event.hook_event_name.as_str() {
        "SessionStart" => AgentPaneStatus {
            status: "idle",
            summary: "Claude Code ready",
        },
        "UserPromptSubmit" => AgentPaneStatus {
            status: "running",
            summary: "Claude Code working",
        },
        "PermissionRequest" => AgentPaneStatus {
            status: "waiting",
            summary: "Claude Code needs approval",
        },
        "Elicitation" => AgentPaneStatus {
            status: "waiting",
            summary: "Claude Code needs input",
        },
        "Stop" if event.background_tasks.is_empty() && event.session_crons.is_empty() => {
            AgentPaneStatus {
                status: "done",
                summary: "Claude Code finished",
            }
        }
        "Stop" => AgentPaneStatus {
            status: "running",
            summary: "Claude Code background work",
        },
        "StopFailure" => AgentPaneStatus {
            status: "failed",
            summary: "Claude Code failed",
        },
        "SessionEnd" => AgentPaneStatus {
            status: "idle",
            summary: "Claude Code exited",
        },
        event => bail!("unsupported Claude Code hook event {event:?}"),
    };
    Ok(status)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(input: &str) -> AgentPaneStatus {
        agent_pane_status("claude", input.as_bytes()).unwrap()
    }

    #[test]
    fn maps_claude_turn_lifecycle_without_copying_prompt_content() {
        assert_eq!(
            status(r#"{"hook_event_name":"SessionStart","cwd":"/private"}"#),
            AgentPaneStatus {
                status: "idle",
                summary: "Claude Code ready",
            }
        );
        assert_eq!(
            status(r#"{"hook_event_name":"UserPromptSubmit","prompt":"do not expose this"}"#),
            AgentPaneStatus {
                status: "running",
                summary: "Claude Code working",
            }
        );
        assert_eq!(
            status(r#"{"hook_event_name":"Stop","last_assistant_message":"private"}"#),
            AgentPaneStatus {
                status: "done",
                summary: "Claude Code finished",
            }
        );
    }

    #[test]
    fn distinguishes_attention_failure_and_background_work() {
        assert_eq!(
            status(r#"{"hook_event_name":"PermissionRequest"}"#).status,
            "waiting"
        );
        assert_eq!(
            status(r#"{"hook_event_name":"StopFailure","error":"rate_limit"}"#).status,
            "failed"
        );
        assert_eq!(
            status(r#"{"hook_event_name":"Stop","background_tasks":[{"id":"1"}]}"#).status,
            "running"
        );
        assert_eq!(
            status(r#"{"hook_event_name":"Stop","session_crons":[{"id":"1"}]}"#).status,
            "running"
        );
    }

    #[test]
    fn rejects_unknown_agents_events_and_oversized_input() {
        assert!(agent_pane_status("other", b"{}").is_err());
        assert!(status_for_unknown_event().is_err());
        assert!(agent_pane_status("claude", &vec![b' '; MAX_AGENT_EVENT_BYTES + 1]).is_err());
    }

    fn status_for_unknown_event() -> Result<AgentPaneStatus> {
        agent_pane_status("claude", br#"{"hook_event_name":"FutureEvent"}"#)
    }
}
