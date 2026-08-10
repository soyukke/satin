use std::{
    collections::BTreeMap,
    env,
    ffi::OsString,
    fs,
    os::unix::{ffi::OsStringExt, fs::PermissionsExt, process::CommandExt},
    path::{Path, PathBuf},
    process::Command,
};

use anyhow::{Context, Result, anyhow};
use satin::control::{ControlCommand, ControlRequest, send_control_request};

const LAUNCHER_VERSION_FLAG: &str = "--satin-launcher-version";
const SATIN_TUI_IMAGE_BRIDGE_LUA: &str = include_str!("../satin_tui_image_bridge.lua");

fn main() {
    let arguments = env::args_os().skip(1).collect::<Vec<_>>();
    if arguments.len() == 1 && arguments[0] == LAUNCHER_VERSION_FLAG {
        println!("satin-nvim {}", env!("CARGO_PKG_VERSION"));
        return;
    }

    let real_nvim = resolve_real_nvim().unwrap_or_else(|error| {
        eprintln!("satin-nvim: {error:#}");
        std::process::exit(127);
    });
    if let Some(exit_code) = try_native_launch(&real_nvim, &arguments) {
        std::process::exit(exit_code);
    }
    let arguments = terminal_nvim_arguments(&arguments);
    exec_real_nvim(&real_nvim, &arguments);
}

fn try_native_launch(real_nvim: &Path, arguments: &[OsString]) -> Option<i32> {
    if !native_launch_environment_is_safe() || arguments_require_terminal_mode(arguments) {
        return None;
    }
    let pane = env::var("SATIN_PANE_ID").ok()?.parse::<usize>().ok()?;
    let socket = PathBuf::from(env::var_os("SATIN_SOCKET")?);
    let cwd = env::current_dir()
        .ok()?
        .into_os_string()
        .into_string()
        .ok()?;
    let executable = real_nvim.as_os_str().to_owned().into_string().ok()?;
    let arguments = arguments
        .iter()
        .cloned()
        .map(OsString::into_string)
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    let environment = env::vars_os()
        .filter_map(|(key, value)| Some((key.into_string().ok()?, value.into_string().ok()?)))
        .collect::<BTreeMap<_, _>>();
    let request = ControlRequest::new(ControlCommand::OpenNeovim {
        pane,
        cwd,
        executable,
        arguments,
        environment,
    });
    let response = send_control_request(&socket, &request).ok()?;
    if !response.ok {
        return None;
    }
    Some(
        response
            .result
            .as_ref()
            .and_then(|result| result.get("exitCode"))
            .and_then(serde_json::Value::as_i64)
            .and_then(|code| i32::try_from(code).ok())
            .unwrap_or(0),
    )
}

fn native_launch_environment_is_safe() -> bool {
    if !stdin_and_stdout_are_terminals()
        || environment_flag("SATIN_NVIM_TUI")
        || env::var_os("TMUX").is_some()
        || env::var_os("STY").is_some()
        || env::var_os("SSH_TTY").is_some()
        || env::var_os("SSH_CONNECTION").is_some()
    {
        return false;
    }
    let Some(expected_shell) = env::var_os("SATIN_SHELL_EXECUTABLE").map(PathBuf::from) else {
        return false;
    };
    parent_executable().is_some_and(|parent| same_executable(&parent, &expected_shell))
}

fn stdin_and_stdout_are_terminals() -> bool {
    // SAFETY: isatty only inspects the two process-owned standard file descriptors.
    unsafe { libc::isatty(libc::STDIN_FILENO) == 1 && libc::isatty(libc::STDOUT_FILENO) == 1 }
}

fn environment_flag(key: &str) -> bool {
    env::var(key).is_ok_and(|value| {
        !value.is_empty() && !matches!(value.to_ascii_lowercase().as_str(), "0" | "false" | "no")
    })
}

fn arguments_require_terminal_mode(arguments: &[OsString]) -> bool {
    arguments.iter().any(|argument| {
        let Some(argument) = argument.to_str() else {
            return true;
        };
        matches!(
            argument,
            "-" | "-e"
                | "-E"
                | "-es"
                | "-Es"
                | "-s"
                | "-v"
                | "--embed"
                | "--headless"
                | "--api-info"
                | "--version"
                | "-h"
                | "--help"
        ) || argument == "--server"
            || argument.starts_with("--server=")
            || argument.starts_with("--remote")
    })
}

fn terminal_nvim_arguments(arguments: &[OsString]) -> Vec<OsString> {
    if env::var_os("TMUX").is_none()
        || !stdin_and_stdout_are_terminals()
        || arguments_require_terminal_mode(arguments)
    {
        return arguments.to_vec();
    }
    let mut bridged = Vec::with_capacity(arguments.len() + 2);
    bridged.push("--cmd".into());
    bridged.push(tui_image_bridge_command().into());
    bridged.extend_from_slice(arguments);
    bridged
}

fn tui_image_bridge_command() -> String {
    format!("lua assert(load({SATIN_TUI_IMAGE_BRIDGE_LUA:?}))()")
}

fn resolve_real_nvim() -> Result<PathBuf> {
    let current = env::current_exe().context("resolve launcher executable")?;
    let current = fs::canonicalize(&current).unwrap_or(current);
    let path = env::var_os("PATH").ok_or_else(|| anyhow!("PATH is not set"))?;
    for directory in env::split_paths(&path) {
        let candidate = directory.join("nvim");
        if !is_executable_file(&candidate) {
            continue;
        }
        let resolved = fs::canonicalize(&candidate).unwrap_or(candidate);
        if resolved != current {
            return Ok(resolved);
        }
    }
    Err(anyhow!(
        "could not find the real nvim after the Satin launcher"
    ))
}

fn is_executable_file(path: &Path) -> bool {
    path.metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

fn same_executable(first: &Path, second: &Path) -> bool {
    match (fs::canonicalize(first), fs::canonicalize(second)) {
        (Ok(first), Ok(second)) => first == second,
        _ => first.file_name() == second.file_name(),
    }
}

#[cfg(target_os = "macos")]
fn parent_executable() -> Option<PathBuf> {
    let mut buffer = vec![0_u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: proc_pidpath writes at most buffer.len() bytes to this valid allocation.
    let length = unsafe {
        libc::proc_pidpath(
            libc::getppid(),
            buffer.as_mut_ptr().cast(),
            u32::try_from(buffer.len()).ok()?,
        )
    };
    if length <= 0 {
        return None;
    }
    buffer.truncate(usize::try_from(length).ok()?);
    Some(PathBuf::from(OsString::from_vec(buffer)))
}

#[cfg(all(unix, not(target_os = "macos")))]
fn parent_executable() -> Option<PathBuf> {
    fs::read_link(format!("/proc/{}/exe", unsafe { libc::getppid() })).ok()
}

fn exec_real_nvim(real_nvim: &Path, arguments: &[OsString]) -> ! {
    let error = Command::new(real_nvim).args(arguments).exec();
    eprintln!(
        "satin-nvim: failed to execute {}: {error}",
        real_nvim.display()
    );
    std::process::exit(126)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interactive_arguments_use_native_mode() {
        assert!(!arguments_require_terminal_mode(&[
            "-u".into(),
            "NONE".into(),
            "+set number".into(),
            "file with spaces".into(),
        ]));
    }

    #[test]
    fn non_ui_and_stdin_arguments_keep_real_terminal_semantics() {
        for argument in ["--headless", "--embed", "--version", "--remote-expr", "-"] {
            assert!(arguments_require_terminal_mode(&[argument.into()]));
        }
    }

    #[test]
    fn launcher_and_shell_paths_compare_by_identity_or_name() {
        assert!(same_executable(
            Path::new("/bin/zsh"),
            Path::new("/bin/zsh")
        ));
        assert!(!same_executable(
            Path::new("/bin/zsh"),
            Path::new("/bin/bash")
        ));
    }

    #[test]
    fn tui_image_bridge_command_preloads_the_kitty_transport() {
        let command = tui_image_bridge_command();
        assert!(command.starts_with("lua assert(load("));
        assert!(command.contains("satin_features"));
        assert!(command.contains("kitty_graphics = true"));
        assert!(!command.contains("vim.g.satin_kitty_graphics"));
        assert!(command.contains("image/backends/kitty/helpers"));
        assert!(command.contains("transmit_medium.direct"));
        assert!(command.ends_with(")()"));
    }
}
