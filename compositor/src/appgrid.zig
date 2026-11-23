//! The app grid in the overview: every app (Show Apps), or the apps matching
//! a search, best first. Matching is scored by cali-shell (Rust).

const std = @import("std");
const plugin = @import("plugin.zig");
const dock = @import("dock.zig");
const overview = @import("overview.zig");
const ui = @import("ui.zig");
const c = plugin.c;
const config = @import("config.zig");

const max_results = 256;
const cell_w: f32 = 132;
const cell_h: f32 = 128;
const icon_size: f32 = 64;
const hover_color: u32 = 0xffffff1f;

const Result = struct { info: *c.GAppInfo, score: i32 };

var display: ?*c.MetaDisplay = null;
var grid: ?*c.ClutterActor = null;
var grid_parent: ?*c.ClutterActor = null;
var grid_area: c.CaliRect = undefined;
/// The open folder ("Utilities", "System"), if any.
var open_folder: ?[*:0]const u8 = null;
var results: [max_results]Result = undefined;
var n_results: usize = 0;

/// Shows the grid inside `parent` over `area`. With a `query`, only matching
/// apps, best first, and the first one highlighted (Enter opens it).
pub fn show(d: ?*c.MetaDisplay, parent: ?*c.ClutterActor, area: c.CaliRect, query: ?[*:0]const u8) void {
    display = d;
    hide();
    grid_parent = parent;
    grid_area = area;
    if (query != null) open_folder = null;
    collect(query);
    if (query == null and config.app_folders) groupIntoFolders() else n_folders = 0;

    const g = c.clutter_actor_new();
    c.clutter_actor_set_position(g, area.x, area.y);
    c.clutter_actor_set_size(g, area.width, area.height);
    c.clutter_actor_add_child(parent, g);
    grid = g;

    const cols: usize = @max(1, @as(usize, @intFromFloat(area.width / cell_w)));
    const rows: usize = @max(1, @as(usize, @intFromFloat(area.height / cell_h)));
    const shown = @min(n_results, cols * rows);
    const total = @min(n_folders + shown, cols * rows);
    const used_cols = @min(cols, @max(total, 1));
    const left = (area.width - @as(f32, @floatFromInt(used_cols)) * cell_w) / 2;

    if (shown == 0 and query != null) {
        const none = ui.label("No results", config.font(.bold, 3));
        c.clutter_actor_set_opacity(none, 180);
        ui.center(none, g, c.CLUTTER_ALIGN_X_AXIS);
        c.clutter_actor_set_y(none, 40);
        c.clutter_actor_add_child(g, none);
    }

    if (open_folder) |name| {
        const back = ui.iconButton("go-previous-symbolic", 32, &onFolderBack, null);
        c.clutter_actor_set_position(back, left, 0);
        c.clutter_actor_add_child(g, back);
        const title = ui.label(name, config.font(.bold, 3));
        c.clutter_actor_set_position(title, left + 44, (32 - ui.preferredHeight(title)) / 2);
        c.clutter_actor_add_child(g, title);
    }
    const top: f32 = if (open_folder != null) 48 else 0;
    var slot: usize = 0;
    for (folders[0..n_folders]) |*f| {
        const cell = makeFolderCell(f);
        c.clutter_actor_set_position(cell, left + @as(f32, @floatFromInt(slot % cols)) * cell_w, top + @as(f32, @floatFromInt(slot / cols)) * cell_h);
        c.clutter_actor_add_child(g, cell);
        slot += 1;
    }
    for (results[0..shown], 0..) |r, i| {
        if (slot >= cols * rows) break;
        defer slot += 1;
        const cell = makeCell(r.info, query != null and i == 0, i);
        c.clutter_actor_set_position(cell, left + @as(f32, @floatFromInt(slot % cols)) * cell_w, top + @as(f32, @floatFromInt(slot / cols)) * cell_h);
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
    n_folders = 0;
}

/// Leaves an open folder. Returns false if none was open.
pub fn closeFolder() bool {
    if (open_folder == null) return false;
    open_folder = null;
    show(display, grid_parent, grid_area, null);
    return true;
}

pub fn reset() void {
    open_folder = null;
}

// ---- Folders --------------------------------------------------------------------------------

const Folder = struct { name: [*:0]const u8, icons: [4]?*c.GAppInfo, count: usize };
var folders: [4]Folder = undefined;
var n_folders: usize = 0;

fn folderOf(info: *c.GAppInfo) ?[*:0]const u8 {
    const categories = c.g_desktop_app_info_get_categories(@ptrCast(@alignCast(info)));
    return c.cali_shell_app_folder(categories);
}

/// Top level: apps that belong in a folder are replaced by the folder.
/// Inside a folder: only its apps.
fn groupIntoFolders() void {
    n_folders = 0;
    var kept: usize = 0;
    for (results[0..n_results]) |r| {
        const folder = folderOf(r.info);
        if (open_folder) |want| {
            if (folder != null and std.mem.eql(u8, std.mem.span(folder.?), std.mem.span(want))) {
                results[kept] = r;
                kept += 1;
            } else c.g_object_unref(r.info);
            continue;
        }
        const name = folder orelse {
            results[kept] = r;
            kept += 1;
            continue;
        };
        var f: ?*Folder = null;
        for (folders[0..n_folders]) |*existing| {
            if (std.mem.eql(u8, std.mem.span(existing.name), std.mem.span(name))) f = existing;
        }
        if (f == null and n_folders < folders.len) {
            folders[n_folders] = .{ .name = name, .icons = .{ null, null, null, null }, .count = 0 };
            f = &folders[n_folders];
            n_folders += 1;
        }
        if (f) |folder_ptr| {
            if (folder_ptr.count < 4) folder_ptr.icons[folder_ptr.count] = r.info else c.g_object_unref(r.info);
            folder_ptr.count += 1;
        } else c.g_object_unref(r.info);
    }
    n_results = kept;
}

fn makeFolderCell(f: *Folder) *c.ClutterActor {
    const cell = c.clutter_actor_new();
    c.clutter_actor_set_size(cell, cell_w, cell_h);
    c.clutter_actor_set_reactive(cell, 1);
    const tile = ui.roundedRect(icon_size, icon_size, 16, 0xffffff26);
    c.clutter_actor_set_position(tile, (cell_w - icon_size) / 2, 14);
    const mini: f32 = 24;
    for (f.icons, 0..) |maybe, i| {
        const info = maybe orelse continue;
        const icon = appIconActor(info, mini);
        c.clutter_actor_set_position(icon, 6 + @as(f32, @floatFromInt(i % 2)) * (mini + 4), 6 + @as(f32, @floatFromInt(i / 2)) * (mini + 4));
        c.clutter_actor_add_child(tile, icon);
        c.g_object_unref(info);
    }
    c.clutter_actor_add_child(cell, tile);
    const label = ui.label(f.name, config.font(.regular, -1));
    c.clutter_actor_set_position(label, (cell_w - ui.preferredWidth(label)) / 2, 14 + icon_size + 10);
    c.clutter_actor_add_child(cell, label);
    plugin.connect(cell, "button-release-event", &onFolderClicked, @constCast(@ptrCast(f.name)));
    return cell;
}

fn onFolderClicked(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, name: c.gpointer) callconv(.C) c.gboolean {
    open_folder = @ptrCast(name);
    show(display, grid_parent, grid_area, null);
    return 1;
}

fn onFolderBack(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    _ = closeFolder();
    return 1;
}

fn appIconActor(info: *c.GAppInfo, size: f32) *c.ClutterActor {
    var name: [*:0]const u8 = "application-x-executable";
    var owned: ?[*:0]u8 = null;
    defer if (owned) |o| c.g_free(o);
    if (c.g_app_info_get_icon(info)) |gicon| {
        if (c.g_icon_to_string(gicon)) |s| {
            owned = s;
            name = dock.iconName(std.mem.span(s));
        }
    }
    return ui.icon(name, size, false, 0);
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

    const label = ui.label(c.g_app_info_get_name(info), config.font(.regular, -1));
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

fn onCellClicked(_: ?*c.ClutterActor, event: ?*c.ClutterEvent, data: c.gpointer) callconv(.C) c.gboolean {
    const index = @intFromPtr(data) - 1;
    if (index < n_results and ui.isSecondary(event)) {
        const pos = ui.eventPosition(event);
        dock.showAppMenu(results[index].info, pos[0], pos[1]);
        return 1;
    }
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
