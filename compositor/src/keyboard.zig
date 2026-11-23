//! Keyboard layouts from the keyboard-layouts setting ("us", "de",
//! "us+dvorak", ...). Super+Space switches; the top bar shows the current
//! one when there is more than one.

const std = @import("std");
const plugin = @import("plugin.zig");
const c = plugin.c;
const config = @import("config.zig");

const max_layouts = 8;

var display: ?*c.MetaDisplay = null;
var layouts: [max_layouts][32]u8 = undefined;
var n_layouts: usize = 0;
var current: usize = 0;
var description: ?*c.MetaKeymapDescription = null;
var action_next: c_uint = 0;

pub fn init(d: ?*c.MetaDisplay) void {
    display = d;
    action_next = c.meta_display_grab_accelerator(d, "<Super>space", @intCast(c.META_KEY_BINDING_NONE));
    plugin.connect(d, "accelerator-activated", &onAccelerator, null);
}

/// Short name for the top bar ("en"), or null with a single layout.
pub fn indicator(buf: []u8) ?[*:0]const u8 {
    if (n_layouts < 2 or !@import("config.zig").show_keyboard_indicator) return null;
    if (c.cali_shell_layout_short_name(@ptrCast(&layouts[current]), buf.ptr, buf.len) == 0) return null;
    return @ptrCast(buf.ptr);
}

/// Applies a new layout list (from settings).
pub fn setLayouts(names: []const [*:0]const u8) void {
    n_layouts = 0;
    for (names) |name| {
        if (n_layouts == max_layouts) break;
        const span = std.mem.span(name);
        if (span.len == 0 or span.len >= layouts[0].len) continue;
        @memcpy(layouts[n_layouts][0..span.len], span);
        layouts[n_layouts][span.len] = 0;
        n_layouts += 1;
    }
    if (n_layouts == 0) {
        @memcpy(layouts[0][0..3], "us\x00");
        n_layouts = 1;
    }
    current = 0;

    // xkb wants "us,de" and variants "dvorak," side by side.
    var layout_buf: [512]u8 = undefined;
    var variant_buf: [512]u8 = undefined;
    var l: usize = 0;
    var v: usize = 0;
    for (layouts[0..n_layouts], 0..) |*entry, i| {
        const span = std.mem.sliceTo(entry, 0);
        var parts = std.mem.splitScalar(u8, span, '+');
        const base = parts.next() orelse "";
        const variant = parts.next() orelse "";
        if (i > 0) {
            layout_buf[l] = ',';
            variant_buf[v] = ',';
            l += 1;
            v += 1;
        }
        @memcpy(layout_buf[l..][0..base.len], base);
        l += base.len;
        @memcpy(variant_buf[v..][0..variant.len], variant);
        v += variant.len;
    }
    layout_buf[l] = 0;
    variant_buf[v] = 0;

    if (description) |old| c.meta_keymap_description_unref(old);
    description = c.meta_keymap_description_new_from_rules("", @ptrCast(&layout_buf), @ptrCast(&variant_buf), "", null, null);
    apply();
}

fn apply() void {
    const d = display orelse return;
    const desc = description orelse return;
    const backend = c.meta_context_get_backend(c.meta_display_get_context(d));
    c.meta_backend_set_keymap_async(backend, desc, @intCast(current), null, null, null);
    @import("statusmenu.zig").refresh();
    std.log.debug("keyboard: layout {d} of {d}", .{ current + 1, n_layouts });
}

/// Moves to the next layout.
pub fn next() void {
    if (n_layouts < 2) return;
    current = (current + 1) % n_layouts;
    apply();
}

fn onAccelerator(_: ?*c.MetaDisplay, action: c_uint, _: ?*c.ClutterInputDevice, _: c_uint, _: c.gpointer) callconv(.C) void {
    if (action != 0 and action == action_next) next();
}
