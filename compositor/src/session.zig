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

/// Starts cali-session.target (and with it graphical-session.target), which
/// xdg-desktop-portal requires: without it apps get no dark style, file
/// chooser or screen sharing. Sent after SetEnvironment on the same
/// connection, so services see WAYLAND_DISPLAY. cali-session stops it.
fn startSessionTarget() void {
    bus.call("org.freedesktop.systemd1", "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", "StartUnit", c.g_variant_new("(ss)", "cali-session.target", "replace"), &sessionTargetStarted, null);
}

fn sessionTargetStarted(_: ?*c.GObject, result: ?*c.GAsyncResult, _: c.gpointer) callconv(.C) void {
    if (bus.finish(result)) |reply| {
        c.g_variant_unref(reply);
        std.log.info("session: started cali-session.target", .{});
    } else std.log.warn("session: couldn't start cali-session.target; portals won't run", .{});
}

// ---- GDM registration ----------------------------------------------------------------

/// cali.desktop says X-GDM-SessionRegisters=true, like GNOME's session, so
/// GDM waits for Cali instead of guessing: once the first frame is on screen
/// we register the session and display. GDM then quits the boot splash with
/// a smooth handover. Without this, gdm-wayland-session registers after a
/// fixed 10 seconds and the splash quits mid-session; on the live ISO GDM
/// then put its login screen on VT1 over the running autologin session.
/// Under other display managers the calls just fail (logged at debug).
pub fn registerWithGdm(stage: ?*c.ClutterStage) void {
    if (c.g_getenv("XDG_SESSION_ID") == null) return; // devkit: no login session
    gdm_paint_handler = c.g_signal_connect_data(@ptrCast(stage), "after-paint", @ptrCast(&firstPaint), null, null, 0);
}

var gdm_paint_handler: c.gulong = 0;

fn firstPaint(stage: ?*c.ClutterStage, _: c.gpointer) callconv(.C) void {
    c.g_signal_handler_disconnect(@ptrCast(stage), gdm_paint_handler);
    gdm_paint_handler = 0;
    var err: ?*c.GError = null;
    const system = c.g_bus_get_sync(@intCast(c.G_BUS_TYPE_SYSTEM), null, @ptrCast(&err));
    if (err) |e| {
        std.log.debug("session: no system bus, not registering with GDM: {s}", .{e.message});
        c.g_error_free(e);
        return;
    }
    // Session first, then display; GDM handles them in order on one connection.
    for ([_][*:0]const u8{ "RegisterSession", "RegisterDisplay" }) |method| {
        c.g_dbus_connection_call(system, "org.gnome.DisplayManager", "/org/gnome/DisplayManager/Manager", "org.gnome.DisplayManager.Manager", method, null, null, @intCast(c.G_DBUS_CALL_FLAGS_NO_AUTO_START), 5000, null, &gdmRegistered, @constCast(@ptrCast(method)));
    }
    c.g_object_unref(system);
}

fn gdmRegistered(source: ?*c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.C) void {
    const method: [*:0]const u8 = @ptrCast(data);
    var err: ?*c.GError = null;
    const reply = c.g_dbus_connection_call_finish(@ptrCast(source), result, @ptrCast(&err));
    if (err) |e| {
        std.log.debug("session: GDM {s} failed (not a GDM login?): {s}", .{ method, e.message });
        c.g_error_free(e);
        return;
    }
    c.g_variant_unref(reply);
    std.log.info("session: {s} with GDM", .{method});
}

// ---- Login session helpers -----------------------------------------------------------

/// In a real login (not the devkit), start what gnome-session would: the
/// XDG autostart programs and a polkit agent for admin password prompts.
pub fn startHelpers() void {
    // CALI_DEBUG_AUTOSTART runs them in the devkit too.
    const login = c.g_getenv("XDG_SESSION_ID") != null or c.g_getenv("CALI_DEBUG_AUTOSTART") != null;
    if (c.g_getenv("CALI_NO_AUTOSTART") != null or !login) return;
    startSessionTarget();
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
