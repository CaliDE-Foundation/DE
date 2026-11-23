//! The dock on the desktop (dock-mode "always" or "autohide"), at the
//! bottom, left or right (dock-position). GNOME's default, a dock only in
//! the overview, is dock-mode "overview" and lives in dock.zig. This one
//! shows favorites and open apps; clicking an open app focuses it (or
//! minimizes it if it's already in front), right-click gives the same menu
//! as the overview dock.

const std = @import("std");
const plugin = @import("plugin.zig");
const dock = @import("dock.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");
const c = plugin.c;

const max_apps = 24;
const edge_gap: f32 = 6; // between the dock and the screen edge
const trigger_size: f32 = 2; // autohide: the strip at the edge that reveals it

const App = struct { info: *c.GAppInfo, window: ?*c.MetaWindow };

var display: ?*c.MetaDisplay = null;
var layer: ?*c.ClutterActor = null; // where the top bar lives (above windows)
var actor: ?*c.ClutterActor = null;
var trigger: ?*c.ClutterActor = null;
var apps: [max_apps]App = undefined;
var n_apps: usize = 0;
var in_overview = false;
var revealed = false;
var hide_timer: c_uint = 0;
var pending = false;
var thickness: f32 = 0; // how much room "always" reserves

pub fn init(d: ?*c.MetaDisplay, parent: ?*c.ClutterActor) void {
    display = d;
    layer = parent;
    plugin.connect(d, "window-created", &onWindowCreated, null);
    plugin.connect(d, "focus-window", &onFocus, null);
}

fn onWindowCreated(_: ?*c.MetaDisplay, window: ?*c.MetaWindow, _: c.gpointer) callconv(.C) void {
    plugin.connect(window, "unmanaged", &onWindowGone, null);
    schedule();
}

fn onWindowGone(_: ?*c.MetaWindow, _: c.gpointer) callconv(.C) void {
    schedule();
}

fn onFocus(_: ?*c.MetaDisplay, _: ?*c.MetaWindow, _: i64, _: c.gpointer) callconv(.C) void {
    schedule();
}

/// Rebuild soon (several windows often change at once).
pub fn schedule() void {
    if (pending) return;
    pending = true;
    _ = c.g_idle_add(&runRebuild, null);
}

fn runRebuild(_: c.gpointer) callconv(.C) c.gboolean {
    pending = false;
    rebuild();
    return 0;
}

/// The overview has its own dock; step aside while it's open.
pub fn overviewChanged(open: bool) void {
    in_overview = open;
    const a = actor orelse return;
    ui.ease(a, 200, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(a, if (open) 0 else if (config.dock_mode == .autohide and !revealed) 0 else 255);
    c.clutter_actor_restore_easing_state(a);
}

/// Room to keep free for windows (dock-mode "always"), for the struts.
pub fn reserved() ?c.MetaStrut {
    if (config.dock_mode != .always or actor == null) return null;
    const d = display orelse return null;
    var r: c.MtkRectangle = undefined;
    c.meta_display_get_monitor_geometry(d, c.meta_display_get_primary_monitor(d), &r);
    const t: c_int = @intFromFloat(thickness);
    return switch (config.dock_position) {
        .bottom => .{ .rect = .{ .x = r.x, .y = r.y + r.height - t, .width = r.width, .height = t }, .side = @intCast(c.META_SIDE_BOTTOM) },
        .left => .{ .rect = .{ .x = r.x, .y = r.y, .width = t, .height = r.height }, .side = @intCast(c.META_SIDE_LEFT) },
        .right => .{ .rect = .{ .x = r.x + r.width - t, .y = r.y, .width = t, .height = r.height }, .side = @intCast(c.META_SIDE_RIGHT) },
    };
}

fn clear() void {
    if (actor) |a| c.clutter_actor_destroy(a);
    if (trigger) |t| c.clutter_actor_destroy(t);
    actor = null;
    trigger = null;
    for (apps[0..n_apps]) |app| c.g_object_unref(app.info);
    n_apps = 0;
}

fn addApp(info: *c.GAppInfo, window: ?*c.MetaWindow) void {
    for (apps[0..n_apps]) |*app| {
        if (c.g_app_info_equal(app.info, info) != 0) {
            if (app.window == null) app.window = window;
            c.g_object_unref(info);
            return;
        }
    }
    if (n_apps == max_apps) return c.g_object_unref(info);
    apps[n_apps] = .{ .info = info, .window = window };
    n_apps += 1;
}

fn collect() void {
    var i: usize = 0;
    while (c.cali_shell_dock_favorite(i)) |id| : (i += 1) {
        if (c.g_desktop_app_info_new(id)) |info| addApp(@ptrCast(@alignCast(info)), null);
    }
    const d = display orelse return;
    const windows = c.meta_display_list_all_windows(d);
    defer c.g_list_free(windows);
    var node = windows;
    while (node != null) : (node = node.*.next) {
        const window: ?*c.MetaWindow = @ptrCast(@alignCast(node.*.data));
        if (!plugin.isAppWindow(window) or c.meta_window_is_skip_taskbar(window) != 0) continue;
        if (dock.appForWindow(window)) |info| addApp(info, window);
    }
}

/// Builds the dock for the current settings (or removes it).
pub fn rebuild() void {
    const was_reserved = thickness;
    clear();
    defer if (thickness != was_reserved) plugin.updateStruts();
    if (config.dock_mode == .overview) {
        thickness = 0;
        return;
    }
    const d = display orelse return;
    const parent = layer orelse return;
    if (c.meta_display_get_n_monitors(d) == 0) return;
    collect();

    var style = c.cali_shell_dock_style();
    style.icon_size = config.dock_icon_size;
    style.corner_radius = config.radius(1.1);
    const vertical = config.dock_position != .bottom;
    const n: f32 = @floatFromInt(n_apps + 1);
    const long = n * style.icon_size + (n - 1) * style.spacing + 2 * style.padding;
    const short = style.icon_size + 2 * style.padding;
    const w = if (vertical) short else long;
    const h = if (vertical) long else short;

    var r: c.MtkRectangle = undefined;
    c.meta_display_get_monitor_geometry(d, c.meta_display_get_primary_monitor(d), &r);
    const mx: f32 = @floatFromInt(r.x);
    const my: f32 = @floatFromInt(r.y);
    const mw: f32 = @floatFromInt(r.width);
    const mh: f32 = @floatFromInt(r.height);
    const top: f32 = @floatFromInt(config.panelHeight());

    const a = ui.roundedRect(w, h, style.corner_radius, style.background);
    const pos: [2]f32 = switch (config.dock_position) {
        .bottom => .{ mx + (mw - w) / 2, my + mh - h - edge_gap },
        .left => .{ mx + edge_gap, my + top + (mh - top - h) / 2 },
        .right => .{ mx + mw - w - edge_gap, my + top + (mh - top - h) / 2 },
    };
    c.clutter_actor_set_position(a, pos[0], pos[1]);
    c.clutter_actor_set_reactive(a, 1);
    ui.accessible(a, c.ATK_ROLE_TOOL_BAR, "Dock");
    thickness = short + 2 * edge_gap;

    const focus = c.meta_display_get_focus_window(d);
    for (apps[0..n_apps], 0..) |app, i| {
        const offset = style.padding + @as(f32, @floatFromInt(i)) * (style.icon_size + style.spacing);
        const button = dock.appIcon(app.info, style.icon_size);
        if (vertical) c.clutter_actor_set_position(button, style.padding, offset) else c.clutter_actor_set_position(button, offset, style.padding);
        c.clutter_actor_set_reactive(button, 1);
        ui.accessible(button, c.ATK_ROLE_PUSH_BUTTON, c.g_app_info_get_display_name(app.info));
        plugin.connect(button, "button-release-event", &onAppClicked, @ptrFromInt(i + 1));
        plugin.connect(button, "enter-event", &onHover, null);
        plugin.connect(button, "leave-event", &onUnhover, null);
        c.clutter_actor_add_child(a, button);
        if (app.window != null and config.dock_running_dots) {
            const size: f32 = if (app.window == focus) style.running_dot * 2.5 else style.running_dot;
            const dot = ui.roundedRect(if (vertical) style.running_dot else size, if (vertical) size else style.running_dot, style.running_dot / 2, 0xffffffff);
            const along = offset + (style.icon_size - size) / 2;
            switch (config.dock_position) {
                .bottom => c.clutter_actor_set_position(dot, along, h - style.running_dot - 2),
                .left => c.clutter_actor_set_position(dot, 2, along),
                .right => c.clutter_actor_set_position(dot, w - style.running_dot - 2, along),
            }
            c.clutter_actor_add_child(a, dot);
        }
    }
    const show_apps = ui.roundedRect(style.icon_size, style.icon_size, 14, 0xffffff1a);
    const grid_icon = ui.icon("view-app-grid-symbolic", 24, true, 0xffffff);
    ui.center(grid_icon, show_apps, c.CLUTTER_ALIGN_BOTH);
    c.clutter_actor_add_child(show_apps, grid_icon);
    c.clutter_actor_set_pivot_point(show_apps, 0.5, 0.5);
    const last = style.padding + @as(f32, @floatFromInt(n_apps)) * (style.icon_size + style.spacing);
    if (vertical) c.clutter_actor_set_position(show_apps, style.padding, last) else c.clutter_actor_set_position(show_apps, last, style.padding);
    c.clutter_actor_set_reactive(show_apps, 1);
    ui.accessible(show_apps, c.ATK_ROLE_PUSH_BUTTON, "Show Apps");
    plugin.connect(show_apps, "button-release-event", &onShowApps, null);
    plugin.connect(show_apps, "enter-event", &onHover, null);
    plugin.connect(show_apps, "leave-event", &onUnhover, null);
    c.clutter_actor_add_child(a, show_apps);

    c.clutter_actor_add_child(parent, a);
    actor = a;

    if (config.dock_mode == .autohide) {
        // A thin strip along the edge brings it back; leaving hides it.
        const t = c.clutter_actor_new();
        switch (config.dock_position) {
            .bottom => {
                c.clutter_actor_set_position(t, mx, my + mh - trigger_size);
                c.clutter_actor_set_size(t, mw, trigger_size);
            },
            .left => {
                c.clutter_actor_set_position(t, mx, my + top);
                c.clutter_actor_set_size(t, trigger_size, mh - top);
            },
            .right => {
                c.clutter_actor_set_position(t, mx + mw - trigger_size, my + top);
                c.clutter_actor_set_size(t, trigger_size, mh - top);
            },
        }
        c.clutter_actor_set_reactive(t, 1);
        plugin.connect(t, "enter-event", &onReveal, null);
        c.clutter_actor_add_child(parent, t);
        trigger = t;
        plugin.connect(a, "enter-event", &onReveal, null);
        plugin.connect(a, "leave-event", &onLeave, null);
        setRevealed(revealed, false);
    }
    if (in_overview) c.clutter_actor_set_opacity(a, 0);
}

fn setRevealed(show: bool, animate: bool) void {
    revealed = show;
    const a = actor orelse return;
    const away: f32 = thickness + 8;
    const shift: [2]f32 = if (show) .{ 0, 0 } else switch (config.dock_position) {
        .bottom => .{ 0, away },
        .left => .{ -away, 0 },
        .right => .{ away, 0 },
    };
    if (animate) ui.ease(a, 200, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_translation(a, shift[0], shift[1], 0);
    c.clutter_actor_set_opacity(a, if (show and !in_overview) 255 else 0);
    if (animate) c.clutter_actor_restore_easing_state(a);
}

fn onReveal(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    if (hide_timer != 0) _ = c.g_source_remove(hide_timer);
    hide_timer = 0;
    if (!revealed) setRevealed(true, true);
    return 0;
}

fn onLeave(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    if (hide_timer == 0) hide_timer = c.g_timeout_add(700, &hideLater, null);
    return 0;
}

fn hideLater(_: c.gpointer) callconv(.C) c.gboolean {
    hide_timer = 0;
    if (ui.popupIsOpen()) return 0; // keep it while its menu is open
    setRevealed(false, true);
    return 0;
}

fn onAppClicked(_: ?*c.ClutterActor, event: ?*c.ClutterEvent, data: c.gpointer) callconv(.C) c.gboolean {
    const index = @intFromPtr(data) - 1;
    if (index >= n_apps) return 1;
    const app = apps[index];
    if (ui.isSecondary(event)) {
        const pos = ui.eventPosition(event);
        dock.showAppMenu(app.info, pos[0], pos[1] - 60);
        return 1;
    }
    const d = display orelse return 1;
    const time = c.meta_display_get_current_time_roundtrip(d);
    if (app.window) |w| {
        if (c.meta_display_get_focus_window(d) == w) c.meta_window_minimize(w) else c.meta_window_activate(w, time);
    } else ui.launch(d, app.info);
    return 1;
}

fn onShowApps(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    @import("overview.zig").showApps();
    return 1;
}

fn onHover(a: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    ui.ease(a, 120, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_scale(a, 1.12, 1.12);
    c.clutter_actor_restore_easing_state(a);
    return 0;
}

fn onUnhover(a: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    ui.ease(a, 120, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_scale(a, 1.0, 1.0);
    c.clutter_actor_restore_easing_state(a);
    return 0;
}
