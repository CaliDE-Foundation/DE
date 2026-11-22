//! Starts the Sookie compositor (libsookie-52). Only compiled with -Dsookie=true.
//!
//! The few functions we need are declared by hand instead of @cImport-ing
//! <meta/meta-context.h>, which would pull in all of GLib and Clutter.
//! Follows the same steps as Sookie's own main() in src/core/mutter.c.

const std = @import("std");

const Context = opaque {};
const GError = extern struct {
    domain: u32,
    code: c_int,
    message: [*:0]const u8,
};

extern fn meta_create_context(name: [*:0]const u8) ?*Context;
extern fn meta_context_configure(ctx: *Context, argc: *c_int, argv: *[*][*:0]u8, err: *?*GError) c_int;
extern fn meta_context_set_plugin_gtype(ctx: *Context, gtype: usize) void;
extern fn meta_context_setup(ctx: *Context, err: *?*GError) c_int;
extern fn meta_context_start(ctx: *Context, err: *?*GError) c_int;
extern fn meta_context_notify_ready(ctx: *Context) void;
extern fn meta_context_run_main_loop(ctx: *Context, err: *?*GError) c_int;
extern fn g_object_unref(obj: *anyopaque) void;
extern fn g_error_free(err: *GError) void;

fn fail(step: []const u8, err: ?*GError) u8 {
    const msg: []const u8 = if (err) |e| std.mem.span(e.message) else "unknown error";
    std.log.err("Sookie failed to {s}: {s}", .{ step, msg });
    if (err) |e| g_error_free(e);
    return 1;
}

/// Runs Sookie until the session ends. Sookie's options (--wayland,
/// --headless, --devkit, ...) are parsed from the process arguments.
pub fn run() u8 {
    const ctx = meta_create_context("Cali") orelse {
        std.log.err("could not create the Sookie context", .{});
        return 1;
    };
    defer g_object_unref(ctx);

    var err: ?*GError = null;
    var argc: c_int = @intCast(std.os.argv.len);
    var argv: [*][*:0]u8 = std.os.argv.ptr;

    if (meta_context_configure(ctx, &argc, &argv, &err) == 0) return fail("configure", err);

    // Cali's own plugin: background, top bar and window animations.
    meta_context_set_plugin_gtype(ctx, @import("plugin.zig").getType());

    if (meta_context_setup(ctx, &err) == 0) return fail("set up", err);
    if (meta_context_start(ctx, &err) == 0) return fail("start", err);
    meta_context_notify_ready(ctx);
    if (meta_context_run_main_loop(ctx, &err) == 0) return fail("run", err);
    return 0;
}
