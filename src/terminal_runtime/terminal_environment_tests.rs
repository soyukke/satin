use super::*;
use std::ffi::OsStr;

#[test]
fn shell_environment_matches_the_selected_shell_without_assuming_zsh() {
    let config = TerminalSpawnConfig::default();
    for shell in ["/bin/sh", "/usr/local/bin/fish"] {
        let mut command = CommandBuilder::new(shell);
        configure_shell_command(&mut command, &config, shell);

        assert_eq!(command.get_env("SHELL"), Some(OsStr::new(shell)));
        assert_eq!(
            command.get_env("SATIN_SHELL_EXECUTABLE"),
            Some(OsStr::new(shell))
        );
    }
}

#[test]
fn terminal_environment_resets_parent_color_suppression_and_identity() {
    let config = TerminalSpawnConfig::default();
    let mut command = CommandBuilder::new("/bin/sh");
    command.env("NO_COLOR", "1");
    command.env("TERM_PROGRAM", "ghostty");
    command.env("TERM_PROGRAM_VERSION", "leaked");

    configure_shell_command(&mut command, &config, "/bin/sh");

    assert_eq!(command.get_env("NO_COLOR"), None);
    assert_eq!(command.get_env("TERM_PROGRAM"), Some(OsStr::new("satin")));
    assert_eq!(
        command.get_env("TERM_PROGRAM_VERSION"),
        Some(OsStr::new(env!("CARGO_PKG_VERSION")))
    );
}
