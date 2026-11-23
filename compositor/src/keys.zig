//! Shell shortcuts that the user can change (the key-* settings, edited on
//! Cali Settings' Shortcuts page). Each module grabs its shortcut through
//! here and keeps comparing "accelerator-activated" against the action id;
//! when a setting changes, the old grab is dropped and the new one made,
//! and the module's id updated in place.

const std = @import("std");
const plugin = @import("plugin.zig");
const c = plugin.c;

const Binding = struct {
    setting: []const u8,
    action: *c_uint,
    accel: [64]u8 = .{0} ** 64,
};

var display: ?*c.MetaDisplay = null;
var bindings: [16]Binding = undefined;
var count: usize = 0;

/// Grabs `default` (until settings say otherwise) and keeps `action` up to date.
pub fn bind(d: ?*c.MetaDisplay, setting: []const u8, default: []const u8, action: *c_uint) void {
    display = d;
    if (count == bindings.len) return;
    bindings[count] = .{ .setting = setting, .action = action };
    regrab(&bindings[count], default);
    count += 1;
}

fn regrab(b: *Binding, accel: []const u8) void {
    const d = display orelse return;
    if (b.action.* != 0) _ = c.meta_display_ungrab_accelerator(d, b.action.*);
    b.action.* = 0;
    const n = @min(accel.len, b.accel.len - 1);
    @memcpy(b.accel[0..n], accel[0..n]);
    b.accel[n] = 0;
    if (n == 0) return; // turned off
    b.action.* = c.meta_display_grab_accelerator(d, @ptrCast(&b.accel), @intCast(c.META_KEY_BINDING_NONE));
    if (b.action.* == 0) std.log.warn("keys: couldn't use {s} for {s} (taken?)", .{ accel, b.setting });
}

/// A key-* setting changed. Returns true if it was one of ours.
pub fn settingChanged(key: []const u8, accel: []const u8) bool {
    for (bindings[0..count]) |*b| {
        if (!std.mem.eql(u8, b.setting, key)) continue;
        if (!std.mem.eql(u8, std.mem.sliceTo(&b.accel, 0), accel)) regrab(b, accel);
        return true;
    }
    return false;
}
