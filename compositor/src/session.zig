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

// ---- Login session helpers -----------------------------------------------------------

/// In a real login (not the devkit), start what gnome-session would: the
/// XDG autostart programs and a polkit agent for admin password prompts.
pub fn startHelpers() void {
    // CALI_DEBUG_AUTOSTART runs them in the devkit too.
    const login = c.g_getenv("XDG_SESSION_ID") != null or c.g_getenv("CALI_DEBUG_AUTOSTART") != null;
    if (c.g_getenv("CALI_NO_AUTOSTART") != null or !login) return;
    _ = c.g_idle_add(&runHelpers, null);
}

fn runHelpers(_: c.gpointer) callconv(.C) c.gboolean {
    startPolkitAgent();
    autostart();
    return 0;
}

// Cali has no polkit agent of its own yet; use the first one installed.
const polkit_agents = [_][*:0]const u8{
    "/usr/libexec/polkit-mate-authentication-agent-1",
    "/usr/lib/mate-polkit/polkit-mate-authentication-agent-1",
    "/usr/libexec/xfce-polkit",
    "/usr/lib/xfce-polkit/xfce-polkit",
    "/usr/bin/lxpolkit",
    "/usr/libexec/polkit-gnome-authentication-agent-1",
    "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1",
};

fn startPolkitAgent() void {
    for (polkit_agents) |agent| {
        if (c.g_file_test(agent, c.G_FILE_TEST_IS_EXECUTABLE) == 0) continue;
        var argv = [_:null]?[*:0]u8{ @constCast(agent), null };
        _ = c.g_spawn_async(null, @ptrCast(&argv), null, @intCast(c.G_SPAWN_DEFAULT), null, null, null, null);
        std.log.info("session: polkit agent {s}", .{agent});
        return;
    }
    std.log.warn("session: no polkit agent installed; admin prompts won't appear", .{});
}

/// XDG autostart: ~/.config/autostart first (it overrides files of the same
/// name), then the system directories. OnlyShowIn/NotShowIn are matched
/// against XDG_CURRENT_DESKTOP=Cali by GIO.
fn autostart() void {
    const seen = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, null);
    defer c.g_hash_table_destroy(seen);
    autostartDir(c.g_get_user_config_dir(), seen);
    const dirs = c.g_get_system_config_dirs();
    var i: usize = 0;
    while (dirs[i] != null) : (i += 1) autostartDir(dirs[i], seen);
}

fn autostartDir(base: [*c]const u8, seen: ?*c.GHashTable) void {
    const path = c.g_build_filename(base, "autostart", @as(?*anyopaque, null));
    defer c.g_free(path);
    const dir = c.g_dir_open(path, 0, null) orelse return;
    defer c.g_dir_close(dir);
    while (c.g_dir_read_name(dir)) |name| {
        if (c.g_str_has_suffix(name, ".desktop") == 0) continue;
        if (c.g_hash_table_contains(seen, name) != 0) continue;
        _ = c.g_hash_table_add(seen, c.g_strdup(name));
        const file = c.g_build_filename(path, name, @as(?*anyopaque, null));
        defer c.g_free(file);
        const info = c.g_desktop_app_info_new_from_filename(file) orelse continue;
        defer c.g_object_unref(info);
        if (c.g_desktop_app_info_get_is_hidden(info) != 0) continue;
        if (c.g_desktop_app_info_get_show_in(info, null) == 0) continue;
        if (c.g_desktop_app_info_has_key(info, "X-GNOME-Autostart-enabled") != 0 and
            c.g_desktop_app_info_get_boolean(info, "X-GNOME-Autostart-enabled") == 0) continue;
        var err: ?*c.GError = null;
        if (c.g_app_info_launch(@ptrCast(info), null, null, @ptrCast(&err)) == 0) {
            if (err) |e| {
                std.log.warn("session: autostart {s}: {s}", .{ name, e.message });
                c.g_error_free(e);
            }
        } else std.log.info("session: autostart {s}", .{name});
    }
}
