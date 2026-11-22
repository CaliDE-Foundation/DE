//! Workspaces: the dots in the top bar, GNOME-style dynamic workspaces (the
//! rules come from cali-shell), and the slide when switching workspaces.

const std = @import("std");
const plugin = @import("plugin.zig");
const overview = @import("overview.zig");
const c = plugin.c;

const max_workspaces = 36;
const dot_ms = 250;
const switch_ms = 250;
const indicator_x: f32 = 14;
const white = c.CoglColor{ .red = 255, .green = 255, .blue = 255, .alpha = 255 };

var display: ?*c.MetaDisplay = null;
var stage: ?*c.ClutterActor = null;
var panel: ?*c.ClutterActor = null;
var style: c.CaliDotStyle = undefined;

var indicator: ?*c.ClutterActor = null;
var circle: ?*c.ClutterContent = null;
var check_pending = false;

pub fn init(d: ?*c.MetaDisplay, s: ?*c.ClutterActor, p: ?*c.ClutterActor) void {
    display = d;
    stage = s;
    panel = p;
    style = c.cali_shell_workspace_dots_style();
    circle = makeCircle(p);

    const box = c.clutter_actor_new();
    const layout = c.clutter_box_layout_new();
    c.clutter_box_layout_set_spacing(@ptrCast(@alignCast(layout)), @intFromFloat(style.spacing));
    c.clutter_actor_set_layout_manager(box, layout);
    c.clutter_actor_set_position(box, indicator_x, 0);
    c.clutter_actor_set_height(box, @floatFromInt(c.cali_shell_panel_height()));
    c.clutter_actor_set_reactive(box, 1);
    c.clutter_actor_add_child(p, box);
    plugin.connect(box, "button-release-event", &onIndicatorClicked, null);
    indicator = box;

    const manager = c.meta_display_get_workspace_manager(d);
    plugin.connect(manager, "workspace-added", &onWorkspacesChanged, null);
    plugin.connect(manager, "workspace-removed", &onWorkspacesChanged, null);
    plugin.connect(manager, "active-workspace-changed", &onActiveChanged, null);
    plugin.connect(d, "window-created", &onWindowCreated, null);

    rebuildDots();
    scheduleCheck();

    // CALI_DEBUG_WORKSPACES=<seconds>: move the focused window to the next
    // workspace and switch there, for testing.
    if (std.posix.getenv("CALI_DEBUG_WORKSPACES")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugMoveAndSwitch, null);
    }
}

// ---- Dots ---------------------------------------------------------------------------

/// The dot image: a white circle rendered by cali-shell at twice the size,
/// so it stays crisp when scaled.
fn makeCircle(p: ?*c.ClutterActor) ?*c.ClutterContent {
    const px: c_uint = @intFromFloat(style.size * 2);
    var buf: [64 * 64 * 4]u8 = undefined;
    if (px * px * 4 > buf.len) return null;
    if (!c.cali_shell_render_rounded_rect(px, px, @floatFromInt(px / 2), 0xffffffff, &buf, buf.len)) return null;

    const ctx = c.clutter_backend_get_cogl_context(c.clutter_context_get_backend(c.clutter_actor_get_context(p)));
    var err: ?*c.GError = null;
    const texture = c.cogl_texture_2d_new_from_data(ctx, @intCast(px), @intCast(px), @intCast(c.COGL_PIXEL_FORMAT_RGBA_8888_PRE), @intCast(px * 4), &buf, @ptrCast(&err));
    if (texture == null) {
        std.log.warn("workspaces: could not create the dot texture", .{});
        if (err) |e| c.g_error_free(e);
        return null;
    }
    defer c.g_object_unref(texture);
    return c.clutter_texture_content_new_from_texture(texture, null);
}

fn circleActor() *c.ClutterActor {
    const actor = c.clutter_actor_new();
    c.clutter_actor_set_size(actor, style.size, style.size);
    if (circle) |content| c.clutter_actor_set_content(actor, content);
    c.clutter_actor_set_content_scaling_filters(actor, @intCast(c.CLUTTER_SCALING_FILTER_TRILINEAR), @intCast(c.CLUTTER_SCALING_FILTER_LINEAR));
    return actor;
}

/// A dot that can stretch into a pill without distorting its round ends:
/// two circles with a bar between them.
fn makeDot() *c.ClutterActor {
    const s = style.size;
    const dot = c.clutter_actor_new();
    c.clutter_actor_set_size(dot, s, s);
    c.clutter_actor_set_y_align(dot, @intCast(c.CLUTTER_ACTOR_ALIGN_CENTER));
    // Flatten before fading so the overlapping parts don't look brighter.
    c.clutter_actor_set_offscreen_redirect(dot, @intCast(c.CLUTTER_OFFSCREEN_REDIRECT_AUTOMATIC_FOR_OPACITY));

    c.clutter_actor_add_child(dot, circleActor());

    const right = circleActor();
    c.clutter_actor_add_constraint(right, c.clutter_align_constraint_new(dot, @intCast(c.CLUTTER_ALIGN_X_AXIS), 1.0));
    c.clutter_actor_add_child(dot, right);

    const bar = c.clutter_actor_new();
    c.clutter_actor_set_background_color(bar, &white);
    c.clutter_actor_set_position(bar, s / 2, 0);
    c.clutter_actor_set_height(bar, s);
    c.clutter_actor_add_constraint(bar, c.clutter_bind_constraint_new(dot, @intCast(c.CLUTTER_BIND_WIDTH), -s));
    c.clutter_actor_add_child(dot, bar);
    return dot;
}

fn styleDot(dot: ?*c.ClutterActor, active: bool, animate: bool) void {
    if (animate) {
        c.clutter_actor_save_easing_state(dot);
        c.clutter_actor_set_easing_mode(dot, @intCast(c.CLUTTER_EASE_OUT_QUAD));
        c.clutter_actor_set_easing_duration(dot, dot_ms);
    }
    c.clutter_actor_set_width(dot, if (active) style.active_width else style.size);
    c.clutter_actor_set_opacity(dot, if (active) 255 else style.inactive_opacity);
    if (animate) c.clutter_actor_restore_easing_state(dot);
}

fn rebuildDots() void {
    const d = display orelse return;
    const box = indicator orelse return;
    const manager = c.meta_display_get_workspace_manager(d);
    const n = @min(c.meta_workspace_manager_get_n_workspaces(manager), max_workspaces);
    const active = c.meta_workspace_manager_get_active_workspace_index(manager);

    c.clutter_actor_destroy_all_children(box);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const dot = makeDot();
        c.clutter_actor_add_child(box, dot);
        styleDot(dot, i == active, false);
    }
}

fn restyleDots(animate: bool) void {
    const d = display orelse return;
    const box = indicator orelse return;
    const active = c.meta_workspace_manager_get_active_workspace_index(c.meta_display_get_workspace_manager(d));
    var i: c_int = 0;
    var child = c.clutter_actor_get_first_child(box);
    while (child != null) : ({
        child = c.clutter_actor_get_next_sibling(child);
        i += 1;
    }) {
        styleDot(child, i == active, animate);
    }
}

fn onIndicatorClicked(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    overview.toggle();
    return 1;
}

fn onWorkspacesChanged(_: ?*c.MetaWorkspaceManager, _: c_int, _: c.gpointer) callconv(.C) void {
    rebuildDots();
    scheduleCheck();
}

fn onActiveChanged(_: ?*c.MetaWorkspaceManager, _: c.gpointer) callconv(.C) void {
    restyleDots(true);
    scheduleCheck();
}

// ---- Dynamic workspaces -------------------------------------------------------------

fn onWindowCreated(_: ?*c.MetaDisplay, window: ?*c.MetaWindow, _: c.gpointer) callconv(.C) void {
    plugin.connect(window, "workspace-changed", &onWindowChanged, null);
    plugin.connect(window, "unmanaged", &onWindowChanged, null);
    scheduleCheck();
}

fn onWindowChanged(_: ?*c.MetaWindow, _: c.gpointer) callconv(.C) void {
    scheduleCheck();
}

/// Checks the workspaces once things settle (many changes come in bursts).
fn scheduleCheck() void {
    if (check_pending) return;
    check_pending = true;
    _ = c.g_idle_add(&runCheck, null);
}

fn hasAppWindows(workspace: ?*c.MetaWorkspace) bool {
    const windows = c.meta_workspace_list_windows(workspace);
    defer c.g_list_free(windows);
    var node = windows;
    while (node != null) : (node = node.*.next) {
        const window: ?*c.MetaWindow = @ptrCast(@alignCast(node.*.data));
        if (!plugin.isAppWindow(window)) continue;
        if (c.meta_window_is_on_all_workspaces(window) != 0) continue;
        if (c.meta_window_is_skip_taskbar(window) != 0) continue;
        return true;
    }
    return false;
}

fn runCheck(_: c.gpointer) callconv(.C) c.gboolean {
    check_pending = false;
    const d = display orelse return 0;
    const manager = c.meta_display_get_workspace_manager(d);
    const n: usize = @intCast(@min(c.meta_workspace_manager_get_n_workspaces(manager), max_workspaces));

    var occupied: [max_workspaces]bool = undefined;
    for (0..n) |i| {
        occupied[i] = hasAppWindows(c.meta_workspace_manager_get_workspace_by_index(manager, @intCast(i)));
    }
    const active: usize = @intCast(c.meta_workspace_manager_get_active_workspace_index(manager));

    var remove: [max_workspaces]c_uint = undefined;
    var append = false;
    const count = c.cali_shell_workspace_plan(&occupied, n, active, &remove, max_workspaces, &append);

    const time = c.meta_display_get_current_time_roundtrip(d);
    for (remove[0..count]) |index| {
        const workspace = c.meta_workspace_manager_get_workspace_by_index(manager, @intCast(index));
        c.meta_workspace_manager_remove_workspace(manager, workspace, time);
    }
    if (append) _ = c.meta_workspace_manager_append_new_workspace(manager, 0, time);
    return 0; // run once
}

// ---- Switching ---------------------------------------------------------------------

var slide_holder: ?*c.ClutterActor = null;
var slide_layer: ?*c.ClutterActor = null;
var slide_plugin: ?*c.MetaPlugin = null;

fn isMinimized(window: ?*c.MetaWindow) bool {
    var minimized: c.gboolean = 0;
    c.g_object_get(window, "minimized", &minimized, @as(?*anyopaque, null));
    return minimized != 0;
}

/// Slides the old workspace's windows out and the new one's in, over a
/// still background. Uses clones, like the overview.
pub fn switchWorkspace(p: ?*c.MetaPlugin, from: c_int, to: c_int, _: c.MetaMotionDirection) callconv(.C) void {
    finishSwitch();
    const d = display orelse return c.meta_plugin_switch_workspace_completed(p);
    const s = stage orelse return c.meta_plugin_switch_workspace_completed(p);
    if (from == to) return c.meta_plugin_switch_workspace_completed(p);

    const compositor = c.meta_display_get_compositor(d);
    var width: f32 = 0;
    var height: f32 = 0;
    c.clutter_actor_get_size(s, &width, &height);
    const sign: f32 = if (to > from) 1 else -1;

    const holder = c.clutter_actor_new();
    c.clutter_actor_set_size(holder, width, height);
    c.clutter_actor_insert_child_below(s, holder, panel);

    const background = c.meta_background_group_new();
    c.clutter_actor_add_child(holder, background);
    plugin.fillBackground(background);

    const layer = c.clutter_actor_new();
    c.clutter_actor_add_child(holder, layer);

    var node = c.meta_compositor_get_window_actors(compositor);
    while (node != null) : (node = node.*.next) {
        const window_actor: ?*c.MetaWindowActor = @ptrCast(@alignCast(node.*.data));
        const window = c.meta_window_actor_get_meta_window(window_actor) orelse continue;
        if (isMinimized(window)) continue;

        const actor: *c.ClutterActor = @ptrCast(@alignCast(window_actor));
        var x: f32 = 0;
        var y: f32 = 0;
        c.clutter_actor_get_position(actor, &x, &y);
        const clone = c.clutter_clone_new(actor);

        if (c.meta_window_is_on_all_workspaces(window) != 0) {
            c.clutter_actor_set_position(clone, x, y); // sticky: stays put
            c.clutter_actor_add_child(holder, clone);
            continue;
        }
        const workspace = c.meta_window_get_workspace(window) orelse {
            c.clutter_actor_destroy(clone);
            continue;
        };
        const index = c.meta_workspace_index(workspace);
        if (index == from) {
            c.clutter_actor_set_position(clone, x, y);
        } else if (index == to) {
            c.clutter_actor_set_position(clone, x + sign * width, y);
        } else {
            c.clutter_actor_destroy(clone);
            continue;
        }
        c.clutter_actor_add_child(layer, clone);
    }

    c.clutter_actor_hide(c.meta_compositor_get_window_group(compositor));
    slide_holder = holder;
    slide_layer = layer;
    slide_plugin = p;

    c.clutter_actor_save_easing_state(layer);
    c.clutter_actor_set_easing_mode(layer, @intCast(c.CLUTTER_EASE_OUT_CUBIC));
    c.clutter_actor_set_easing_duration(layer, switch_ms);
    c.clutter_actor_set_x(layer, -sign * width);
    c.clutter_actor_restore_easing_state(layer);
    plugin.connect(layer, "transitions-completed", &onSlideDone, null);
}

fn onSlideDone(_: ?*c.ClutterActor, _: c.gpointer) callconv(.C) void {
    finishSwitch();
}

pub fn killSwitchWorkspace(_: ?*c.MetaPlugin) callconv(.C) void {
    finishSwitch();
}

fn finishSwitch() void {
    const holder = slide_holder orelse return;
    slide_holder = null;
    if (slide_layer) |layer| c.clutter_actor_remove_all_transitions(layer);
    slide_layer = null;
    c.clutter_actor_destroy(holder);
    if (display) |d| c.clutter_actor_show(c.meta_compositor_get_window_group(c.meta_display_get_compositor(d)));
    const p = slide_plugin;
    slide_plugin = null;
    c.meta_plugin_switch_workspace_completed(p);
}

// ---- Debug --------------------------------------------------------------------------

fn debugMoveAndSwitch(_: c.gpointer) callconv(.C) c.gboolean {
    const d = display orelse return 0;
    const window = c.meta_display_get_focus_window(d) orelse {
        std.log.warn("workspaces: no focused window to move", .{});
        return 0;
    };
    const manager = c.meta_display_get_workspace_manager(d);
    const next = c.meta_workspace_manager_get_active_workspace_index(manager) + 1;
    c.meta_window_change_workspace_by_index(window, next, 1);
    c.meta_workspace_activate(c.meta_workspace_manager_get_workspace_by_index(manager, next), c.meta_display_get_current_time_roundtrip(d));
    std.log.debug("workspaces: moved the focused window to workspace {d}", .{next + 1});
    return 0;
}
