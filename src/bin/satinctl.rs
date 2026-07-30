use std::{
    env,
    io::{self, BufReader, Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    time::Duration,
};

use anyhow::{Context, Result, anyhow, bail};
use satin::control::{ControlCommand, ControlRequest, ControlResponse, ControlSplitAxis};
use serde_json::Value;

fn main() {
    if let Err(error) = run() {
        eprintln!("satinctl: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    if version_requested(&args) {
        println!("satinctl {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    let socket = extract_value(&mut args, "--socket")
        .map(PathBuf::from)
        .or_else(|| env::var_os("SATIN_SOCKET").map(PathBuf::from))
        .or_else(|| env::var_os("NVTERM_SOCKET").map(PathBuf::from))
        .or_else(default_socket_path)
        .ok_or_else(|| anyhow!("set SATIN_SOCKET or pass --socket PATH"))?;
    let json_output = remove_flag(&mut args, "--json");
    let request = parse_request(&mut args)?;
    let response = send_request(&socket, &request)?;
    print_response(response, json_output)
}

fn version_requested(args: &[String]) -> bool {
    args.len() == 1 && args[0] == "--version"
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
        "rename-tab" => parse_rename_tab(args)?,
        "set-theme" => parse_set_theme(args)?,
        "help" | "--help" | "-h" => bail!(usage()),
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
        bail!("status requires set or wait");
    };
    args.remove(0);
    let pane = pane_argument(args)?;
    match subcommand.as_str() {
        "set" => parse_status_set(args, pane),
        "wait" => parse_status_wait(args, pane),
        _ => bail!("status requires set or wait"),
    }
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
    ensure_empty(args)?;
    Ok(ControlCommand::NewTab { cwd })
}

fn parse_split(args: &mut Vec<String>) -> Result<ControlCommand> {
    let pane = pane_argument(args)?;
    let cwd = extract_value(args, "--cwd");
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
    })
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

fn send_request(socket: &PathBuf, request: &ControlRequest) -> Result<ControlResponse> {
    let mut stream =
        UnixStream::connect(socket).with_context(|| format!("connect {}", socket.display()))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    serde_json::to_writer(&mut stream, request)?;
    stream.write_all(b"\n")?;
    stream.flush()?;
    stream.set_read_timeout(Some(request_timeout(request)))?;
    let reader = BufReader::new(stream.take(1024 * 1024));
    serde_json::from_reader(reader).context("decode control response")
}

fn request_timeout(request: &ControlRequest) -> Duration {
    match &request.command {
        ControlCommand::StatusWait { timeout_ms, .. } => {
            Duration::from_millis((*timeout_ms).min(60 * 60 * 1_000) + 5_000)
        }
        _ => Duration::from_secs(35),
    }
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
    "usage: satinctl --version
       satinctl [--socket PATH] [--json] COMMAND

commands:
  list
  read-screen [--pane ID]
  send [--pane ID] TEXT|-
  key [--pane ID] KEY
  status set [--pane ID] STATUS [SUMMARY]
  status wait [--pane ID] [--timeout SECONDS]
  new-tab [--cwd PATH]
  split [--pane ID] --vertical|--horizontal [--cwd PATH]
  rename-tab [--tab ID] TITLE
  set-theme [--tab ID] THEME"
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
                cwd: Some("/tmp".to_owned())
            }
        );
    }

    #[test]
    fn version_request_is_exact_and_does_not_require_socket_arguments() {
        assert!(version_requested(&["--version".to_owned()]));
        assert!(!version_requested(&[]));
        assert!(!version_requested(&[
            "--version".to_owned(),
            "--json".to_owned()
        ]));
    }
}
