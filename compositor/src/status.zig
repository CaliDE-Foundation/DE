//! System status from cali-statusd (Go): network, Bluetooth, volume,
//! battery, brightness. Also the volume and brightness keys, which change
//! them through cali-statusd and show the on-screen display.

const std = @import("std");
const plugin = @import("plugin.zig");
const bus = @import("bus.zig");
const osd = @import("osd.zig");
const c = plugin.c;

const dest = "org.calide.Status";
const path = "/org/calide/Status";
const iface = "org.calide.Status";
const volume_step = 0.05;
const brightness_step = 0.05;

/// The latest status. Levels are negative until known.
pub var current = c.CaliStatus{
    .network = 0,
    .wifi_available = false,
    .wifi_enabled = false,
    .bluetooth_available = false,
    .bluetooth_enabled = false,
    .volume = -1,
    .muted = false,
    .battery = -1,
    .charging = false,
    .brightness = -1,
};

const Key = enum { volume_up, volume_down, mute, brightness_up, brightness_down };
const accelerators = [_]struct { key: Key, accel: [*:0]const u8 }{
    .{ .key = .volume_up, .accel = "XF86AudioRaiseVolume" },
    .{ .key = .volume_down, .accel = "XF86AudioLowerVolume" },
    .{ .key = .mute, .accel = "XF86AudioMute" },
    .{ .key = .brightness_up, .accel = "XF86MonBrightnessUp" },
    .{ .key = .brightness_down, .accel = "XF86MonBrightnessDown" },
};
var actions: [accelerators.len]c_uint = .{0} ** accelerators.len;

pub fn init(display: ?*c.MetaDisplay) void {
    bus.subscribe(dest, iface, "Changed", &onChanged);
    bus.watch(dest, &onAppeared);
    bus.spawnSibling("cali-statusd");

    for (accelerators, 0..) |a, i| {
        actions[i] = c.meta_display_grab_accelerator(display, a.accel, @intCast(c.META_KEY_BINDING_NONE));
    }
    plugin.connect(display, "accelerator-activated", &onAccelerator, null);
}

fn onAppeared(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: c.gpointer) callconv(.C) void {
    bus.call(dest, path, iface, "GetAll", null, &onGetAll, null);
}

fn onGetAll(_: ?*c.GObject, result: ?*c.GAsyncResult, _: c.gpointer) callconv(.C) void {
    const reply = bus.finish(result) orelse return;
    defer c.g_variant_unref(reply);
    update(reply);
}

fn onChanged(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, params: ?*c.GVariant, _: c.gpointer) callconv(.C) void {
    update(params);
}

fn update(tuple: ?*c.GVariant) void {
    bus.forEachEntry(tuple, &apply);
    @import("statusmenu.zig").refresh();
}

fn apply(key: [:0]const u8, v: ?*c.GVariant) void {
    const eql = std.mem.eql;
    const is = struct {
        fn f(value: ?*c.GVariant, t: [*:0]const u8) bool {
            return c.g_variant_is_of_type(value, @ptrCast(t)) != 0;
        }
    }.f;
    if (is(v, "b")) {
        const b = c.g_variant_get_boolean(v) != 0;
        if (eql(u8, key, "wifi-available")) current.wifi_available = b;
        if (eql(u8, key, "wifi-enabled")) current.wifi_enabled = b;
        if (eql(u8, key, "bluetooth-available")) current.bluetooth_available = b;
        if (eql(u8, key, "bluetooth-enabled")) current.bluetooth_enabled = b;
        if (eql(u8, key, "muted")) current.muted = b;
        if (eql(u8, key, "charging")) current.charging = b;
    } else if (is(v, "d")) {
        const d: f32 = @floatCast(c.g_variant_get_double(v));
        if (eql(u8, key, "volume")) current.volume = d;
        if (eql(u8, key, "battery")) current.battery = d;
        if (eql(u8, key, "brightness")) current.brightness = d;
    } else if (is(v, "u") and eql(u8, key, "network")) {
        current.network = c.g_variant_get_uint32(v);
    }
}

// ---- Changing things -----------------------------------------------------------------------

pub fn setVolume(level: f32) void {
    current.volume = level;
    current.muted = false;
    bus.call(dest, path, iface, "SetVolume", c.g_variant_new("(d)", @as(f64, level)), null, null);
}

pub fn setWifiEnabled(on: bool) void {
    current.wifi_enabled = on;
    bus.call(dest, path, iface, "SetWifiEnabled", c.g_variant_new("(b)", @as(c.gboolean, @intFromBool(on))), null, null);
}

pub fn setBluetoothEnabled(on: bool) void {
    current.bluetooth_enabled = on;
    bus.call(dest, path, iface, "SetBluetoothEnabled", c.g_variant_new("(b)", @as(c.gboolean, @intFromBool(on))), null, null);
}

fn onAccelerator(_: ?*c.MetaDisplay, action: c_uint, _: ?*c.ClutterInputDevice, _: c_uint, _: c.gpointer) callconv(.C) void {
    for (actions, 0..) |a, i| {
        if (a == 0 or a != action) continue;
        switch (accelerators[i].key) {
            .volume_up => bus.call(dest, path, iface, "AdjustVolume", c.g_variant_new("(d)", @as(f64, volume_step)), &onVolumeReply, null),
            .volume_down => bus.call(dest, path, iface, "AdjustVolume", c.g_variant_new("(d)", @as(f64, -volume_step)), &onVolumeReply, null),
            .mute => bus.call(dest, path, iface, "ToggleMute", null, &onMuteReply, null),
            .brightness_up => bus.call(dest, path, iface, "AdjustBrightness", c.g_variant_new("(d)", @as(f64, brightness_step)), &onBrightnessReply, null),
            .brightness_down => bus.call(dest, path, iface, "AdjustBrightness", c.g_variant_new("(d)", @as(f64, -brightness_step)), &onBrightnessReply, null),
        }
    }
}

fn replyDouble(result: ?*c.GAsyncResult) ?f32 {
    const reply = bus.finish(result) orelse return null;
    defer c.g_variant_unref(reply);
    var d: f64 = 0;
    c.g_variant_get(reply, "(d)", &d);
    return @floatCast(d);
}

fn onVolumeReply(_: ?*c.GObject, result: ?*c.GAsyncResult, _: c.gpointer) callconv(.C) void {
    const level = replyDouble(result) orelse return;
    if (level < 0) return;
    current.volume = level;
    current.muted = false;
    osd.show(c.cali_shell_volume_icon(level, false), level);
}

fn onMuteReply(_: ?*c.GObject, result: ?*c.GAsyncResult, _: c.gpointer) callconv(.C) void {
    const reply = bus.finish(result) orelse return;
    defer c.g_variant_unref(reply);
    var muted: c.gboolean = 0;
    c.g_variant_get(reply, "(b)", &muted);
    current.muted = muted != 0;
    const level = @max(current.volume, 0);
    osd.show(c.cali_shell_volume_icon(level, current.muted), if (current.muted) 0 else level);
}

fn onBrightnessReply(_: ?*c.GObject, result: ?*c.GAsyncResult, _: c.gpointer) callconv(.C) void {
    const level = replyDouble(result) orelse return;
    if (level < 0) return; // no backlight (desktop monitor)
    current.brightness = level;
    osd.show("display-brightness-symbolic", level);
}
