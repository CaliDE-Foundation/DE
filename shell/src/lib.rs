//! cali-shell: the Cali desktop shell.
//!
//! The compositor (Zig) talks to the shell only through the C ABI below.
//! Keep it small and stable, and keep it in sync with `include/cali_shell.h`.

use std::ffi::{c_char, CStr};

mod calendar;
mod capture;
mod keyboard;
mod lock;
mod wallpaper;
mod dock;
mod draw;
mod search;
mod status;
mod tiling;
mod wobble;
mod icons;
mod menu;
mod overview;
mod panel;
mod rules;
mod workspaces;

pub use calendar::CaliDay;
pub use dock::CaliDockStyle;
pub use status::CaliStatus;
pub use wobble::CaliWobble;
pub use rules::CaliRuleActions;

/// Replaces the window rules (one "MATCH -> ACTIONS" per line).
///
/// # Safety
/// `text` must be a valid C string.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_set_window_rules(text: *const c_char) {
    if !text.is_null() {
        rules::set(&CStr::from_ptr(text).to_string_lossy());
    }
}

/// The actions for a window, from every rule that matches its app id,
/// class or title. Returns false if no rule matches.
///
/// # Safety
/// Strings may be null; `out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_window_rules_for(app: *const c_char, class: *const c_char, title: *const c_char, out: *mut CaliRuleActions) -> bool {
    let s = |p: *const c_char| if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() };
    match rules::lookup(&s(app), &s(class), &s(title)) {
        Some(a) if !out.is_null() => {
            *out = a;
            true
        }
        _ => false,
    }
}

/// Sets the clock's date and 12/24-hour options.
#[no_mangle]
pub extern "C" fn cali_shell_set_clock_date_options(date: bool, h24: bool) {
    panel::set_clock_date_options(date, h24);
}

/// Overview layout with a custom gap between windows.
///
/// # Safety
/// As `cali_shell_overview_layout`.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_overview_layout_gap(
    area: CaliRect,
    windows: *const CaliRect,
    n: usize,
    gap: f32,
    out: *mut CaliRect,
) -> usize {
    if n == 0 || windows.is_null() || out.is_null() {
        return 0;
    }
    let placed = overview::layout_with_gap(area, unsafe { std::slice::from_raw_parts(windows, n) }, gap);
    unsafe { std::slice::from_raw_parts_mut(out, placed.len()) }.copy_from_slice(&placed);
    placed.len()
}

/// Tiling: writes `n` window rects into `out`. `mode` 1 = dwindle (uses
/// `ratio`), 2 = scrolling columns (uses `focused` and `ratio` as the column
/// width share). Returns how many were written.
///
/// # Safety
/// `out` must point to `n` writable rects.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_tile(mode: u32, area: CaliRect, n: usize, focused: usize, ratio: f32, gap: f32, out: *mut CaliRect) -> usize {
    if n == 0 || out.is_null() {
        return 0;
    }
    let rects = match mode {
        1 => tiling::dwindle(area, n, gap, ratio),
        2 => tiling::scrolling(area, n, focused, ratio, gap),
        _ => return 0,
    };
    unsafe { std::slice::from_raw_parts_mut(out, rects.len()) }.copy_from_slice(&rects);
    rects.len()
}

/// Wobbly windows: advances the springs after the window moved (dx, dy) in
/// `dt` seconds. Returns true once it has settled.
///
/// # Safety
/// `w` must point to a valid `CaliWobble`.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_wobble_step(w: *mut CaliWobble, dx: f32, dy: f32, dt: f32, strength: f32, friction: f32) -> bool {
    let Some(w) = (unsafe { w.as_mut() }) else { return true };
    wobble::step(w, dx, dy, dt, strength, friction);
    wobble::settled(w)
}

/// Wobbly windows: how far to move vertex (x, y) of a window grabbed at (gx, gy).
///
/// # Safety
/// `w` must point to a valid `CaliWobble`; `ox`/`oy` must be writable.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_wobble_offset(w: *const CaliWobble, x: f32, y: f32, gx: f32, gy: f32, width: f32, height: f32, ox: *mut f32, oy: *mut f32) {
    let (Some(w), false, false) = (unsafe { w.as_ref() }, ox.is_null(), oy.is_null()) else { return };
    let (dx, dy) = wobble::offset(w, x, y, gx, gy, width, height);
    unsafe {
        *ox = dx;
        *oy = dy;
    }
}

/// The `i`th top bar status icon for `status`, left to right; NULL past the end.
///
/// # Safety
/// `status` must be NULL or point to a valid `CaliStatus`.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_status_icons(status: *const CaliStatus, i: usize) -> *const c_char {
    let s = if status.is_null() { CaliStatus::default() } else { unsafe { *status } };
    status::icons(&s).get(i).map_or(std::ptr::null(), |n| n.as_ptr())
}

/// Volume icon for a level (0-1) and mute state.
#[no_mangle]
pub extern "C" fn cali_shell_volume_icon(volume: f32, muted: bool) -> *const c_char {
    status::volume_icon(volume, muted).as_ptr()
}

/// An accent color name (coral, blue, ...) as 0xRRGGBBAA; coral if unknown.
///
/// # Safety
/// `name` must be NULL or a valid C string.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_accent_rgba(name: *const c_char) -> u32 {
    let name = if name.is_null() { "" } else { unsafe { CStr::from_ptr(name) }.to_str().unwrap_or("") };
    accent(name)
}

/// Accent colors: GNOME's palette, plus Cali's coral (the default).
pub fn accent(name: &str) -> u32 {
    match name {
        "blue" => 0x3584e4ff,
        "teal" => 0x2190a4ff,
        "green" => 0x3a944aff,
        "yellow" => 0xc88800ff,
        "orange" => 0xed5b00ff,
        "red" => 0xe62d42ff,
        "pink" => 0xd56199ff,
        "purple" => 0x9141acff,
        "slate" => 0x6f8396ff,
        _ => 0xe2725bff, // coral
    }
}

/// Sets what the top bar clock shows.
#[no_mangle]
pub extern "C" fn cali_shell_set_clock_options(weekday: bool, seconds: bool) {
    panel::set_clock_options(weekday, seconds);
}

/// Replaces the dock favorites with a comma-separated list of desktop IDs.
///
/// # Safety
/// `list` must be NULL or a valid C string.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_set_dock_favorites(list: *const c_char) {
    if !list.is_null() {
        dock::set_favorites(&unsafe { CStr::from_ptr(list) }.to_string_lossy());
    }
}

/// Today's date as year, month (1-12) and day.
///
/// # Safety
/// Each pointer must be NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_calendar_today(year: *mut i32, month: *mut u32, day: *mut u32) {
    let (y, m, d) = panel::today();
    unsafe {
        if !year.is_null() {
            *year = y;
        }
        if !month.is_null() {
            *month = m;
        }
        if !day.is_null() {
            *day = d;
        }
    }
}

/// Fills `out` (42 cells, 6 weeks from Sunday) with the grid for
/// `year`/`month` (1-12), marking today.
///
/// # Safety
/// `out` must point to 42 writable `CaliDay`s.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_calendar_grid(year: i32, month: u32, out: *mut CaliDay) -> bool {
    if out.is_null() || !(1..=12).contains(&month) {
        return false;
    }
    let cells = calendar::grid(year, month, panel::today());
    unsafe { std::ptr::copy_nonoverlapping(cells.as_ptr(), out, calendar::CELLS) };
    true
}

/// Moves `delta` months from `*year`/`*month`, in place.
///
/// # Safety
/// Both pointers must be valid.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_calendar_add_months(year: *mut i32, month: *mut u32, delta: i32) {
    if year.is_null() || month.is_null() {
        return;
    }
    let (y, m) = calendar::add_months(unsafe { *year }, unsafe { *month }, delta);
    unsafe {
        *year = y;
        *month = m;
    }
}

/// Formats a date with strftime (`format`) in the user's locale into `buf`.
/// Day 0 means today. Returns the length written.
///
/// # Safety
/// `format` must be a C string and `buf` must point to `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_format_date(
    year: i32,
    month: u32,
    day: u32,
    format: *const c_char,
    buf: *mut c_char,
    len: usize,
) -> usize {
    if format.is_null() || buf.is_null() || len == 0 {
        return 0;
    }
    let date = if day == 0 { None } else { Some((year, month, day)) };
    let text = panel::format_date(date, unsafe { CStr::from_ptr(format) });
    write_c_string(&text, buf, len)
}

/// Scores how well `query` matches `text` for search: higher is better,
/// -1 for no match.
///
/// # Safety
/// Both must be NULL or valid C strings.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_search_score(query: *const c_char, text: *const c_char) -> i32 {
    if query.is_null() || text.is_null() {
        return -1;
    }
    let q = unsafe { CStr::from_ptr(query) }.to_string_lossy();
    let t = unsafe { CStr::from_ptr(text) }.to_string_lossy();
    search::score(&q, &t).map_or(-1, |s| s as i32)
}

// ---- Screenshots -------------------------------------------------------------------

/// Writes the path for a new screenshot (in Pictures/Screenshots, created
/// if needed) into `buf`. Returns its length, 0 on failure.
///
/// # Safety
/// `buf` must point to `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_screenshot_path(buf: *mut c_char, len: usize) -> usize {
    if buf.is_null() || len == 0 {
        return 0;
    }
    let stamp = panel::format_date(None, c"%Y-%m-%d %H-%M-%S");
    match capture::screenshot_path(&stamp) {
        Some(p) => write_c_string(&p.to_string_lossy(), buf, len),
        None => 0,
    }
}

/// Saves premultiplied RGBA pixels as a PNG at `path`.
///
/// # Safety
/// `path` must be a C string and `data` must hold `stride * height` bytes.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_save_png(path: *const c_char, width: u32, height: u32, stride: usize, data: *const u8) -> bool {
    if path.is_null() || data.is_null() {
        return false;
    }
    let path = unsafe { CStr::from_ptr(path) }.to_string_lossy().into_owned();
    let data = unsafe { std::slice::from_raw_parts(data, stride * height as usize) };
    capture::save_png(std::path::Path::new(&path), width, height, stride, data)
}

// ---- Lock screen ---------------------------------------------------------------------

extern "C" {
    fn getuid() -> u32;
    fn getpwuid(uid: u32) -> *const *const c_char; // struct passwd starts with pw_name
}

/// The logged-in user's name.
pub fn current_user() -> String {
    if let Ok(user) = std::env::var("USER") {
        if !user.is_empty() {
            return user;
        }
    }
    unsafe {
        let pw = getpwuid(getuid());
        if pw.is_null() || (*pw).is_null() {
            return String::new();
        }
        CStr::from_ptr(*pw).to_string_lossy().into_owned()
    }
}

/// Writes the current user's name into `buf`.
///
/// # Safety
/// `buf` must point to `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_current_user(buf: *mut c_char, len: usize) -> usize {
    if buf.is_null() || len == 0 {
        return 0;
    }
    write_c_string(&current_user(), buf, len)
}

/// Starts checking the user's password in the background (PAM).
/// Returns false if a check is already running.
///
/// # Safety
/// `password` must be a valid C string.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_auth_start(password: *const c_char) -> bool {
    if password.is_null() {
        return false;
    }
    let password = unsafe { CStr::from_ptr(password) }.to_string_lossy().into_owned();
    lock::start(current_user(), password)
}

/// -1 while checking, 1 = correct, 0 = wrong (each reported once), -2 idle.
#[no_mangle]
pub extern "C" fn cali_shell_auth_poll() -> i32 {
    lock::poll()
}

// ---- Wallpaper ----------------------------------------------------------------------

/// If `name` is a built-in gradient, writes its colors (0xRRGGBBAA) and
/// returns true.
///
/// # Safety
/// `name` must be NULL or a C string; `top`/`bottom` must be writable.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_wallpaper_gradient(name: *const c_char, top: *mut u32, bottom: *mut u32) -> bool {
    if name.is_null() || top.is_null() || bottom.is_null() {
        return false;
    }
    let name = unsafe { CStr::from_ptr(name) }.to_string_lossy();
    match wallpaper::gradient(&name) {
        Some((t, b)) => {
            unsafe {
                *top = t;
                *bottom = b;
            }
            true
        }
        None => false,
    }
}

/// Loads a PNG/JPEG as premultiplied RGBA. Returns the pixels (free with
/// `cali_shell_free_image`) and writes the size, or NULL on failure.
///
/// # Safety
/// `path` must be a C string; `width`/`height` must be writable.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_load_image(path: *const c_char, width: *mut u32, height: *mut u32) -> *mut u8 {
    if path.is_null() || width.is_null() || height.is_null() {
        return std::ptr::null_mut();
    }
    let path = unsafe { CStr::from_ptr(path) }.to_string_lossy().into_owned();
    let Some((w, h, pixels)) = wallpaper::load(std::path::Path::new(&path)) else {
        return std::ptr::null_mut();
    };
    unsafe {
        *width = w;
        *height = h;
    }
    Box::into_raw(pixels.into_boxed_slice()) as *mut u8
}

/// Frees pixels from `cali_shell_load_image` (`len` = width * height * 4).
///
/// # Safety
/// `pixels` must come from `cali_shell_load_image` with that size.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_free_image(pixels: *mut u8, len: usize) {
    if !pixels.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(pixels, len)) });
    }
}

// ---- Keyboard and folders --------------------------------------------------------------

/// The top bar's short name for an xkb layout ("us" -> "en").
///
/// # Safety
/// `layout` must be a C string; `buf` must point to `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_layout_short_name(layout: *const c_char, buf: *mut c_char, len: usize) -> usize {
    if layout.is_null() || buf.is_null() || len == 0 {
        return 0;
    }
    let name = keyboard::short_name(&unsafe { CStr::from_ptr(layout) }.to_string_lossy());
    write_c_string(&name, buf, len)
}

/// The app grid folder ("Utilities", "System") for desktop Categories, or NULL.
///
/// # Safety
/// `categories` must be NULL or a C string.
#[no_mangle]
pub unsafe extern "C" fn cali_shell_app_folder(categories: *const c_char) -> *const c_char {
    if categories.is_null() {
        return std::ptr::null();
    }
    match keyboard::folder(&unsafe { CStr::from_ptr(categories) }.to_string_lossy()) {
        Some("System") => c"System".as_ptr(),
        Some(_) => c"Utilities".as_ptr(),
        None => std::ptr::null(),
    }
}

/// Copies `text` into `buf` as a C string, truncating at a character
/// boundary. Returns the length written (without the NUL).
fn write_c_string(text: &str, buf: *mut c_char, len: usize) -> usize {
    let mut end = text.len().min(len - 1);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(text.as_ptr(), buf.cast::<u8>(), end);
        *buf.add(end) = 0;
    }
    end
}
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
    dock::favorite(i).unwrap_or(std::ptr::null())
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
    fn accents() {
        assert_eq!(accent("blue"), 0x3584e4ff);
        assert_eq!(accent("nonsense"), accent("coral"));
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
