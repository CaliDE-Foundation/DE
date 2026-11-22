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

fn apply(key: [:0]const u8, value: ?*c.GVariant) void {
    const eql = std.mem.eql;
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
    }
    std.log.debug("settings: {s} applied", .{key});
}
