//! Activities overview: Super (or the top-left hot corner) zooms the windows
//! out into a grid. Click a window to switch to it; Escape, Super or a click
//! on empty space goes back. The grid layout comes from cali-shell (Rust).

const std = @import("std");
const plugin = @import("plugin.zig");
const dock = @import("dock.zig");
const ui = @import("ui.zig");
const c = plugin.c;

const duration_ms = 250;
const dim_opacity = 110;
const margin: f32 = 48.0;
const max_windows = 64;
const title_space: f32 = 40.0; // room under each window for its title
const title_font = "Adwaita Sans 10";
const close_size: f32 = 28.0;

const State = enum { closed, opening, open, closing };

/// One window in the overview: a card holding a live clone, a title pill
/// below it and a close button on its corner (shown on hover).
const Entry = struct {
    item: *c.ClutterActor,
    title: *c.ClutterActor,
    close_button: *c.ClutterActor,
    window: *c.MetaWindow,
    from: c.CaliRect,
};

var state: State = .closed;
var display: ?*c.MetaDisplay = null;
var stage: ?*c.ClutterActor = null;
var panel: ?*c.ClutterActor = null;

var group: ?*c.ClutterActor = null;
var dim: ?*c.ClutterActor = null;
var grab: ?*c.ClutterGrab = null;
var hot_corner: ?*c.ClutterActor = null;
var hot_corner_armed = false;
var entries: [max_windows]Entry = undefined;
var n_entries: usize = 0;
var layout_area = c.CaliRect{ .x = 0, .y = 0, .width = 0, .height = 0 };

const black = c.CoglColor{ .red = 0, .green = 0, .blue = 0, .alpha = 255 };

pub fn init(d: ?*c.MetaDisplay, s: ?*c.ClutterActor, p: ?*c.ClutterActor) void {
    display = d;
    stage = s;
    panel = p;

    plugin.connect(d, "overlay-key", &onOverlayKey, null);

    // Hot corner: pushing the pointer into the top-left corner opens the overview.
    // It only fires after the pointer has been outside it, so a pointer that
    // starts in the corner (as in a fresh nested session) doesn't trigger it.
    const corner = c.clutter_actor_new();
    c.clutter_actor_set_size(corner, 1, 1);
    c.clutter_actor_set_reactive(corner, 1);
    c.clutter_actor_add_child(p, corner);
    plugin.connect(corner, "enter-event", &onHotCorner, null);
    plugin.connect(corner, "leave-event", &onHotCornerLeft, null);
    hot_corner = corner;
    _ = c.g_timeout_add_seconds(2, &armHotCornerIfFree, null);

    // CALI_DEBUG_OVERVIEW=<seconds> opens the overview once, for testing.
    if (std.posix.getenv("CALI_DEBUG_OVERVIEW")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugOpen, null);
    }
}

pub fn toggle() void {
    switch (state) {
        .closed => open(),
        .open => close(null),
        .opening, .closing => {},
    }
}

fn onOverlayKey(_: ?*c.MetaDisplay, _: c.gpointer) callconv(.C) void {
    toggle();
}

fn onHotCorner(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    if (hot_corner_armed) {
        hot_corner_armed = false;
        toggle();
    }
    return 0;
}

fn onHotCornerLeft(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    hot_corner_armed = true;
    return 0;
}

fn armHotCornerIfFree(_: c.gpointer) callconv(.C) c.gboolean {
    if (hot_corner) |corner| {
        if (c.clutter_actor_has_pointer(corner) == 0) hot_corner_armed = true;
    }
    return 0; // run once
}

/// A window opened while the overview is up: go back to the desktop so it's visible.
pub fn windowMapped() void {
    if (state == .open) close(null);
}

fn debugOpen(_: c.gpointer) callconv(.C) c.gboolean {
    if (state == .closed) open();
    // CALI_DEBUG_OVERVIEW_PICK=<seconds> then picks the last window, like a click.
    if (std.posix.getenv("CALI_DEBUG_OVERVIEW_PICK")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugPick, null);
    }
    return 0; // run once
}

fn debugPick(_: c.gpointer) callconv(.C) c.gboolean {
    if (n_entries > 0) close(entries[n_entries - 1].window) else close(null);
    std.log.debug("overview: picked a window, closing", .{});
    return 0;
}

// ---- Opening ---------------------------------------------------------------------

fn open() void {
    const d = display orelse return;
    const s = stage orelse return;
    if (c.meta_display_get_n_monitors(d) == 0) return;

    const compositor = c.meta_display_get_compositor(d);
    const window_group = c.meta_compositor_get_window_group(compositor);
    const workspace = c.meta_workspace_manager_get_active_workspace(c.meta_display_get_workspace_manager(d));
    const primary = c.meta_display_get_primary_monitor(d);

    var work: c.MtkRectangle = undefined;
    c.meta_workspace_get_work_area_for_monitor(workspace, primary, &work);

    var stage_w: f32 = 0;
    var stage_h: f32 = 0;
    c.clutter_actor_get_size(s, &stage_w, &stage_h);

    const g = c.clutter_actor_new();
    c.clutter_actor_set_size(g, stage_w, stage_h);
    c.clutter_actor_set_reactive(g, 1);
    c.clutter_actor_insert_child_below(s, g, panel);
    group = g;

    // The real windows (and the desktop background inside the window group) are
    // hidden while the overview is open, so it gets a background of its own.
    // (Cloning the desktop one would reuse its culling and leave holes.)
    const background = c.meta_background_group_new();
    c.clutter_actor_add_child(g, background);
    plugin.fillBackground(background);

    const dm = c.clutter_actor_new();
    c.clutter_actor_set_size(dm, stage_w, stage_h);
    c.clutter_actor_set_background_color(dm, &black);
    c.clutter_actor_set_opacity(dm, 0);
    c.clutter_actor_add_child(g, dm);
    dim = dm;

    // The dock sits at the bottom; windows get the space above it, with room
    // for their titles.
    const dock_height = dock.create(d, g, stage_w, stage_h);
    const work_top = @as(f32, @floatFromInt(work.y));
    const work_bottom = @min(@as(f32, @floatFromInt(work.y + work.height)), stage_h - dock_height);
    layout_area = .{
        .x = @as(f32, @floatFromInt(work.x)) + margin,
        .y = work_top + margin,
        .width = @as(f32, @floatFromInt(work.width)) - 2 * margin,
        .height = work_bottom - work_top - 2 * margin - title_space,
    };

    // One card per window on this workspace, in stacking order.
    n_entries = 0;
    var node = c.meta_compositor_get_window_actors(compositor);
    while (node != null and n_entries < max_windows) : (node = node.*.next) {
        const window_actor: ?*c.MetaWindowActor = @ptrCast(@alignCast(node.*.data));
        const window = c.meta_window_actor_get_meta_window(window_actor) orelse continue;
        if (!plugin.isAppWindow(window)) continue;
        if (c.meta_window_is_hidden(window) != 0) continue;
        if (c.meta_window_is_skip_taskbar(window) != 0) continue;
        if (c.meta_window_located_on_workspace(window, workspace) == 0) continue;

        const actor: *c.ClutterActor = @ptrCast(@alignCast(window_actor));
        var from = c.CaliRect{ .x = 0, .y = 0, .width = 0, .height = 0 };
        c.clutter_actor_get_position(actor, &from.x, &from.y);
        c.clutter_actor_get_size(actor, &from.width, &from.height);

        entries[n_entries] = makeCard(g, actor, window, from);
        n_entries += 1;
    }

    std.log.debug("overview: {d} windows", .{n_entries});
    relayout();

    ease(dm);
    c.clutter_actor_set_opacity(dm, dim_opacity);
    c.clutter_actor_restore_easing_state(dm);
    plugin.connect(dm, "transitions-completed", &onDimDone, null);

    c.clutter_actor_hide(window_group);

    plugin.connect(g, "button-release-event", &onEmptyClicked, null);
    plugin.connect(g, "key-press-event", &onKey, null);
    grab = c.clutter_stage_grab(@ptrCast(@alignCast(s)), g);
    c.clutter_stage_set_key_focus(@ptrCast(@alignCast(s)), g);

    state = .opening;
}

fn ease(actor: ?*c.ClutterActor) void {
    c.clutter_actor_save_easing_state(actor);
    c.clutter_actor_set_easing_mode(actor, @intCast(c.CLUTTER_EASE_OUT_QUAD));
    c.clutter_actor_set_easing_duration(actor, duration_ms);
}

fn makeCard(parent: ?*c.ClutterActor, actor: *c.ClutterActor, window: *c.MetaWindow, from: c.CaliRect) Entry {
    const item = c.clutter_actor_new();
    c.clutter_actor_set_position(item, from.x, from.y);
    c.clutter_actor_set_size(item, from.width, from.height);
    c.clutter_actor_set_reactive(item, 1);

    const clone = c.clutter_clone_new(actor);
    c.clutter_actor_add_constraint(clone, c.clutter_bind_constraint_new(item, @intCast(c.CLUTTER_BIND_SIZE), 0));
    c.clutter_actor_add_child(item, clone);

    // Title pill, centered under the window.
    const text = ui.label(c.meta_window_get_title(window) orelse "", title_font);
    const text_w = @min(ui.preferredWidth(text), 280);
    const text_h = ui.preferredHeight(text);
    c.clutter_actor_set_width(text, text_w);
    const pill_h = text_h + 10;
    const title = ui.roundedRect(text_w + 24, pill_h, pill_h / 2, 0x000000b0);
    c.clutter_actor_set_position(text, 12, 5);
    c.clutter_actor_add_child(title, text);
    ui.center(title, item, c.CLUTTER_ALIGN_X_AXIS);
    c.clutter_actor_add_constraint(title, c.clutter_align_constraint_new(item, @intCast(c.CLUTTER_ALIGN_Y_AXIS), 1.0));
    c.clutter_actor_set_translation(title, 0, pill_h + 10, 0);
    c.clutter_actor_set_opacity(title, 0);
    c.clutter_actor_add_child(item, title);

    // Close button on the top-right corner.
    const button = ui.roundedRect(close_size, close_size, close_size / 2, 0x3a3a3aff);
    const x_icon = ui.icon("window-close-symbolic", 16, true, 0xffffff);
    ui.center(x_icon, button, c.CLUTTER_ALIGN_BOTH);
    c.clutter_actor_add_child(button, x_icon);
    c.clutter_actor_add_constraint(button, c.clutter_align_constraint_new(item, @intCast(c.CLUTTER_ALIGN_X_AXIS), 1.0));
    c.clutter_actor_set_translation(button, close_size / 2 - 4, -(close_size / 2 - 4), 0);
    c.clutter_actor_set_opacity(button, 0);
    c.clutter_actor_set_reactive(button, 1);
    c.clutter_actor_add_child(item, button);

    plugin.connect(item, "button-release-event", &onItemClicked, item);
    plugin.connect(button, "button-release-event", &onCloseClicked, item);
    plugin.connect(item, "enter-event", &onItemEnter, button);
    plugin.connect(item, "leave-event", &onItemLeave, button);
    c.clutter_actor_add_child(parent, item);

    return .{ .item = item, .title = title, .close_button = button, .window = window, .from = from };
}

/// Places every card in the grid from cali-shell, animating there.
fn relayout() void {
    var rects: [max_windows]c.CaliRect = undefined;
    for (entries[0..n_entries], 0..) |entry, i| rects[i] = entry.from;
    var targets: [max_windows]c.CaliRect = undefined;
    const placed = c.cali_shell_overview_layout(layout_area, &rects, n_entries, &targets);
    for (entries[0..placed], targets[0..placed]) |entry, to| {
        animate(entry.item, to);
        fade(entry.title, 255);
    }
}

fn fade(actor: ?*c.ClutterActor, opacity: u8) void {
    ui.ease(actor, 150, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(actor, opacity);
    c.clutter_actor_restore_easing_state(actor);
}

fn entryIndex(item: c.gpointer) ?usize {
    for (entries[0..n_entries], 0..) |entry, i| {
        if (@as(c.gpointer, entry.item) == item) return i;
    }
    return null;
}

fn animate(actor: *c.ClutterActor, to: c.CaliRect) void {
    ease(actor);
    c.clutter_actor_set_position(actor, to.x, to.y);
    c.clutter_actor_set_size(actor, to.width, to.height);
    c.clutter_actor_restore_easing_state(actor);
}

// ---- Input while open -------------------------------------------------------------

fn onItemClicked(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, item: c.gpointer) callconv(.C) c.gboolean {
    if (entryIndex(item)) |i| close(entries[i].window);
    return 1; // handled
}

/// Closes the window (the app may still ask first) and closes the gap.
fn onCloseClicked(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, item: c.gpointer) callconv(.C) c.gboolean {
    if (state != .open) return 1;
    const i = entryIndex(item) orelse return 1;
    const d = display orelse return 1;
    c.meta_window_delete(entries[i].window, c.meta_display_get_current_time_roundtrip(d));
    c.clutter_actor_destroy(entries[i].item);
    std.mem.copyForwards(Entry, entries[i .. n_entries - 1], entries[i + 1 .. n_entries]);
    n_entries -= 1;
    relayout();
    return 1;
}

fn onItemEnter(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, button: c.gpointer) callconv(.C) c.gboolean {
    fade(@ptrCast(@alignCast(button)), 255);
    return 0;
}

fn onItemLeave(item: ?*c.ClutterActor, event: ?*c.ClutterEvent, button: c.gpointer) callconv(.C) c.gboolean {
    // Moving onto the close button (a child) isn't leaving the card.
    const to = c.clutter_event_get_related(event);
    if (to != null and c.clutter_actor_contains(item, to) != 0) return 0;
    fade(@ptrCast(@alignCast(button)), 0);
    return 0;
}

/// Leaves the overview, switching to `window` if given (used by the dock).
pub fn closeTo(window: ?*c.MetaWindow) void {
    close(window);
}

fn onEmptyClicked(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    close(null);
    return 1;
}

fn onKey(_: ?*c.ClutterActor, event: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    switch (c.clutter_event_get_key_symbol(event)) {
        c.CLUTTER_KEY_Escape, c.CLUTTER_KEY_Super_L, c.CLUTTER_KEY_Super_R => {
            close(null);
            return 1;
        },
        else => return 0,
    }
}

// ---- Closing ----------------------------------------------------------------------

/// Animates back to the desktop, switching to `target` if given.
fn close(target: ?*c.MetaWindow) void {
    if (state != .open) return;
    state = .closing;

    if (grab) |g| {
        c.clutter_grab_dismiss(g);
        c.g_object_unref(g);
        grab = null;
    }

    if (target) |window| activate(window);

    for (entries[0..n_entries]) |entry| {
        if (target != null and entry.window == target.?) {
            c.clutter_actor_set_child_above_sibling(group, entry.item, null);
        }
        c.clutter_actor_hide(entry.title);
        c.clutter_actor_hide(entry.close_button);
        animate(entry.item, entry.from);
    }
    dock.hide();

    ease(dim);
    c.clutter_actor_set_opacity(dim, 0);
    c.clutter_actor_restore_easing_state(dim);
}

/// Focuses `window` if it still exists (it may have closed meanwhile).
fn activate(window: *c.MetaWindow) void {
    const d = display orelse return;
    const all = c.meta_display_list_all_windows(d);
    defer c.g_list_free(all);
    var node = all;
    while (node != null) : (node = node.*.next) {
        if (node.*.data == @as(c.gpointer, window)) {
            c.meta_window_activate(window, c.meta_display_get_current_time_roundtrip(d));
            return;
        }
    }
}

fn onDimDone(_: ?*c.ClutterActor, _: c.gpointer) callconv(.C) void {
    switch (state) {
        .opening => state = .open,
        .closing => finishClose(),
        else => {},
    }
}

fn finishClose() void {
    if (display) |d| {
        c.clutter_actor_show(c.meta_compositor_get_window_group(c.meta_display_get_compositor(d)));
    }
    if (group) |g| c.clutter_actor_destroy(g);
    group = null;
    dim = null;
    dock.clear();
    n_entries = 0;
    state = .closed;
    std.log.debug("overview: closed", .{});
}
