//! Accessibility: the AT-SPI bridge (screen readers see the shell's buttons
//! and menus), Orca on and off with the screen-reader setting or
//! Super+Alt+S, and keyboard ways into the top bar: Super+V opens the date
//! menu, Super+S quick settings (Tab, arrows and Enter work inside).

const std = @import("std");
const plugin = @import("plugin.zig");
const config = @import("config.zig");
const settings = @import("settings.zig");
const c = plugin.c;

var display: ?*c.MetaDisplay = null;
var action_reader: c_uint = 0;
var action_calendar: c_uint = 0;
var action_quick: c_uint = 0;
var orca_pid: c.GPid = 0;

pub fn init(d: ?*c.MetaDisplay) void {
    display = d;
    // Like GNOME Shell: always expose the shell over AT-SPI, so a screen
    // reader started later can read it.
    if (c.atk_bridge_adaptor_init(null, null) != 0) std.log.warn("a11y: AT-SPI bridge unavailable", .{});
    const none: c_uint = @intCast(c.META_KEY_BINDING_NONE);
    action_reader = c.meta_display_grab_accelerator(d, "<Super><Alt>s", none);
    action_calendar = c.meta_display_grab_accelerator(d, "<Super>v", none);
    action_quick = c.meta_display_grab_accelerator(d, "<Super>s", none);
    plugin.connect(d, "accelerator-activated", &onAccelerator, null);
}

fn onAccelerator(_: ?*c.MetaDisplay, action: c_uint, _: ?*c.ClutterInputDevice, _: c_uint, _: c.gpointer) callconv(.C) void {
    if (action == 0) return;
    if (action == action_reader) {
        settings.set("screen-reader", c.g_variant_new_boolean(@intFromBool(!config.screen_reader)));
    } else if (action == action_calendar) {
        @import("calendar.zig").toggle();
    } else if (action == action_quick) {
        @import("statusmenu.zig").toggle();
    }
}

/// Settings changed: start or stop Orca to match.
pub fn update() void {
    if (config.screen_reader and orca_pid == 0) {
        var argv = [_:null]?[*:0]u8{ @constCast("orca"), @constCast("--replace"), null };
        var err: ?*c.GError = null;
        const flags: c.GSpawnFlags = @intCast(c.G_SPAWN_SEARCH_PATH | c.G_SPAWN_DO_NOT_REAP_CHILD);
        if (c.g_spawn_async(null, @ptrCast(&argv), null, flags, null, null, &orca_pid, @ptrCast(&err)) == 0) {
            if (err) |e| {
                std.log.warn("a11y: could not start Orca: {s}", .{e.message});
                c.g_error_free(e);
            }
            orca_pid = 0;
            return;
        }
        _ = c.g_child_watch_add(orca_pid, &onOrcaExit, null);
        std.log.info("a11y: screen reader on", .{});
    } else if (!config.screen_reader and orca_pid != 0) {
        _ = std.posix.kill(orca_pid, std.posix.SIG.TERM) catch {};
        std.log.info("a11y: screen reader off", .{});
    }
}

fn onOrcaExit(pid: c.GPid, _: c_int, _: c.gpointer) callconv(.C) void {
    c.g_spawn_close_pid(pid);
    if (pid == orca_pid) orca_pid = 0;
}
