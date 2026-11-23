//! Lock screen password checks through PAM.
//!
//! libpam is loaded at runtime (dlopen), so Cali builds without PAM headers.
//! Checks run on a thread: PAM can take seconds (it delays after a wrong
//! password) and the compositor must keep drawing meanwhile.

use std::ffi::{c_char, c_int, c_void, CString};
use std::sync::atomic::{AtomicI32, Ordering};

pub const PENDING: i32 = -1;
pub const IDLE: i32 = -2;
pub const FAILED: i32 = 0;
pub const OK: i32 = 1;

static RESULT: AtomicI32 = AtomicI32::new(IDLE);

/// The PAM service: Cali's own if installed, else the first common one
/// this system has.
fn service() -> &'static str {
    ["cali-lock", "login", "system-auth"]
        .into_iter()
        .find(|name| std::path::Path::new("/etc/pam.d").join(name).exists())
        .unwrap_or("other")
}

/// Starts checking `password` for `user`. Returns false if a check is
/// already running.
pub fn start(user: String, password: String) -> bool {
    if RESULT.swap(PENDING, Ordering::SeqCst) == PENDING {
        return false;
    }
    std::thread::spawn(move || {
        let ok = authenticate(service(), &user, &password);
        RESULT.store(if ok { OK } else { FAILED }, Ordering::SeqCst);
    });
    true
}

/// PENDING while checking, then OK or FAILED (once), then IDLE.
pub fn poll() -> i32 {
    let r = RESULT.load(Ordering::SeqCst);
    if r == OK || r == FAILED {
        RESULT.store(IDLE, Ordering::SeqCst);
    }
    r
}

// ---- PAM via dlopen ----------------------------------------------------------------------

#[repr(C)]
struct PamMessage {
    msg_style: c_int,
    msg: *const c_char,
}

#[repr(C)]
struct PamResponse {
    resp: *mut c_char,
    resp_retcode: c_int,
}

#[repr(C)]
struct PamConv {
    conv: extern "C" fn(c_int, *mut *const PamMessage, *mut *mut PamResponse, *mut c_void) -> c_int,
    appdata: *mut c_void,
}

const PAM_SUCCESS: c_int = 0;
const PAM_CONV_ERR: c_int = 19;
const PAM_PROMPT_ECHO_OFF: c_int = 1;
const PAM_PROMPT_ECHO_ON: c_int = 2;
const RTLD_NOW: c_int = 2;

extern "C" {
    fn dlopen(file: *const c_char, mode: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
    fn calloc(n: usize, size: usize) -> *mut c_void;
    fn strdup(s: *const c_char) -> *mut c_char;
}

/// Answers PAM's prompts: the password for hidden prompts, the user name
/// for visible ones, nothing for info messages.
extern "C" fn converse(n: c_int, msgs: *mut *const PamMessage, out: *mut *mut PamResponse, appdata: *mut c_void) -> c_int {
    if n <= 0 || msgs.is_null() || out.is_null() || appdata.is_null() {
        return PAM_CONV_ERR;
    }
    let creds = unsafe { &*(appdata as *const (CString, CString)) };
    let replies = unsafe { calloc(n as usize, std::mem::size_of::<PamResponse>()) } as *mut PamResponse;
    if replies.is_null() {
        return PAM_CONV_ERR;
    }
    for i in 0..n as usize {
        let msg = unsafe { &**msgs.add(i) };
        let answer = match msg.msg_style {
            PAM_PROMPT_ECHO_OFF => Some(&creds.1),
            PAM_PROMPT_ECHO_ON => Some(&creds.0),
            _ => None,
        };
        if let Some(text) = answer {
            unsafe { (*replies.add(i)).resp = strdup(text.as_ptr()) };
        }
    }
    unsafe { *out = replies };
    PAM_SUCCESS
}

type PamStart = unsafe extern "C" fn(*const c_char, *const c_char, *const PamConv, *mut *mut c_void) -> c_int;
type PamHandleFn = unsafe extern "C" fn(*mut c_void, c_int) -> c_int;

pub fn authenticate(service: &str, user: &str, password: &str) -> bool {
    let (Ok(service), Ok(user_c), Ok(pass_c)) = (CString::new(service), CString::new(user), CString::new(password)) else {
        return false;
    };
    unsafe {
        let lib = dlopen(c"libpam.so.0".as_ptr(), RTLD_NOW);
        if lib.is_null() {
            return false;
        }
        let sym = |name: &std::ffi::CStr| dlsym(lib, name.as_ptr());
        let (start, auth, acct, end) = (sym(c"pam_start"), sym(c"pam_authenticate"), sym(c"pam_acct_mgmt"), sym(c"pam_end"));
        if start.is_null() || auth.is_null() || acct.is_null() || end.is_null() {
            return false;
        }
        let start: PamStart = std::mem::transmute(start);
        let auth: PamHandleFn = std::mem::transmute(auth);
        let acct: PamHandleFn = std::mem::transmute(acct);
        let end: PamHandleFn = std::mem::transmute(end);

        let creds = Box::new((user_c.clone(), pass_c));
        let conv = PamConv { conv: converse, appdata: &*creds as *const _ as *mut c_void };
        let mut handle: *mut c_void = std::ptr::null_mut();
        if start(service.as_ptr(), user_c.as_ptr(), &conv, &mut handle) != PAM_SUCCESS {
            return false;
        }
        let mut status = auth(handle, 0);
        if status == PAM_SUCCESS {
            status = acct(handle, 0);
        }
        end(handle, status);
        status == PAM_SUCCESS
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrong_password_fails() {
        // No real account has this password; without PAM it fails too.
        assert!(!authenticate("login", "cali-test-nobody", "definitely wrong"));
    }

    #[test]
    fn poll_reports_once() {
        RESULT.store(OK, Ordering::SeqCst);
        assert_eq!(poll(), OK);
        assert_eq!(poll(), IDLE);
    }
}
