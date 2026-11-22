//! cali-shell: the Cali desktop shell.
//!
//! The compositor (Zig) talks to the shell only through the C ABI below.
//! Keep it small and stable, and keep it in sync with `include/cali_shell.h`.

use std::ffi::{c_char, CStr};

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
}
