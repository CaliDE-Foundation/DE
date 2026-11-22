//! cali-shell: the Cali desktop shell.
//!
//! The compositor (Zig) talks to the shell only through the C ABI below.
//! Keep it small and stable, and keep it in sync with `include/cali_shell.h`.

use std::ffi::{c_char, CStr};

mod panel;

const VERSION: &CStr = c"0.1.0";

/// Shell state owned by the compositor through an opaque pointer.
pub struct Shell {
    started: bool,
}

impl Shell {
    fn new() -> Self {
        Shell { started: false }
    }

    fn start(&mut self) {
        self.started = true;
    }
}

/// Returns the shell version as a static NUL-terminated string.
#[no_mangle]
pub extern "C" fn cali_shell_version() -> *const c_char {
    VERSION.as_ptr()
}

/// Creates the shell. Free it with `cali_shell_free`.
#[no_mangle]
pub extern "C" fn cali_shell_new() -> *mut Shell {
    Box::into_raw(Box::new(Shell::new()))
}

/// Called once the compositor is ready. Returns `true` on success.
///
/// # Safety
/// `shell` must come from `cali_shell_new` and must not have been freed.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_start(shell: *mut Shell) -> bool {
    match unsafe { shell.as_mut() } {
        Some(s) => {
            s.start();
            s.started
        }
        None => false,
    }
}

/// Height of the top bar in logical pixels.
#[no_mangle]
pub extern "C" fn cali_shell_panel_height() -> u32 {
    panel::HEIGHT
}

/// Writes the top bar clock text (for example "Nov 22  17:05") into `buf`
/// as a NUL-terminated string. Returns the length without the NUL, or 0 if
/// `buf` is NULL or too small.
///
/// # Safety
/// `buf` must point to at least `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_clock_text(buf: *mut c_char, len: usize) -> usize {
    if buf.is_null() || len == 0 {
        return 0;
    }
    let text = panel::clock_text();
    let bytes = text.as_bytes();
    if bytes.len() + 1 > len {
        unsafe { *buf = 0 };
        return 0;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf.cast::<u8>(), bytes.len());
        *buf.add(bytes.len()) = 0;
    }
    bytes.len()
}

/// Frees a shell created by `cali_shell_new`. A NULL pointer is ignored.
///
/// # Safety
/// `shell` must come from `cali_shell_new` and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_free(shell: *mut Shell) {
    if !shell.is_null() {
        drop(unsafe { Box::from_raw(shell) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lifecycle() {
        let s = cali_shell_new();
        assert!(unsafe { cali_shell_start(s) });
        unsafe { cali_shell_free(s) };
        assert!(!unsafe { cali_shell_start(std::ptr::null_mut()) });
    }

    #[test]
    fn clock_text_fits_and_terminates() {
        let mut buf = [0 as c_char; 64];
        let n = unsafe { cali_shell_clock_text(buf.as_mut_ptr(), buf.len()) };
        assert!(n > 0);
        let s = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_str().unwrap();
        assert_eq!(s.len(), n);
        assert!(s.contains(':'), "{s:?}");

        let mut tiny = [1 as c_char; 2];
        assert_eq!(unsafe { cali_shell_clock_text(tiny.as_mut_ptr(), tiny.len()) }, 0);
        assert_eq!(tiny[0], 0);
    }
}
