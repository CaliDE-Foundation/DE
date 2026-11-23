//! Session environment: tells apps and D-Bus-started services (portals) that
//! this is Cali and which display to use. xdg-desktop-portal reads
//! XDG_CURRENT_DESKTOP to pick cali-portals.conf, which routes screen
//! sharing and settings (dark style) to the GNOME portal backend; that
//! backend talks to Sookie's org.gnome.Mutter.ScreenCast.

const std = @import("std");
const bus = @import("bus.zig");
const c = @import("plugin.zig").c;

pub fn init() void {
    _ = c.g_setenv("XDG_CURRENT_DESKTOP", "Cali", 1);
    _ = c.g_setenv("XDG_SESSION_DESKTOP", "cali", 1);
    _ = c.g_setenv("XDG_SESSION_TYPE", "wayland", 1);
    _ = c.g_setenv("DESKTOP_SESSION", "cali", 1);

    // Sookie set WAYLAND_DISPLAY (and DISPLAY for Xwayland) for itself.
    const names = [_][*:0]const u8{ "WAYLAND_DISPLAY", "DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "XDG_SESSION_TYPE", "DESKTOP_SESSION" };

    const dict = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{ss}")));
    defer c.g_variant_builder_unref(dict);
    const list = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "as")));
    defer c.g_variant_builder_unref(list);
    var buf: [512]u8 = undefined;
    for (names) |name| {
        const value = c.g_getenv(name) orelse continue;
        c.g_variant_builder_add(dict, "{ss}", name, value);
        const entry = std.fmt.bufPrintZ(&buf, "{s}={s}", .{ std.mem.span(name), std.mem.span(value) }) catch continue;
        c.g_variant_builder_add(list, "s", entry.ptr);
    }

    // For services D-Bus starts on demand (the portals)...
    bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "UpdateActivationEnvironment", c.g_variant_new("(a{ss})", dict), null, null);
    // ...and for systemd user services, where there is a systemd user session.
    bus.call("org.freedesktop.systemd1", "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", "SetEnvironment", c.g_variant_new("(as)", list), null, null);
}
