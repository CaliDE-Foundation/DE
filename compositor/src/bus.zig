//! Session D-Bus helpers for talking to Cali's Go services, and starting them.

const std = @import("std");
const c = @import("plugin.zig").c;

var connection: ?*c.GDBusConnection = null;

pub fn session() ?*c.GDBusConnection {
    if (connection == null) {
        var err: ?*c.GError = null;
        connection = c.g_bus_get_sync(@intCast(c.G_BUS_TYPE_SESSION), null, @ptrCast(&err));
        if (err) |e| {
            std.log.warn("bus: no session bus: {s}", .{e.message});
            c.g_error_free(e);
        }
    }
    return connection;
}

/// Calls a method without waiting. `callback` (may be null) gets the result;
/// read it with `finish`. `params` is consumed if floating.
pub fn call(
    dest: [*:0]const u8,
    path: [*:0]const u8,
    iface: [*:0]const u8,
    method: [*:0]const u8,
    params: ?*c.GVariant,
    callback: c.GAsyncReadyCallback,
    data: c.gpointer,
) void {
    const conn = session() orelse return;
    c.g_dbus_connection_call(conn, dest, path, iface, method, params, null, @intCast(c.G_DBUS_CALL_FLAGS_NONE), 3000, null, callback, data);
}

/// The reply of a `call`, or null on error (logged). Unref when done.
pub fn finish(result: ?*c.GAsyncResult) ?*c.GVariant {
    var err: ?*c.GError = null;
    const reply = c.g_dbus_connection_call_finish(session(), result, @ptrCast(&err));
    if (err) |e| {
        std.log.debug("bus: call failed: {s}", .{e.message});
        c.g_error_free(e);
    }
    return reply;
}

pub fn subscribe(sender: [*:0]const u8, iface: [*:0]const u8, member: [*:0]const u8, callback: c.GDBusSignalCallback) void {
    const conn = session() orelse return;
    _ = c.g_dbus_connection_signal_subscribe(conn, sender, iface, member, null, null, @intCast(c.G_DBUS_SIGNAL_FLAGS_NONE), callback, null, null);
}

/// Runs `appeared` whenever `name` gets an owner on the session bus
/// (including right away if it already has one).
pub fn watch(name: [*:0]const u8, appeared: c.GBusNameAppearedCallback) void {
    _ = c.g_bus_watch_name(@intCast(c.G_BUS_TYPE_SESSION), name, @intCast(c.G_BUS_NAME_WATCHER_FLAGS_NONE), appeared, null, null, null);
}

/// Starts a program installed next to cali-compositor (one of Cali's Go
/// services). Logs and returns if it isn't there.
pub fn spawnSibling(name: []const u8) void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fs.selfExeDirPath(&dir_buf) catch return;
    var path_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch return;
    std.fs.accessAbsolute(path, .{}) catch {
        std.log.info("{s} not found next to cali-compositor; that part of the shell stays off", .{name});
        return;
    };
    var argv = [_:null]?[*:0]u8{ path.ptr, null };
    var err: ?*c.GError = null;
    if (c.g_spawn_async(null, @ptrCast(&argv), null, @intCast(c.G_SPAWN_DEFAULT), null, null, null, @ptrCast(&err)) == 0) {
        if (err) |e| {
            std.log.warn("could not start {s}: {s}", .{ name, e.message });
            c.g_error_free(e);
        }
    }
}

/// Iterates an a{sv} dictionary (the first item of `tuple`), calling
/// `f(key, value)` for each entry.
pub fn forEachEntry(tuple: ?*c.GVariant, f: *const fn ([:0]const u8, ?*c.GVariant) void) void {
    var iter: ?*c.GVariantIter = null;
    c.g_variant_get(tuple, "(a{sv})", &iter);
    defer c.g_variant_iter_free(iter);
    var key: [*c]const u8 = null;
    var value: ?*c.GVariant = null;
    while (c.g_variant_iter_next(iter, "{&sv}", &key, &value) != 0) {
        f(std.mem.span(key), value);
        c.g_variant_unref(value);
    }
}
