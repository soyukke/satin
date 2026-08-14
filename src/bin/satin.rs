use std::{
    env,
    io::{self, Read},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, anyhow, bail};
use satin::{
    agent_status::{MAX_AGENT_EVENT_BYTES, agent_pane_status},
    artifact::{
        ArtifactKind, ArtifactOverflow, RegisterArtifact, list_artifacts, load_manifest,
        load_policy, register_artifact, save_policy, view_artifact,
    },
    control::{
        ControlCommand, ControlRequest, ControlResponse, ControlSplitAxis, send_control_request,
    },
};
use serde_json::{Value, json};

const SATIN_SKILL: &str = include_str!("../../skills/satin/SKILL.md");

fn main() {
    if let Err(error) = run() {
        eprintln!("satin: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    if version_requested(&args) {
        println!("satin {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if help_requested(&args) {
        println!("{}", usage());
        return Ok(());
    }
    if args.first().is_some_and(|argument| argument == "skill") {
        args.remove(0);
        ensure_empty(&args)?;
        print!("{SATIN_SKILL}");
        return Ok(());
    }

    let socket_argument = extract_value(&mut args, "--socket").map(PathBuf::from);
    let json_output = remove_flag(&mut args, "--json");
    if args.first().is_some_and(|argument| argument == "artifact") {
        args.remove(0);
        let socket = resolve_socket(socket_argument)?;
        return run_artifact(&socket, &mut args, json_output);
    }

    let socket = resolve_socket(socket_argument)?;
    if args.first().is_some_and(|argument| argument == "identify") {
        args.remove(0);
        ensure_empty(&args)?;
        return identify(&socket, json_output);
    }
    let request = parse_request(&mut args)?;
    let response = send_control_request(&socket, &request)?;
    print_response(response, json_output)
}

fn resolve_socket(argument: Option<PathBuf>) -> Result<PathBuf> {
    argument
        .or_else(|| env::var_os("SATIN_SOCKET").map(PathBuf::from))
        .or_else(|| env::var_os("NVTERM_SOCKET").map(PathBuf::from))
        .or_else(default_socket_path)
        .ok_or_else(|| anyhow!("set SATIN_SOCKET or pass --socket PATH"))
}

fn run_artifact(socket: &Path, args: &mut Vec<String>, json_output: bool) -> Result<()> {
    let Some(command) = args.first().cloned() else {
        bail!(artifact_usage());
    };
    args.remove(0);
    match command.as_str() {
        "policy" => artifact_policy(socket, args, json_output),
        "add" => artifact_add(socket, args, json_output),
        "list" => artifact_list(socket, args, json_output),
        "show" => artifact_show(socket, args, json_output),
        "view" => artifact_view(socket, args),
        _ => bail!(
            "unknown artifact command {command:?}\n\n{}",
            artifact_usage()
        ),
    }
}

fn artifact_policy(socket: &Path, args: &mut Vec<String>, json_output: bool) -> Result<()> {
    let mut policy = load_policy(socket)?;
    let update = args.first().is_some_and(|argument| argument == "set");
    if update {
        args.remove(0);
        if let Some(value) = extract_value(args, "--max-columns") {
            policy.max_columns = value.parse().context("--max-columns must be an integer")?;
        }
        if let Some(value) = extract_value(args, "--max-rows") {
            policy.max_rows = value.parse().context("--max-rows must be an integer")?;
        }
        if let Some(value) = extract_value(args, "--language") {
            policy.language = value;
        }
        if let Some(value) = extract_value(args, "--overflow") {
            policy.overflow = value.parse::<ArtifactOverflow>()?;
        }
        save_policy(socket, &policy)?;
    }
    ensure_empty(args)?;
    let resolved_language = policy.resolved_language();
    print_response(
        ControlResponse::success(json!({
            "policy": policy,
            "resolvedLanguage": resolved_language,
        })),
        json_output,
    )
}

fn artifact_add(socket: &Path, args: &mut Vec<String>, json_output: bool) -> Result<()> {
    let id = extract_value(args, "--id");
    let kind = extract_value(args, "--kind")
        .ok_or_else(|| anyhow!("artifact add requires --kind KIND"))?
        .parse::<ArtifactKind>()?;
    let title = extract_value(args, "--title")
        .ok_or_else(|| anyhow!("artifact add requires --title TITLE"))?;
    let source = extract_value(args, "--file")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("artifact add requires --file PATH"))?;
    if !source.is_absolute() {
        bail!("artifact source path must be absolute");
    }
    let language = extract_value(args, "--language");
    let owner_pane = optional_identifier(args, "--pane", "SATIN_PANE_ID", "NVTERM_PANE_ID")?;
    let owner_tab = optional_identifier(args, "--tab", "SATIN_TAB_ID", "NVTERM_TAB_ID")?;
    ensure_empty(args)?;
    let policy = load_policy(socket)?;
    let manifest = register_artifact(
        socket,
        &policy,
        RegisterArtifact {
            id: id.as_deref(),
            kind,
            title: &title,
            language: language.as_deref(),
            source: &source,
            owner_tab,
            owner_pane,
        },
    )?;
    print_response(
        ControlResponse::success(serde_json::to_value(manifest)?),
        json_output,
    )
}

fn artifact_list(socket: &Path, args: &mut Vec<String>, json_output: bool) -> Result<()> {
    let limit = extract_value(args, "--limit")
        .map(|value| value.parse::<usize>().context("--limit must be an integer"))
        .transpose()?
        .unwrap_or(20);
    if !(1..=200).contains(&limit) {
        bail!("--limit must be between 1 and 200");
    }
    if args.len() > 1 {
        bail!("artifact list accepts at most one artifact ID");
    }
    let artifacts = list_artifacts(socket, None)?;
    if let Some(id) = args.first() {
        let item = artifacts
            .iter()
            .find(|artifact| artifact.id == *id)
            .ok_or_else(|| anyhow!("artifact {id} does not exist"))?;
        let versions = (1..=item.version_count)
            .rev()
            .take(limit)
            .map(|version| load_manifest(socket, &format!("{}@{version}", item.id)))
            .collect::<Result<Vec<_>>>()?;
        let text = versions
            .iter()
            .map(|version| {
                format!(
                    "v{}\t{}\t{} bytes",
                    version.version, version.created_at, version.source_bytes
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        return print_response(
            ControlResponse::success(json!({
                "artifact": item,
                "versions": versions,
                "text": text,
            })),
            json_output,
        );
    }
    let artifacts = artifacts.into_iter().take(limit).collect::<Vec<_>>();
    let text = if artifacts.is_empty() {
        "No artifacts.\n".to_owned()
    } else {
        artifacts
            .iter()
            .map(|artifact| {
                format!(
                    "{}\tv{}\t{}\t{}\t{}\t{}",
                    artifact.id,
                    artifact.version,
                    artifact.kind.as_str(),
                    artifact.updated_at,
                    artifact.title,
                    artifact.preview
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
            + "\n"
    };
    print_response(
        ControlResponse::success(json!({"artifacts": artifacts, "text": text})),
        json_output,
    )
}

fn artifact_show(socket: &Path, args: &mut Vec<String>, json_output: bool) -> Result<()> {
    let pane = pane_argument(args)?;
    let background = remove_flag(args, "--background");
    let vertical = remove_flag(args, "--vertical");
    let horizontal = remove_flag(args, "--horizontal");
    if vertical && horizontal {
        bail!("artifact show accepts at most one of --vertical or --horizontal");
    }
    if args.len() != 1 {
        bail!("artifact show requires one artifact ID");
    }
    let artifact = args.remove(0);
    load_manifest(socket, &artifact)?;
    let response = send_control_request(
        socket,
        &ControlRequest::new(ControlCommand::ArtifactShow {
            pane,
            artifact,
            axis: if horizontal {
                ControlSplitAxis::Horizontal
            } else {
                ControlSplitAxis::Vertical
            },
            background,
        }),
    )?;
    print_response(response, json_output)
}

fn artifact_view(socket: &Path, args: &mut Vec<String>) -> Result<()> {
    let no_wait = remove_flag(args, "--no-wait");
    if args.len() != 1 {
        bail!("artifact view requires one artifact ID");
    }
    view_artifact(socket, &args[0], !no_wait)
}

fn version_requested(args: &[String]) -> bool {
    args.len() == 1 && args[0] == "--version"
}

fn help_requested(args: &[String]) -> bool {
    args.len() == 1 && matches!(args[0].as_str(), "help" | "--help" | "-h")
}

fn identify(socket: &Path, json_output: bool) -> Result<()> {
    let tab_id = environment_identifier("SATIN_TAB_ID", "tab")?;
    let pane_id = environment_identifier("SATIN_PANE_ID", "pane")?;
    let response = send_control_request(socket, &ControlRequest::new(ControlCommand::List))?;
    if !response.ok {
        return print_response(response, json_output);
    }
    let result = response
        .result
        .ok_or_else(|| anyhow!("list response did not include a result"))?;
    let tab = result
        .get("tabs")
        .and_then(Value::as_array)
        .and_then(|tabs| find_identifier(tabs, tab_id))
        .cloned()
        .ok_or_else(|| anyhow!("SATIN_TAB_ID does not identify a live tab"))?;
    let pane = result
        .get("panes")
        .and_then(Value::as_array)
        .and_then(|panes| find_identifier(panes, pane_id))
        .cloned()
        .ok_or_else(|| anyhow!("SATIN_PANE_ID does not identify a live pane"))?;
    if pane.get("tab").and_then(Value::as_u64) != Some(tab_id as u64) {
        bail!("SATIN_TAB_ID and SATIN_PANE_ID do not identify the same live context");
    }
    print_response(
        ControlResponse::success(json!({
            "socket": socket,
            "tab": tab,
            "pane": pane,
        })),
        json_output,
    )
}

fn environment_identifier(key: &str, label: &str) -> Result<usize> {
    env::var(key)
        .with_context(|| format!("{key} is required; run this command inside a Satin pane"))?
        .parse::<usize>()
        .with_context(|| format!("invalid {label} identifier in {key}"))
}

fn find_identifier(values: &[Value], identifier: usize) -> Option<&Value> {
    values
        .iter()
        .find(|value| value.get("id").and_then(Value::as_u64) == Some(identifier as u64))
}

fn parse_request(args: &mut Vec<String>) -> Result<ControlRequest> {
    let Some(command) = args.first().cloned() else {
        bail!(usage());
    };
    args.remove(0);
    let command = match command.as_str() {
        "list" => parse_list(args)?,
        "read-screen" => parse_read_screen(args)?,
        "send" => parse_send(args)?,
        "key" => parse_key(args)?,
        "status" => parse_status(args)?,
        "new-tab" => parse_new_tab(args)?,
        "split" => parse_split(args)?,
        "select-tab" => parse_select_tab(args)?,
        "move-tab" => parse_move_tab(args)?,
        "close-tab" => parse_close_tab(args)?,
        "select-pane" => parse_select_pane(args)?,
        "close-pane" => parse_close_pane(args)?,
        "rename-tab" => parse_rename_tab(args)?,
        "set-theme" => parse_set_theme(args)?,
        _ => bail!("unknown command {command:?}\n\n{}", usage()),
    };
    Ok(ControlRequest::new(command))
}

fn parse_list(args: &[String]) -> Result<ControlCommand> {
    ensure_empty(args)?;
    Ok(ControlCommand::List)
}

fn parse_read_screen(args: &mut Vec<String>) -> Result<ControlCommand> {
    let pane = pane_argument(args)?;
    ensure_empty(args)?;
    Ok(ControlCommand::ReadScreen { pane })
}

fn parse_send(args: &mut Vec<String>) -> Result<ControlCommand> {
    let pane = pane_argument(args)?;
    if args.is_empty() {
        bail!("send requires TEXT or - for stdin");
    }
    let text = if args.len() == 1 && args[0] == "-" {
        let mut text = String::new();
        io::stdin().read_to_string(&mut text)?;
        text
    } else {
        args.join(" ")
    };
    Ok(ControlCommand::Send { pane, text })
}

fn parse_key(args: &mut Vec<String>) -> Result<ControlCommand> {
    let pane = pane_argument(args)?;
    if args.len() != 1 {
        bail!("key requires one key name");
    }
    Ok(ControlCommand::Key {
        pane,
        key: args.remove(0),
    })
}

fn parse_status(args: &mut Vec<String>) -> Result<ControlCommand> {
    let Some(subcommand) = args.first().cloned() else {
        bail!("status requires set, wait, event, or session-start");
    };
    args.remove(0);
    let pane = pane_argument(args)?;
    match subcommand.as_str() {
        "set" => parse_status_set(args, pane),
        "wait" => parse_status_wait(args, pane),
        "event" => parse_status_event(args, pane),
        "session-start" => parse_status_session_start(args, pane),
        _ => bail!("status requires set, wait, event, or session-start"),
    }
}

fn parse_status_event(args: &mut Vec<String>, pane: usize) -> Result<ControlCommand> {
    if args.len() != 1 {
        bail!("status event requires one agent name");
    }
    let agent = args.remove(0);
    let mut input = Vec::new();
    io::stdin()
        .take((MAX_AGENT_EVENT_BYTES + 1) as u64)
        .read_to_end(&mut input)?;
    let mapped = agent_pane_status(&agent, &input)?;
    Ok(ControlCommand::StatusSet {
        pane,
        status: mapped.status.to_owned(),
        summary: mapped.summary.to_owned(),
        agent_session_start: None,
    })
}

fn parse_status_session_start(args: &mut Vec<String>, pane: usize) -> Result<ControlCommand> {
    let summary = match args.as_slice() {
        [agent] if agent == "codex" => "Codex ready",
        [agent] if agent == "claude" => "Claude Code ready",
        _ => bail!("status session-start requires codex or claude"),
    };
    Ok(ControlCommand::StatusSet {
        pane,
        status: "idle".to_owned(),
        summary: summary.to_owned(),
        agent_session_start: Some(true),
    })
}

fn parse_status_set(args: &mut Vec<String>, pane: usize) -> Result<ControlCommand> {
    if args.is_empty() {
        bail!("status set requires STATUS [SUMMARY]");
    }
    let status = args.remove(0);
    let summary = args.join(" ");
    Ok(ControlCommand::StatusSet {
        pane,
        status,
        summary,
        agent_session_start: None,
    })
}

fn parse_status_wait(args: &mut Vec<String>, pane: usize) -> Result<ControlCommand> {
    let timeout_seconds = extract_value(args, "--timeout")
        .map(|value| value.parse::<u64>())
        .transpose()
        .context("--timeout must be whole seconds")?
        .unwrap_or(60)
        .min(60 * 60);
    ensure_empty(args)?;
    Ok(ControlCommand::StatusWait {
        pane,
        timeout_ms: timeout_seconds * 1_000,
    })
}

fn parse_new_tab(args: &mut Vec<String>) -> Result<ControlCommand> {
    let cwd = extract_value(args, "--cwd");
    let title = extract_value(args, "--title");
    let background = remove_flag(args, "--background");
    ensure_empty(args)?;
    Ok(ControlCommand::NewTab {
        cwd,
        title,
        background,
    })
}

fn parse_split(args: &mut Vec<String>) -> Result<ControlCommand> {
    let pane = pane_argument(args)?;
    let cwd = extract_value(args, "--cwd");
    let background = remove_flag(args, "--background");
    let vertical = remove_flag(args, "--vertical");
    let horizontal = remove_flag(args, "--horizontal");
    if vertical == horizontal {
        bail!("split requires exactly one of --vertical or --horizontal");
    }
    ensure_empty(args)?;
    Ok(ControlCommand::Split {
        pane,
        axis: if vertical {
            ControlSplitAxis::Vertical
        } else {
            ControlSplitAxis::Horizontal
        },
        cwd,
        background,
    })
}

fn parse_select_tab(args: &mut Vec<String>) -> Result<ControlCommand> {
    let tab = tab_argument(args)?;
    ensure_empty(args)?;
    Ok(ControlCommand::SelectTab { tab })
}

fn parse_move_tab(args: &mut Vec<String>) -> Result<ControlCommand> {
    let tab = tab_argument(args)?;
    let index = extract_value(args, "--index")
        .ok_or_else(|| anyhow!("move-tab requires --index INDEX"))?
        .parse::<usize>()
        .context("--index must be a zero-based integer")?;
    ensure_empty(args)?;
    Ok(ControlCommand::MoveTab { tab, index })
}

fn parse_close_tab(args: &mut Vec<String>) -> Result<ControlCommand> {
    let tab = tab_argument(args)?;
    ensure_empty(args)?;
    Ok(ControlCommand::CloseTab { tab })
}

fn parse_select_pane(args: &mut Vec<String>) -> Result<ControlCommand> {
    let pane = pane_argument(args)?;
    ensure_empty(args)?;
    Ok(ControlCommand::SelectPane { pane })
}

fn parse_close_pane(args: &mut Vec<String>) -> Result<ControlCommand> {
    let pane = pane_argument(args)?;
    ensure_empty(args)?;
    Ok(ControlCommand::ClosePane { pane })
}

fn parse_rename_tab(args: &mut Vec<String>) -> Result<ControlCommand> {
    let tab = tab_argument(args)?;
    if args.is_empty() {
        bail!("rename-tab requires TITLE");
    }
    Ok(ControlCommand::RenameTab {
        tab,
        title: args.join(" "),
    })
}

fn parse_set_theme(args: &mut Vec<String>) -> Result<ControlCommand> {
    let tab = tab_argument(args)?;
    if args.len() != 1 {
        bail!("set-theme requires THEME");
    }
    Ok(ControlCommand::SetTheme {
        tab,
        theme: args.remove(0),
    })
}

fn pane_argument(args: &mut Vec<String>) -> Result<usize> {
    numeric_argument(args, "--pane", "SATIN_PANE_ID", "NVTERM_PANE_ID", "pane")
}

fn tab_argument(args: &mut Vec<String>) -> Result<usize> {
    numeric_argument(args, "--tab", "SATIN_TAB_ID", "NVTERM_TAB_ID", "tab")
}

fn numeric_argument(
    args: &mut Vec<String>,
    flag: &str,
    environment: &str,
    legacy_environment: &str,
    label: &str,
) -> Result<usize> {
    extract_value(args, flag)
        .or_else(|| env::var(environment).ok())
        .or_else(|| env::var(legacy_environment).ok())
        .ok_or_else(|| anyhow!("pass {flag} or set {environment}"))?
        .parse::<usize>()
        .with_context(|| format!("invalid {label} identifier"))
}

fn optional_identifier(
    args: &mut Vec<String>,
    flag: &str,
    environment: &str,
    legacy_environment: &str,
) -> Result<Option<usize>> {
    extract_value(args, flag)
        .or_else(|| env::var(environment).ok())
        .or_else(|| env::var(legacy_environment).ok())
        .map(|value| {
            value
                .parse::<usize>()
                .with_context(|| format!("invalid identifier in {environment}"))
        })
        .transpose()
}

fn print_response(response: ControlResponse, json_output: bool) -> Result<()> {
    if json_output {
        println!("{}", serde_json::to_string_pretty(&response)?);
    }
    if !response.ok {
        let error = response
            .error
            .ok_or_else(|| anyhow!("request failed without an error"))?;
        bail!("{}: {}", error.code, error.message);
    }
    if json_output {
        return Ok(());
    }
    let result = response.result.unwrap_or(Value::Null);
    if let Some(text) = result.as_str().or_else(|| result.get("text")?.as_str()) {
        print!("{text}");
        if !text.ends_with('\n') {
            println!();
        }
    } else {
        println!("{}", serde_json::to_string_pretty(&result)?);
    }
    Ok(())
}

fn extract_value(args: &mut Vec<String>, flag: &str) -> Option<String> {
    let index = args.iter().position(|value| value == flag)?;
    if index + 1 >= args.len() {
        return None;
    }
    args.remove(index);
    Some(args.remove(index))
}

fn remove_flag(args: &mut Vec<String>, flag: &str) -> bool {
    let Some(index) = args.iter().position(|value| value == flag) else {
        return false;
    };
    args.remove(index);
    true
}

fn ensure_empty(args: &[String]) -> Result<()> {
    if !args.is_empty() {
        bail!("unexpected arguments: {}", args.join(" "));
    }
    Ok(())
}

fn default_socket_path() -> Option<PathBuf> {
    let home = env::var_os("HOME")?;
    Some(
        PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("Satin")
            .join("run")
            .join("control.sock"),
    )
}

fn usage() -> &'static str {
    "usage: satin --version
       satin skill
       satin [--socket PATH] [--json] COMMAND

commands:
  skill
  identify
  artifact policy [set [--max-columns N] [--max-rows N] [--language TAG]
                       [--overflow compact|defer|reject]]
  artifact add [--id ID] --kind KIND --title TITLE --file PATH [--language TAG]
  artifact list [ID] [--limit N]
  artifact show [--pane ID] ID [--background]
  artifact view ID [--no-wait]
  list
  read-screen [--pane ID]
  send [--pane ID] TEXT|-
  key [--pane ID] KEY
  status set [--pane ID] STATUS [SUMMARY]
  status wait [--pane ID] [--timeout SECONDS]
  status event [--pane ID] claude
  status session-start [--pane ID] codex|claude
  new-tab [--cwd PATH] [--title TITLE] [--background]
  split [--pane ID] --vertical|--horizontal [--cwd PATH] [--background]
  select-tab [--tab ID]
  move-tab [--tab ID] --index INDEX
  close-tab [--tab ID]
  select-pane [--pane ID]
  close-pane [--pane ID]
  rename-tab [--tab ID] TITLE
  set-theme [--tab ID] THEME"
}

fn artifact_usage() -> &'static str {
    "usage: satin artifact policy
       satin artifact policy set [--max-columns N] [--max-rows N]
                                 [--language TAG]
                                 [--overflow compact|defer|reject]
       satin artifact add [--id ID] --kind KIND --title TITLE --file PATH
                          [--language TAG] [--pane ID] [--tab ID]
       satin artifact list [ID] [--limit N]
       satin artifact show [--pane ID] ID [--background]
       satin artifact view ID [--no-wait]

kinds: text, markdown, table, tree, timeline, diff, image"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_explicitly_scoped_send() {
        let mut args = vec![
            "send".to_owned(),
            "--pane".to_owned(),
            "9".to_owned(),
            "hello".to_owned(),
        ];
        let request = parse_request(&mut args).unwrap();

        assert_eq!(
            request.command,
            ControlCommand::Send {
                pane: 9,
                text: "hello".to_owned()
            }
        );
    }

    #[test]
    fn parses_codex_session_start_marker() {
        let mut args = vec![
            "status".to_owned(),
            "session-start".to_owned(),
            "--pane".to_owned(),
            "4".to_owned(),
            "codex".to_owned(),
        ];

        assert_eq!(
            parse_request(&mut args).unwrap().command,
            ControlCommand::StatusSet {
                pane: 4,
                status: "idle".to_owned(),
                summary: "Codex ready".to_owned(),
                agent_session_start: Some(true),
            }
        );
    }

    #[test]
    fn parses_split_axis_and_directory() {
        let mut args = vec![
            "split".to_owned(),
            "--pane".to_owned(),
            "2".to_owned(),
            "--horizontal".to_owned(),
            "--cwd".to_owned(),
            "/tmp".to_owned(),
        ];

        assert_eq!(
            parse_request(&mut args).unwrap().command,
            ControlCommand::Split {
                pane: 2,
                axis: ControlSplitAxis::Horizontal,
                cwd: Some("/tmp".to_owned()),
                background: false,
            }
        );
    }

    #[test]
    fn parses_project_tab_options() {
        let mut args = vec![
            "new-tab".to_owned(),
            "--cwd".to_owned(),
            "/tmp/project".to_owned(),
            "--title".to_owned(),
            "project".to_owned(),
            "--background".to_owned(),
        ];

        assert_eq!(
            parse_request(&mut args).unwrap().command,
            ControlCommand::NewTab {
                cwd: Some("/tmp/project".to_owned()),
                title: Some("project".to_owned()),
                background: true,
            }
        );
    }

    #[test]
    fn parses_stable_tab_and_pane_operations() {
        let mut move_args = vec![
            "move-tab".to_owned(),
            "--tab".to_owned(),
            "7".to_owned(),
            "--index".to_owned(),
            "1".to_owned(),
        ];
        let mut close_args = vec!["close-pane".to_owned(), "--pane".to_owned(), "9".to_owned()];

        assert_eq!(
            parse_request(&mut move_args).unwrap().command,
            ControlCommand::MoveTab { tab: 7, index: 1 }
        );
        assert_eq!(
            parse_request(&mut close_args).unwrap().command,
            ControlCommand::ClosePane { pane: 9 }
        );
    }

    #[test]
    fn local_information_requests_are_exact() {
        assert!(version_requested(&["--version".to_owned()]));
        assert!(help_requested(&["--help".to_owned()]));
        assert!(!version_requested(&[]));
        assert!(!help_requested(&["--help".to_owned(), "list".to_owned()]));
    }

    #[test]
    fn bundled_skill_has_valid_core_metadata() {
        assert!(SATIN_SKILL.starts_with("---\nname: satin\ndescription: "));
        assert!(SATIN_SKILL.contains("\n---\n"));
        assert!(SATIN_SKILL.contains("satin artifact policy --json"));
        assert!(SATIN_SKILL.contains("satin artifact show"));
        assert!(SATIN_SKILL.contains("$artifact_id@$artifact_version"));
        assert!(!SATIN_SKILL.contains("$artifact_id@2"));
        assert!(!SATIN_SKILL.contains("TODO"));
    }
}
