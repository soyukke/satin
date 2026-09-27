//! The VT terminal lives in the Kizu core (`vt_ffi.kizu` in satin-kizu): Kizu
//! creates the libghostty-vt terminal, installs its PTY-reply and bell
//! callbacks, feeds it output and tracks shell prompts beside it. This is the
//! runtime's handle on it. The runtime borrows the terminal itself to render,
//! select and encode input.

use std::mem::ManuallyDrop;
use std::ptr;

use anyhow::{Result, anyhow};
use libghostty_vt::Terminal;

#[repr(C)]
struct KizuVtHandle {
    _private: [u8; 0],
}

unsafe extern "C" {
    fn satin_vt_create(cols: u16, rows: u16, max_scrollback: usize) -> *mut KizuVtHandle;
    fn satin_vt_destroy(handle: *mut KizuVtHandle);
    fn satin_vt_terminal(handle: *mut KizuVtHandle) -> *mut std::ffi::c_void;
    fn satin_vt_feed(handle: *mut KizuVtHandle, bytes: *const u8, len: usize);
    fn satin_vt_take_replies(handle: *mut KizuVtHandle, out_len: *mut usize) -> *mut u8;
    fn satin_vt_take_bell_count(handle: *mut KizuVtHandle) -> u64;
    fn satin_vt_prompt_seen(handle: *mut KizuVtHandle) -> u8;
    fn satin_vt_prompt_generation(handle: *mut KizuVtHandle) -> u64;
    fn satin_vt_reset_prompt(handle: *mut KizuVtHandle);
}

#[derive(Debug)]
pub struct KizuVt {
    handle: *mut KizuVtHandle,
}

// SAFETY: the Kizu terminal is owned by this value alone and every call goes
// through `&mut self` or `&self` on the thread that holds it.
unsafe impl Send for KizuVt {}

impl KizuVt {
    /// Creates the terminal and the borrowed view the runtime reads it through.
    ///
    /// The view must not outlive the returned `KizuVt`, which frees the
    /// terminal when dropped.
    pub fn new(
        cols: u16,
        rows: u16,
        max_scrollback: usize,
    ) -> Result<(Self, ManuallyDrop<Terminal<'static, 'static>>)> {
        // SAFETY: creating a terminal has no preconditions; null means failure.
        let handle = unsafe { satin_vt_create(cols, rows, max_scrollback) };
        if handle.is_null() {
            return Err(anyhow!("Kizu could not create the terminal"));
        }
        let vt = Self { handle };
        // SAFETY: `handle` is live, and the terminal lives until it is destroyed.
        let raw = unsafe { satin_vt_terminal(vt.handle) };
        // SAFETY: `raw` is the live terminal `vt` owns; the runtime drops the
        // view before `vt` and installs no callbacks through it.
        let terminal = unsafe { Terminal::from_raw_borrowed(raw.cast())? };
        Ok((vt, terminal))
    }

    /// Feeds output to the terminal and to the prompt tracker beside it.
    pub fn feed(&mut self, bytes: &[u8]) {
        // SAFETY: `handle` is live and `bytes` is readable for its length.
        unsafe { satin_vt_feed(self.handle, bytes.as_ptr(), bytes.len()) };
    }

    /// The replies the terminal owes the PTY since the last take.
    pub fn take_replies(&mut self) -> Vec<u8> {
        let mut len = 0usize;
        // SAFETY: `handle` is live and `len` is writable.
        let bytes = unsafe { satin_vt_take_replies(self.handle, &raw mut len) };
        take_bytes(bytes, len)
    }

    pub fn clear_replies(&mut self) {
        let _ = self.take_replies();
    }

    pub fn take_bell_count(&self) -> u64 {
        // SAFETY: `handle` is live.
        unsafe { satin_vt_take_bell_count(self.handle) }
    }

    pub fn prompt_seen(&self) -> bool {
        // SAFETY: `handle` is live.
        unsafe { satin_vt_prompt_seen(self.handle) != 0 }
    }

    pub fn prompt_generation(&self) -> u64 {
        // SAFETY: `handle` is live.
        unsafe { satin_vt_prompt_generation(self.handle) }
    }

    pub fn reset_prompt(&mut self) {
        // SAFETY: `handle` is live.
        unsafe { satin_vt_reset_prompt(self.handle) };
    }
}

impl Drop for KizuVt {
    fn drop(&mut self) {
        // SAFETY: `handle` came from `satin_vt_create` and is destroyed once.
        unsafe { satin_vt_destroy(self.handle) };
        self.handle = ptr::null_mut();
    }
}

/// Copies malloc storage from Kizu into a Vec and frees it.
fn take_bytes(bytes: *mut u8, len: usize) -> Vec<u8> {
    if bytes.is_null() {
        return Vec::new();
    }
    // SAFETY: Kizu returned `len` readable bytes of malloc storage.
    let out = unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec();
    // SAFETY: the storage came from malloc and is freed once.
    unsafe { libc::free(bytes.cast()) };
    out
}
