use std::ffi::{CStr, CString, c_char, c_void};
use std::{path::PathBuf, ptr};

use serde::{Deserialize, Serialize};

use crate::control::{ControlResponse, ControlServer};
use crate::core::{SplitAxis, TerminalCore, TerminalWorkspaceInput};
use crate::neovim_runtime::{NativeNeovimRuntime, NeovimLaunchOptions};
use crate::skia_metal::{NativeSkiaMetalRenderer, SkiaRenderGeometry};
use crate::terminal_runtime::{
    NativeKeyInput, NativeMouseInput, NativeTerminalRuntime, TerminalGridSize, TerminalPoint,
    TerminalSpawnConfig,
};

const SATIN_SPLIT_VERTICAL: u32 = 0;
const SATIN_SPLIT_HORIZONTAL: u32 = 1;

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_create() -> *mut TerminalCore {
    crate::logging::init();
    log::info!(target: "lifecycle", "core_created");
    Box::into_raw(Box::new(TerminalCore::new()))
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_create_with_theme(theme: *const c_char) -> *mut TerminalCore {
    crate::logging::init();
    let theme = c_string(theme).unwrap_or_else(|| "Graphite".to_owned());
    log::info!(target: "lifecycle", "core_created theme={theme}");
    Box::into_raw(Box::new(TerminalCore::new_with_theme(theme)))
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `handle` must be either null or a pointer returned by `satin_core_create`.
/// Non-null handles must be passed to this function at most once.
pub unsafe extern "C" fn satin_core_destroy(handle: *mut TerminalCore) {
    if handle.is_null() {
        return;
    }

    // SAFETY: `handle` must come from `satin_core_create` and is consumed once here.
    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_new_tab(handle: *mut TerminalCore) -> usize {
    let Some(core) = core_mut(handle) else {
        return usize::MAX;
    };
    core.new_tab()
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_split_active(handle: *mut TerminalCore, axis: u32) -> usize {
    let Some(core) = core_mut(handle) else {
        return usize::MAX;
    };
    let Some(axis) = split_axis(axis) else {
        return usize::MAX;
    };
    core.split_active(axis).unwrap_or(usize::MAX)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_resize_split(
    handle: *mut TerminalCore,
    first_pane_id: usize,
    second_pane_id: usize,
    ratio: f64,
) -> u8 {
    core_mut(handle).is_some_and(|core| core.resize_split(first_pane_id, second_pane_id, ratio))
        as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_close_pane(handle: *mut TerminalCore, pane_id: usize) -> u8 {
    core_mut(handle).is_some_and(|core| core.close_pane(pane_id)) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_select_tab(handle: *mut TerminalCore, index: usize) -> u8 {
    core_mut(handle).is_some_and(|core| core.select_tab(index)) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_move_tab(
    handle: *mut TerminalCore,
    tab_id: usize,
    index: usize,
) -> u8 {
    core_mut(handle).is_some_and(|core| core.move_tab(tab_id, index)) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_select_pane(handle: *mut TerminalCore, pane_id: usize) -> u8 {
    core_mut(handle).is_some_and(|core| core.select_pane(pane_id)) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_rename_tab(
    handle: *mut TerminalCore,
    index: usize,
    title: *const c_char,
) -> u8 {
    let Some(core) = core_mut(handle) else {
        return 0;
    };
    let Some(title) = c_string(title) else {
        return 0;
    };
    core.rename_tab(index, title) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_set_tab_theme(
    handle: *mut TerminalCore,
    index: usize,
    theme: *const c_char,
) -> u8 {
    let Some(core) = core_mut(handle) else {
        return 0;
    };
    let Some(theme) = c_string(theme) else {
        return 0;
    };
    core.set_tab_theme(index, theme) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_set_default_theme(
    handle: *mut TerminalCore,
    theme: *const c_char,
) -> u8 {
    let Some(core) = core_mut(handle) else {
        return 0;
    };
    let Some(theme) = c_string(theme) else {
        return 0;
    };
    core.set_default_theme(theme);
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_snapshot_json(handle: *const TerminalCore) -> *mut c_char {
    let Some(core) = core_ref(handle) else {
        return ptr::null_mut();
    };
    json_ptr(&core.snapshot())
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_apply_workspace_json(
    handle: *mut TerminalCore,
    workspace: *const c_char,
) -> u8 {
    let Some(core) = core_mut(handle) else {
        return 0;
    };
    let Some(workspace) = c_string(workspace) else {
        return 0;
    };
    let Ok(workspace) = serde_json::from_str::<TerminalWorkspaceInput>(&workspace) else {
        return 0;
    };
    core.apply_workspace(workspace).is_ok() as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_control_create(path: *const c_char) -> *mut ControlServer {
    crate::logging::init();
    let Some(path) = c_string(path) else {
        return ptr::null_mut();
    };
    match ControlServer::start(path) {
        Ok(server) => {
            log::info!(
                target: "control",
                "server_started path={}",
                server.socket_path().display()
            );
            Box::into_raw(Box::new(server))
        }
        Err(error) => {
            log::error!(target: "control", "server_start_failed error={error:#}");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `handle` must be null or a pointer returned by `satin_control_create`.
pub unsafe extern "C" fn satin_control_destroy(handle: *mut ControlServer) {
    if handle.is_null() {
        return;
    }
    // SAFETY: `handle` was returned by `Box::into_raw` in `satin_control_create`.
    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_control_wakeup_fd(handle: *const ControlServer) -> i32 {
    control_ref(handle).map_or(-1, ControlServer::wakeup_fd)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_control_take_request_json(handle: *mut ControlServer) -> *mut c_char {
    control_mut(handle)
        .and_then(ControlServer::take_request)
        .map_or(ptr::null_mut(), |request| json_ptr(&request))
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_control_respond(
    handle: *mut ControlServer,
    id: u64,
    response: *const c_char,
) -> u8 {
    let Some(server) = control_mut(handle) else {
        return 0;
    };
    let Some(response) = c_string(response) else {
        return 0;
    };
    let Ok(response) = serde_json::from_str::<ControlResponse>(&response) else {
        return 0;
    };
    server.respond(id, response) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_create(
    rows: u16,
    cols: u16,
    pixel_width: u16,
    pixel_height: u16,
) -> *mut NativeTerminalRuntime {
    crate::logging::init();
    let size = TerminalGridSize {
        rows,
        cols,
        pixel_width,
        pixel_height,
    };
    match NativeTerminalRuntime::spawn(size) {
        Ok(runtime) => Box::into_raw(Box::new(runtime)),
        Err(error) => {
            log::error!(target: "terminal", "spawn_failed error={error:#}");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_create_in_cwd(
    rows: u16,
    cols: u16,
    pixel_width: u16,
    pixel_height: u16,
    cwd: *const c_char,
) -> *mut NativeTerminalRuntime {
    crate::logging::init();
    let size = TerminalGridSize {
        rows,
        cols,
        pixel_width,
        pixel_height,
    };
    let cwd = c_string(cwd).map(PathBuf::from);
    match NativeTerminalRuntime::spawn_in_cwd(size, cwd.as_deref()) {
        Ok(runtime) => Box::into_raw(Box::new(runtime)),
        Err(error) => {
            log::error!(target: "terminal", "spawn_in_cwd_failed error={error:#}");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_create_config(
    rows: u16,
    cols: u16,
    pixel_width: u16,
    pixel_height: u16,
    config: *const c_char,
) -> *mut NativeTerminalRuntime {
    crate::logging::init();
    let Some(config) = c_string(config) else {
        return ptr::null_mut();
    };
    let Ok(config) = serde_json::from_str::<TerminalSpawnConfig>(&config) else {
        log::error!(target: "terminal", "spawn_config_decode_failed");
        return ptr::null_mut();
    };
    let size = TerminalGridSize {
        rows,
        cols,
        pixel_width,
        pixel_height,
    };
    match NativeTerminalRuntime::spawn_with_config(size, config) {
        Ok(runtime) => Box::into_raw(Box::new(runtime)),
        Err(error) => {
            log::error!(target: "terminal", "spawn_config_failed error={error:#}");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_create_external(
    rows: u16,
    cols: u16,
    pixel_width: u16,
    pixel_height: u16,
) -> *mut NativeTerminalRuntime {
    let size = TerminalGridSize {
        rows,
        cols,
        pixel_width,
        pixel_height,
    };
    match NativeTerminalRuntime::external(size) {
        Ok(runtime) => Box::into_raw(Box::new(runtime)),
        Err(error) => {
            log::error!(target: "tmux", "external_runtime_create_failed error={error:#}");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `handle` must be either null or a pointer returned by `satin_runtime_create`.
/// Non-null handles must be passed to this function at most once.
pub unsafe extern "C" fn satin_runtime_destroy(handle: *mut NativeTerminalRuntime) {
    if handle.is_null() {
        return;
    }

    // SAFETY: `handle` must come from `satin_runtime_create` and is consumed once here.
    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_resize(
    handle: *mut NativeTerminalRuntime,
    rows: u16,
    cols: u16,
    pixel_width: u16,
    pixel_height: u16,
) -> u8 {
    let Some(runtime) = runtime_mut(handle) else {
        return 0;
    };
    let size = TerminalGridSize {
        rows,
        cols,
        pixel_width,
        pixel_height,
    };
    runtime.resize(size).is_ok() as u8
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `bytes` must point to `len` readable bytes for the duration of the call.
pub unsafe extern "C" fn satin_runtime_write(
    handle: *mut NativeTerminalRuntime,
    bytes: *const u8,
    len: usize,
) -> u8 {
    let Some(runtime) = runtime_mut(handle) else {
        return 0;
    };
    if bytes.is_null() {
        return 0;
    }

    // SAFETY: The caller promises that `bytes` points to `len` readable bytes.
    let bytes = unsafe { std::slice::from_raw_parts(bytes, len) };
    runtime.write_all(bytes).is_ok() as u8
}

#[unsafe(no_mangle)]
/// # Safety
///
/// Non-null text pointers must point to their specified number of readable bytes.
pub unsafe extern "C" fn satin_runtime_key(
    handle: *mut NativeTerminalRuntime,
    key_code: u16,
    modifiers: u32,
    text: *const u8,
    text_len: usize,
    unshifted: *const u8,
    unshifted_len: usize,
    repeat: u8,
    released: u8,
) -> u8 {
    let Some(runtime) = runtime_mut(handle) else {
        return 0;
    };
    // SAFETY: The caller promises readable buffers for non-null pointers.
    let text = unsafe { optional_utf8(text, text_len) };
    // SAFETY: The caller promises readable buffers for non-null pointers.
    let Some(unshifted) = (unsafe { optional_utf8(unshifted, unshifted_len) }) else {
        return 0;
    };
    runtime
        .write_key(NativeKeyInput {
            key_code,
            modifiers,
            text,
            unshifted,
            repeat: repeat != 0,
            released: released != 0,
        })
        .unwrap_or(false) as u8
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `bytes` must point to `len` readable UTF-8 bytes for the duration of the call.
pub unsafe extern "C" fn satin_runtime_text(
    handle: *mut NativeTerminalRuntime,
    bytes: *const u8,
    len: usize,
) -> u8 {
    let Some(runtime) = runtime_mut(handle) else {
        return 0;
    };
    // SAFETY: The caller promises a readable buffer.
    let Some(text) = (unsafe { optional_utf8(bytes, len) }) else {
        return 0;
    };
    runtime.write_text(text).is_ok() as u8
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `bytes` must point to `len` readable UTF-8 bytes for the duration of the call.
pub unsafe extern "C" fn satin_runtime_paste(
    handle: *mut NativeTerminalRuntime,
    bytes: *const u8,
    len: usize,
) -> u8 {
    let Some(runtime) = runtime_mut(handle) else {
        return 0;
    };
    // SAFETY: The caller promises a readable buffer.
    let Some(text) = (unsafe { optional_utf8(bytes, len) }) else {
        return 0;
    };
    runtime.write_paste(text).is_ok() as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_mouse(
    handle: *mut NativeTerminalRuntime,
    action: u32,
    button: i32,
    modifiers: u32,
    x: f32,
    y: f32,
    cell_width: u32,
    cell_height: u32,
) -> u8 {
    let Some(runtime) = runtime_mut(handle) else {
        return 0;
    };
    let Some(action) = mouse_action(action) else {
        return 0;
    };
    let Some(button) = mouse_button(button) else {
        return 0;
    };
    runtime
        .write_mouse(NativeMouseInput {
            action,
            button,
            modifiers,
            x,
            y,
            cell_width,
            cell_height,
        })
        .unwrap_or(false) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_focus(handle: *mut NativeTerminalRuntime, focused: u8) -> u8 {
    let Some(runtime) = runtime_mut(handle) else {
        return 0;
    };
    runtime.write_focus(focused != 0).unwrap_or(false) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_select(
    handle: *mut NativeTerminalRuntime,
    start_row: u32,
    start_col: u16,
    end_row: u32,
    end_col: u16,
    rectangular: u8,
) -> u8 {
    runtime_ref(handle).is_some_and(|runtime| {
        runtime
            .select(
                TerminalPoint {
                    row: start_row,
                    col: start_col,
                },
                TerminalPoint {
                    row: end_row,
                    col: end_col,
                },
                rectangular != 0,
            )
            .is_ok()
    }) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_select_all(handle: *const NativeTerminalRuntime) -> u8 {
    runtime_ref(handle).is_some_and(|runtime| runtime.select_all().is_ok()) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_clear_selection(handle: *const NativeTerminalRuntime) -> u8 {
    runtime_ref(handle).is_some_and(|runtime| runtime.clear_selection().is_ok()) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_selected_text(handle: *const NativeTerminalRuntime) -> *mut c_char {
    runtime_ref(handle)
        .and_then(|runtime| runtime.selected_text().ok().flatten())
        .map_or(ptr::null_mut(), string_ptr)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_hyperlink(
    handle: *const NativeTerminalRuntime,
    row: u32,
    col: u16,
) -> *mut c_char {
    runtime_ref(handle)
        .and_then(|runtime| {
            runtime
                .hyperlink_at(TerminalPoint { row, col })
                .ok()
                .flatten()
        })
        .map_or(ptr::null_mut(), string_ptr)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_title(handle: *const NativeTerminalRuntime) -> *mut c_char {
    runtime_ref(handle)
        .and_then(NativeTerminalRuntime::title)
        .map_or(ptr::null_mut(), string_ptr)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_take_bell_count(handle: *const NativeTerminalRuntime) -> u64 {
    runtime_ref(handle).map_or(0, NativeTerminalRuntime::take_bell_count)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_set_option_as_alt(
    handle: *mut NativeTerminalRuntime,
    enabled: u8,
) -> u8 {
    let Some(runtime) = runtime_mut(handle) else {
        return 0;
    };
    runtime.set_option_as_alt(enabled != 0);
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_find(
    handle: *mut NativeTerminalRuntime,
    query: *const c_char,
    backwards: u8,
) -> u8 {
    let Some(runtime) = runtime_mut(handle) else {
        return 0;
    };
    let Some(query) = c_string(query) else {
        return 0;
    };
    runtime.find(&query, backwards != 0).unwrap_or(false) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_drain(handle: *mut NativeTerminalRuntime) -> u8 {
    let Some(runtime) = runtime_mut(handle) else {
        return 0;
    };
    runtime.drain().unwrap_or(false) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_take_tmux_event_json(
    handle: *mut NativeTerminalRuntime,
) -> *mut c_char {
    runtime_mut(handle)
        .and_then(NativeTerminalRuntime::take_tmux_event)
        .map_or(ptr::null_mut(), |event| json_ptr(&event))
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_tmux_command(
    handle: *mut NativeTerminalRuntime,
    command: *const c_char,
) -> u8 {
    let Some(runtime) = runtime_mut(handle) else {
        return 0;
    };
    let Some(command) = c_string(command) else {
        return 0;
    };
    runtime.tmux_command(&command).unwrap_or(false) as u8
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `bytes` must point to `len` readable bytes and `pane` must be a live
/// external runtime handle.
pub unsafe extern "C" fn satin_runtime_tmux_feed_pane(
    pane: *mut NativeTerminalRuntime,
    bytes: *const u8,
    len: usize,
) -> u8 {
    let Some(pane) = runtime_mut(pane) else {
        return 0;
    };
    if bytes.is_null() {
        return 0;
    }
    // SAFETY: The caller promises that `bytes` points to `len` readable bytes.
    let bytes = unsafe { std::slice::from_raw_parts(bytes, len) };
    if pane.feed_tmux_projection(bytes).is_err() {
        return 0;
    }
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_tmux_shell_prompt_state(pane: *mut NativeTerminalRuntime) -> u8 {
    runtime_ref(pane)
        .and_then(|pane| pane.tmux_shell_prompt_state().ok())
        .map_or(0, |state| state as u8)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_tmux_semantic_prompt_seen(pane: *mut NativeTerminalRuntime) -> u8 {
    runtime_ref(pane).is_some_and(NativeTerminalRuntime::tmux_semantic_prompt_seen) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_tmux_prompt_generation(pane: *mut NativeTerminalRuntime) -> u64 {
    runtime_ref(pane).map_or(0, NativeTerminalRuntime::tmux_prompt_generation)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_tmux_reset_prompt_tracking(pane: *mut NativeTerminalRuntime) -> u8 {
    let Some(pane) = runtime_mut(pane) else {
        return 0;
    };
    pane.reset_tmux_prompt_tracking();
    1
}

#[unsafe(no_mangle)]
/// # Safety
///
/// Non-null text pointers must point to their specified number of readable
/// bytes. `gateway` and `pane` must be distinct live runtime handles.
pub unsafe extern "C" fn satin_runtime_tmux_key(
    gateway: *mut NativeTerminalRuntime,
    pane: *mut NativeTerminalRuntime,
    pane_id: u32,
    key_code: u16,
    modifiers: u32,
    text: *const u8,
    text_len: usize,
    unshifted: *const u8,
    unshifted_len: usize,
    repeat: u8,
    released: u8,
) -> u8 {
    let Some((gateway, pane)) = distinct_runtimes(gateway, pane) else {
        return 0;
    };
    // SAFETY: The caller promises readable buffers for non-null pointers.
    let text = unsafe { optional_utf8(text, text_len) };
    // SAFETY: The caller promises readable buffers for non-null pointers.
    let Some(unshifted) = (unsafe { optional_utf8(unshifted, unshifted_len) }) else {
        return 0;
    };
    let input = NativeKeyInput {
        key_code,
        modifiers,
        text,
        unshifted,
        repeat: repeat != 0,
        released: released != 0,
    };
    let Ok(Some(encoded)) = pane.encode_key(input) else {
        return 0;
    };
    let sent = gateway.tmux_send_bytes(pane_id, &encoded).unwrap_or(false);
    if sent {
        pane.finish_external_input();
    }
    sent as u8
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `bytes` must point to `len` readable bytes. `gateway` and `pane` must be
/// distinct live runtime handles.
pub unsafe extern "C" fn satin_runtime_tmux_write(
    gateway: *mut NativeTerminalRuntime,
    pane: *mut NativeTerminalRuntime,
    pane_id: u32,
    bytes: *const u8,
    len: usize,
) -> u8 {
    let Some((gateway, pane)) = distinct_runtimes(gateway, pane) else {
        return 0;
    };
    if bytes.is_null() {
        return 0;
    }
    // SAFETY: The caller promises that `bytes` points to `len` readable bytes.
    let bytes = unsafe { std::slice::from_raw_parts(bytes, len) };
    let sent = gateway.tmux_send_bytes(pane_id, bytes).unwrap_or(false);
    if sent {
        pane.finish_external_input();
    }
    sent as u8
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `bytes` must point to `len` readable UTF-8 bytes. `gateway` and `pane` must
/// be distinct live runtime handles.
pub unsafe extern "C" fn satin_runtime_tmux_paste(
    gateway: *mut NativeTerminalRuntime,
    pane: *mut NativeTerminalRuntime,
    pane_id: u32,
    bytes: *const u8,
    len: usize,
) -> u8 {
    let Some((gateway, pane)) = distinct_runtimes(gateway, pane) else {
        return 0;
    };
    // SAFETY: The caller promises a readable buffer.
    let Some(text) = (unsafe { optional_utf8(bytes, len) }) else {
        return 0;
    };
    let sent = gateway
        .tmux_paste(pane_id, text.as_bytes())
        .unwrap_or(false);
    if sent {
        pane.finish_external_input();
    }
    sent as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_tmux_mouse(
    gateway: *mut NativeTerminalRuntime,
    pane: *mut NativeTerminalRuntime,
    pane_id: u32,
    action: u32,
    button: i32,
    modifiers: u32,
    x: f32,
    y: f32,
    cell_width: u32,
    cell_height: u32,
) -> u8 {
    let Some((gateway, pane)) = distinct_runtimes(gateway, pane) else {
        return 0;
    };
    let Some(action) = mouse_action(action) else {
        return 0;
    };
    let Some(button) = mouse_button(button) else {
        return 0;
    };
    let Ok(Some(encoded)) = pane.encode_mouse(NativeMouseInput {
        action,
        button,
        modifiers,
        x,
        y,
        cell_width,
        cell_height,
    }) else {
        return 0;
    };
    gateway.tmux_send_bytes(pane_id, &encoded).unwrap_or(false) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_tmux_focus(
    gateway: *mut NativeTerminalRuntime,
    pane: *mut NativeTerminalRuntime,
    pane_id: u32,
    focused: u8,
) -> u8 {
    let Some((gateway, pane)) = distinct_runtimes(gateway, pane) else {
        return 0;
    };
    let Ok(Some(encoded)) = pane.encode_focus(focused != 0) else {
        return 0;
    };
    gateway.tmux_send_bytes(pane_id, &encoded).unwrap_or(false) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_exited(handle: *mut NativeTerminalRuntime) -> u8 {
    let Some(runtime) = runtime_mut(handle) else {
        return 1;
    };
    runtime.is_exited() as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_wakeup_fd(handle: *const NativeTerminalRuntime) -> i32 {
    runtime_ref(handle).map_or(-1, NativeTerminalRuntime::wakeup_fd)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_scroll(
    handle: *mut NativeTerminalRuntime,
    requested_rows: isize,
) -> isize {
    let Some(runtime) = runtime_mut(handle) else {
        return 0;
    };
    runtime.scroll_delta(requested_rows).unwrap_or(0)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_renderer_scroll_position(
    handle: *const NativeTerminalRuntime,
) -> f32 {
    runtime_ref(handle).map_or(0.0, NativeTerminalRuntime::renderer_scroll_position)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_cursor_position(handle: *const NativeTerminalRuntime) -> u32 {
    runtime_ref(handle)
        .and_then(|runtime| runtime.cursor_position().ok().flatten())
        .map_or(u32::MAX, |(x, y)| u32::from(x) | (u32::from(y) << 16))
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_cwd(handle: *const NativeTerminalRuntime) -> *mut c_char {
    let Some(runtime) = runtime_ref(handle) else {
        return ptr::null_mut();
    };
    let Some(cwd) = runtime.current_working_directory() else {
        return ptr::null_mut();
    };
    string_ptr(cwd.to_string_lossy().into_owned())
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_screen_text(handle: *mut NativeTerminalRuntime) -> *mut c_char {
    let Some(runtime) = runtime_mut(handle) else {
        return ptr::null_mut();
    };
    runtime.screen_text().map_or(ptr::null_mut(), string_ptr)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_runtime_kitty_placement_count(
    handle: *const NativeTerminalRuntime,
) -> usize {
    let Some(runtime) = runtime_ref(handle) else {
        return 0;
    };
    runtime
        .kitty_placements()
        .map_or(0, |placements| placements.len())
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_create(
    rows: u16,
    cols: u16,
    pixel_width: u16,
    pixel_height: u16,
) -> *mut NativeNeovimRuntime {
    let size = TerminalGridSize {
        rows,
        cols,
        pixel_width,
        pixel_height,
    };
    create_nvim_runtime(size, NeovimLaunchOptions::default())
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_create_in_cwd(
    rows: u16,
    cols: u16,
    pixel_width: u16,
    pixel_height: u16,
    cwd: *const c_char,
) -> *mut NativeNeovimRuntime {
    let size = TerminalGridSize {
        rows,
        cols,
        pixel_width,
        pixel_height,
    };
    create_nvim_runtime(
        size,
        NeovimLaunchOptions {
            cwd: c_string(cwd).map(PathBuf::from),
            ..NeovimLaunchOptions::default()
        },
    )
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NativeNeovimLaunchConfiguration {
    cwd: Option<PathBuf>,
    executable: Option<PathBuf>,
    #[serde(default)]
    arguments: Vec<String>,
    #[serde(default)]
    environment: std::collections::BTreeMap<String, String>,
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_create_with_config(
    rows: u16,
    cols: u16,
    pixel_width: u16,
    pixel_height: u16,
    configuration: *const c_char,
) -> *mut NativeNeovimRuntime {
    let Some(configuration) = c_string(configuration)
        .and_then(|json| serde_json::from_str::<NativeNeovimLaunchConfiguration>(&json).ok())
    else {
        return ptr::null_mut();
    };
    let size = TerminalGridSize {
        rows,
        cols,
        pixel_width,
        pixel_height,
    };
    create_nvim_runtime(
        size,
        NeovimLaunchOptions {
            cwd: configuration.cwd,
            executable: configuration.executable,
            arguments: configuration.arguments,
            environment: configuration.environment,
        },
    )
}

fn create_nvim_runtime(
    size: TerminalGridSize,
    options: NeovimLaunchOptions,
) -> *mut NativeNeovimRuntime {
    crate::logging::init();
    match NativeNeovimRuntime::spawn_with_options(size, options) {
        Ok(runtime) => Box::into_raw(Box::new(runtime)),
        Err(error) => {
            log::error!(target: "neovim", "spawn_failed error={error:#}");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `handle` must be either null or a pointer returned by `satin_nvim_create`.
/// Non-null handles must be passed to this function at most once.
pub unsafe extern "C" fn satin_nvim_destroy(handle: *mut NativeNeovimRuntime) {
    if handle.is_null() {
        return;
    }

    // SAFETY: `handle` must come from `satin_nvim_create` and is consumed once here.
    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_resize(
    handle: *mut NativeNeovimRuntime,
    rows: u16,
    cols: u16,
    pixel_width: u16,
    pixel_height: u16,
) -> u8 {
    let Some(runtime) = nvim_mut(handle) else {
        return 0;
    };
    let size = TerminalGridSize {
        rows,
        cols,
        pixel_width,
        pixel_height,
    };
    runtime.resize(size).is_ok() as u8
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `bytes` must point to `len` readable bytes for the duration of the call.
pub unsafe extern "C" fn satin_nvim_input(
    handle: *mut NativeNeovimRuntime,
    bytes: *const u8,
    len: usize,
) -> u8 {
    let Some(runtime) = nvim_mut(handle) else {
        return 0;
    };
    if bytes.is_null() {
        return 0;
    }

    // SAFETY: The caller promises that `bytes` points to `len` readable bytes.
    let bytes = unsafe { std::slice::from_raw_parts(bytes, len) };
    runtime.input_bytes(bytes).is_ok() as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_mouse(
    handle: *mut NativeNeovimRuntime,
    button: *const c_char,
    action: *const c_char,
    modifier: *const c_char,
    grid: i64,
    row: i64,
    col: i64,
) -> u8 {
    let Some(runtime) = nvim_mut(handle) else {
        return 0;
    };
    let Some(button) = c_string(button) else {
        return 0;
    };
    let Some(action) = c_string(action) else {
        return 0;
    };
    let Some(modifier) = c_string(modifier) else {
        return 0;
    };
    match runtime.mouse_input(&button, &action, &modifier, grid, row, col) {
        Ok(true) => 2,
        Ok(false) => 1,
        Err(_) => 0,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_take_message_selection_text(
    handle: *mut NativeNeovimRuntime,
) -> *mut c_char {
    nvim_mut(handle)
        .and_then(NativeNeovimRuntime::take_message_selection_text)
        .map_or(ptr::null_mut(), string_ptr)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_command(
    handle: *mut NativeNeovimRuntime,
    command: *const c_char,
) -> u8 {
    let Some(runtime) = nvim_mut(handle) else {
        return 0;
    };
    let Some(command) = c_string(command) else {
        return 0;
    };
    runtime.command(&command).is_ok() as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_drain(handle: *mut NativeNeovimRuntime) -> u8 {
    let Some(runtime) = nvim_mut(handle) else {
        return 0;
    };
    runtime.drain().unwrap_or(false) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_exited(handle: *mut NativeNeovimRuntime) -> u8 {
    let Some(runtime) = nvim_mut(handle) else {
        return 1;
    };
    runtime.is_exited() as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_exit_code(handle: *mut NativeNeovimRuntime) -> i32 {
    nvim_mut(handle)
        .and_then(NativeNeovimRuntime::exit_code)
        .unwrap_or(i32::MIN)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_wakeup_fd(handle: *const NativeNeovimRuntime) -> i32 {
    nvim_ref(handle).map_or(-1, NativeNeovimRuntime::wakeup_fd)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_kitty_placement_count(handle: *const NativeNeovimRuntime) -> usize {
    nvim_ref(handle)
        .and_then(|runtime| runtime.kitty_placements().ok())
        .map_or(0, |placements| placements.len())
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_renderer_model_json(handle: *mut NativeNeovimRuntime) -> *mut c_char {
    let Some(runtime) = nvim_mut(handle) else {
        return ptr::null_mut();
    };
    json_ptr(&runtime.renderer_model_with_pending_scroll())
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_nvim_ui_state_json(handle: *mut NativeNeovimRuntime) -> *mut c_char {
    let Some(runtime) = nvim_mut(handle) else {
        return ptr::null_mut();
    };
    json_ptr(&runtime.ui_state_with_pending_scroll())
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `device` and `command_queue` must be live Metal protocol object pointers.
pub unsafe extern "C" fn satin_skia_metal_create(
    device: *mut c_void,
    command_queue: *mut c_void,
) -> *mut NativeSkiaMetalRenderer {
    // SAFETY: The caller guarantees both pointers are live Metal protocol objects.
    match unsafe { NativeSkiaMetalRenderer::new(device, command_queue) } {
        Some(renderer) => Box::into_raw(Box::new(renderer)),
        None => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `handle` must be either null or a pointer returned by `satin_skia_metal_create`.
/// Non-null handles must be passed to this function at most once.
pub unsafe extern "C" fn satin_skia_metal_destroy(handle: *mut NativeSkiaMetalRenderer) {
    if handle.is_null() {
        return;
    }

    // SAFETY: `handle` must come from `satin_skia_metal_create` and is consumed once here.
    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `renderer`, `nvim`, and `texture` must be live pointers for the duration of the call.
pub unsafe extern "C" fn satin_skia_metal_render_nvim(
    renderer: *mut NativeSkiaMetalRenderer,
    nvim: *mut NativeNeovimRuntime,
    texture: *mut c_void,
    width: i32,
    height: i32,
    origin_x: f32,
    origin_y: f32,
    content_width: f32,
    content_height: f32,
    cell_width: f32,
    cell_height: f32,
    clear: u8,
) -> u8 {
    let Some(renderer) = skia_renderer_mut(renderer) else {
        return 0;
    };
    let Some(nvim) = nvim_mut(nvim) else {
        return 0;
    };
    let geometry = SkiaRenderGeometry {
        width,
        height,
        origin_x,
        origin_y,
        content_width,
        content_height,
        cell_width,
        cell_height,
    };
    // SAFETY: The caller guarantees the renderer, nvim runtime, and drawable texture are live.
    (unsafe { renderer.render_nvim(nvim, texture, geometry, clear != 0) }) as u8
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `renderer`, `runtime`, and `texture` must be live pointers for the duration of the call.
pub unsafe extern "C" fn satin_skia_metal_render_terminal(
    renderer: *mut NativeSkiaMetalRenderer,
    runtime: *mut NativeTerminalRuntime,
    texture: *mut c_void,
    width: i32,
    height: i32,
    origin_x: f32,
    origin_y: f32,
    content_width: f32,
    content_height: f32,
    cell_width: f32,
    cell_height: f32,
    clear: u8,
) -> u8 {
    let Some(renderer) = skia_renderer_mut(renderer) else {
        return 0;
    };
    let Some(runtime) = runtime_mut(runtime) else {
        return 0;
    };
    let geometry = SkiaRenderGeometry {
        width,
        height,
        origin_x,
        origin_y,
        content_width,
        content_height,
        cell_width,
        cell_height,
    };
    // SAFETY: The caller guarantees the renderer, terminal runtime, and drawable texture are live.
    (unsafe { renderer.render_terminal(runtime, texture, geometry, clear != 0) }) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_skia_metal_needs_animation_frame(
    renderer: *const NativeSkiaMetalRenderer,
) -> u8 {
    skia_renderer_ref(renderer).is_some_and(NativeSkiaMetalRenderer::needs_animation_frame) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_skia_metal_forget_runtime(
    renderer: *mut NativeSkiaMetalRenderer,
    runtime: *const c_void,
) {
    let Some(renderer) = skia_renderer_mut(renderer) else {
        return;
    };
    if runtime.is_null() {
        return;
    }
    renderer.forget_runtime(runtime as usize);
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_skia_metal_set_font_family(
    renderer: *mut NativeSkiaMetalRenderer,
    family: *const c_char,
) -> u8 {
    let Some(renderer) = skia_renderer_mut(renderer) else {
        return 0;
    };
    let family = c_string(family);
    renderer.set_font_family(family.as_deref());
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_skia_metal_next_frame_delay_ms(
    renderer: *const NativeSkiaMetalRenderer,
) -> u64 {
    skia_renderer_ref(renderer)
        .and_then(NativeSkiaMetalRenderer::next_frame_delay_ms)
        .unwrap_or(u64::MAX)
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `value` must be either null or a pointer returned by this crate through
/// `CString::into_raw`. Non-null pointers must be passed at most once.
pub unsafe extern "C" fn satin_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }

    // SAFETY: `value` must be a pointer returned by this crate through `CString::into_raw`.
    unsafe {
        drop(CString::from_raw(value));
    }
}

fn split_axis(axis: u32) -> Option<SplitAxis> {
    match axis {
        SATIN_SPLIT_VERTICAL => Some(SplitAxis::Vertical),
        SATIN_SPLIT_HORIZONTAL => Some(SplitAxis::Horizontal),
        _ => None,
    }
}

fn core_ref<'a>(handle: *const TerminalCore) -> Option<&'a TerminalCore> {
    if handle.is_null() {
        return None;
    }

    // SAFETY: Callers pass an opaque pointer created by `satin_core_create`.
    unsafe { handle.as_ref() }
}

fn control_mut<'a>(handle: *mut ControlServer) -> Option<&'a mut ControlServer> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: Callers pass an exclusive opaque pointer created by `satin_control_create`.
    Some(unsafe { &mut *handle })
}

fn control_ref<'a>(handle: *const ControlServer) -> Option<&'a ControlServer> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: Callers pass an opaque pointer created by `satin_control_create`.
    Some(unsafe { &*handle })
}

fn core_mut<'a>(handle: *mut TerminalCore) -> Option<&'a mut TerminalCore> {
    if handle.is_null() {
        return None;
    }

    // SAFETY: Callers pass an exclusive opaque pointer created by `satin_core_create`.
    unsafe { handle.as_mut() }
}

fn runtime_mut<'a>(handle: *mut NativeTerminalRuntime) -> Option<&'a mut NativeTerminalRuntime> {
    if handle.is_null() {
        return None;
    }

    // SAFETY: Callers pass an exclusive opaque pointer created by `satin_runtime_create`.
    unsafe { handle.as_mut() }
}

fn distinct_runtimes<'a>(
    gateway: *mut NativeTerminalRuntime,
    pane: *mut NativeTerminalRuntime,
) -> Option<(&'a mut NativeTerminalRuntime, &'a mut NativeTerminalRuntime)> {
    if gateway.is_null() || pane.is_null() || gateway == pane {
        return None;
    }
    // SAFETY: FFI callers guarantee both pointers are live, distinct runtime
    // handles and provide exclusive access for the duration of the call.
    Some(unsafe { (&mut *gateway, &mut *pane) })
}

fn runtime_ref<'a>(handle: *const NativeTerminalRuntime) -> Option<&'a NativeTerminalRuntime> {
    if handle.is_null() {
        return None;
    }

    // SAFETY: Callers pass an opaque pointer created by `satin_runtime_create`.
    unsafe { handle.as_ref() }
}

fn nvim_mut<'a>(handle: *mut NativeNeovimRuntime) -> Option<&'a mut NativeNeovimRuntime> {
    if handle.is_null() {
        return None;
    }

    // SAFETY: Callers pass an exclusive opaque pointer created by `satin_nvim_create`.
    unsafe { handle.as_mut() }
}

fn nvim_ref<'a>(handle: *const NativeNeovimRuntime) -> Option<&'a NativeNeovimRuntime> {
    if handle.is_null() {
        return None;
    }

    // SAFETY: Callers pass an opaque pointer created by `satin_nvim_create`.
    unsafe { handle.as_ref() }
}

fn skia_renderer_mut<'a>(
    handle: *mut NativeSkiaMetalRenderer,
) -> Option<&'a mut NativeSkiaMetalRenderer> {
    if handle.is_null() {
        return None;
    }

    // SAFETY: Callers pass an exclusive opaque pointer created by `satin_skia_metal_create`.
    unsafe { handle.as_mut() }
}

fn skia_renderer_ref<'a>(
    handle: *const NativeSkiaMetalRenderer,
) -> Option<&'a NativeSkiaMetalRenderer> {
    if handle.is_null() {
        return None;
    }

    // SAFETY: Callers pass an opaque pointer created by `satin_skia_metal_create`.
    unsafe { handle.as_ref() }
}

fn c_string(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }

    // SAFETY: The native host passes a valid NUL-terminated C string.
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

unsafe fn optional_utf8<'a>(value: *const u8, len: usize) -> Option<&'a str> {
    if value.is_null() {
        return None;
    }
    // SAFETY: The caller guarantees `value` points to `len` readable bytes.
    std::str::from_utf8(unsafe { std::slice::from_raw_parts(value, len) }).ok()
}

fn mouse_action(value: u32) -> Option<libghostty_vt::mouse::Action> {
    match value {
        0 => Some(libghostty_vt::mouse::Action::Press),
        1 => Some(libghostty_vt::mouse::Action::Release),
        2 => Some(libghostty_vt::mouse::Action::Motion),
        _ => None,
    }
}

fn mouse_button(value: i32) -> Option<Option<libghostty_vt::mouse::Button>> {
    use libghostty_vt::mouse::Button;
    Some(match value {
        -1 => None,
        0 => Some(Button::Left),
        1 => Some(Button::Right),
        2 => Some(Button::Middle),
        3 => Some(Button::Four),
        4 => Some(Button::Five),
        5 => Some(Button::Six),
        6 => Some(Button::Seven),
        7 => Some(Button::Eight),
        8 => Some(Button::Nine),
        9 => Some(Button::Ten),
        10 => Some(Button::Eleven),
        _ => return None,
    })
}

fn json_ptr(value: &impl Serialize) -> *mut c_char {
    let json = match serde_json::to_string(value) {
        Ok(json) => json,
        Err(error) => {
            log::error!(target: "ffi", "json_encode_failed error={error}");
            return ptr::null_mut();
        }
    };
    string_ptr(json)
}

fn string_ptr(value: String) -> *mut c_char {
    match CString::new(value) {
        Ok(value) => value.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_snapshot_json_exposes_tabs() {
        let handle = satin_core_create();
        assert!(!handle.is_null());

        assert_eq!(satin_core_new_tab(handle), 1);
        let json = owned_string(satin_core_snapshot_json(handle));

        // SAFETY: `handle` was created by `satin_core_create` in this test.
        unsafe {
            satin_core_destroy(handle);
        }
        assert!(json.contains("\"active_tab\":1"));
        assert!(json.contains("\"session 2\""));
    }

    fn owned_string(value: *mut c_char) -> String {
        assert!(!value.is_null());
        // SAFETY: `value` is returned by this module and remains valid until freed below.
        let string = unsafe { CStr::from_ptr(value) }
            .to_string_lossy()
            .into_owned();
        // SAFETY: `value` was returned by an FFI function in this module.
        unsafe {
            satin_string_free(value);
        }
        string
    }
}
