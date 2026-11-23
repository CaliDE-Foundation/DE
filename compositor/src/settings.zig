//! Cali's settings, kept by cali-settingsd (Go) and applied here live.

const std = @import("std");
const plugin = @import("plugin.zig");
const bus = @import("bus.zig");
const ui = @import("ui.zig");
const overview = @import("overview.zig");
const c = plugin.c;

const dest = "org.calide.SettingsDaemon";
const path = "/org/calide/Settings";
const iface = "org.calide.Settings";

pub var dark_style = true;
var clock_weekday = false;
var clock_seconds = false;
var idle_minutes: f64 = 5;
var lock_on_idle = true;

pub fn init() void {
    bus.subscribe(dest, iface, "Changed", &onChanged);
    bus.watch(dest, &onAppeared);
    bus.spawnSibling("cali-settingsd");
}

/// Changes a setting (e.g. from quick settings). `value` is consumed if floating.
pub fn set(key: [*:0]const u8, value: ?*c.GVariant) void {
    bus.call(dest, path, iface, "Set", c.g_variant_new("(sv)", key, value), null, null);
}

fn onAppeared(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: c.gpointer) callconv(.C) void {
    bus.call(dest, path, iface, "GetAll", null, &onGetAll, null);
}

fn onGetAll(_: ?*c.GObject, result: ?*c.GAsyncResult, _: c.gpointer) callconv(.C) void {
    const reply = bus.finish(result) orelse return;
    defer c.g_variant_unref(reply);
    bus.forEachEntry(reply, &apply);
}

fn onChanged(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, params: ?*c.GVariant, _: c.gpointer) callconv(.C) void {
    var key: [*c]const u8 = null;
    var value: ?*c.GVariant = null;
    c.g_variant_get(params, "(&sv)", &key, &value);
    defer c.g_variant_unref(value);
    apply(std.mem.span(key), value);
}

fn is(value: ?*c.GVariant, type_string: [*:0]const u8) bool {
    return c.g_variant_is_of_type(value, @ptrCast(type_string)) != 0;
}

const cfg = @import("config.zig");

const NumberSetting = struct { name: []const u8, ptr: *f32 };
const number_settings = [_]NumberSetting{
    .{ .name = "corner-radius", .ptr = &cfg.corner_radius },
    .{ .name = "shell-font-size", .ptr = &cfg.font_size },
    .{ .name = "panel-height", .ptr = &cfg.panel_height },
    .{ .name = "panel-opacity", .ptr = &cfg.panel_opacity },
    .{ .name = "overview-dim", .ptr = &cfg.overview_dim },
    .{ .name = "overview-window-gap", .ptr = &cfg.overview_gap },
    .{ .name = "dock-icon-size", .ptr = &cfg.dock_icon_size },
    .{ .name = "wobbly-strength", .ptr = &cfg.wobbly_strength },
    .{ .name = "wobbly-friction", .ptr = &cfg.wobbly_friction },
    .{ .name = "tiling-gap", .ptr = &cfg.tiling_gap },
    .{ .name = "tiling-outer-gap", .ptr = &cfg.tiling_outer_gap },
    .{ .name = "tiling-split-ratio", .ptr = &cfg.tiling_split },
    .{ .name = "tiling-column-width", .ptr = &cfg.tiling_column },
};

const BoolSetting = struct { name: []const u8, ptr: *bool };
const bool_settings = [_]BoolSetting{
    .{ .name = "show-workspace-dots", .ptr = &cfg.show_workspace_dots },
    .{ .name = "show-battery-percentage", .ptr = &cfg.show_battery_percentage },
    .{ .name = "show-keyboard-indicator", .ptr = &cfg.show_keyboard_indicator },
    .{ .name = "overview-search", .ptr = &cfg.overview_search },
    .{ .name = "app-folders", .ptr = &cfg.app_folders },
    .{ .name = "dock-running-dots", .ptr = &cfg.dock_running_dots },
    .{ .name = "media-controls", .ptr = &cfg.media_controls },
    .{ .name = "wobbly-windows", .ptr = &cfg.wobbly },
    .{ .name = "dynamic-workspaces", .ptr = &cfg.dynamic_workspaces },
    .{ .name = "alt-tab-current-workspace", .ptr = &cfg.alt_tab_current_workspace },
};

var clock_date = true;
var clock_24h = true;

/// The look-and-behavior settings kept in config.zig. Returns true if
/// `key` was one of them.
fn applyConfig(key: []const u8, value: ?*c.GVariant) bool {
    const eql = std.mem.eql;
    if (is(value, "d")) {
        for (number_settings) |setting| {
            if (eql(u8, key, setting.name)) {
                setting.ptr.* = @floatCast(c.g_variant_get_double(value));
                return true;
            }
        }
    }
    if (is(value, "b")) {
        const on = c.g_variant_get_boolean(value) != 0;
        for (bool_settings) |setting| {
            if (eql(u8, key, setting.name)) {
                setting.ptr.* = on;
                return true;
            }
        }
        if (eql(u8, key, "clock-show-date")) clock_date = on else if (eql(u8, key, "clock-24h")) clock_24h = on else return false;
        c.cali_shell_set_clock_date_options(clock_date, clock_24h);
        return true;
    }
    if (is(value, "s")) {
        const text = std.mem.span(c.g_variant_get_string(value, null));
        if (eql(u8, key, "shell-font")) {
            cfg.setFont(text);
        } else if (eql(u8, key, "clock-position")) {
            cfg.clock_position = cfg.parseEnum(cfg.ClockPosition, text, .center);
        } else if (eql(u8, key, "open-animation")) {
            cfg.open_animation = cfg.parseEnum(cfg.OpenAnimation, text, .scale);
        } else if (eql(u8, key, "close-animation")) {
            cfg.close_animation = cfg.parseEnum(cfg.CloseAnimation, text, .scale);
        } else if (eql(u8, key, "minimize-animation")) {
            cfg.minimize_animation = cfg.parseEnum(cfg.MinimizeAnimation, text, .dock);
        } else if (eql(u8, key, "tiling-mode")) {
            cfg.tiling_mode = cfg.parseEnum(cfg.TilingMode, text, .off);
        } else if (eql(u8, key, "tiling-new-windows")) {
            cfg.tiling_new_tiled = !eql(u8, text, "floating");
        } else if (eql(u8, key, "alt-tab-mode")) {
            cfg.alt_tab_windows = eql(u8, text, "windows");
        } else if (eql(u8, key, "notification-position")) {
            cfg.notifications_top_right = eql(u8, text, "top-right");
        } else if (eql(u8, key, "wallpaper-style")) {
            plugin.setWallpaperStyle(text);
        } else return false;
        return true;
    }
    return false;
}

fn apply(key: [:0]const u8, value: ?*c.GVariant) void {
    const eql = std.mem.eql;
    if (applyConfig(key, value)) {
        plugin.restyle();
        std.log.debug("settings: {s} applied", .{key});
        return;
    }
    if (eql(u8, key, "accent-color") and is(value, "s")) {
        ui.accent = c.cali_shell_accent_rgba(c.g_variant_get_string(value, null));
    } else if (eql(u8, key, "animation-speed") and is(value, "d")) {
        ui.speed = @floatCast(c.g_variant_get_double(value));
    } else if (eql(u8, key, "hot-corner") and is(value, "b")) {
        overview.hot_corner_enabled = c.g_variant_get_boolean(value) != 0;
    } else if (eql(u8, key, "dark-style") and is(value, "b")) {
        dark_style = c.g_variant_get_boolean(value) != 0;
        @import("statusmenu.zig").refresh();
    } else if (eql(u8, key, "clock-show-weekday") and is(value, "b")) {
        clock_weekday = c.g_variant_get_boolean(value) != 0;
        c.cali_shell_set_clock_options(clock_weekday, clock_seconds);
        plugin.refreshClock();
    } else if (eql(u8, key, "clock-show-seconds") and is(value, "b")) {
        clock_seconds = c.g_variant_get_boolean(value) != 0;
        c.cali_shell_set_clock_options(clock_weekday, clock_seconds);
        plugin.refreshClock();
    } else if (eql(u8, key, "do-not-disturb") and is(value, "b")) {
        @import("notifications.zig").do_not_disturb = c.g_variant_get_boolean(value) != 0;
        @import("calendar.zig").refresh();
    } else if (eql(u8, key, "idle-delay") and is(value, "d")) {
        idle_minutes = c.g_variant_get_double(value);
        @import("lock.zig").setIdle(idle_minutes, lock_on_idle);
    } else if (eql(u8, key, "lock-on-idle") and is(value, "b")) {
        lock_on_idle = c.g_variant_get_boolean(value) != 0;
        @import("lock.zig").setIdle(idle_minutes, lock_on_idle);
    } else if (eql(u8, key, "wallpaper") and is(value, "s")) {
        plugin.setWallpaper(c.g_variant_get_string(value, null));
    } else if (eql(u8, key, "keyboard-layouts") and is(value, "as")) {
        var n: usize = 0;
        const items = c.g_variant_get_strv(value, &n);
        defer c.g_free(@ptrCast(items));
        var names: [8][*:0]const u8 = undefined;
        const count = @min(n, names.len);
        for (0..count) |i| names[i] = items[i];
        @import("keyboard.zig").setLayouts(names[0..count]);
    } else if (eql(u8, key, "dock-favorites") and is(value, "as")) {
        var n: usize = 0;
        const items = c.g_variant_get_strv(value, &n);
        defer c.g_free(@ptrCast(items));
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        for (0..n) |i| {
            const id = std.mem.span(items[i]);
            if (len + id.len + 2 > buf.len) break;
            if (len > 0) {
                buf[len] = ',';
                len += 1;
            }
            @memcpy(buf[len..][0..id.len], id);
            len += id.len;
        }
        buf[len] = 0;
        c.cali_shell_set_dock_favorites(@ptrCast(&buf));
        @import("dock.zig").rebuild();
    }
    std.log.debug("settings: {s} applied", .{key});
}
