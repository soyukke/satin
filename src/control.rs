use std::{
    collections::{BTreeMap, HashMap},
    fs,
    io::{self, BufRead, BufReader, Read, Write},
    os::unix::{
        fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        mpsc::{self, Receiver, Sender},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::wakeup::{WakeupReceiver, WakeupSender};

pub const CONTROL_PROTOCOL_VERSION: u32 = 1;
const MAX_CONTROL_REQUEST_BYTES: u64 = 1024 * 1024;
const MAX_CONTROL_CLIENTS: usize = 32;
const DEFAULT_RESPONSE_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_WAIT_TIMEOUT_MS: u64 = 60 * 60 * 1000;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct ControlRequest {
    pub version: u32,
    #[serde(flatten)]
    pub command: ControlCommand,
}

impl ControlRequest {
    pub fn new(command: ControlCommand) -> Self {
        Self {
            version: CONTROL_PROTOCOL_VERSION,
            command,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(tag = "command", rename_all = "kebab-case")]
pub enum ControlCommand {
    List,
    ReadScreen {
        pane: usize,
    },
    Send {
        pane: usize,
        text: String,
    },
    Key {
        pane: usize,
        key: String,
    },
    StatusSet {
        pane: usize,
        status: String,
        summary: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        agent_session_start: Option<bool>,
    },
    StatusWait {
        pane: usize,
        timeout_ms: u64,
    },
    NewTab {
        cwd: Option<String>,
        title: Option<String>,
        #[serde(default)]
        background: bool,
    },
    Split {
        pane: usize,
        axis: ControlSplitAxis,
        cwd: Option<String>,
        #[serde(default)]
        background: bool,
    },
    ArtifactShow {
        pane: usize,
        artifact: String,
        axis: ControlSplitAxis,
        #[serde(default)]
        background: bool,
    },
    SelectTab {
        tab: usize,
    },
    MoveTab {
        tab: usize,
        index: usize,
    },
    CloseTab {
        tab: usize,
    },
    SelectPane {
        pane: usize,
    },
    ClosePane {
        pane: usize,
    },
    OpenNeovim {
        pane: usize,
        cwd: String,
        executable: String,
        arguments: Vec<String>,
        environment: BTreeMap<String, String>,
    },
    RenameTab {
        tab: usize,
        title: String,
    },
    SetTheme {
        tab: usize,
        theme: String,
    },
}

impl ControlCommand {
    fn response_timeout(&self) -> Option<Duration> {
        match self {
            Self::StatusWait { timeout_ms, .. } => Some(Duration::from_millis(
                (*timeout_ms).min(MAX_WAIT_TIMEOUT_MS) + 2_000,
            )),
            Self::OpenNeovim { .. } => None,
            _ => Some(DEFAULT_RESPONSE_TIMEOUT),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ControlSplitAxis {
    Vertical,
    Horizontal,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct ControlResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ControlResponseError>,
}

impl ControlResponse {
    pub fn success(result: Value) -> Self {
        Self {
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    pub fn failure(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            ok: false,
            result: None,
            error: Some(ControlResponseError {
                code: code.into(),
                message: message.into(),
            }),
        }
    }
}

pub fn send_control_request(path: &Path, request: &ControlRequest) -> Result<ControlResponse> {
    let mut stream =
        UnixStream::connect(path).with_context(|| format!("connect {}", path.display()))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    serde_json::to_writer(&mut stream, request)?;
    stream.write_all(b"\n")?;
    stream.flush()?;
    stream.set_read_timeout(request.command.response_timeout())?;
    let reader = BufReader::new(stream.take(MAX_CONTROL_REQUEST_BYTES));
    serde_json::from_reader(reader).context("decode control response")
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ControlResponseError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Serialize)]
pub struct ControlHostRequest {
    pub id: u64,
    #[serde(flatten)]
    pub request: ControlRequest,
}

struct PendingRequest {
    id: u64,
    request: ControlRequest,
    response: Sender<ControlResponse>,
}

pub struct ControlServer {
    socket_path: PathBuf,
    socket_parent_created: bool,
    incoming: Receiver<PendingRequest>,
    responders: HashMap<u64, Sender<ControlResponse>>,
    wakeup: WakeupReceiver,
    stopping: Arc<AtomicBool>,
    listener_thread: Option<JoinHandle<()>>,
}

impl ControlServer {
    pub fn start(path: impl Into<PathBuf>) -> Result<Self> {
        let socket_path = path.into();
        let socket_parent_created = prepare_socket_path(&socket_path)?;
        let listener = match UnixListener::bind(&socket_path) {
            Ok(listener) => listener,
            Err(error) => {
                remove_created_socket_parent(&socket_path, socket_parent_created);
                return Err(error)
                    .with_context(|| format!("bind control socket {}", socket_path.display()));
            }
        };
        if let Err(error) = fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600)) {
            let _ = fs::remove_file(&socket_path);
            remove_created_socket_parent(&socket_path, socket_parent_created);
            return Err(error.into());
        }
        let (incoming_tx, incoming) = mpsc::channel();
        let (wakeup, wakeup_tx) = crate::wakeup::pipe()?;
        let stopping = Arc::new(AtomicBool::new(false));
        let listener_thread =
            spawn_listener(listener, Arc::clone(&stopping), incoming_tx, wakeup_tx)?;
        Ok(Self {
            socket_path,
            socket_parent_created,
            incoming,
            responders: HashMap::new(),
            wakeup,
            stopping,
            listener_thread: Some(listener_thread),
        })
    }

    pub fn wakeup_fd(&self) -> i32 {
        self.wakeup.fd()
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    pub fn take_request(&mut self) -> Option<ControlHostRequest> {
        self.wakeup.clear();
        let pending = self.incoming.try_recv().ok()?;
        self.responders.insert(pending.id, pending.response);
        Some(ControlHostRequest {
            id: pending.id,
            request: pending.request,
        })
    }

    pub fn respond(&mut self, id: u64, response: ControlResponse) -> bool {
        self.responders
            .remove(&id)
            .is_some_and(|sender| sender.send(response).is_ok())
    }
}

impl Drop for ControlServer {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Release);
        let _ = UnixStream::connect(&self.socket_path);
        if let Some(thread) = self.listener_thread.take() {
            let _ = thread.join();
        }
        if socket_owned_by_current_user(&self.socket_path) {
            let _ = fs::remove_file(&self.socket_path);
        }
        remove_created_socket_parent(&self.socket_path, self.socket_parent_created);
    }
}

fn prepare_socket_path(path: &Path) -> Result<bool> {
    if !path.is_absolute() {
        bail!("control socket path must be absolute");
    }
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("control socket path has no parent"))?;
    let parent_created = !parent.exists();
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true).mode(0o700);
    builder.create(parent)?;
    let parent_metadata = fs::symlink_metadata(parent)?;
    if !parent_metadata.file_type().is_dir()
        || parent_metadata.uid() != effective_uid()
        || parent_metadata.permissions().mode() & 0o077 != 0
    {
        bail!(
            "control socket parent must be an owner-only directory: {}",
            parent.display()
        );
    }
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return Ok(parent_created);
    };
    if !metadata.file_type().is_socket() || metadata.uid() != effective_uid() {
        bail!(
            "refusing to replace unsafe control socket path {}",
            path.display()
        );
    }
    if UnixStream::connect(path).is_ok() {
        bail!("control socket is already in use: {}", path.display());
    }
    fs::remove_file(path)?;
    Ok(parent_created)
}

fn spawn_listener(
    listener: UnixListener,
    stopping: Arc<AtomicBool>,
    incoming: Sender<PendingRequest>,
    wakeup: WakeupSender,
) -> Result<JoinHandle<()>> {
    let next_id = Arc::new(AtomicU64::new(1));
    let clients = Arc::new(AtomicUsize::new(0));
    let wakeup = Arc::new(wakeup);
    thread::Builder::new()
        .name("nvterm-control-listener".to_owned())
        .spawn(move || {
            accept_loop(listener, stopping, incoming, wakeup, next_id, clients);
        })
        .context("spawn control listener")
}

fn accept_loop(
    listener: UnixListener,
    stopping: Arc<AtomicBool>,
    incoming: Sender<PendingRequest>,
    wakeup: Arc<WakeupSender>,
    next_id: Arc<AtomicU64>,
    clients: Arc<AtomicUsize>,
) {
    while let Ok((stream, _)) = listener.accept() {
        if stopping.load(Ordering::Acquire) {
            break;
        }
        if clients.fetch_add(1, Ordering::AcqRel) >= MAX_CONTROL_CLIENTS {
            clients.fetch_sub(1, Ordering::AcqRel);
            write_failure(stream, "too_many_clients", "too many control clients");
            continue;
        }
        spawn_client(
            stream,
            incoming.clone(),
            Arc::clone(&wakeup),
            Arc::clone(&next_id),
            Arc::clone(&clients),
        );
    }
}

fn spawn_client(
    stream: UnixStream,
    incoming: Sender<PendingRequest>,
    wakeup: Arc<WakeupSender>,
    next_id: Arc<AtomicU64>,
    clients: Arc<AtomicUsize>,
) {
    let client_count = Arc::clone(&clients);
    let result = thread::Builder::new()
        .name("nvterm-control-client".to_owned())
        .spawn(move || {
            let _guard = ClientCountGuard(client_count);
            if let Err(error) = handle_client(stream, incoming, wakeup.as_ref(), &next_id) {
                log::debug!(target: "control", "client_closed error={error:#}");
            }
        });
    if let Err(error) = result {
        clients.fetch_sub(1, Ordering::AcqRel);
        log::warn!(target: "control", "client_spawn_failed error={error}");
    }
}

struct ClientCountGuard(Arc<AtomicUsize>);

impl Drop for ClientCountGuard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

fn handle_client(
    mut stream: UnixStream,
    incoming: Sender<PendingRequest>,
    wakeup: &WakeupSender,
    next_id: &AtomicU64,
) -> Result<()> {
    verify_peer(&stream)?;
    let request = read_request(&stream)?;
    let timeout = request.command.response_timeout();
    let id = next_id.fetch_add(1, Ordering::Relaxed);
    let (response_tx, response_rx) = mpsc::channel();
    incoming
        .send(PendingRequest {
            id,
            request,
            response: response_tx,
        })
        .map_err(|_| anyhow!("control host stopped"))?;
    wakeup.notify();
    let response = match timeout {
        Some(timeout) => response_rx
            .recv_timeout(timeout)
            .unwrap_or_else(|_| ControlResponse::failure("timeout", "control request timed out")),
        None => response_rx.recv().unwrap_or_else(|_| {
            ControlResponse::failure("host_stopped", "control host stopped before responding")
        }),
    };
    write_response(&mut stream, &response)?;
    Ok(())
}

fn read_request(stream: &UnixStream) -> Result<ControlRequest> {
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    let mut line = String::new();
    let mut reader = BufReader::new(stream.try_clone()?.take(MAX_CONTROL_REQUEST_BYTES + 1));
    let read = reader.read_line(&mut line)?;
    if read == 0 || read as u64 > MAX_CONTROL_REQUEST_BYTES || !line.ends_with('\n') {
        bail!("invalid control request length");
    }
    let request: ControlRequest = serde_json::from_str(&line).context("decode control request")?;
    if request.version != CONTROL_PROTOCOL_VERSION {
        bail!("unsupported control protocol version {}", request.version);
    }
    Ok(request)
}

fn write_response(stream: &mut UnixStream, response: &ControlResponse) -> Result<()> {
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    serde_json::to_writer(&mut *stream, response)?;
    stream.write_all(b"\n")?;
    stream.flush()?;
    Ok(())
}

fn write_failure(mut stream: UnixStream, code: &str, message: &str) {
    let _ = write_response(&mut stream, &ControlResponse::failure(code, message));
}

#[cfg(any(target_os = "macos", target_os = "freebsd"))]
fn verify_peer(stream: &UnixStream) -> Result<()> {
    use std::os::fd::AsRawFd;

    let mut uid = 0;
    let mut gid = 0;
    // SAFETY: `getpeereid` writes uid/gid to valid pointers for this connected socket.
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    if uid != effective_uid() {
        bail!("control peer uid does not match application uid");
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn verify_peer(stream: &UnixStream) -> Result<()> {
    use std::{mem::size_of, os::fd::AsRawFd};

    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: the credential buffer and length pointer are valid for `getsockopt`.
    let status = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    };
    if status != 0 {
        return Err(io::Error::last_os_error().into());
    }
    if credentials.uid != effective_uid() {
        bail!("control peer uid does not match application uid");
    }
    Ok(())
}

#[cfg(not(any(target_os = "macos", target_os = "freebsd", target_os = "linux")))]
fn verify_peer(_stream: &UnixStream) -> Result<()> {
    bail!("control peer credential checks are unsupported on this platform")
}

fn effective_uid() -> u32 {
    // SAFETY: `geteuid` has no preconditions.
    unsafe { libc::geteuid() }
}

fn socket_owned_by_current_user(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .is_ok_and(|metadata| metadata.file_type().is_socket() && metadata.uid() == effective_uid())
}

fn remove_created_socket_parent(path: &Path, created: bool) {
    if created && let Some(parent) = path.parent() {
        let _ = fs::remove_dir(parent);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol_round_trips_tagged_commands() {
        let request = ControlRequest::new(ControlCommand::StatusSet {
            pane: 7,
            status: "done".to_owned(),
            summary: "tests passed".to_owned(),
            agent_session_start: None,
        });
        let json = serde_json::to_string(&request).unwrap();

        assert_eq!(
            serde_json::from_str::<ControlRequest>(&json).unwrap(),
            request
        );
        assert!(json.contains("\"command\":\"status-set\""));
    }

    #[test]
    fn protocol_round_trips_artifact_presentation_context() {
        let request = ControlRequest::new(ControlCommand::ArtifactShow {
            pane: 7,
            artifact: "a123abc@2".to_owned(),
            axis: ControlSplitAxis::Vertical,
            background: true,
        });
        let json = serde_json::to_string(&request).unwrap();

        assert_eq!(
            serde_json::from_str::<ControlRequest>(&json).unwrap(),
            request
        );
        assert!(json.contains("\"command\":\"artifact-show\""));
        assert!(json.contains("\"artifact\":\"a123abc@2\""));
    }

    #[test]
    fn protocol_defaults_new_tab_fields_for_existing_v1_clients() {
        let request = serde_json::from_value::<ControlRequest>(serde_json::json!({
            "version": 1,
            "command": "new-tab",
            "cwd": "/tmp/project"
        }))
        .unwrap();

        assert_eq!(
            request.command,
            ControlCommand::NewTab {
                cwd: Some("/tmp/project".to_owned()),
                title: None,
                background: false,
            }
        );
    }

    #[test]
    fn protocol_preserves_native_neovim_launch_context() {
        let request = ControlRequest::new(ControlCommand::OpenNeovim {
            pane: 4,
            cwd: "/tmp/project".to_owned(),
            executable: "/usr/local/bin/nvim".to_owned(),
            arguments: vec!["-u".to_owned(), "NONE".to_owned(), "file name".to_owned()],
            environment: BTreeMap::from([
                ("NVIM_APPNAME".to_owned(), "minimal".to_owned()),
                ("PATH".to_owned(), "/usr/bin:/bin".to_owned()),
            ]),
        });
        let json = serde_json::to_string(&request).unwrap();

        assert_eq!(
            serde_json::from_str::<ControlRequest>(&json).unwrap(),
            request
        );
        assert!(json.contains("\"command\":\"open-neovim\""));
        assert!(json.contains("\"NVIM_APPNAME\":\"minimal\""));
        assert_eq!(request.command.response_timeout(), None);
    }

    #[test]
    fn server_routes_requests_and_uses_owner_only_permissions() {
        let root = test_root("round-trip");
        let socket = root.join("control.sock");
        let mut server = ControlServer::start(&socket).unwrap();
        let client_socket = socket.clone();
        let client = thread::spawn(move || request_list(&client_socket));

        let host_request = wait_for_request(&mut server);
        assert!(matches!(host_request.request.command, ControlCommand::List));
        assert!(server.respond(
            host_request.id,
            ControlResponse::success(serde_json::json!({"tabs": []}))
        ));
        assert!(client.join().unwrap().ok);
        assert_eq!(
            fs::metadata(&socket).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(&root).unwrap().permissions().mode() & 0o777,
            0o700
        );
        drop(server);
        assert!(!socket.exists());
        assert!(!root.exists());
    }

    #[test]
    fn server_refuses_to_replace_a_regular_file() {
        let root = test_root("unsafe-path");
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let socket = root.join("control.sock");
        fs::write(&socket, b"keep").unwrap();

        assert!(ControlServer::start(&socket).is_err());
        assert_eq!(fs::read(&socket).unwrap(), b"keep");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn server_refuses_an_insecure_existing_parent_without_changing_it() {
        let root = test_root("insecure-parent");
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
        let socket = root.join("control.sock");

        assert!(ControlServer::start(&socket).is_err());
        assert_eq!(
            fs::metadata(&root).unwrap().permissions().mode() & 0o777,
            0o755
        );
        assert!(!socket.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn server_refuses_a_relative_socket_path() {
        assert!(ControlServer::start("control.sock").is_err());
    }

    #[test]
    fn server_does_not_replace_a_live_owned_socket() {
        let root = test_root("live-socket");
        let socket = root.join("control.sock");
        let server = ControlServer::start(&socket).unwrap();
        let inode = fs::metadata(&socket).unwrap().ino();

        assert!(ControlServer::start(&socket).is_err());
        assert_eq!(fs::metadata(&socket).unwrap().ino(), inode);

        drop(server);
        assert!(!root.exists());
    }

    fn request_list(socket: &Path) -> ControlResponse {
        let mut stream = UnixStream::connect(socket).unwrap();
        let request = ControlRequest::new(ControlCommand::List);
        serde_json::to_writer(&mut stream, &request).unwrap();
        stream.write_all(b"\n").unwrap();
        serde_json::from_reader(stream).unwrap()
    }

    fn wait_for_request(server: &mut ControlServer) -> ControlHostRequest {
        for _ in 0..100 {
            if let Some(request) = server.take_request() {
                return request;
            }
            thread::sleep(Duration::from_millis(10));
        }
        panic!("control request not received");
    }

    fn test_root(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "satin-control-{label}-{}-{}",
            std::process::id(),
            next_test_id()
        ))
    }

    fn next_test_id() -> u64 {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        NEXT.fetch_add(1, Ordering::Relaxed)
    }
}
