//! tmux control mode lives in the Kizu core (`satin::tmux` in satin-kizu).
//! This is the terminal runtime's handle on it: the same calls the Rust
//! implementation offered, with events handed over as the JSON the host reads.

use std::ffi::{CStr, c_char};
use std::ptr;

use anyhow::Result;

#[repr(C)]
struct KizuTmux {
    _private: [u8; 0],
}

unsafe extern "C" {
    fn satin_tmux_create() -> *mut KizuTmux;
    fn satin_tmux_destroy(handle: *mut KizuTmux);
    fn satin_tmux_feed(
        handle: *mut KizuTmux,
        bytes: *const u8,
        len: usize,
        out_len: *mut usize,
    ) -> *mut u8;
    fn satin_tmux_take_event_json(handle: *mut KizuTmux) -> *mut c_char;
    fn satin_tmux_take_outgoing(handle: *mut KizuTmux, out_len: *mut usize) -> *mut u8;
    fn satin_tmux_command(handle: *mut KizuTmux, bytes: *const u8, len: usize) -> u8;
    fn satin_tmux_pane_accepts_input(handle: *mut KizuTmux, pane_id: u32) -> u8;
    fn satin_tmux_paste(handle: *mut KizuTmux, pane_id: u32, bytes: *const u8, len: usize) -> u8;
    fn satin_tmux_is_active(handle: *mut KizuTmux) -> u8;
}

#[derive(Debug)]
pub struct TmuxControl {
    handle: *mut KizuTmux,
}

// SAFETY: the Kizu control is owned by this value alone and every call goes
// through `&mut self` or `&self` on the thread that holds it.
unsafe impl Send for TmuxControl {}

impl Default for TmuxControl {
    fn default() -> Self {
        // SAFETY: creating a control has no preconditions; a null handle makes
        // every call below a no-op.
        let handle = unsafe { satin_tmux_create() };
        Self { handle }
    }
}

impl Drop for TmuxControl {
    fn drop(&mut self) {
        if self.handle.is_null() {
            return;
        }
        // SAFETY: `handle` came from `satin_tmux_create` and is destroyed once.
        unsafe { satin_tmux_destroy(self.handle) };
        self.handle = ptr::null_mut();
    }
}

/// Takes ownership of malloc storage the Kizu side returned.
fn owned_bytes(data: *mut u8, len: usize) -> Option<Vec<u8>> {
    if data.is_null() {
        return None;
    }
    // SAFETY: the Kizu side returned `len` initialized bytes at `data`.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
    // SAFETY: `data` is malloc storage nothing else frees.
    unsafe { libc::free(data.cast()) };
    Some(bytes)
}

impl TmuxControl {
    pub fn is_active(&self) -> bool {
        // SAFETY: `handle` is null or a live control owned by `self`.
        !self.handle.is_null() && unsafe { satin_tmux_is_active(self.handle) } != 0
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Result<Vec<u8>> {
        if self.handle.is_null() {
            return Ok(bytes.to_vec());
        }
        let mut len = 0;
        // SAFETY: `bytes` is readable for its length and `len` is writable.
        let data = unsafe { satin_tmux_feed(self.handle, bytes.as_ptr(), bytes.len(), &mut len) };
        Ok(owned_bytes(data, len).unwrap_or_default())
    }

    /// The oldest event as the JSON the host reads.
    pub fn take_event(&mut self) -> Option<String> {
        if self.handle.is_null() {
            return None;
        }
        // SAFETY: `handle` is a live control owned by `self`.
        let json = unsafe { satin_tmux_take_event_json(self.handle) };
        if json.is_null() {
            return None;
        }
        // SAFETY: the Kizu side returned a NUL-terminated string at `json`.
        let text = unsafe { CStr::from_ptr(json) }
            .to_string_lossy()
            .into_owned();
        // SAFETY: `json` is malloc storage nothing else frees.
        unsafe { libc::free(json.cast()) };
        Some(text)
    }

    pub fn take_outgoing(&mut self) -> Option<Vec<u8>> {
        if self.handle.is_null() {
            return None;
        }
        let mut len = 0;
        // SAFETY: `handle` is a live control owned by `self`; `len` is writable.
        let data = unsafe { satin_tmux_take_outgoing(self.handle, &mut len) };
        owned_bytes(data, len)
    }

    pub fn command(&mut self, command: impl Into<String>) -> bool {
        let command = command.into();
        // SAFETY: `command` is readable for its length.
        !self.handle.is_null()
            && unsafe { satin_tmux_command(self.handle, command.as_ptr(), command.len()) } != 0
    }

    pub fn pane_accepts_input(&self, pane_id: u32) -> bool {
        // SAFETY: `handle` is null or a live control owned by `self`.
        !self.handle.is_null()
            && unsafe { satin_tmux_pane_accepts_input(self.handle, pane_id) } != 0
    }

    pub fn paste(&mut self, pane_id: u32, bytes: &[u8]) -> bool {
        // SAFETY: `bytes` is readable for its length.
        !self.handle.is_null()
            && unsafe { satin_tmux_paste(self.handle, pane_id, bytes.as_ptr(), bytes.len()) } != 0
    }
}
