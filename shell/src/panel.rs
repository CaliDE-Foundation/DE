//! The top bar: what it shows. The compositor (Zig) draws it.

use std::ffi::{c_char, c_int, c_long, CStr};

/// Bar height in logical pixels.
pub const HEIGHT: u32 = 32;

/// GNOME-style clock: abbreviated month, day, en space, 24-hour time.
const CLOCK_FORMAT: &CStr = c"%b %-d\u{2002}%H:%M";

#[repr(C)]
struct Tm {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: *const c_char,
}

extern "C" {
    fn time(t: *mut i64) -> i64;
    fn localtime_r(t: *const i64, out: *mut Tm) -> *mut Tm;
    fn strftime(s: *mut c_char, max: usize, format: *const c_char, tm: *const Tm) -> usize;
}

/// Current local time formatted for the top bar.
pub fn clock_text() -> String {
    let mut buf = [0 as c_char; 64];
    let n = unsafe {
        let now = time(std::ptr::null_mut());
        let mut tm = std::mem::zeroed::<Tm>();
        if localtime_r(&now, &mut tm).is_null() {
            return String::new();
        }
        strftime(buf.as_mut_ptr(), buf.len(), CLOCK_FORMAT.as_ptr(), &tm)
    };
    let bytes: Vec<u8> = buf[..n].iter().map(|&b| b as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}
