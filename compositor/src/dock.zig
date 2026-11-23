//! The dock at the bottom of the overview: favorite and running apps.
//! Click a running app to switch to it, or any other to launch it.

const std = @import("std");
const plugin = @import("plugin.zig");
const overview = @import("overview.zig");
const ui = @import("ui.zig");
const c = plugin.c;
const config = @import("config.zig");

const max_apps = 24;

const App = struct {
    info: *c.GAppInfo,
    window: ?*c.MetaWindow, // a window of the app, if it's running
};

var display: ?*c.MetaDisplay = null;
var dock_actor: ?*c.ClutterActor = null;
var dock_parent: ?*c.ClutterActor = null;
var dock_area = [3]f32{ 0, 0, 0 }; // x, width, bottom
var apps: [max_apps]App = undefined;
var n_apps: usize = 0;

/// Builds the dock inside `parent`, centered at the bottom of the monitor
/// spanning `left`..`left + width` and ending at `bottom`. Returns the height it
/// takes up (with margins).
pub fn create(d: ?*c.MetaDisplay, parent: ?*c.ClutterActor, left: f32, width: f32, bottom: f32) f32 {
    display = d;
    dock_parent = parent;
    dock_area = .{ left, width, bottom };
    clear();
    collectApps();
    var style = c.cali_shell_dock_style();
    style.icon_size = config.dock_icon_size;
    style.corner_radius = config.radius(1.1);
    // One slot per app plus the Show Apps button.
    const n: f32 = @floatFromInt(n_apps + 1);
    const dock_w = n * style.icon_size + (n - 1) * style.spacing + 2 * style.padding;
    const dock_h = style.icon_size + 2 * style.padding;

    const dock = ui.roundedRect(dock_w, dock_h, style.corner_radius, style.background);
    c.clutter_actor_set_position(dock, left + (width - dock_w) / 2, bottom - dock_h - style.bottom_margin);
    c.clutter_actor_add_child(parent, dock);
    dock_actor = dock;

    for (apps[0..n_apps], 0..) |app, i| {
        const x = style.padding + @as(f32, @floatFromInt(i)) * (style.icon_size + style.spacing);
        const button = appIcon(app.info, style.icon_size);
        c.clutter_actor_set_position(button, x, style.padding);
        c.clutter_actor_set_reactive(button, 1);
        plugin.connect(button, "button-release-event", &onAppClicked, @ptrFromInt(i + 1));
        plugin.connect(button, "enter-event", &onHover, null);
        plugin.connect(button, "leave-event", &onUnhover, null);
        c.clutter_actor_add_child(dock, button);

        if (app.window != null and config.dock_running_dots) {
            const dot = ui.roundedRect(style.running_dot, style.running_dot, style.running_dot / 2, 0xffffffff);
            c.clutter_actor_set_position(dot, x + (style.icon_size - style.running_dot) / 2, dock_h - style.running_dot - 2);
            c.clutter_actor_add_child(dock, dot);
        }
    }

    // Show Apps, after a little gap.
    const show_apps = ui.roundedRect(style.icon_size, style.icon_size, 14, 0xffffff1a);
    const grid_icon = ui.icon("view-app-grid-symbolic", 24, true, 0xffffff);
    ui.center(grid_icon, show_apps, c.CLUTTER_ALIGN_BOTH);
    c.clutter_actor_add_child(show_apps, grid_icon);
    c.clutter_actor_set_pivot_point(show_apps, 0.5, 0.5);
    c.clutter_actor_set_position(show_apps, style.padding + @as(f32, @floatFromInt(n_apps)) * (style.icon_size + style.spacing), style.padding);
    c.clutter_actor_set_reactive(show_apps, 1);
    plugin.connect(show_apps, "button-release-event", &onShowApps, null);
    plugin.connect(show_apps, "enter-event", &onHover, null);
    plugin.connect(show_apps, "leave-event", &onUnhover, null);
    c.clutter_actor_add_child(dock, show_apps);

    // Rise into place with the overview.
    c.clutter_actor_set_translation(dock, 0, dock_h, 0);
    c.clutter_actor_set_opacity(dock, 0);
    ui.ease(dock, 250, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_translation(dock, 0, 0, 0);
    c.clutter_actor_set_opacity(dock, 255);
    c.clutter_actor_restore_easing_state(dock);

    return dock_h + style.bottom_margin;
}

/// CALI_DEBUG_APPMENU: the first dock app's right-click menu.
pub fn debugMenu() void {
    if (n_apps > 0) showAppMenu(apps[0].info, 500, 500);
}

/// Rebuilds a visible dock (favorites changed).
pub fn rebuild() void {
    const old = dock_actor orelse return;
    const parent = dock_parent orelse return;
    c.clutter_actor_destroy(old);
    clear();
    _ = create(display, parent, dock_area[0], dock_area[1], dock_area[2]);
}

/// Slides the dock away as the overview closes.
pub fn hide() void {
    const dock = dock_actor orelse return;
    ui.ease(dock, 200, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_translation(dock, 0, c.clutter_actor_get_height(dock), 0);
    c.clutter_actor_set_opacity(dock, 0);
    c.clutter_actor_restore_easing_state(dock);
}

/// Drops the app list (the overview destroys the actors).
pub fn clear() void {
    dock_actor = null;
    for (apps[0..n_apps]) |app| c.g_object_unref(app.info);
    n_apps = 0;
}

pub fn appIcon(info: *c.GAppInfo, size: f32) *c.ClutterActor {
    var name: [*:0]const u8 = "application-x-executable";
    var owned: ?[*:0]u8 = null;
    defer if (owned) |o| c.g_free(o);
    if (c.g_app_info_get_icon(info)) |gicon| {
        if (c.g_icon_to_string(gicon)) |s| {
            owned = s;
            name = iconName(std.mem.span(s));
        }
    }
    const actor = ui.icon(name, size, false, 0);
    c.clutter_actor_set_pivot_point(actor, 0.5, 0.5);
    return actor;
}

/// `g_icon_to_string` gives a name, a path, or ". GThemedIcon name1 name2 ..."
/// for icons with fallbacks; take the first name then.
pub fn iconName(s: [:0]u8) [*:0]const u8 {
    const prefix = ". GThemedIcon ";
    if (!std.mem.startsWith(u8, s, prefix)) return s.ptr;
    const rest = s[prefix.len..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    s[prefix.len + end] = 0;
    return @ptrCast(rest.ptr);
}

// ---- Which apps -----------------------------------------------------------------------

fn findApp(info: *c.GAppInfo) ?usize {
    for (apps[0..n_apps], 0..) |app, i| {
        if (c.g_app_info_equal(app.info, info) != 0) return i;
    }
    return null;
}

fn addApp(info: *c.GAppInfo, window: ?*c.MetaWindow) void {
    if (findApp(info)) |i| {
        if (apps[i].window == null) apps[i].window = window;
        c.g_object_unref(info);
        return;
    }
    if (n_apps == max_apps) {
        c.g_object_unref(info);
        return;
    }
    apps[n_apps] = .{ .info = info, .window = window };
    n_apps += 1;
}

/// The desktop file for a window: GTK application ID, sandbox app ID, then
/// WM_CLASS as given and in lower case.
pub fn appForWindow(window: ?*c.MetaWindow) ?*c.GAppInfo {
    var candidates = [_]?[*:0]const u8{
        c.meta_window_get_gtk_application_id(window),
        c.meta_window_get_sandboxed_app_id(window),
        c.meta_window_get_wm_class(window),
    };
    var buf: [256]u8 = undefined;
    for (&candidates, 0..) |*candidate, round| {
        _ = round;
        const id = candidate.* orelse continue;
        for ([_]bool{ false, true }) |lower| {
            const span = std.mem.span(id);
            if (span.len + ".desktop".len + 1 > buf.len) continue;
            for (span, 0..) |ch, i| buf[i] = if (lower) std.ascii.toLower(ch) else ch;
            @memcpy(buf[span.len..][0..".desktop".len], ".desktop");
            buf[span.len + ".desktop".len] = 0;
            if (c.g_desktop_app_info_new(@ptrCast(&buf))) |info| return @ptrCast(@alignCast(info));
        }
    }
    return null;
}

fn collectApps() void {
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
        if (appForWindow(window)) |info| addApp(info, window);
    }
}

// ---- Input -------------------------------------------------------------------------------

fn onAppClicked(_: ?*c.ClutterActor, event: ?*c.ClutterEvent, data: c.gpointer) callconv(.C) c.gboolean {
    const index = @intFromPtr(data) - 1;
    if (index >= n_apps) return 1;
    const app = apps[index];
    if (ui.isSecondary(event)) {
        const pos = ui.eventPosition(event);
        showAppMenu(app.info, pos[0], pos[1] - 60);
        return 1;
    }
    if (app.window) |window| {
        overview.closeTo(window);
    } else {
        ui.launch(display, app.info);
        overview.closeTo(null);
    }
    return 1;
}

// ---- App menus (shared with the app grid) ---------------------------------------------------

var menu_app: ?*c.GAppInfo = null;
var menu_entries: [4]enum { new_window, quit, pin, unpin } = undefined;
var menu_count: usize = 0;

fn isFavorite(id: [*:0]const u8) bool {
    var i: usize = 0;
    while (c.cali_shell_dock_favorite(i)) |fav| : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(fav), std.mem.span(id))) return true;
    }
    return false;
}

fn runningWindow(info: *c.GAppInfo) ?*c.MetaWindow {
    const d = display orelse return null;
    const windows = c.meta_display_list_all_windows(d);
    defer c.g_list_free(windows);
    var node = windows;
    while (node != null) : (node = node.*.next) {
        const window: ?*c.MetaWindow = @ptrCast(@alignCast(node.*.data));
        const other = appForWindow(window) orelse continue;
        defer c.g_object_unref(other);
        if (c.g_app_info_equal(other, info) != 0) return window;
    }
    return null;
}

/// Right-click menu for an app: New Window / Quit when running, and
/// Pin to Dock / Unpin from Dock.
pub fn showAppMenu(info: *c.GAppInfo, x: f32, y: f32) void {
    if (menu_app) |old| c.g_object_unref(old);
    menu_app = @ptrCast(@alignCast(c.g_object_ref(info)));
    var labels: [4][*:0]const u8 = undefined;
    menu_count = 0;
    if (runningWindow(info) != null) {
        labels[menu_count] = "New Window";
        menu_entries[menu_count] = .new_window;
        menu_count += 1;
        labels[menu_count] = "Quit";
        menu_entries[menu_count] = .quit;
        menu_count += 1;
    }
    const id: [*:0]const u8 = if (c.g_app_info_get_id(info)) |p| p else "";
    const pinned = isFavorite(id);
    labels[menu_count] = if (pinned) "Unpin from Dock" else "Pin to Dock";
    menu_entries[menu_count] = if (pinned) .unpin else .pin;
    menu_count += 1;
    ui.menu(x, y, labels[0..menu_count], &onMenuChoice);
}

fn onMenuChoice(index: usize) void {
    const info = menu_app orelse return;
    if (index >= menu_count) return;
    switch (menu_entries[index]) {
        .new_window => {
            ui.launch(display, info);
            overview.closeTo(null);
        },
        .quit => {
            // Ask every window of the app to close (the app may still ask to save).
            const d = display orelse return;
            const windows = c.meta_display_list_all_windows(d);
            defer c.g_list_free(windows);
            var node = windows;
            while (node != null) : (node = node.*.next) {
                const window: ?*c.MetaWindow = @ptrCast(@alignCast(node.*.data));
                const other = appForWindow(window) orelse continue;
                defer c.g_object_unref(other);
                if (c.g_app_info_equal(other, info) != 0) c.meta_window_delete(window, c.meta_display_get_current_time_roundtrip(d));
            }
        },
        .pin, .unpin => setPinned(c.g_app_info_get_id(info) orelse return, menu_entries[index] == .pin),
    }
}

/// Adds or removes an app from the dock-favorites setting.
fn setPinned(id: [*:0]const u8, pin: bool) void {
    const builder = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "as")));
    defer c.g_variant_builder_unref(builder);
    var i: usize = 0;
    while (c.cali_shell_dock_favorite(i)) |fav| : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(fav), std.mem.span(id))) continue;
        c.g_variant_builder_add(builder, "s", fav);
    }
    if (pin) c.g_variant_builder_add(builder, "s", id);
    @import("settings.zig").set("dock-favorites", c.g_variant_builder_end(builder));
}

fn onShowApps(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    overview.showApps();
    return 1;
}

fn onHover(actor: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    ui.ease(actor, 120, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_scale(actor, 1.12, 1.12);
    c.clutter_actor_restore_easing_state(actor);
    return 0;
}

fn onUnhover(actor: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    ui.ease(actor, 120, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_scale(actor, 1.0, 1.0);
    c.clutter_actor_restore_easing_state(actor);
    return 0;
}
