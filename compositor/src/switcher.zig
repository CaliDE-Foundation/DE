//! Alt+Tab: switch between apps, most recently used first. Tab / Shift+Tab
//! (or the arrow keys) move; letting go of Alt switches; Escape cancels.

const std = @import("std");
const plugin = @import("plugin.zig");
const dock = @import("dock.zig");
const ui = @import("ui.zig");
const c = plugin.c;
const config = @import("config.zig");

const max_apps = 16;
const icon_size: f32 = 64;
const cell: f32 = 96;
const padding: f32 = 18;
const label_h: f32 = 30;
const background: u32 = 0x2e2e32f0;
const highlight: u32 = 0xffffff26;
/// Alt is xkb's Mod1, the fourth real modifier.
const alt_mask: u32 = 1 << 3;

const Entry = struct {
    info: ?*c.GAppInfo,
    window: *c.MetaWindow,
};

var display: ?*c.MetaDisplay = null;
var stage: ?*c.ClutterActor = null;
var entries: [max_apps]Entry = undefined;
var n_entries: usize = 0;
var selected: usize = 0;

var card: ?*c.ClutterActor = null;
var marker: ?*c.ClutterActor = null;
var name_label: ?*c.ClutterActor = null;
var grab: ?*c.ClutterGrab = null;
var last_event_time: u32 = 0;
var sticky = false; // debug: don't wait for Alt

pub fn init(d: ?*c.MetaDisplay, s: ?*c.ClutterActor) void {
    display = d;
    stage = s;
    for ([_][*:0]const u8{ "switch-applications", "switch-windows" }) |name| {
        _ = c.meta_keybindings_set_custom_handler(name, &onBinding, null, null);
    }
    for ([_][*:0]const u8{ "switch-applications-backward", "switch-windows-backward" }) |name| {
        _ = c.meta_keybindings_set_custom_handler(name, &onBinding, @ptrFromInt(1), null);
    }

    // CALI_DEBUG_SWITCHER=<seconds> opens it (without needing Alt held) and
    // switches 3 seconds later, for testing.
    if (std.posix.getenv("CALI_DEBUG_SWITCHER")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugOpen, null);
    }
}

fn onBinding(_: ?*c.MetaDisplay, _: ?*c.MetaWindow, event: ?*const c.ClutterEvent, _: ?*c.MetaKeyBinding, data: c.gpointer) callconv(.C) void {
    const backward = data != null;
    if (event) |e| last_event_time = c.clutter_event_get_time(e);
    if (card != null) {
        move(if (backward) -1 else 1);
    } else {
        open(backward);
    }
}

fn debugOpen(_: c.gpointer) callconv(.C) c.gboolean {
    sticky = true;
    open(false);
    _ = c.g_timeout_add_seconds(3, &debugFinish, null);
    return 0;
}

fn debugFinish(_: c.gpointer) callconv(.C) c.gboolean {
    finish(true);
    std.log.debug("switcher: switched", .{});
    return 0;
}

// ---- Building the list ---------------------------------------------------------------------

fn collect() void {
    const d = display orelse return;
    n_entries = 0;
    const workspace = if (config.alt_tab_current_workspace) c.meta_workspace_manager_get_active_workspace(c.meta_display_get_workspace_manager(d)) else null;
    const windows = c.meta_display_get_tab_list(d, @intCast(c.META_TAB_LIST_NORMAL), workspace);
    defer c.g_list_free(windows);
    var node = windows;
    outer: while (node != null and n_entries < max_apps) : (node = node.*.next) {
        const window: *c.MetaWindow = @ptrCast(@alignCast(node.*.data orelse continue));
        const info = dock.appForWindow(window);
        // In windows mode every window gets its own entry.
        if (info != null and !config.alt_tab_windows) {
            const i = info.?;
            for (entries[0..n_entries]) |e| {
                if (e.info != null and c.g_app_info_equal(e.info, i) != 0) {
                    c.g_object_unref(i);
                    continue :outer; // one entry per app, its most recent window
                }
            }
        }
        entries[n_entries] = .{ .info = info, .window = window };
        n_entries += 1;
    }
}

fn clear() void {
    for (entries[0..n_entries]) |e| if (e.info) |i| c.g_object_unref(i);
    n_entries = 0;
}

// ---- Showing -------------------------------------------------------------------------------

fn open(backward: bool) void {
    const s = stage orelse return;
    collect();
    if (n_entries == 0) return;
    selected = if (n_entries == 1) 0 else if (backward) n_entries - 1 else 1;

    const n: f32 = @floatFromInt(n_entries);
    const w = n * cell + 2 * padding;
    const h = cell + label_h + 2 * padding;
    const k = ui.roundedRect(w, h, config.radius(1.3), background);

    const m = ui.roundedRect(cell, cell, 16, highlight);
    c.clutter_actor_set_y(m, padding);
    c.clutter_actor_add_child(k, m);
    marker = m;

    for (entries[0..n_entries], 0..) |e, i| {
        const icon = appIcon(e);
        c.clutter_actor_set_position(icon, padding + @as(f32, @floatFromInt(i)) * cell + (cell - icon_size) / 2, padding + (cell - icon_size) / 2);
        c.clutter_actor_add_child(k, icon);
    }

    const l = ui.label("", config.font(.bold, 0));
    c.clutter_actor_set_y(l, padding + cell + 6);
    c.clutter_actor_add_child(k, l);
    name_label = l;

    var sw: f32 = 0;
    var sh: f32 = 0;
    c.clutter_actor_get_size(s, &sw, &sh);
    c.clutter_actor_set_position(k, (sw - w) / 2, (sh - h) / 2);
    c.clutter_actor_set_reactive(k, 1);
    c.clutter_actor_add_child(s, k);
    card = k;

    plugin.connect(k, "key-press-event", &onKeyPress, null);
    plugin.connect(k, "key-release-event", &onKeyRelease, null);
    grab = c.clutter_stage_grab(@ptrCast(@alignCast(s)), k);
    c.clutter_stage_set_key_focus(@ptrCast(@alignCast(s)), k);

    updateSelection(false);

    // A quick Alt+Tab may have released Alt before we grabbed the keyboard.
    if (!sticky and !altHeld()) finish(true);
}

fn appIcon(e: Entry) *c.ClutterActor {
    var name: [*:0]const u8 = "application-x-executable";
    var owned: ?[*:0]u8 = null;
    defer if (owned) |o| c.g_free(o);
    if (e.info) |info| {
        if (c.g_app_info_get_icon(info)) |gicon| {
            if (c.g_icon_to_string(gicon)) |s| {
                owned = s;
                name = dock.iconName(std.mem.span(s));
            }
        }
    }
    return ui.icon(name, icon_size, false, 0);
}

fn updateSelection(animate: bool) void {
    const m = marker orelse return;
    const x = padding + @as(f32, @floatFromInt(selected)) * cell;
    if (animate) ui.ease(m, 120, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_x(m, x);
    if (animate) c.clutter_actor_restore_easing_state(m);

    const e = entries[selected];
    const title = c.meta_window_get_title(e.window);
    const text: [*:0]const u8 = if (config.alt_tab_windows and title != null) title else if (e.info) |i| c.g_app_info_get_name(i) else title orelse "";
    const l = name_label orelse return;
    c.clutter_text_set_text(@ptrCast(@alignCast(l)), text);
    const k = card orelse return;
    const lw = @min(ui.preferredWidth(l), c.clutter_actor_get_width(k) - 2 * padding);
    c.clutter_actor_set_width(l, lw);
    c.clutter_actor_set_x(l, (c.clutter_actor_get_width(k) - lw) / 2);
}

fn move(delta: isize) void {
    if (n_entries == 0) return;
    const n: isize = @intCast(n_entries);
    selected = @intCast(@mod(@as(isize, @intCast(selected)) + delta, n));
    updateSelection(true);
}

fn altHeld() bool {
    const s = stage orelse return false;
    const backend = c.clutter_context_get_backend(c.clutter_actor_get_context(s));
    const keymap = c.clutter_seat_get_keymap(c.clutter_backend_get_default_seat(backend));
    var depressed: c.xkb_mod_mask_t = 0;
    var latched: c.xkb_mod_mask_t = 0;
    var locked: c.xkb_mod_mask_t = 0;
    c.clutter_keymap_get_modifier_state(keymap, &depressed, &latched, &locked);
    return depressed & alt_mask != 0;
}

fn onKeyPress(_: ?*c.ClutterActor, event: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    // The same Tab may already have reached us as a key binding.
    if (c.clutter_event_get_time(event) == last_event_time) return 1;
    const shift = c.clutter_event_get_state(event) & c.CLUTTER_SHIFT_MASK != 0;
    switch (c.clutter_event_get_key_symbol(event)) {
        c.CLUTTER_KEY_Escape => finish(false),
        c.CLUTTER_KEY_Return, c.CLUTTER_KEY_KP_Enter => finish(true),
        c.CLUTTER_KEY_Tab => move(if (shift) -1 else 1),
        c.CLUTTER_KEY_ISO_Left_Tab, c.CLUTTER_KEY_Left => move(-1),
        c.CLUTTER_KEY_Right => move(1),
        else => {},
    }
    return 1;
}

fn onKeyRelease(_: ?*c.ClutterActor, event: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    switch (c.clutter_event_get_key_symbol(event)) {
        c.CLUTTER_KEY_Alt_L, c.CLUTTER_KEY_Alt_R, c.CLUTTER_KEY_Meta_L, c.CLUTTER_KEY_Meta_R => {
            if (!sticky) finish(true);
        },
        else => {},
    }
    return 1;
}

fn finish(activate: bool) void {
    if (grab) |g| {
        c.clutter_grab_dismiss(g);
        c.g_object_unref(g);
        grab = null;
    }
    if (activate and n_entries > 0) {
        if (display) |d| c.meta_window_activate(entries[selected].window, c.meta_display_get_current_time_roundtrip(d));
    }
    if (card) |k| c.clutter_actor_destroy(k);
    card = null;
    marker = null;
    name_label = null;
    sticky = false;
    clear();
}
