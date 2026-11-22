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
    fn mktime(tm: *mut Tm) -> i64;
    fn strftime(s: *mut c_char, max: usize, format: *const c_char, tm: *const Tm) -> usize;
}

fn now() -> Option<Tm> {
    unsafe {
        let t = time(std::ptr::null_mut());
        let mut tm = std::mem::zeroed::<Tm>();
        (!localtime_r(&t, &mut tm).is_null()).then_some(tm)
    }
}

/// Today as (year, month 1-12, day).
pub fn today() -> (i32, u32, u32) {
    now().map_or((1970, 1, 1), |tm| (tm.tm_year + 1900, tm.tm_mon as u32 + 1, tm.tm_mday as u32))
}

/// Formats `date` (year, month 1-12, day), or now, with a strftime format.
pub fn format_date(date: Option<(i32, u32, u32)>, format: &CStr) -> String {
    let Some(mut tm) = now() else {
        return String::new();
    };
    if let Some((y, m, d)) = date {
        tm.tm_year = y - 1900;
        tm.tm_mon = m as c_int - 1;
        tm.tm_mday = d as c_int;
        tm.tm_hour = 12;
        tm.tm_isdst = -1;
        unsafe { mktime(&mut tm) }; // fills in the weekday
    }
    let mut buf = [0 as c_char; 128];
    let n = unsafe { strftime(buf.as_mut_ptr(), buf.len(), format.as_ptr(), &tm) };
    let bytes: Vec<u8> = buf[..n].iter().map(|&b| b as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// Current local time formatted for the top bar.
pub fn clock_text() -> String {
    format_date(None, CLOCK_FORMAT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_a_given_date() {
        // Use the C locale's English names: tests don't set a locale.
        assert_eq!(format_date(Some((2026, 11, 22)), c"%A %Y-%m-%d"), "Sunday 2026-11-22");
        assert_eq!(format_date(Some((2024, 2, 29)), c"%a"), "Thu");
    }

    #[test]
    fn today_is_a_valid_date() {
        let (y, m, d) = today();
        assert!(y >= 2024 && (1..=12).contains(&m) && (1..=31).contains(&d));
    }
}
