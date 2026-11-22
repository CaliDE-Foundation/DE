//! The app grid in the overview: every app (Show Apps), or the apps matching
//! a search, best first. Matching is scored by cali-shell (Rust).

const std = @import("std");
const plugin = @import("plugin.zig");
const dock = @import("dock.zig");
const overview = @import("overview.zig");
const ui = @import("ui.zig");
const c = plugin.c;

const max_results = 256;
const cell_w: f32 = 132;
const cell_h: f32 = 128;
const icon_size: f32 = 64;
const hover_color: u32 = 0xffffff1f;

const Result = struct { info: *c.GAppInfo, score: i32 };

var display: ?*c.MetaDisplay = null;
var grid: ?*c.ClutterActor = null;
var results: [max_results]Result = undefined;
var n_results: usize = 0;

/// Shows the grid inside `parent` over `area`. With a `query`, only matching
/// apps, best first, and the first one highlighted (Enter opens it).
pub fn show(d: ?*c.MetaDisplay, parent: ?*c.ClutterActor, area: c.CaliRect, query: ?[*:0]const u8) void {
    display = d;
    hide();
    collect(query);

    const g = c.clutter_actor_new();
    c.clutter_actor_set_position(g, area.x, area.y);
    c.clutter_actor_set_size(g, area.width, area.height);
    c.clutter_actor_add_child(parent, g);
    grid = g;

    const cols: usize = @max(1, @as(usize, @intFromFloat(area.width / cell_w)));
    const rows: usize = @max(1, @as(usize, @intFromFloat(area.height / cell_h)));
    const shown = @min(n_results, cols * rows);
    const used_cols = @min(cols, @max(shown, 1));
    const left = (area.width - @as(f32, @floatFromInt(used_cols)) * cell_w) / 2;

    if (shown == 0 and query != null) {
        const none = ui.label("No results", "Adwaita Sans Bold 14");
        c.clutter_actor_set_opacity(none, 180);
        ui.center(none, g, c.CLUTTER_ALIGN_X_AXIS);
        c.clutter_actor_set_y(none, 40);
        c.clutter_actor_add_child(g, none);
    }

    for (results[0..shown], 0..) |r, i| {
        const cell = makeCell(r.info, query != null and i == 0, i);
        c.clutter_actor_set_position(cell, left + @as(f32, @floatFromInt(i % cols)) * cell_w, @as(f32, @floatFromInt(i / cols)) * cell_h);
        c.clutter_actor_add_child(g, cell);
    }

    c.clutter_actor_set_opacity(g, 0);
    ui.ease(g, 150, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(g, 255);
    c.clutter_actor_restore_easing_state(g);
}

pub fn hide() void {
    if (grid) |g| c.clutter_actor_destroy(g);
    grid = null;
    for (results[0..n_results]) |r| c.g_object_unref(r.info);
    n_results = 0;
}

/// Opens the first (best) result. Returns false if there is none.
pub fn activateFirst() bool {
    if (n_results == 0) return false;
    ui.launch(display, results[0].info);
    return true;
}

fn makeCell(info: *c.GAppInfo, highlighted: bool, index: usize) *c.ClutterActor {
    const cell = c.clutter_actor_new();
    c.clutter_actor_set_size(cell, cell_w, cell_h);
    c.clutter_actor_set_reactive(cell, 1);

    const hover = ui.roundedRect(cell_w - 8, cell_h - 8, 18, hover_color);
    c.clutter_actor_set_position(hover, 4, 4);
    c.clutter_actor_set_opacity(hover, if (highlighted) 255 else 0);
    c.clutter_actor_add_child(cell, hover);

    var name: [*:0]const u8 = "application-x-executable";
    var owned: ?[*:0]u8 = null;
    defer if (owned) |o| c.g_free(o);
    if (c.g_app_info_get_icon(info)) |gicon| {
        if (c.g_icon_to_string(gicon)) |s| {
            owned = s;
            name = dock.iconName(std.mem.span(s));
        }
    }
    const icon = ui.icon(name, icon_size, false, 0);
    c.clutter_actor_set_position(icon, (cell_w - icon_size) / 2, 14);
    c.clutter_actor_add_child(cell, icon);

    const label = ui.label(c.g_app_info_get_name(info), "Adwaita Sans 10");
    const lw = @min(ui.preferredWidth(label), cell_w - 14);
    c.clutter_actor_set_width(label, lw);
    c.clutter_actor_set_position(label, (cell_w - lw) / 2, 14 + icon_size + 10);
    c.clutter_actor_add_child(cell, label);

    plugin.connect(cell, "button-release-event", &onCellClicked, @ptrFromInt(index + 1));
    if (!highlighted) {
        plugin.connect(cell, "enter-event", &onEnter, hover);
        plugin.connect(cell, "leave-event", &onLeave, hover);
    }
    return cell;
}

// ---- Which apps ---------------------------------------------------------------------------------

fn bestScore(query: [*:0]const u8, info: *c.GAppInfo) i32 {
    var best: i32 = -1;
    for ([_]?[*:0]const u8{ c.g_app_info_get_name(info), c.g_app_info_get_id(info), c.g_app_info_get_executable(info) }) |text| {
        if (text) |t| best = @max(best, c.cali_shell_search_score(query, t));
    }
    // Keywords count a little less than the name.
    if (c.g_desktop_app_info_get_keywords(@ptrCast(@alignCast(info)))) |keywords| {
        var i: usize = 0;
        while (keywords[i]) |k| : (i += 1) {
            const s = c.cali_shell_search_score(query, k);
            if (s >= 0) best = @max(best, s - 5);
        }
    }
    return best;
}

fn lessThan(_: void, a: Result, b: Result) bool {
    if (a.score != b.score) return a.score > b.score;
    return c.g_utf8_collate(c.g_app_info_get_name(a.info), c.g_app_info_get_name(b.info)) < 0;
}

fn collect(query: ?[*:0]const u8) void {
    const all = c.g_app_info_get_all();
    defer c.g_list_free_full(all, &c.g_object_unref);
    var node = all;
    while (node != null and n_results < max_results) : (node = node.*.next) {
        const info: *c.GAppInfo = @ptrCast(@alignCast(node.*.data orelse continue));
        if (c.g_app_info_should_show(info) == 0) continue;
        const score = if (query) |q| bestScore(q, info) else 0;
        if (score < 0) continue;
        results[n_results] = .{ .info = @ptrCast(@alignCast(c.g_object_ref(info))), .score = score };
        n_results += 1;
    }
    std.mem.sort(Result, results[0..n_results], {}, lessThan);
}

// ---- Input ----------------------------------------------------------------------------------------

fn onCellClicked(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, data: c.gpointer) callconv(.C) c.gboolean {
    const index = @intFromPtr(data) - 1;
    if (index < n_results) {
        ui.launch(display, results[index].info);
        overview.closeTo(null);
    }
    return 1;
}

fn onEnter(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, hover: c.gpointer) callconv(.C) c.gboolean {
    const h: ?*c.ClutterActor = @ptrCast(@alignCast(hover));
    ui.ease(h, 100, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(h, 255);
    c.clutter_actor_restore_easing_state(h);
    return 0;
}

fn onLeave(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, hover: c.gpointer) callconv(.C) c.gboolean {
    const h: ?*c.ClutterActor = @ptrCast(@alignCast(hover));
    ui.ease(h, 100, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(h, 0);
    c.clutter_actor_restore_easing_state(h);
    return 0;
}
