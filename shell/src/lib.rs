//! cali-shell: the Cali desktop shell.
//!
//! The compositor (Zig) talks to the shell only through the C ABI below.
//! Keep it small and stable, and keep it in sync with `include/cali_shell.h`.

use std::ffi::{c_char, CStr};

mod dock;
mod draw;
mod icons;
mod menu;
mod overview;
mod panel;
mod workspaces;

pub use dock::CaliDockStyle;
pub use menu::{CaliMenuAction, CaliMenuStyle};
pub use overview::CaliRect;
pub use workspaces::CaliDotStyle;

/// Loads icon `name` (a theme icon name or an absolute path) as a `size` x
/// `size` premultiplied RGBA image into `buf`. Falls back to a generic app
/// icon. When `recolor` is true every pixel becomes `rgb` (0xRRGGBB), for
/// symbolic icons. Returns false if nothing could be loaded.
///
/// # Safety
/// `name` must be a valid C string and `buf` must point to `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_load_icon(
    name: *const c_char,
    size: u32,
    recolor: bool,
    rgb: u32,
    buf: *mut u8,
    len: usize,
) -> bool {
    let needed = size as usize * size as usize * 4;
    if name.is_null() || buf.is_null() || len < needed || size == 0 {
        return false;
    }
    let Ok(name) = unsafe { CStr::from_ptr(name) }.to_str() else {
        return false;
    };
    let Some(mut pixels) = icons::load_named(name, size) else {
        return false;
    };
    if recolor {
        let [_, r, g, b] = rgb.to_be_bytes();
        icons::recolor(&mut pixels, [r, g, b]);
    }
    unsafe { std::ptr::copy_nonoverlapping(pixels.as_ptr(), buf, needed) };
    true
}

/// Look of the dock.
#[no_mangle]
pub extern "C" fn cali_shell_dock_style() -> CaliDockStyle {
    dock::STYLE
}

/// The `i`th favorite app's desktop file ID, or NULL past the end.
#[no_mangle]
pub extern "C" fn cali_shell_dock_favorite(i: usize) -> *const c_char {
    dock::favorites().get(i).map_or(std::ptr::null(), |id| id.as_ptr())
}

/// Look of the system menu.
#[no_mangle]
pub extern "C" fn cali_shell_menu_style() -> CaliMenuStyle {
    menu::STYLE
}

/// The `i`th system menu entry's label (NULL past the end); its action is
/// written to `action`.
///
/// # Safety
/// `action` must be NULL or point to a writable `CaliMenuAction`.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_menu_entry(i: usize, action: *mut CaliMenuAction) -> *const c_char {
    let Some(entry) = menu::ENTRIES.get(i) else {
        return std::ptr::null();
    };
    if !action.is_null() {
        unsafe { *action = entry.action };
    }
    entry.label.as_ptr()
}

/// The `i`th status icon name in the top bar, or NULL past the end.
#[no_mangle]
pub extern "C" fn cali_shell_status_icon(i: usize) -> *const c_char {
    menu::STATUS_ICONS.get(i).map_or(std::ptr::null(), |n| n.as_ptr())
}

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

/// Lays out `n` windows for the Activities overview inside `area`.
/// Writes `n` target rectangles to `out` and returns how many were written.
///
/// # Safety
/// `windows` must point to `n` readable rects and `out` to `n` writable rects.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_overview_layout(
    area: CaliRect,
    windows: *const CaliRect,
    n: usize,
    out: *mut CaliRect,
) -> usize {
    if n == 0 || windows.is_null() || out.is_null() {
        return 0;
    }
    let input = unsafe { std::slice::from_raw_parts(windows, n) };
    let placed = overview::layout(area, input);
    let out = unsafe { std::slice::from_raw_parts_mut(out, placed.len()) };
    out.copy_from_slice(&placed);
    placed.len()
}

/// Look of the workspace dots in the top bar.
#[no_mangle]
pub extern "C" fn cali_shell_workspace_dots_style() -> CaliDotStyle {
    workspaces::DOTS
}

/// Decides how to keep GNOME-style dynamic workspaces. `occupied[i]` says
/// whether workspace `i` has windows. Writes the workspaces to remove
/// (highest index first) to `remove_out` and returns how many; sets
/// `*append_out` when an empty workspace should be added at the end.
///
/// # Safety
/// `occupied` must point to `n` bools, `remove_out` to `cap` writable u32s,
/// and `append_out` to a writable bool.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_workspace_plan(
    occupied: *const bool,
    n: usize,
    active: usize,
    remove_out: *mut u32,
    cap: usize,
    append_out: *mut bool,
) -> usize {
    if append_out.is_null() || (n > 0 && occupied.is_null()) || (cap > 0 && remove_out.is_null()) {
        return 0;
    }
    let occupied = if n == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(occupied, n) } };
    let plan = workspaces::plan(occupied, active);
    unsafe { *append_out = plan.append };
    let count = plan.remove.len().min(cap);
    for (i, index) in plan.remove.iter().take(count).enumerate() {
        unsafe { *remove_out.add(i) = *index as u32 };
    }
    count
}

/// Renders an anti-aliased rounded rectangle as premultiplied RGBA into
/// `buf` (`width * height * 4` bytes). `rgba` is 0xRRGGBBAA. Returns false if
/// `buf` is NULL or too small.
///
/// # Safety
/// `buf` must point to at least `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_render_rounded_rect(
    width: u32,
    height: u32,
    radius: f32,
    rgba: u32,
    buf: *mut u8,
    len: usize,
) -> bool {
    let (w, h) = (width as usize, height as usize);
    if buf.is_null() || len < w * h * 4 {
        return false;
    }
    let pixels = draw::rounded_rect(w, h, radius, rgba.to_be_bytes());
    unsafe { std::ptr::copy_nonoverlapping(pixels.as_ptr(), buf, pixels.len()) };
    true
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
