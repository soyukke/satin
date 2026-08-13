use std::{env, path::Path};

use anyhow::{Result, bail};
use portable_pty::CommandBuilder;

use super::{TerminalSpawnConfig, terminal_locale};

const MAX_STARTUP_ARGUMENTS: usize = 256;
const MAX_STARTUP_BYTES: usize = 64 * 1024;

pub(super) fn configure_shell_command(
    command: &mut CommandBuilder,
    config: &TerminalSpawnConfig,
    shell: &str,
) {
    command.arg("-l");
    command.arg("-i");
    configure_terminal_environment(command, config, shell);
    configure_zsh_integration(command, config, shell);
}

pub(super) fn configure_terminal_environment(
    command: &mut CommandBuilder,
    config: &TerminalSpawnConfig,
    shell: &str,
) {
    if let Some(cwd) = config.cwd.clone().or_else(|| env::current_dir().ok()) {
        command.cwd(&cwd);
        command.env("PWD", cwd);
    }
    let locale = terminal_locale();
    command.env_remove("LC_ALL");
    // Launcher-side presentation preferences describe the parent process, not
    // the new terminal. Shell startup files can still opt back into NO_COLOR.
    command.env_remove("NO_COLOR");
    command.env("LANG", &locale);
    command.env("LC_CTYPE", &locale);
    command.env("TERM", "xterm-256color");
    command.env("COLORTERM", "truecolor");
    command.env("TERM_PROGRAM", "satin");
    command.env("TERM_PROGRAM_VERSION", env!("CARGO_PKG_VERSION"));
    command.env("SHELL", shell);
    command.env("SATIN_PROTO", "libghostty-vt");
    command.env("NVTERM_PROTO", "libghostty-vt");
    for (key, value) in &config.environment {
        if allowed_terminal_environment_key(key) {
            command.env(key, value);
        }
    }
    command.env("SATIN_SHELL_EXECUTABLE", shell);
}

pub(super) fn direct_startup_command(arguments: &[String]) -> Result<CommandBuilder> {
    let Some(arguments) = validated_startup_command(arguments)? else {
        bail!("direct terminal startup requires a command");
    };
    let mut command = CommandBuilder::new(&arguments[0]);
    for argument in &arguments[1..] {
        command.arg(argument);
    }
    Ok(command)
}

pub(super) fn startup_command_input(arguments: &[String]) -> Result<Option<Vec<u8>>> {
    let Some(arguments) = validated_startup_command(arguments)? else {
        return Ok(None);
    };
    let mut input = arguments
        .iter()
        .map(|argument| shell_quote(argument))
        .collect::<Vec<_>>()
        .join(" ")
        .into_bytes();
    input.extend_from_slice(b"; exit $?\r");
    if input.len() > MAX_STARTUP_BYTES {
        bail!("terminal startup command is too large");
    }
    Ok(Some(input))
}

fn validated_startup_command(arguments: &[String]) -> Result<Option<&[String]>> {
    if arguments.is_empty() {
        return Ok(None);
    }
    let argument_bytes = arguments.iter().fold(0_usize, |total, argument| {
        total.saturating_add(argument.len()).saturating_add(1)
    });
    if arguments.len() > MAX_STARTUP_ARGUMENTS
        || argument_bytes > MAX_STARTUP_BYTES
        || arguments[0].is_empty()
        || arguments
            .iter()
            .any(|argument| argument.chars().any(char::is_control))
    {
        bail!("invalid terminal startup command");
    }
    Ok(Some(arguments))
}

fn shell_quote(value: &str) -> String {
    let mut quoted = String::with_capacity(value.len().saturating_add(2));
    quoted.push('\'');
    for character in value.chars() {
        if character == '\'' {
            quoted.push_str("'\\''");
        } else {
            quoted.push(character);
        }
    }
    quoted.push('\'');
    quoted
}

fn configure_zsh_integration(
    command: &mut CommandBuilder,
    config: &TerminalSpawnConfig,
    shell: &str,
) {
    if Path::new(shell).file_name().and_then(|name| name.to_str()) != Some("zsh") {
        return;
    }
    let Some(integration) = config
        .environment
        .get("SATIN_ZSH_INTEGRATION_DIR")
        .map(Path::new)
        .filter(|path| path.is_absolute() && path.is_dir())
    else {
        return;
    };
    let original = resolve_user_zdotdir(
        env::var("SATIN_USER_ZDOTDIR").ok(),
        env::var("ZDOTDIR").ok(),
        env::var("HOME").ok(),
    );
    command.env("SATIN_USER_ZDOTDIR", original);
    command.env("ZDOTDIR", integration);
}

fn resolve_user_zdotdir(
    satin_user_zdotdir: Option<String>,
    zdotdir: Option<String>,
    home: Option<String>,
) -> String {
    [satin_user_zdotdir, zdotdir, home]
        .into_iter()
        .flatten()
        .find(|value| !value.is_empty())
        .unwrap_or_else(|| "/tmp".to_owned())
}

fn allowed_terminal_environment_key(key: &str) -> bool {
    key.starts_with("SATIN_") || key.starts_with("NVTERM_") || key == "PATH"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn startup_command_is_argv_quoted_and_exits_the_shell() {
        let input = startup_command_input(&[
            "nvim".to_owned(),
            "--".to_owned(),
            "/tmp/file with spaces.txt".to_owned(),
            "/tmp/it's-safe.txt".to_owned(),
            "/tmp/$(touch nope);still-safe.txt".to_owned(),
        ])
        .unwrap()
        .unwrap();
        assert_eq!(
            String::from_utf8(input).unwrap(),
            concat!(
                "'nvim' '--' '/tmp/file with spaces.txt' '/tmp/it'\\''s-safe.txt' ",
                "'/tmp/$(touch nope);still-safe.txt'; exit $?\r"
            )
        );
    }

    #[test]
    fn startup_command_rejects_invalid_or_oversized_argv() {
        assert!(startup_command_input(&[]).unwrap().is_none());
        assert!(startup_command_input(&[String::new()]).is_err());
        assert!(startup_command_input(&["nvim\0bad".to_owned()]).is_err());
        assert!(startup_command_input(&["nvim\nbad".to_owned()]).is_err());
        assert!(startup_command_input(&vec!["x".to_owned(); 257]).is_err());
        assert!(startup_command_input(&["x".repeat(64 * 1024)]).is_err());
    }

    #[test]
    fn direct_startup_requires_the_same_bounded_argv() {
        assert!(direct_startup_command(&[]).is_err());
        assert!(direct_startup_command(&["/bin/echo".to_owned(), "ready".to_owned()]).is_ok());
        assert!(direct_startup_command(&["bad\ncommand".to_owned()]).is_err());
        assert!(direct_startup_command(&["x".repeat(64 * 1024)]).is_err());
    }

    #[test]
    fn terminal_environment_allows_control_discovery_without_arbitrary_injection() {
        assert!(allowed_terminal_environment_key("SATIN_SOCKET"));
        assert!(allowed_terminal_environment_key("SATIN_CLI"));
        assert!(allowed_terminal_environment_key("NVTERM_SOCKET"));
        assert!(allowed_terminal_environment_key("PATH"));
        assert!(!allowed_terminal_environment_key("HOME"));
        assert!(!allowed_terminal_environment_key("DYLD_INSERT_LIBRARIES"));
    }

    #[test]
    fn nested_satin_shell_preserves_the_original_user_zdotdir() {
        assert_eq!(
            resolve_user_zdotdir(
                Some("/Users/tester".to_owned()),
                Some("/Applications/Satin.app/Contents/Resources/ShellIntegration/zsh".to_owned()),
                Some("/Users/tester".to_owned()),
            ),
            "/Users/tester"
        );
    }
}
