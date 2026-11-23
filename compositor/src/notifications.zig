//! Notifications. cali-notifyd (Go) speaks the freedesktop notification
//! protocol and calls us over D-Bus (org.calide.Shell). We show a banner
//! (unless Do Not Disturb is on or the screen is locked) and keep every
//! notification in a list, shown in the calendar, until it is cleared or
//! the app withdraws it. Clicking a banner dismisses it and tells cali-notifyd.

const std = @import("std");
const plugin = @import("plugin.zig");
const ui = @import("ui.zig");
const c = plugin.c;
const config = @import("config.zig");

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
    \\    <method name="RemoveNotification">
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

/// Do Not Disturb (from settings): no banners, the list still fills up.
pub var do_not_disturb = false;

// ---- The list --------------------------------------------------------------------------

pub const max_items = 50;
pub const Item = struct {
    id: u32,
    icon: [256]u8,
    summary: [256]u8,
    body: [512]u8,
    time: [16]u8,
};
pub var items: [max_items]Item = undefined;
pub var n_items: usize = 0;
var local_id: u32 = 0x8000_0000; // ids for the shell's own notifications

fn copyZ(dest: []u8, src: []const u8) void {
    const n = @min(src.len, dest.len - 1);
    @memcpy(dest[0..n], src[0..n]);
    dest[n] = 0;
}

/// Adds to the top of the list (replacing an item with the same id).
fn remember(id: u32, icon: []const u8, summary: []const u8, body: []const u8) void {
    forget(id);
    if (n_items == max_items) n_items -= 1;
    std.mem.copyBackwards(Item, items[1 .. n_items + 1], items[0..n_items]);
    var item: Item = undefined;
    item.id = id;
    copyZ(&item.icon, icon);
    copyZ(&item.summary, summary);
    copyZ(&item.body, body);
    _ = c.cali_shell_format_date(0, 0, 0, "%H:%M", @ptrCast(&item.time), item.time.len);
    items[0] = item;
    n_items += 1;
    changed();
}

fn forget(id: u32) void {
    for (items[0..n_items], 0..) |item, i| {
        if (item.id != id) continue;
        std.mem.copyForwards(Item, items[i .. n_items - 1], items[i + 1 .. n_items]);
        n_items -= 1;
        changed();
        return;
    }
}

/// Empties the list (the calendar's Clear button).
pub fn clearAll() void {
    n_items = 0;
    changed();
}

fn changed() void {
    plugin.setClockDot(n_items > 0);
    @import("calendar.zig").refresh();
}

/// A notification from the shell itself (e.g. "Screenshot captured").
pub fn addLocal(app: [*:0]const u8, icon: [*:0]const u8, summary: [*:0]const u8, body: [*:0]const u8) void {
    local_id +%= 1;
    show(local_id, std.mem.span(app), std.mem.span(icon), summary, body);
}

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
    @import("bus.zig").spawnSibling("cali-notifyd");
}

fn onBusAcquired(conn: ?*c.GDBusConnection, _: [*c]const u8, _: c.gpointer) callconv(.C) void {
    connection = conn;
    @import("panelitems.zig").register(conn);
    @import("bus.zig").spawnSibling("cali-extd");
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
    } else if (std.mem.eql(u8, name, "RemoveNotification")) {
        var id: u32 = 0;
        c.g_variant_get(params, "(u)", &id);
        forget(id);
        if (id == banner_id) hide();
    }
    c.g_dbus_method_invocation_return_value(invocation, null);
}

// ---- Banner -----------------------------------------------------------------------------------

pub fn bannerIcon(app: []const u8, icon: [:0]const u8, size: f32) *c.ClutterActor {
    // A desktop file ID: use that app's icon.
    if (std.mem.endsWith(u8, icon, ".desktop")) {
        if (c.g_desktop_app_info_new(icon.ptr)) |info| {
            defer c.g_object_unref(info);
            if (c.g_app_info_get_icon(@ptrCast(@alignCast(info)))) |gicon| {
                if (c.g_icon_to_string(gicon)) |s| {
                    defer c.g_free(s);
                    return ui.icon(@import("dock.zig").iconName(std.mem.span(s)), size, false, 0);
                }
            }
        }
    }
    _ = app;
    if (icon.len > 0) {
        const symbolic = std.mem.endsWith(u8, icon, "-symbolic");
        return ui.icon(icon.ptr, size, symbolic, 0xffffff);
    }
    return ui.icon("dialog-information-symbolic", size, true, 0xffffff);
}

fn show(id: u32, app: []const u8, icon: [:0]const u8, summary: [*c]const u8, body: [*c]const u8) void {
    remember(id, icon, std.mem.span(summary), std.mem.span(body));
    if (do_not_disturb or @import("lock.zig").locked) return;
    const s = stage orelse return;
    if (banner) |old| c.clutter_actor_destroy(old);

    const text_x = padding + icon_size + 12;
    const text_w = width - text_x - padding;
    const title = ui.label(summary, config.font(.bold, 0));
    c.clutter_actor_set_width(title, @min(ui.preferredWidth(title), text_w));
    const text = ui.label(body, config.font(.regular, -1));
    c.clutter_actor_set_width(text, @min(ui.preferredWidth(text), text_w));
    c.clutter_actor_set_opacity(text, 210);

    const title_h = ui.preferredHeight(title);
    const text_h = if (std.mem.span(body).len > 0) ui.preferredHeight(text) else 0;
    const height = @max(icon_size, title_h + 2 + text_h) + 2 * padding;

    const card = ui.roundedRect(width, height, config.radius(1), background);
    const glyph = bannerIcon(app, icon, icon_size);
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
    const top: f32 = @as(f32, @floatFromInt(@import("config.zig").panelHeight())) + 8;
    const x = if (config.notifications_top_right) sw - width - 12 else (sw - width) / 2;
    c.clutter_actor_set_position(card, x, top);
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

/// Takes the banner down (it stays in the list).
pub fn hide() void {
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
    forget(id);
    if (connection) |conn| {
        _ = c.g_dbus_connection_emit_signal(conn, null, "/org/calide/Shell", "org.calide.Shell", "NotificationDismissed", c.g_variant_new("(u)", id), null);
    }
    return 1;
}
