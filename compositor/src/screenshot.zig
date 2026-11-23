//! Screenshots: Print saves the screen, Alt+Print the focused window, to
//! Pictures/Screenshots, with a flash and a notification. Also serves
//! org.gnome.Shell.Screenshot so the screenshot portal (and apps using it)
//! work under Cali.

const std = @import("std");
const plugin = @import("plugin.zig");
const ui = @import("ui.zig");
const notifications = @import("notifications.zig");
const c = plugin.c;

var display: ?*c.MetaDisplay = null;
var stage: ?*c.ClutterActor = null;
var action_screen: c_uint = 0;
var action_window: c_uint = 0;

const introspection =
    \\<node>
    \\  <interface name="org.gnome.Shell.Screenshot">
    \\    <method name="Screenshot">
    \\      <arg type="b" direction="in" name="include_cursor"/>
    \\      <arg type="b" direction="in" name="flash"/>
    \\      <arg type="s" direction="in" name="filename"/>
    \\      <arg type="b" direction="out" name="success"/>
    \\      <arg type="s" direction="out" name="filename_used"/>
    \\    </method>
    \\    <method name="ScreenshotWindow">
    \\      <arg type="b" direction="in" name="include_frame"/>
    \\      <arg type="b" direction="in" name="include_cursor"/>
    \\      <arg type="b" direction="in" name="flash"/>
    \\      <arg type="s" direction="in" name="filename"/>
    \\      <arg type="b" direction="out" name="success"/>
    \\      <arg type="s" direction="out" name="filename_used"/>
    \\    </method>
    \\    <method name="ScreenshotArea">
    \\      <arg type="i" direction="in" name="x"/>
    \\      <arg type="i" direction="in" name="y"/>
    \\      <arg type="i" direction="in" name="width"/>
    \\      <arg type="i" direction="in" name="height"/>
    \\      <arg type="b" direction="in" name="flash"/>
    \\      <arg type="s" direction="in" name="filename"/>
    \\      <arg type="b" direction="out" name="success"/>
    \\      <arg type="s" direction="out" name="filename_used"/>
    \\    </method>
    \\  </interface>
    \\</node>
;

pub fn init(d: ?*c.MetaDisplay, s: ?*c.ClutterActor) void {
    display = d;
    stage = s;
    @import("keys.zig").bind(d, "key-screenshot", "Print", &action_screen);
    @import("keys.zig").bind(d, "key-screenshot-window", "<Alt>Print", &action_window);
    plugin.connect(d, "accelerator-activated", &onAccelerator, null);

    _ = c.g_bus_own_name(@intCast(c.G_BUS_TYPE_SESSION), "org.gnome.Shell.Screenshot", @intCast(c.G_BUS_NAME_OWNER_FLAGS_REPLACE), &onBusAcquired, null, null, null, null);

    // CALI_DEBUG_SCREENSHOT=<seconds> takes one, for testing.
    if (std.posix.getenv("CALI_DEBUG_SCREENSHOT")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugShot, null);
    }
}

fn debugShot(_: c.gpointer) callconv(.C) c.gboolean {
    var buf: [1024]u8 = undefined;
    if (save(screenRect(), true, null, &buf)) |path| std.log.debug("screenshot: saved {s}", .{path});
    return 0;
}

fn screenRect() c.MtkRectangle {
    var w: f32 = 0;
    var h: f32 = 0;
    c.clutter_actor_get_size(stage, &w, &h);
    return .{ .x = 0, .y = 0, .width = @intFromFloat(w), .height = @intFromFloat(h) };
}

fn focusedWindowRect() ?c.MtkRectangle {
    const d = display orelse return null;
    const window = c.meta_display_get_focus_window(d) orelse return null;
    var rect: c.MtkRectangle = undefined;
    c.meta_window_get_frame_rect(window, &rect);
    return rect;
}

/// Captures `rect` of the screen to `filename` (or a new file in
/// Pictures/Screenshots). Returns the path used, written into `out`.
fn save(rect: c.MtkRectangle, flash: bool, filename: ?[]const u8, out: []u8) ?[:0]const u8 {
    const s = stage orelse return null;
    if (rect.width <= 0 or rect.height <= 0) return null;

    const path: [:0]const u8 = if (filename) |f| (std.fmt.bufPrintZ(out, "{s}", .{f}) catch return null) else blk: {
        const n = c.cali_shell_screenshot_path(out.ptr, out.len);
        if (n == 0) return null;
        break :blk out[0..n :0];
    };

    const w: usize = @intCast(rect.width);
    const h: usize = @intCast(rect.height);
    const stride = w * 4;
    const pixels = std.heap.c_allocator.alloc(u8, stride * h) catch return null;
    defer std.heap.c_allocator.free(pixels);

    var err: ?*c.GError = null;
    const color_state = c.clutter_context_get_default_color_state(c.clutter_actor_get_context(s));
    if (c.clutter_stage_paint_to_buffer(@ptrCast(@alignCast(s)), &rect, 1.0, pixels.ptr, @intCast(stride), @intCast(c.COGL_PIXEL_FORMAT_RGBA_8888_PRE), color_state, @intCast(c.CLUTTER_PAINT_FLAG_NONE), @ptrCast(&err)) == 0) {
        if (err) |e| {
            std.log.warn("screenshot failed: {s}", .{e.message});
            c.g_error_free(e);
        }
        return null;
    }
    if (!c.cali_shell_save_png(path.ptr, @intCast(w), @intCast(h), stride, pixels.ptr)) return null;
    if (flash) flashRect(rect);
    return path;
}

/// A quick white flash over what was captured, like GNOME.
fn flashRect(rect: c.MtkRectangle) void {
    const s = stage orelse return;
    const f = c.clutter_actor_new();
    c.clutter_actor_set_background_color(f, &ui.white);
    c.clutter_actor_set_position(f, @floatFromInt(rect.x), @floatFromInt(rect.y));
    c.clutter_actor_set_size(f, @floatFromInt(rect.width), @floatFromInt(rect.height));
    c.clutter_actor_set_opacity(f, 220);
    c.clutter_actor_add_child(s, f);
    ui.ease(f, 300, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(f, 0);
    c.clutter_actor_restore_easing_state(f);
    plugin.connect(f, "transitions-completed", &destroyWhenDone, null);
}

fn destroyWhenDone(actor: ?*c.ClutterActor, _: c.gpointer) callconv(.C) void {
    c.clutter_actor_destroy(actor);
}

fn onAccelerator(_: ?*c.MetaDisplay, action: c_uint, _: ?*c.ClutterInputDevice, _: c_uint, _: c.gpointer) callconv(.C) void {
    if (action == 0 or (action != action_screen and action != action_window)) return;
    const rect = if (action == action_window) focusedWindowRect() orelse screenRect() else screenRect();
    var buf: [1024]u8 = undefined;
    if (save(rect, true, null, &buf) != null) {
        notifications.addLocal("Screenshot", "camera-photo-symbolic", "Screenshot captured", "You can find it in Pictures/Screenshots");
    }
}

// ---- org.gnome.Shell.Screenshot -------------------------------------------------------

fn onBusAcquired(conn: ?*c.GDBusConnection, _: [*c]const u8, _: c.gpointer) callconv(.C) void {
    var err: ?*c.GError = null;
    const node = c.g_dbus_node_info_new_for_xml(introspection, @ptrCast(&err)) orelse return;
    const Static = struct {
        var table: c.GDBusInterfaceVTable = undefined;
    };
    Static.table = std.mem.zeroes(c.GDBusInterfaceVTable);
    Static.table.method_call = &onMethodCall;
    _ = c.g_dbus_connection_register_object(conn, "/org/gnome/Shell/Screenshot", node.*.interfaces[0], &Static.table, null, null, @ptrCast(&err));
    if (err) |e| c.g_error_free(e);
}

fn onMethodCall(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, method: [*c]const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, _: c.gpointer) callconv(.C) void {
    const name = std.mem.span(method);
    var flash: c.gboolean = 0;
    var filename: [*c]const u8 = null;
    var rect = screenRect();
    if (std.mem.eql(u8, name, "Screenshot")) {
        var cursor: c.gboolean = 0;
        c.g_variant_get(params, "(bb&s)", &cursor, &flash, &filename);
    } else if (std.mem.eql(u8, name, "ScreenshotWindow")) {
        var frame: c.gboolean = 0;
        var cursor: c.gboolean = 0;
        c.g_variant_get(params, "(bbb&s)", &frame, &cursor, &flash, &filename);
        rect = focusedWindowRect() orelse rect;
    } else if (std.mem.eql(u8, name, "ScreenshotArea")) {
        c.g_variant_get(params, "(iiiib&s)", &rect.x, &rect.y, &rect.width, &rect.height, &flash, &filename);
    }
    const given = std.mem.span(filename);
    var buf: [1024]u8 = undefined;
    // Only absolute paths are honored; anything else goes to Pictures/Screenshots.
    const target: ?[]const u8 = if (given.len > 0 and given[0] == '/') given else null;
    const used = save(rect, flash != 0, target, &buf);
    c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(bs)", @as(c.gboolean, @intFromBool(used != null)), if (used) |u| u.ptr else ""));
}
