//! CaliPlugin: Cali's Sookie plugin (a MetaPlugin subclass).
//!
//! It draws the background and the top bar, and animates windows. What the
//! bar shows comes from cali-shell (Rust); this file only draws it with Clutter.

const std = @import("std");
const overview = @import("overview.zig");
const workspaces = @import("workspaces.zig");
const statusmenu = @import("statusmenu.zig");
const ui = @import("ui.zig");
const calendar = @import("calendar.zig");
const switcher = @import("switcher.zig");
const notifications = @import("notifications.zig");
const settings = @import("settings.zig");
const status = @import("status.zig");
const osd = @import("osd.zig");
const session = @import("session.zig");
const lock = @import("lock.zig");
const screenshot = @import("screenshot.zig");
const keyboard = @import("keyboard.zig");
const config = @import("config.zig");
const tiling = @import("tiling.zig");
const wobbly = @import("wobbly.zig");
const media = @import("media.zig");

pub const c = @cImport({
    @cDefine("CLUTTER_ENABLE_EXPERIMENTAL_API", "1");
    @cDefine("COGL_ENABLE_EXPERIMENTAL_API", "1");
    @cInclude("meta/meta-plugin.h");
    @cInclude("meta/display.h");
    @cInclude("meta/compositor.h");
    @cInclude("meta/meta-context.h");
    @cInclude("meta/meta-backend.h");
    @cInclude("meta/meta-monitor-manager.h");
    @cInclude("meta/meta-background.h");
    @cInclude("meta/meta-background-actor.h");
    @cInclude("meta/meta-background-content.h");
    @cInclude("meta/meta-background-group.h");
    @cInclude("meta/meta-workspace-manager.h");
    @cInclude("meta/meta-window-actor.h");
    @cInclude("meta/workspace.h");
    @cInclude("meta/window.h");
    @cInclude("clutter/clutter.h");
    @cInclude("clutter/clutter-pango.h");
    @cInclude("meta/meta-startup-notification.h");
    @cInclude("meta/meta-launch-context.h");
    @cInclude("gio/gdesktopappinfo.h");
    @cInclude("meta/keybindings.h");
    @cInclude("meta/prefs.h");
    @cInclude("meta/meta-cursor-tracker.h");
    @cInclude("atk-bridge.h");
    @cInclude("cali_shell.h");
});

// ---- Look ------------------------------------------------------------------

const background_top = c.CoglColor{ .red = 0x2c, .green = 0x4a, .blue = 0x86, .alpha = 255 };
const background_bottom = c.CoglColor{ .red = 0xe2, .green = 0x7d, .blue = 0x60, .alpha = 255 };
const panel_color = c.CoglColor{ .red = 0, .green = 0, .blue = 0, .alpha = 255 };
const panel_text_color = c.CoglColor{ .red = 255, .green = 255, .blue = 255, .alpha = 255 };

const map_duration_ms = 180;
const map_start_scale = 0.94;

// ---- State (Sookie creates exactly one plugin instance) ---------------------

var display: ?*c.MetaDisplay = null;
var background_group: ?*c.ClutterActor = null;
var panel: ?*c.ClutterActor = null;
var clock: ?*c.ClutterActor = null;
/// A plain actor over the clock that takes its clicks (opens the calendar).
/// Clicks on the ClutterText itself never opened it.
var clock_hit: ?*c.ClutterActor = null;
var panel_rect = c.MtkRectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };


// ---- GObject type -------------------------------------------------------------

var plugin_type: c.GType = 0;

/// The CaliPlugin GType, registered on first use.
pub fn getType() c.GType {
    if (plugin_type == 0) {
        plugin_type = c.g_type_register_static_simple(
            c.meta_plugin_get_type(),
            "CaliPlugin",
            @sizeOf(c.MetaPluginClass),
            &classInit,
            @sizeOf(c.MetaPlugin),
            null,
            0,
        );
    }
    return plugin_type;
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.C) void {
    const k: *c.MetaPluginClass = @ptrCast(@alignCast(klass));
    k.start = &start;
    k.map = &map;
    k.kill_window_effects = &killWindowEffects;
    k.destroy = &destroy;
    k.show_tile_preview = &showTilePreview;
    k.hide_tile_preview = &hideTilePreview;
    k.keybinding_filter = &keybindingFilter;
    k.minimize = &minimize;
    k.unminimize = &unminimize;
    k.switch_workspace = &workspaces.switchWorkspace;
    k.kill_switch_workspace = &workspaces.killSwitchWorkspace;
}

// ---- Startup ------------------------------------------------------------------

fn start(plugin: ?*c.MetaPlugin) callconv(.C) void {
    const d = c.meta_plugin_get_display(plugin);
    display = d;
    const backend = c.meta_context_get_backend(c.meta_display_get_context(d));
    const compositor = c.meta_display_get_compositor(d);
    const monitor_manager = c.meta_backend_get_monitor_manager(backend);
    const stage = c.meta_backend_get_stage(backend);

    const group = c.meta_background_group_new();
    c.clutter_actor_insert_child_below(c.meta_compositor_get_window_group(compositor), group, null);
    background_group = group;

    session.init();
    session.startHelpers();
    session.registerWithGdm(@ptrCast(stage));
    @import("a11y.zig").init(d);
    ui.init(stage);
    createPanel(stage);
    overview.init(d, stage, panel);
    workspaces.init(d, stage, panel);
    statusmenu.init(d, stage, panel);
    @import("panelitems.zig").init(panel);
    @import("deskdock.zig").init(d, stage);
    @import("gestures.zig").init(d, stage);
    calendar.init(stage, clock_hit);
    switcher.init(d, stage);
    notifications.init(stage);
    osd.init(stage);
    status.init(d);
    lock.init(d, stage, panel);
    screenshot.init(d, stage);
    keyboard.init(d);
    tiling.init(d);
    wobbly.init(d);
    media.init();
    settings.init();

    // CALI_DEBUG_SECOND_MONITOR=<seconds>: move the focused window to monitor 2.
    if (std.posix.getenv("CALI_DEBUG_SECOND_MONITOR")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugSecondMonitor, null);
    }
    if (std.posix.getenv("CALI_DEBUG_TILE")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugTile, null);
    }

    if (std.posix.getenv("CALI_DEBUG_MINIMIZE")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugMinimize, null);
    }

    connect(monitor_manager, "monitors-changed", &onMonitorsChanged, null);
    connect(c.meta_display_get_workspace_manager(d), "workspace-added", &onWorkspaceAdded, null);
    onMonitorsChanged(monitor_manager, null);

    _ = c.g_timeout_add_seconds(1, &tickClock, null);
    c.clutter_actor_show(stage);
}

pub fn connect(instance: anytype, signal: [*:0]const u8, handler: anytype, data: c.gpointer) void {
    _ = c.g_signal_connect_data(instance, signal, @ptrCast(handler), data, null, 0);
}

// ---- Background -----------------------------------------------------------------

fn onMonitorsChanged(_: ?*c.MetaMonitorManager, _: c.gpointer) callconv(.C) void {
    if (background_group) |group| fillBackground(group);
    layoutPanel();
}

/// Replaces the children of `group` with one background actor per monitor.
/// Used for the desktop and, separately, for the overview.
pub fn fillBackground(group: *c.ClutterActor) void {
    const d = display orelse return;

    c.clutter_actor_destroy_all_children(group);
    const n = c.meta_display_get_n_monitors(d);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        var rect: c.MtkRectangle = undefined;
        c.meta_display_get_monitor_geometry(d, i, &rect);

        const actor = c.meta_background_actor_new(d, i);
        c.clutter_actor_set_position(actor, @floatFromInt(rect.x), @floatFromInt(rect.y));
        c.clutter_actor_set_size(actor, @floatFromInt(rect.width), @floatFromInt(rect.height));

        const background = c.meta_background_new(d);
        if (wallpaper_texture) |texture| {
            const color_state = c.clutter_context_get_default_color_state(c.clutter_actor_get_context(group));
            c.meta_background_set_texture(background, texture, @intCast(wallpaper_style), color_state);
        } else {
            var top = wallpaper_top;
            var bottom = wallpaper_bottom;
            c.meta_background_set_gradient(background, @intCast(c.G_DESKTOP_BACKGROUND_SHADING_VERTICAL), &top, &bottom);
        }

        const content: *c.MetaBackgroundContent = @ptrCast(@alignCast(c.clutter_actor_get_content(actor)));
        c.meta_background_content_set_background(content, background);
        c.g_object_unref(background);

        c.clutter_actor_add_child(group, actor);
    }
}

// ---- Top bar ---------------------------------------------------------------------

// ---- Wallpaper ------------------------------------------------------------------------

var wallpaper_top = background_top;
var wallpaper_bottom = background_bottom;
var wallpaper_texture: ?*c.CoglTexture = null;

fn color(rgba: u32) c.CoglColor {
    return .{ .red = @truncate(rgba >> 24), .green = @truncate(rgba >> 16), .blue = @truncate(rgba >> 8), .alpha = @truncate(rgba) };
}

/// Applies the wallpaper setting: a built-in gradient or an image file.
pub fn setWallpaper(name: [*:0]const u8) void {
    if (wallpaper_texture) |t| c.g_object_unref(t);
    wallpaper_texture = null;
    var top: u32 = 0;
    var bottom: u32 = 0;
    if (c.cali_shell_wallpaper_gradient(name, &top, &bottom)) {
        wallpaper_top = color(top);
        wallpaper_bottom = color(bottom);
    } else blk: {
        var w: c_uint = 0;
        var h: c_uint = 0;
        const pixels = c.cali_shell_load_image(name, &w, &h) orelse {
            std.log.warn("wallpaper: could not load {s}, using the default", .{name});
            wallpaper_top = background_top;
            wallpaper_bottom = background_bottom;
            break :blk;
        };
        defer c.cali_shell_free_image(pixels, @as(usize, w) * h * 4);
        const s = stage_actor orelse break :blk;
        const ctx = c.clutter_backend_get_cogl_context(c.clutter_context_get_backend(c.clutter_actor_get_context(s)));
        var err: ?*c.GError = null;
        wallpaper_texture = c.cogl_texture_2d_new_from_data(ctx, @intCast(w), @intCast(h), @intCast(c.COGL_PIXEL_FORMAT_RGBA_8888_PRE), @intCast(w * 4), pixels, @ptrCast(&err));
        if (err) |e| c.g_error_free(e);
    }
    if (background_group) |group| fillBackground(group);
}

// ---- Snap (tile) preview -----------------------------------------------------------------

var tile_preview: ?*c.ClutterActor = null;

/// Sookie asks to show where a dragged window will snap (half screen,
/// maximized): an accent-colored rounded area that grows into place.
fn showTilePreview(_: ?*c.MetaPlugin, window: ?*c.MetaWindow, tile_rect: ?*c.MtkRectangle, _: c_int) callconv(.C) void {
    const s = stage_actor orelse return;
    const rect = tile_rect orelse return;
    const gap: f32 = 8;
    const w = @as(f32, @floatFromInt(rect.*.width)) - 2 * gap;
    const h = @as(f32, @floatFromInt(rect.*.height)) - 2 * gap;
    if (w <= 0 or h <= 0) return;

    if (tile_preview) |old| c.clutter_actor_destroy(old);
    const accent = ui.accent;
    const preview = ui.roundedRect(w, h, 16, (accent & 0xffffff00) | 0x55);
    var from: c.MtkRectangle = undefined;
    if (window) |win| c.meta_window_get_frame_rect(win, &from) else from = rect.*;
    c.clutter_actor_set_position(preview, @floatFromInt(from.x), @floatFromInt(from.y));
    c.clutter_actor_set_size(preview, @floatFromInt(from.width), @floatFromInt(from.height));
    c.clutter_actor_set_opacity(preview, 0);
    // Under the window being dragged (inside the window group), like GNOME.
    const window_actor: ?*c.ClutterActor = if (window) |win| @ptrCast(@alignCast(c.meta_window_get_compositor_private(win))) else null;
    if (window_actor) |wa| {
        c.clutter_actor_insert_child_below(c.clutter_actor_get_parent(wa), preview, wa);
    } else {
        c.clutter_actor_insert_child_below(s, preview, panel);
    }

    ui.ease(preview, 150, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_position(preview, @as(f32, @floatFromInt(rect.*.x)) + gap, @as(f32, @floatFromInt(rect.*.y)) + gap);
    c.clutter_actor_set_size(preview, w, h);
    c.clutter_actor_set_opacity(preview, 255);
    c.clutter_actor_restore_easing_state(preview);
    tile_preview = preview;
}

fn hideTilePreview(_: ?*c.MetaPlugin) callconv(.C) void {
    const preview = tile_preview orelse return;
    tile_preview = null;
    c.clutter_actor_destroy(preview);
}

fn debugSecondMonitor(_: c.gpointer) callconv(.C) c.gboolean {
    const d = display orelse return 0;
    if (c.meta_display_get_n_monitors(d) < 2) return 0;
    if (c.meta_display_get_focus_window(d)) |w| c.meta_window_move_to_monitor(w, 1);
    return 0;
}

/// CALI_DEBUG_TILE=<seconds>: shows the left-half snap preview for 4 seconds.
fn debugTile(_: c.gpointer) callconv(.C) c.gboolean {
    var rect = panel_rect;
    rect.y += rect.height;
    if (display) |d| {
        var mon: c.MtkRectangle = undefined;
        c.meta_display_get_monitor_geometry(d, c.meta_display_get_primary_monitor(d), &mon);
        rect = .{ .x = mon.x, .y = mon.y + panel_rect.height, .width = @divTrunc(mon.width, 2), .height = mon.height - panel_rect.height };
    }
    showTilePreview(null, if (display) |d| c.meta_display_get_focus_window(d) else null, &rect, 0);
    _ = c.g_timeout_add_seconds(4, &debugTileHide, null);
    return 0;
}

fn debugTileHide(_: c.gpointer) callconv(.C) c.gboolean {
    hideTilePreview(null);
    return 0;
}

/// While locked, no keybinding does anything (they could reveal windows).
fn keybindingFilter(_: ?*c.MetaPlugin, _: ?*c.MetaKeyBinding) callconv(.C) c.gboolean {
    return @intFromBool(lock.locked);
}

// ---- Top bar -------------------------------------------------------------------------

var clock_dot: ?*c.ClutterActor = null;
var clock_align: ?*c.ClutterAlignConstraint = null;
var wallpaper_style: c_uint = c.G_DESKTOP_BACKGROUND_STYLE_ZOOM;

/// The wallpaper-style setting: how an image fits the screen.
pub fn setWallpaperStyle(name: []const u8) void {
    const eql = std.mem.eql;
    wallpaper_style = if (eql(u8, name, "centered")) c.G_DESKTOP_BACKGROUND_STYLE_CENTERED else if (eql(u8, name, "scaled")) c.G_DESKTOP_BACKGROUND_STYLE_SCALED else if (eql(u8, name, "stretched")) c.G_DESKTOP_BACKGROUND_STYLE_STRETCHED else if (eql(u8, name, "wallpaper")) c.G_DESKTOP_BACKGROUND_STYLE_WALLPAPER else c.G_DESKTOP_BACKGROUND_STYLE_ZOOM;
    if (background_group) |group| fillBackground(group);
}

/// Re-applies every look-and-behavior setting (one of them changed).
pub fn restyle() void {
    if (panel) |p| {
        const alpha: u8 = @intFromFloat(std.math.clamp(config.panel_opacity, 0, 1) * 255);
        const rgb = config.panel_rgb;
        c.clutter_actor_set_background_color(p, &c.CoglColor{ .red = @truncate(rgb >> 16), .green = @truncate(rgb >> 8), .blue = @truncate(rgb), .alpha = alpha });
        if (clock) |t| c.clutter_text_set_font_name(@ptrCast(@alignCast(t)), config.font(.bold, 0));
    }
    layoutPanel();
    refreshClock();
    workspaces.restyle();
    statusmenu.restyle();
    @import("calendar.zig").refresh();
    @import("dock.zig").rebuild();
    @import("deskdock.zig").rebuild();
    tiling.retileAll();
    @import("a11y.zig").update();
    @import("media.zig").updateTopBar();
}
var stage_actor: ?*c.ClutterActor = null;

/// The small dot beside the clock that says there are notifications.
pub fn setClockDot(visible: bool) void {
    const dot = clock_dot orelse return;
    if (visible) c.clutter_actor_show(dot) else c.clutter_actor_hide(dot);
    placeClockDot();
}

/// Re-places the clock (top bar items appeared or went away).
pub fn restyleClock() void {
    placeClockDot();
}

fn placeClockDot() void {
    const dot = clock_dot orelse return;
    const text = clock orelse return;
    const p = panel orelse return;
    // Clock position: centered, after the workspace dots, or before the status icons.
    if (clock_align) |a| {
        const factor: f32 = switch (config.clock_position) {
            .center => 0.5,
            .left => 0,
            .right => 1,
        };
        c.clutter_align_constraint_set_factor(a, factor);
        const shift: f32 = switch (config.clock_position) {
            .center => 0,
            .left => workspaces.indicatorWidth() + 32,
            .right => -(statusmenu.iconsWidth() + @import("panelitems.zig").width() + 32),
        };
        c.clutter_actor_set_translation(text, shift, 0, 0);
        if (clock_hit) |hit| c.clutter_actor_set_translation(hit, shift, 0, 0);
    }
    var tx: f32 = 0;
    var ty: f32 = 0;
    var tz: f32 = 0;
    c.clutter_actor_get_translation(text, &tx, &ty, &tz);
    const x = c.clutter_actor_get_x(text) + tx + ui.preferredWidth(text) + 8;
    c.clutter_actor_set_position(dot, x, (c.clutter_actor_get_height(p) - 6) / 2);
}

fn createPanel(stage: ?*c.ClutterActor) void {
    stage_actor = stage;
    const p = c.clutter_actor_new();
    c.clutter_actor_set_background_color(p, &panel_color);

    const text = c.clutter_text_new_full(config.font(.bold, 0), "", &panel_text_color);
    ui.plainText(text);
    c.clutter_actor_add_child(p, text);
    const x_align = c.clutter_align_constraint_new(p, @intCast(c.CLUTTER_ALIGN_X_AXIS), 0.5);
    c.clutter_actor_add_constraint(text, x_align);
    c.clutter_actor_add_constraint(text, c.clutter_align_constraint_new(p, @intCast(c.CLUTTER_ALIGN_Y_AXIS), 0.5));
    clock_align = @ptrCast(@alignCast(x_align));

    c.clutter_actor_add_child(stage, p);
    panel = p;
    clock = text;

    const dot = ui.roundedRect(6, 6, 3, 0xffffffff);
    c.clutter_actor_hide(dot);
    c.clutter_actor_add_child(p, dot);
    clock_dot = dot;

    const hit = c.clutter_actor_new();
    c.clutter_actor_add_constraint(hit, c.clutter_bind_constraint_new(text, @intCast(c.CLUTTER_BIND_ALL), 0));
    c.clutter_actor_add_child(p, hit);
    clock_hit = hit;
    _ = tickClock(null);
}

fn layoutPanel() void {
    const d = display orelse return;
    const p = panel orelse return;
    // Monitors can be missing early in startup (e.g. before a virtual monitor is added).
    if (c.meta_display_get_n_monitors(d) == 0) return;
    const primary = c.meta_display_get_primary_monitor(d);
    if (primary < 0) return;

    var rect: c.MtkRectangle = undefined;
    c.meta_display_get_monitor_geometry(d, primary, &rect);
    const height: c_int = @intCast(@import("config.zig").panelHeight());

    c.clutter_actor_set_position(p, @floatFromInt(rect.x), @floatFromInt(rect.y));
    c.clutter_actor_set_size(p, @floatFromInt(rect.width), @floatFromInt(height));
    panel_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = height };
    applyStruts();
}

/// Re-applies the reserved areas (the dock appeared, moved or went away).
pub fn updateStruts() void {
    applyStruts();
}

/// Reserve the bar's area on every workspace so windows stay below it.
fn applyStruts() void {
    const d = display orelse return;
    const manager = c.meta_display_get_workspace_manager(d);

    var strut = c.MetaStrut{ .rect = panel_rect, .side = @intCast(c.META_SIDE_TOP) };
    var list = c.g_slist_append(null, &strut);
    var dock_strut = @import("deskdock.zig").reserved();
    if (dock_strut != null) list = c.g_slist_append(list, &dock_strut.?);
    defer c.g_slist_free(list); // Sookie copies the list.

    const n = c.meta_workspace_manager_get_n_workspaces(manager);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        c.meta_workspace_set_builtin_struts(c.meta_workspace_manager_get_workspace_by_index(manager, i), list);
    }
}

fn onWorkspaceAdded(_: ?*c.MetaWorkspaceManager, _: c_int, _: c.gpointer) callconv(.C) void {
    applyStruts();
}

/// Redraws the clock now (after its settings change).
pub fn refreshClock() void {
    _ = tickClock(null);
    placeClockDot();
}

fn tickClock(_: c.gpointer) callconv(.C) c.gboolean {
    const text = clock orelse return 0;
    var buf: [64]u8 = undefined;
    if (c.cali_shell_clock_text(&buf, buf.len) > 0) {
        c.clutter_text_set_text(@ptrCast(@alignCast(text)), &buf);
    }
    return 1; // keep ticking
}

// ---- Window animations -----------------------------------------------------------

fn sameEnum(a: anytype, b: anytype) bool {
    return @as(i64, @intCast(a)) == @as(i64, @intCast(b));
}

/// Normal app windows and dialogs: the ones that animate and show in the overview.
pub fn isAppWindow(window: ?*c.MetaWindow) bool {
    const kind = c.meta_window_get_window_type(window);
    return sameEnum(kind, c.META_WINDOW_NORMAL) or
        sameEnum(kind, c.META_WINDOW_DIALOG) or
        sameEnum(kind, c.META_WINDOW_MODAL_DIALOG);
}

// Every window effect follows the same pattern: animate, then tell Sookie
// it's done (it waits for that). The kind of effect and its signal handler
// are kept on the actor so an interrupted effect can be finished properly.

const Effect = enum(usize) { map = 1, destroy, minimize, unminimize };
const effect_key = "cali-effect";
const handler_key = "cali-effect-handler";

const destroy_ms = 150;
const minimize_ms = 220;

fn startEffect(plugin: ?*c.MetaPlugin, actor: *c.ClutterActor, effect: Effect) void {
    const object: *c.GObject = @ptrCast(@alignCast(actor));
    const id = c.g_signal_connect_data(actor, "transitions-completed", @ptrCast(&onEffectDone), plugin, null, 0);
    c.g_object_set_data(object, effect_key, @ptrFromInt(@intFromEnum(effect)));
    c.g_object_set_data(object, handler_key, @ptrFromInt(id));
}

fn onEffectDone(actor: ?*c.ClutterActor, plugin: c.gpointer) callconv(.C) void {
    finishEffect(actor, @ptrCast(@alignCast(plugin)));
}

/// Ends the running effect on `actor` (if any) and tells Sookie.
fn finishEffect(actor: ?*c.ClutterActor, plugin: ?*c.MetaPlugin) void {
    const object: *c.GObject = @ptrCast(@alignCast(actor));
    const kind = c.g_object_get_data(object, effect_key) orelse return;
    if (c.g_object_get_data(object, handler_key)) |id| c.g_signal_handler_disconnect(object, @intFromPtr(id));
    c.g_object_set_data(object, effect_key, null);
    c.g_object_set_data(object, handler_key, null);

    // Back to normal before Sookie hides, shows or destroys the window.
    c.clutter_actor_set_opacity(actor, 255);
    c.clutter_actor_set_scale(actor, 1.0, 1.0);
    c.clutter_actor_set_translation(actor, 0, 0, 0);

    const window_actor: ?*c.MetaWindowActor = @ptrCast(@alignCast(actor));
    switch (@as(Effect, @enumFromInt(@intFromPtr(kind)))) {
        .map => c.meta_plugin_map_completed(plugin, window_actor),
        .destroy => c.meta_plugin_destroy_completed(plugin, window_actor),
        .minimize => c.meta_plugin_minimize_completed(plugin, window_actor),
        .unminimize => c.meta_plugin_unminimize_completed(plugin, window_actor),
    }
    std.log.debug("effect done: {s}", .{@tagName(@as(Effect, @enumFromInt(@intFromPtr(kind))))});
}

fn appWindow(window_actor: ?*c.MetaWindowActor) bool {
    return isAppWindow(c.meta_window_actor_get_meta_window(window_actor));
}

/// New windows fade in while growing slightly, like GNOME.
fn map(plugin: ?*c.MetaPlugin, window_actor: ?*c.MetaWindowActor) callconv(.C) void {
    if (!appWindow(window_actor)) return c.meta_plugin_map_completed(plugin, window_actor);
    overview.windowMapped();

    const meta_window = c.meta_window_actor_get_meta_window(window_actor);
    tiling.windowMapped(meta_window, @import("rules.zig").apply(meta_window));
    if (config.open_animation == .none) return c.meta_plugin_map_completed(plugin, window_actor);

    const actor: *c.ClutterActor = @ptrCast(@alignCast(window_actor));
    c.clutter_actor_set_pivot_point(actor, 0.5, 0.5);
    c.clutter_actor_set_opacity(actor, 0);
    switch (config.open_animation) {
        .scale => c.clutter_actor_set_scale(actor, map_start_scale, map_start_scale),
        .slide => c.clutter_actor_set_translation(actor, 0, 40, 0),
        else => {},
    }
    c.clutter_actor_show(actor);

    ui.ease(actor, map_duration_ms, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(actor, 255);
    c.clutter_actor_set_scale(actor, 1.0, 1.0);
    c.clutter_actor_set_translation(actor, 0, 0, 0);
    c.clutter_actor_restore_easing_state(actor);
    startEffect(plugin, actor, .map);
}

/// Closing windows fade out while shrinking a little.
fn destroy(plugin: ?*c.MetaPlugin, window_actor: ?*c.MetaWindowActor) callconv(.C) void {
    if (!appWindow(window_actor) or config.close_animation == .none) return c.meta_plugin_destroy_completed(plugin, window_actor);
    const actor: *c.ClutterActor = @ptrCast(@alignCast(window_actor));
    c.clutter_actor_set_pivot_point(actor, 0.5, 0.5);
    ui.ease(actor, destroy_ms, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(actor, 0);
    if (config.close_animation == .scale) c.clutter_actor_set_scale(actor, 0.9, 0.9);
    c.clutter_actor_restore_easing_state(actor);
    startEffect(plugin, actor, .destroy);
}

/// Where minimized windows go: the bottom middle of the primary monitor,
/// where the dock appears.
fn minimizeOffset(actor: *c.ClutterActor) [2]f32 {
    const d = display orelse return .{ 0, 0 };
    if (c.meta_display_get_n_monitors(d) == 0) return .{ 0, 0 };
    var mon: c.MtkRectangle = undefined;
    c.meta_display_get_monitor_geometry(d, c.meta_display_get_primary_monitor(d), &mon);
    var x: f32 = 0;
    var y: f32 = 0;
    var w: f32 = 0;
    var h: f32 = 0;
    c.clutter_actor_get_position(actor, &x, &y);
    c.clutter_actor_get_size(actor, &w, &h);
    const tx = @as(f32, @floatFromInt(mon.x)) + @as(f32, @floatFromInt(mon.width)) / 2 - (x + w / 2);
    const ty = @as(f32, @floatFromInt(mon.y + mon.height)) - (y + h / 2);
    return .{ tx, ty };
}

/// Minimizing shrinks the window down toward the dock.
fn minimize(plugin: ?*c.MetaPlugin, window_actor: ?*c.MetaWindowActor) callconv(.C) void {
    if (!appWindow(window_actor) or config.minimize_animation == .none) return c.meta_plugin_minimize_completed(plugin, window_actor);
    const actor: *c.ClutterActor = @ptrCast(@alignCast(window_actor));
    const offset = minimizeOffset(actor);
    c.clutter_actor_set_pivot_point(actor, 0.5, 0.5);
    ui.ease(actor, minimize_ms, c.CLUTTER_EASE_IN_QUAD);
    if (config.minimize_animation == .dock) {
        c.clutter_actor_set_translation(actor, offset[0], offset[1], 0);
        c.clutter_actor_set_scale(actor, 0.1, 0.1);
    }
    c.clutter_actor_set_opacity(actor, 0);
    c.clutter_actor_restore_easing_state(actor);
    startEffect(plugin, actor, .minimize);
}

/// Restoring grows the window back out of the dock.
fn unminimize(plugin: ?*c.MetaPlugin, window_actor: ?*c.MetaWindowActor) callconv(.C) void {
    if (!appWindow(window_actor) or config.minimize_animation == .none) return c.meta_plugin_unminimize_completed(plugin, window_actor);
    const actor: *c.ClutterActor = @ptrCast(@alignCast(window_actor));
    const offset = minimizeOffset(actor);
    c.clutter_actor_set_pivot_point(actor, 0.5, 0.5);
    if (config.minimize_animation == .dock) {
        c.clutter_actor_set_translation(actor, offset[0], offset[1], 0);
        c.clutter_actor_set_scale(actor, 0.1, 0.1);
    }
    c.clutter_actor_set_opacity(actor, 0);
    c.clutter_actor_show(actor);
    ui.ease(actor, minimize_ms, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_translation(actor, 0, 0, 0);
    c.clutter_actor_set_scale(actor, 1.0, 1.0);
    c.clutter_actor_set_opacity(actor, 255);
    c.clutter_actor_restore_easing_state(actor);
    startEffect(plugin, actor, .unminimize);
}

/// Sookie asks to stop effects early (window closed, moved, ...).
fn killWindowEffects(plugin: ?*c.MetaPlugin, window_actor: ?*c.MetaWindowActor) callconv(.C) void {
    const actor: *c.ClutterActor = @ptrCast(@alignCast(window_actor));
    if (c.g_object_get_data(@ptrCast(@alignCast(actor)), effect_key) == null) return;
    c.clutter_actor_remove_all_transitions(actor);
    finishEffect(actor, plugin);
}

// ---- Debug -----------------------------------------------------------------------

/// CALI_DEBUG_MINIMIZE=<seconds>: minimize the focused window, restore it two
/// seconds later, then close it two seconds after that.
fn debugMinimize(_: c.gpointer) callconv(.C) c.gboolean {
    const d = display orelse return 0;
    debug_window = c.meta_display_get_focus_window(d);
    if (debug_window) |w| c.meta_window_minimize(w);
    _ = c.g_timeout_add_seconds(2, &debugUnminimize, null);
    return 0;
}

var debug_window: ?*c.MetaWindow = null;

fn debugUnminimize(_: c.gpointer) callconv(.C) c.gboolean {
    if (debug_window) |w| c.meta_window_unminimize(w);
    _ = c.g_timeout_add_seconds(2, &debugClose, null);
    return 0;
}

fn debugClose(_: c.gpointer) callconv(.C) c.gboolean {
    const d = display orelse return 0;
    if (debug_window) |w| c.meta_window_delete(w, c.meta_display_get_current_time_roundtrip(d));
    return 0;
}
