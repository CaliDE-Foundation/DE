//! Notification banners. cali-notifyd (Go) speaks the freedesktop
//! notification protocol and calls us over D-Bus (org.calide.Shell) to show
//! and hide banners; clicking a banner dismisses it and tells cali-notifyd.

const std = @import("std");
const plugin = @import("plugin.zig");
const ui = @import("ui.zig");
const c = plugin.c;

const width: f32 = 380;
const padding: f32 = 14;
const icon_size: f32 = 32;
const background: u32 = 0x2e2e32f2;

const introspection =
    \\<node>
    \\  <interface name="org.calide.Shell">
    \\    <method name="ShowNotification">
    \\      <arg direction="in" type="u" name="id"/>
    \\      <arg direction="in" type="s" name="app"/>
    \\      <arg direction="in" type="s" name="icon"/>
    \\      <arg direction="in" type="s" name="summary"/>
    \\      <arg direction="in" type="s" name="body"/>
    \\    </method>
    \\    <method name="HideNotification">
    \\      <arg direction="in" type="u" name="id"/>
    \\    </method>
    \\    <signal name="NotificationDismissed">
    \\      <arg type="u" name="id"/>
    \\    </signal>
    \\  </interface>
    \\</node>
;

var stage: ?*c.ClutterActor = null;
var connection: ?*c.GDBusConnection = null;
var banner: ?*c.ClutterActor = null;
var banner_id: u32 = 0;

pub fn init(s: ?*c.ClutterActor) void {
    stage = s;
    _ = c.g_bus_own_name(
        @intCast(c.G_BUS_TYPE_SESSION),
        "org.calide.Shell",
        @intCast(c.G_BUS_NAME_OWNER_FLAGS_REPLACE),
        &onBusAcquired,
        null,
        null,
        null,
        null,
    );
    spawnDaemon();
}

/// Starts cali-notifyd from the folder cali-compositor runs from.
fn spawnDaemon() void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fs.selfExeDirPath(&dir_buf) catch return;
    var path_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/cali-notifyd", .{dir}) catch return;
    std.fs.accessAbsolute(path, .{}) catch {
        std.log.info("notifications: {s} not found, banners need another notification server", .{path});
        return;
    };
    var argv = [_:null]?[*:0]u8{ path.ptr, null };
    var err: ?*c.GError = null;
    if (c.g_spawn_async(null, @ptrCast(&argv), null, @intCast(c.G_SPAWN_DEFAULT), null, null, null, @ptrCast(&err)) == 0) {
        if (err) |e| {
            std.log.warn("notifications: could not start cali-notifyd: {s}", .{e.message});
            c.g_error_free(e);
        }
    }
}

fn onBusAcquired(conn: ?*c.GDBusConnection, _: [*c]const u8, _: c.gpointer) callconv(.C) void {
    connection = conn;
    var err: ?*c.GError = null;
    const node = c.g_dbus_node_info_new_for_xml(introspection, @ptrCast(&err)) orelse {
        if (err) |e| c.g_error_free(e);
        return;
    };
    var vtable = std.mem.zeroes(c.GDBusInterfaceVTable);
    vtable.method_call = &onMethodCall;
    const Static = struct {
        var table: c.GDBusInterfaceVTable = undefined;
    };
    Static.table = vtable;
    if (c.g_dbus_connection_register_object(conn, "/org/calide/Shell", node.*.interfaces[0], &Static.table, null, null, @ptrCast(&err)) == 0) {
        if (err) |e| {
            std.log.warn("notifications: could not register org.calide.Shell: {s}", .{e.message});
            c.g_error_free(e);
        }
    }
}

fn onMethodCall(
    _: ?*c.GDBusConnection,
    _: [*c]const u8,
    _: [*c]const u8,
    _: [*c]const u8,
    method: [*c]const u8,
    params: ?*c.GVariant,
    invocation: ?*c.GDBusMethodInvocation,
    _: c.gpointer,
) callconv(.C) void {
    const name = std.mem.span(method);
    if (std.mem.eql(u8, name, "ShowNotification")) {
        var id: u32 = 0;
        var app: [*c]const u8 = null;
        var icon: [*c]const u8 = null;
        var summary: [*c]const u8 = null;
        var body: [*c]const u8 = null;
        c.g_variant_get(params, "(u&s&s&s&s)", &id, &app, &icon, &summary, &body);
        show(id, std.mem.span(app), std.mem.span(icon), summary, body);
    } else if (std.mem.eql(u8, name, "HideNotification")) {
        var id: u32 = 0;
        c.g_variant_get(params, "(u)", &id);
        if (id == banner_id) hide();
    }
    c.g_dbus_method_invocation_return_value(invocation, null);
}

// ---- Banner -----------------------------------------------------------------------------------

fn bannerIcon(app: []const u8, icon: [:0]const u8) *c.ClutterActor {
    // A desktop file ID: use that app's icon.
    if (std.mem.endsWith(u8, icon, ".desktop")) {
        if (c.g_desktop_app_info_new(icon.ptr)) |info| {
            defer c.g_object_unref(info);
            if (c.g_app_info_get_icon(@ptrCast(@alignCast(info)))) |gicon| {
                if (c.g_icon_to_string(gicon)) |s| {
                    defer c.g_free(s);
                    return ui.icon(@import("dock.zig").iconName(std.mem.span(s)), icon_size, false, 0);
                }
            }
        }
    }
    _ = app;
    if (icon.len > 0) {
        const symbolic = std.mem.endsWith(u8, icon, "-symbolic");
        return ui.icon(icon.ptr, icon_size, symbolic, 0xffffff);
    }
    return ui.icon("dialog-information-symbolic", icon_size, true, 0xffffff);
}

fn show(id: u32, app: []const u8, icon: [:0]const u8, summary: [*c]const u8, body: [*c]const u8) void {
    const s = stage orelse return;
    if (banner) |old| c.clutter_actor_destroy(old);

    const text_x = padding + icon_size + 12;
    const text_w = width - text_x - padding;
    const title = ui.label(summary, "Adwaita Sans Bold 11");
    c.clutter_actor_set_width(title, @min(ui.preferredWidth(title), text_w));
    const text = ui.label(body, "Adwaita Sans 10");
    c.clutter_actor_set_width(text, @min(ui.preferredWidth(text), text_w));
    c.clutter_actor_set_opacity(text, 210);

    const title_h = ui.preferredHeight(title);
    const text_h = if (std.mem.span(body).len > 0) ui.preferredHeight(text) else 0;
    const height = @max(icon_size, title_h + 2 + text_h) + 2 * padding;

    const card = ui.roundedRect(width, height, 18, background);
    const glyph = bannerIcon(app, icon);
    c.clutter_actor_set_position(glyph, padding, (height - icon_size) / 2);
    c.clutter_actor_add_child(card, glyph);
    const block_y = (height - (title_h + 2 + text_h)) / 2;
    c.clutter_actor_set_position(title, text_x, block_y);
    c.clutter_actor_set_position(text, text_x, block_y + title_h + 2);
    c.clutter_actor_add_child(card, title);
    c.clutter_actor_add_child(card, text);

    var sw: f32 = 0;
    var sh: f32 = 0;
    c.clutter_actor_get_size(s, &sw, &sh);
    const top: f32 = @as(f32, @floatFromInt(c.cali_shell_panel_height())) + 8;
    c.clutter_actor_set_position(card, (sw - width) / 2, top);
    c.clutter_actor_set_reactive(card, 1);
    plugin.connect(card, "button-release-event", &onBannerClicked, null);
    c.clutter_actor_add_child(s, card);

    // Slide down into place.
    c.clutter_actor_set_translation(card, 0, -(height + top), 0);
    ui.ease(card, 250, c.CLUTTER_EASE_OUT_CUBIC);
    c.clutter_actor_set_translation(card, 0, 0, 0);
    c.clutter_actor_restore_easing_state(card);

    banner = card;
    banner_id = id;
}

fn hide() void {
    const card = banner orelse return;
    banner = null;
    banner_id = 0;
    ui.ease(card, 200, c.CLUTTER_EASE_IN_QUAD);
    c.clutter_actor_set_translation(card, 0, -c.clutter_actor_get_height(card) - 40, 0);
    c.clutter_actor_set_opacity(card, 0);
    c.clutter_actor_restore_easing_state(card);
    plugin.connect(card, "transitions-completed", &destroyWhenDone, null);
}

fn destroyWhenDone(actor: ?*c.ClutterActor, _: c.gpointer) callconv(.C) void {
    c.clutter_actor_destroy(actor);
}

fn onBannerClicked(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    const id = banner_id;
    hide();
    if (connection) |conn| {
        _ = c.g_dbus_connection_emit_signal(conn, null, "/org/calide/Shell", "org.calide.Shell", "NotificationDismissed", c.g_variant_new("(u)", id), null);
    }
    return 1;
}
