//! Tiling: Hyprland-style dwindle or niri-style scrolling columns (the
//! tiling-mode setting), per monitor and workspace. The layouts come from
//! cali-shell (Rust). Super+T moves a window in or out of the layout; with
//! scrolling columns Super+Left/Right move between columns. Dialogs and
//! windows that can't be resized always float.

const std = @import("std");
const plugin = @import("plugin.zig");
const config = @import("config.zig");
const c = plugin.c;

const max_windows = 64;
const floating_key = "cali-floating";

var display: ?*c.MetaDisplay = null;
var action_toggle: c_uint = 0;
var order: [max_windows]*c.MetaWindow = undefined; // in the order they opened
var n_order: usize = 0;
var pending = false;
var handlers_installed = false;

pub fn init(d: ?*c.MetaDisplay) void {
    display = d;
    @import("keys.zig").bind(d, "key-tile-float", "<Super>t", &action_toggle);
    plugin.connect(d, "accelerator-activated", &onAccelerator, null);
    plugin.connect(d, "window-created", &onWindowCreated, null);
    plugin.connect(d, "focus-window", &onFocus, null);
}

fn isTileable(window: ?*c.MetaWindow) bool {
    const w = window orelse return false;
    if (!plugin.isAppWindow(w)) return false;
    if (c.meta_window_get_transient_for(w) != null) return false; // dialogs float
    if (c.meta_window_allows_resize(w) == 0) return false;
    if (c.meta_window_is_skip_taskbar(w) != 0) return false;
    return true;
}

fn isFloating(window: *c.MetaWindow) bool {
    return c.g_object_get_data(@ptrCast(@alignCast(window)), floating_key) != null;
}

fn setFloating(window: *c.MetaWindow, floating: bool) void {
    c.g_object_set_data(@ptrCast(@alignCast(window)), floating_key, if (floating) @ptrFromInt(1) else null);
}

fn onWindowCreated(_: ?*c.MetaDisplay, window: ?*c.MetaWindow, _: c.gpointer) callconv(.C) void {
    const w = window orelse return;
    plugin.connect(w, "unmanaged", &onUnmanaged, null);
    plugin.connect(w, "workspace-changed", &onWindowChanged, null);
    plugin.connect(w, "notify::minimized", &onWindowChanged, null);
}

/// A window appeared (from the map effect): add it to the layout.
/// `rule` is a window rule's choice: -1 none, 0 tile, 1 float.
pub fn windowMapped(window: ?*c.MetaWindow, rule: i8) void {
    const w = window orelse return;
    if (!isTileable(w)) return;
    for (order[0..n_order]) |o| if (o == w) return;
    if (n_order == max_windows) return;
    order[n_order] = w;
    n_order += 1;
    if (rule == 1 or (rule == -1 and !config.tiling_new_tiled)) setFloating(w, true);
    schedule();
}

fn onUnmanaged(window: ?*c.MetaWindow, _: c.gpointer) callconv(.C) void {
    for (order[0..n_order], 0..) |o, i| {
        if (o != window) continue;
        std.mem.copyForwards(*c.MetaWindow, order[i .. n_order - 1], order[i + 1 .. n_order]);
        n_order -= 1;
        break;
    }
    schedule();
}

fn onWindowChanged(_: ?*c.MetaWindow, _: c.gpointer) callconv(.C) void {
    schedule();
}

fn onFocus(_: ?*c.MetaDisplay, _: ?*c.MetaWindow, _: i64, _: c.gpointer) callconv(.C) void {
    if (config.tiling_mode == .scrolling) schedule(); // keep the focused column in view
}

fn onAccelerator(_: ?*c.MetaDisplay, action: c_uint, _: ?*c.ClutterInputDevice, _: c_uint, _: c.gpointer) callconv(.C) void {
    if (action == 0 or action != action_toggle or config.tiling_mode == .off) return;
    const d = display orelse return;
    const w = c.meta_display_get_focus_window(d) orelse return;
    if (!isTileable(w)) return;
    const floating = !isFloating(w);
    setFloating(w, floating);
    if (floating) {
        // Back to a comfortable floating size, centered on its monitor.
        var area: c.MtkRectangle = undefined;
        c.meta_workspace_get_work_area_for_monitor(c.meta_window_get_workspace(w), c.meta_window_get_monitor(w), &area);
        const fw = @divTrunc(area.width * 3, 5);
        const fh = @divTrunc(area.height * 3, 5);
        c.meta_window_move_resize_frame(w, 0, area.x + @divTrunc(area.width - fw, 2), area.y + @divTrunc(area.height - fh, 2), fw, fh);
    }
    schedule();
}

/// Re-applies the layout everywhere (a tiling setting changed).
pub fn retileAll() void {
    updateKeybindings();
    schedule();
}

fn schedule() void {
    if (pending or config.tiling_mode == .off) return;
    pending = true;
    _ = c.g_idle_add(&runRetile, null);
}

fn isMinimized(window: *c.MetaWindow) bool {
    var minimized: c.gboolean = 0;
    c.g_object_get(window, "minimized", &minimized, @as(?*anyopaque, null));
    return minimized != 0;
}

fn runRetile(_: c.gpointer) callconv(.C) c.gboolean {
    pending = false;
    const d = display orelse return 0;
    if (config.tiling_mode == .off) return 0;
    const workspace = c.meta_workspace_manager_get_active_workspace(c.meta_display_get_workspace_manager(d));
    const focus = c.meta_display_get_focus_window(d);
    const monitors = c.meta_display_get_n_monitors(d);
    var m: c_int = 0;
    while (m < monitors) : (m += 1) retileMonitor(workspace, m, focus);
    return 0;
}

var last_focused: [8]usize = .{0} ** 8;

fn retileMonitor(workspace: ?*c.MetaWorkspace, monitor: c_int, focus: ?*c.MetaWindow) void {
    var windows: [max_windows]*c.MetaWindow = undefined;
    var n: usize = 0;
    var focused: ?usize = null;
    for (order[0..n_order]) |w| {
        if (isFloating(w) or isMinimized(w)) continue;
        if (c.meta_window_is_fullscreen(w) != 0) continue;
        if (c.meta_window_get_monitor(w) != monitor) continue;
        if (c.meta_window_located_on_workspace(w, workspace) == 0) continue;
        if (focus == w) focused = n;
        windows[n] = w;
        n += 1;
    }
    if (n == 0) return;

    var work: c.MtkRectangle = undefined;
    c.meta_workspace_get_work_area_for_monitor(workspace, monitor, &work);
    const outer = config.tiling_outer_gap;
    const area = c.CaliRect{
        .x = @as(f32, @floatFromInt(work.x)) + outer,
        .y = @as(f32, @floatFromInt(work.y)) + outer,
        .width = @as(f32, @floatFromInt(work.width)) - 2 * outer,
        .height = @as(f32, @floatFromInt(work.height)) - 2 * outer,
    };
    const slot: usize = @intCast(@min(@max(monitor, 0), 7));
    const focus_index = focused orelse @min(last_focused[slot], n - 1);
    last_focused[slot] = focus_index;

    const mode: c_uint = if (config.tiling_mode == .dwindle) 1 else 2;
    const ratio = if (config.tiling_mode == .dwindle) config.tiling_split else config.tiling_column;
    var rects: [max_windows]c.CaliRect = undefined;
    const placed = c.cali_shell_tile(mode, area, n, focus_index, ratio, config.tiling_gap, &rects);
    for (windows[0..placed], rects[0..placed]) |w, r| {
        if (c.meta_window_is_maximized(w) != 0) c.meta_window_unmaximize(w);
        // As a user move: Sookie then lets scrolled-away columns sit mostly
        // off screen (a sliver stays visible) instead of forcing them back.
        c.meta_window_move_resize_frame(w, 1, @intFromFloat(@round(r.x)), @intFromFloat(@round(r.y)), @intFromFloat(@round(r.width)), @intFromFloat(@round(r.height)));
    }
}

// ---- Super+Left/Right between columns (scrolling mode) -------------------------------

fn updateKeybindings() void {
    const want = config.tiling_mode != .off;
    if (want == handlers_installed) return;
    handlers_installed = want;
    if (want) {
        _ = c.meta_keybindings_set_custom_handler("toggle-tiled-left", &onFocusNeighbor, null, null);
        _ = c.meta_keybindings_set_custom_handler("toggle-tiled-right", &onFocusNeighbor, @ptrFromInt(1), null);
    } else {
        // Back to Sookie's half-screen snapping.
        _ = c.meta_keybindings_set_custom_handler("toggle-tiled-left", null, null, null);
        _ = c.meta_keybindings_set_custom_handler("toggle-tiled-right", null, null, null);
    }
}

fn onFocusNeighbor(_: ?*c.MetaDisplay, window: ?*c.MetaWindow, _: ?*const c.ClutterEvent, _: ?*c.MetaKeyBinding, data: c.gpointer) callconv(.C) void {
    const d = display orelse return;
    const current = window orelse return;
    const right = data != null;
    const workspace = c.meta_window_get_workspace(current);
    const monitor = c.meta_window_get_monitor(current);
    var prev: ?*c.MetaWindow = null;
    var found = false;
    for (order[0..n_order]) |w| {
        if (isFloating(w) or isMinimized(w) or c.meta_window_get_monitor(w) != monitor) continue;
        if (c.meta_window_located_on_workspace(w, workspace) == 0) continue;
        if (found and right) {
            c.meta_window_activate(w, c.meta_display_get_current_time_roundtrip(d));
            return;
        }
        if (w == current) {
            if (!right) {
                if (prev) |p| c.meta_window_activate(p, c.meta_display_get_current_time_roundtrip(d));
                return;
            }
            found = true;
        }
        prev = w;
    }
}
