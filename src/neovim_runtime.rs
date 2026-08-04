use std::{
    collections::BTreeMap,
    env,
    io::{BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver},
    thread,
    time::Duration,
};

#[cfg(target_os = "macos")]
use std::os::fd::AsRawFd;
#[cfg(unix)]
use std::os::unix::process::{CommandExt, ExitStatusExt};

use anyhow::{Result, anyhow};
use rmpv::{Value, decode::read_value, encode::write_value};

use crate::{
    neovide_render::NeovideRendererModelSnapshot,
    neovim_editor::{NeovimEditor, NeovimMessageSelectionResult},
    terminal_runtime::TerminalGridSize,
    wakeup::{WakeupReceiver, WakeupSender},
};

#[cfg(target_os = "macos")]
const F_SETNOSIGPIPE: libc::c_int = 73;

pub struct NativeNeovimRuntime {
    process: NeovimProcess,
    rx: Receiver<Value>,
    next_msg_id: u64,
    editor: NeovimEditor,
    pending_message_selection_text: Option<String>,
    exited: bool,
    exit_code: Option<i32>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct NeovimLaunchOptions {
    pub cwd: Option<PathBuf>,
    pub executable: Option<PathBuf>,
    pub arguments: Vec<String>,
    pub environment: BTreeMap<String, String>,
}

impl NativeNeovimRuntime {
    pub fn spawn(size: TerminalGridSize) -> Result<Self> {
        Self::spawn_in_directory(size, None)
    }

    pub fn spawn_in_directory(size: TerminalGridSize, cwd: Option<PathBuf>) -> Result<Self> {
        Self::spawn_with_options(
            size,
            NeovimLaunchOptions {
                cwd,
                ..NeovimLaunchOptions::default()
            },
        )
    }

    pub fn spawn_with_options(
        size: TerminalGridSize,
        options: NeovimLaunchOptions,
    ) -> Result<Self> {
        let initial_cwd = options.cwd.or_else(|| env::current_dir().ok());
        let (process, rx) = NeovimProcess::spawn(
            initial_cwd.as_deref(),
            options.executable.as_deref(),
            &options.arguments,
            &options.environment,
        )?;
        let mut runtime = Self {
            process,
            rx,
            next_msg_id: 1,
            editor: NeovimEditor::new(size.cols, size.rows),
            pending_message_selection_text: None,
            exited: false,
            exit_code: None,
        };
        runtime.attach(size)?;
        if let Some(cwd) = initial_cwd {
            runtime.set_current_directory(&cwd)?;
        }
        Ok(runtime)
    }

    pub fn resize(&mut self, size: TerminalGridSize) -> Result<()> {
        self.editor.resize_screen(size.cols, size.rows);
        self.request(
            "nvim_ui_try_resize",
            vec![size.cols.into(), size.rows.into()],
        )
    }

    pub fn input_bytes(&mut self, bytes: &[u8]) -> Result<()> {
        let input = nvim_input_notation(bytes);
        if input.is_empty() {
            return Ok(());
        }
        self.request("nvim_input", vec![input.into()])
    }

    pub fn mouse_input(
        &mut self,
        button: &str,
        action: &str,
        modifier: &str,
        grid: i64,
        row: i64,
        col: i64,
    ) -> Result<bool> {
        if button == "left" && action == "press" {
            self.pending_message_selection_text = None;
        }
        if let Some(result) = self
            .editor
            .handle_message_selection(button, action, row, col)
        {
            if let NeovimMessageSelectionResult::Finished(text) = result {
                self.pending_message_selection_text = text;
            }
            return Ok(true);
        }
        self.request(
            "nvim_input_mouse",
            vec![
                button.into(),
                action.into(),
                modifier.into(),
                grid.into(),
                row.into(),
                col.into(),
            ],
        )?;
        Ok(false)
    }

    pub fn take_message_selection_text(&mut self) -> Option<String> {
        self.pending_message_selection_text.take()
    }

    pub fn command(&mut self, command: &str) -> Result<()> {
        self.request("nvim_command", vec![command.into()])
    }

    fn set_current_directory(&mut self, cwd: &Path) -> Result<()> {
        self.request(
            "nvim_set_current_dir",
            vec![cwd.to_string_lossy().into_owned().into()],
        )
    }

    pub fn drain(&mut self) -> Result<bool> {
        self.process.clear_wakeup();
        let mut changed = false;
        while let Ok(value) = self.rx.try_recv() {
            changed = self.handle_message(value) || changed;
        }
        let was_exited = self.exited;
        if self.refresh_exited() && !was_exited {
            changed = true;
        }
        Ok(changed)
    }

    pub fn wakeup_fd(&self) -> i32 {
        self.process.wakeup_fd()
    }

    pub fn is_exited(&mut self) -> bool {
        self.refresh_exited()
    }

    pub fn exit_code(&mut self) -> Option<i32> {
        self.refresh_exited();
        self.exit_code
    }

    pub fn renderer_model(&self) -> NeovideRendererModelSnapshot {
        self.editor.renderer_model()
    }

    pub fn renderer_model_with_pending_scroll(&mut self) -> NeovideRendererModelSnapshot {
        self.editor.renderer_model_with_pending_scroll()
    }

    pub fn advance_renderer_animations(&mut self, dt: f32) -> bool {
        self.editor.advance_renderer_animations(dt)
    }

    pub fn has_active_renderer_animation(&self) -> bool {
        self.editor.has_active_renderer_animation()
    }

    fn attach(&mut self, size: TerminalGridSize) -> Result<()> {
        let options = Value::Map(vec![
            ("ext_linegrid".into(), true.into()),
            ("ext_multigrid".into(), true.into()),
            ("ext_popupmenu".into(), true.into()),
            ("rgb".into(), true.into()),
        ]);
        self.request(
            "nvim_ui_attach",
            vec![size.cols.into(), size.rows.into(), options],
        )
    }

    fn request(&mut self, method: &str, args: Vec<Value>) -> Result<()> {
        if self.refresh_exited() {
            return Ok(());
        }
        let message = Value::Array(vec![
            0.into(),
            self.next_msg_id.into(),
            method.into(),
            Value::Array(args),
        ]);
        self.next_msg_id += 1;
        if let Err(error) = write_value(&mut self.process.stdin, &message) {
            self.refresh_exited();
            return Err(error.into());
        }
        if let Err(error) = self.process.stdin.flush() {
            self.refresh_exited();
            return Err(error.into());
        }
        Ok(())
    }

    fn refresh_exited(&mut self) -> bool {
        if !self.exited
            && let Some(exit_code) = self.process.poll_exit_code()
        {
            self.exited = true;
            self.exit_code = Some(exit_code);
        }
        self.exited
    }

    fn handle_message(&mut self, value: Value) -> bool {
        let Some(items) = value.as_array() else {
            return false;
        };
        if items.len() < 3 || items[0].as_i64() != Some(2) {
            return false;
        }
        if items[1].as_str() != Some("redraw") {
            return false;
        }
        self.handle_redraw_batches(&items[2])
    }

    fn handle_redraw_batches(&mut self, batches: &Value) -> bool {
        let Some(batches) = batches.as_array() else {
            return false;
        };
        let mut changed = false;
        for batch in batches {
            changed = self.handle_redraw_batch(batch) || changed;
        }
        changed
    }

    fn handle_redraw_batch(&mut self, batch: &Value) -> bool {
        let Some(items) = batch.as_array() else {
            return false;
        };
        let Some(event) = items.first().and_then(Value::as_str) else {
            return false;
        };
        if event == "flush" {
            self.editor.flush_renderer();
            return true;
        }
        let mut changed = false;
        for args in &items[1..] {
            changed = self.editor.handle_event(event, args) || changed;
        }
        changed
    }
}

struct NeovimProcess {
    child: Child,
    stdin: ChildStdin,
    wakeup: WakeupReceiver,
    reader_thread: Option<thread::JoinHandle<()>>,
    reader_done: Receiver<()>,
}

impl NeovimProcess {
    fn spawn(
        cwd: Option<&Path>,
        executable: Option<&Path>,
        arguments: &[String],
        environment: &BTreeMap<String, String>,
    ) -> Result<(Self, Receiver<Value>)> {
        let mut command = Command::new(
            executable
                .map(Path::to_path_buf)
                .unwrap_or_else(|| PathBuf::from(nvim_command())),
        );
        configure_process_group(&mut command);
        configure_working_directory(&mut command, cwd);
        command.envs(environment);
        let mut child = command
            .arg("--embed")
            .arg("--cmd")
            .arg("let g:neovide = v:true")
            .arg("--cmd")
            .arg("let g:satin = v:true")
            .arg("--cmd")
            .arg("let g:auto_session_enabled = v:false")
            .args(arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("nvim stdin unavailable"))?;
        disable_sigpipe(&stdin);
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("nvim stdout unavailable"))?;
        let (tx, rx) = mpsc::channel();
        let (wakeup, wakeup_sender) = crate::wakeup::pipe()?;
        let (done_tx, reader_done) = mpsc::channel();
        let reader_thread = thread::spawn(move || {
            read_msgpack_loop(stdout, tx, &wakeup_sender);
            wakeup_sender.notify();
            let _ = done_tx.send(());
        });
        Ok((
            Self {
                child,
                stdin,
                wakeup,
                reader_thread: Some(reader_thread),
                reader_done,
            },
            rx,
        ))
    }
}

impl Drop for NeovimProcess {
    fn drop(&mut self) {
        terminate_process_tree(&mut self.child);
        if self
            .reader_done
            .recv_timeout(Duration::from_secs(1))
            .is_ok()
            && let Some(reader_thread) = self.reader_thread.take()
        {
            let _ = reader_thread.join();
        }
    }
}

impl NeovimProcess {
    fn poll_exit_code(&mut self) -> Option<i32> {
        match self.child.try_wait() {
            Ok(Some(status)) => Some(exit_status_code(status)),
            Ok(None) => None,
            Err(_) => Some(1),
        }
    }

    fn wakeup_fd(&self) -> i32 {
        self.wakeup.fd()
    }

    fn clear_wakeup(&self) {
        self.wakeup.clear();
    }
}

#[cfg(unix)]
fn exit_status_code(status: std::process::ExitStatus) -> i32 {
    status
        .code()
        .or_else(|| status.signal().map(|signal| 128_i32.saturating_add(signal)))
        .unwrap_or(1)
}

#[cfg(not(unix))]
fn exit_status_code(status: std::process::ExitStatus) -> i32 {
    status.code().unwrap_or(1)
}

#[cfg(target_os = "macos")]
fn disable_sigpipe(stdin: &ChildStdin) {
    // SAFETY: fcntl only reads the file descriptor value and sets a Darwin pipe flag.
    let _ = unsafe { libc::fcntl(stdin.as_raw_fd(), F_SETNOSIGPIPE, 1) };
}

#[cfg(not(target_os = "macos"))]
fn disable_sigpipe(_stdin: &ChildStdin) {}

#[cfg(unix)]
fn configure_process_group(command: &mut Command) {
    command.process_group(0);
}

#[cfg(not(unix))]
fn configure_process_group(_command: &mut Command) {}

fn configure_working_directory(command: &mut Command, cwd: Option<&Path>) {
    let Some(cwd) = cwd else {
        return;
    };
    command.current_dir(cwd);
    command.env("PWD", cwd);
}

#[cfg(unix)]
fn terminate_process_tree(child: &mut Child) {
    if wait_for_child_exit(child) {
        return;
    }
    let Ok(pid) = i32::try_from(child.id()) else {
        let _ = child.kill();
        return;
    };
    signal_process_group(pid, libc::SIGTERM);
    if wait_for_child_exit(child) {
        return;
    }
    signal_process_group(pid, libc::SIGKILL);
    let _ = child.wait();
}

#[cfg(not(unix))]
fn terminate_process_tree(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(unix)]
fn signal_process_group(pid: i32, signal: i32) {
    // SAFETY: `kill` is called with a process-group id and does not dereference pointers.
    unsafe {
        libc::kill(-pid, signal);
    }
}

fn wait_for_child_exit(child: &mut Child) -> bool {
    for _ in 0..20 {
        match child.try_wait() {
            Ok(Some(_)) => return true,
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(_) => return true,
        }
    }
    false
}

fn read_msgpack_loop(
    stdout: std::process::ChildStdout,
    tx: mpsc::Sender<Value>,
    wakeup: &WakeupSender,
) {
    let mut reader = BufReader::new(stdout);
    while let Ok(value) = read_value(&mut reader) {
        if tx.send(value).is_err() {
            break;
        }
        wakeup.notify();
    }
}

fn nvim_command() -> String {
    env::var("SATIN_NVIM")
        .or_else(|_| env::var("NVTERM_NVIM"))
        .unwrap_or_else(|_| "nvim".to_owned())
}

fn nvim_input_notation(bytes: &[u8]) -> String {
    let mut output = String::new();
    let mut index = 0;
    while index < bytes.len() {
        if let Some((notation, consumed)) = special_key(&bytes[index..]) {
            output.push_str(notation);
            index += consumed;
            continue;
        }
        if bytes[index].is_ascii_control() {
            push_control_notation(bytes[index], &mut output);
            index += 1;
            continue;
        }
        let end = printable_run_end(bytes, index);
        output.push_str(&escape_nvim_input(&String::from_utf8_lossy(
            &bytes[index..end],
        )));
        index = end;
    }
    output
}

fn special_key(bytes: &[u8]) -> Option<(&'static str, usize)> {
    for (sequence, notation) in [
        (b"\x1b[A".as_slice(), "<Up>"),
        (b"\x1b[B".as_slice(), "<Down>"),
        (b"\x1b[C".as_slice(), "<Right>"),
        (b"\x1b[D".as_slice(), "<Left>"),
        (b"\x1b[H".as_slice(), "<Home>"),
        (b"\x1b[F".as_slice(), "<End>"),
        (b"\x1b[3~".as_slice(), "<Del>"),
        (b"\x1b[5~".as_slice(), "<PageUp>"),
        (b"\x1b[6~".as_slice(), "<PageDown>"),
    ] {
        if bytes.starts_with(sequence) {
            return Some((notation, sequence.len()));
        }
    }
    None
}

fn push_control_notation(byte: u8, output: &mut String) {
    match byte {
        b'\r' | b'\n' => output.push_str("<CR>"),
        b'\t' => output.push_str("<Tab>"),
        0x1b => output.push_str("<Esc>"),
        0x7f | 0x08 => output.push_str("<BS>"),
        1..=26 => {
            output.push_str("<C-");
            output.push(char::from(b'a' + byte - 1));
            output.push('>');
        }
        _ => {}
    }
}

fn printable_run_end(bytes: &[u8], start: usize) -> usize {
    let mut end = start;
    while end < bytes.len() && !bytes[end].is_ascii_control() {
        end += 1;
    }
    end
}

fn escape_nvim_input(input: &str) -> String {
    input.replace('<', "<lt>")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_terminal_control_bytes_to_nvim_notation() {
        assert_eq!(nvim_input_notation(&[0x10]), "<C-p>");
        assert_eq!(nvim_input_notation(b"\x1b[A"), "<Up>");
        assert_eq!(nvim_input_notation(b":edit file\r"), ":edit file<CR>");
    }
}
