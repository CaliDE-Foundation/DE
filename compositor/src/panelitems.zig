//! Top bar items from extensions (org.calide.Shell.Panel on the shell's bus
//! name, path /org/calide/Shell/Panel). An extension calls SetItem to show
//! an icon and/or text left of the status icons, SetMenu to give it a menu,
//! and gets Activated(id, index) when it's clicked (index -1) or a menu row
//! is picked. Items belong to the D-Bus connection that made them and go
//! away when it does, so a crashed extension never leaves junk behind.

const std = @import("std");
const plugin = @import("plugin.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");
const c = plugin.c;

const object_path = "/org/calide/Shell/Panel";
const iface = "org.calide.Shell.Panel";
const introspection =
    \\<node>
    \\  <interface name="org.calide.Shell.Panel">
    \\    <method name="SetItem">
    \\      <arg direction="in" type="s" name="id"/>
    \\      <arg direction="in" type="s" name="icon"/>
    \\      <arg direction="in" type="s" name="label"/>
    \\      <arg direction="in" type="s" name="tooltip"/>
    \\    </method>
    \\    <method name="SetMenu">
    \\      <arg direction="in" type="s" name="id"/>
    \\      <arg direction="in" type="as" name="rows"/>
    \\    </method>
    \\    <method name="RemoveItem">
    \\      <arg direction="in" type="s" name="id"/>
    \\    </method>
    \\    <signal name="Activated">
    \\      <arg type="s" name="id"/>
    \\      <arg type="i" name="index"/>
    \\    </signal>
    \\  </interface>
    \\</node>
;

const max_items = 16;
const max_rows = 12;

const Item = struct {
    owner: [64]u8 = .{0} ** 64, // unique bus name of the extension
    id: [64]u8 = .{0} ** 64,
    icon: [128]u8 = .{0} ** 128,
    label: [128]u8 = .{0} ** 128,
    tooltip: [128]u8 = .{0} ** 128,
    rows: [max_rows][96]u8 = undefined,
    n_rows: usize = 0,
    watch: c_uint = 0,
    actor: ?*c.ClutterActor = null,
    on_click: ?*const fn () void = null, // the shell's own items
};

const local_owner = "cali";

/// The shell's own top bar items (e.g. now playing): same look, a callback
/// instead of D-Bus.
pub fn setLocal(id: [*:0]const u8, icon: [*:0]const u8, label: [*:0]const u8, tooltip: [*:0]const u8, on_click: *const fn () void) void {
    const index = find(local_owner, id) orelse blk: {
        for (&items, 0..) |*slot, i| {
            if (slot.* != null) continue;
            slot.* = Item{};
            copyZ(&slot.*.?.owner, local_owner);
            copyZ(&slot.*.?.id, id);
            break :blk i;
        }
        return;
    };
    const item = &items[index].?;
    copyZ(&item.icon, icon);
    copyZ(&item.label, label);
    copyZ(&item.tooltip, tooltip);
    item.on_click = on_click;
    rebuild(index);
}

pub fn removeLocal(id: [*:0]const u8) void {
    if (find(local_owner, id)) |i| remove(i);
}

var items: [max_items]?Item = .{null} ** max_items;
var connection: ?*c.GDBusConnection = null;
var panel: ?*c.ClutterActor = null;
var box: ?*c.ClutterActor = null;
var menu_item: usize = 0; // which item's menu is open

pub fn init(p: ?*c.ClutterActor) void {
    panel = p;
    const b = c.clutter_actor_new();
    const layout = c.clutter_box_layout_new();
    c.clutter_box_layout_set_spacing(@ptrCast(@alignCast(layout)), 4);
    c.clutter_actor_set_layout_manager(b, layout);
    c.clutter_actor_set_height(b, @floatFromInt(config.panelHeight()));
    c.clutter_actor_add_constraint(b, c.clutter_align_constraint_new(p, @intCast(c.CLUTTER_ALIGN_X_AXIS), 1.0));
    c.clutter_actor_add_child(p, b);
    box = b;
}

/// Keeps the items just left of the status icons.
pub fn relayout() void {
    const b = box orelse return;
    c.clutter_actor_set_height(b, @floatFromInt(config.panelHeight()));
    c.clutter_actor_set_translation(b, -(@import("statusmenu.zig").iconsWidth() + 10), 0, 0);
}

/// Width of the items, so the clock can stay clear of them.
pub fn width() f32 {
    const b = box orelse return 0;
    return ui.preferredWidth(b);
}

const vtable = c.GDBusInterfaceVTable{ .method_call = &onMethod, .get_property = null, .set_property = null, .padding = undefined };

/// Called once the shell owns its bus name.
pub fn register(conn: ?*c.GDBusConnection) void {
    connection = conn;
    var err: ?*c.GError = null;
    const node = c.g_dbus_node_info_new_for_xml(introspection, @ptrCast(&err)) orelse return;
    defer c.g_dbus_node_info_unref(node);
    _ = c.g_dbus_connection_register_object(conn, object_path, node.*.interfaces[0], &vtable, null, null, @ptrCast(&err));
    if (err) |e| {
        std.log.warn("panel items: {s}", .{e.message});
        c.g_error_free(e);
    }
}

fn copyZ(dest: []u8, src: [*c]const u8) void {
    const s = std.mem.span(src);
    const n = @min(s.len, dest.len - 1);
    @memcpy(dest[0..n], s[0..n]);
    dest[n] = 0;
}

fn find(owner: [*c]const u8, id: [*c]const u8) ?usize {
    for (&items, 0..) |*slot, i| {
        const item = &(slot.* orelse continue);
        if (std.mem.eql(u8, std.mem.sliceTo(&item.owner, 0), std.mem.span(owner)) and
            std.mem.eql(u8, std.mem.sliceTo(&item.id, 0), std.mem.span(id))) return i;
    }
    return null;
}

fn onMethod(_: ?*c.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, method: [*c]const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, _: c.gpointer) callconv(.C) void {
    const name = std.mem.span(method);
    if (std.mem.eql(u8, name, "SetItem")) {
        var id: [*c]const u8 = null;
        var icon: [*c]const u8 = null;
        var label: [*c]const u8 = null;
        var tooltip: [*c]const u8 = null;
        c.g_variant_get(params, "(&s&s&s&s)", &id, &icon, &label, &tooltip);
        const index = find(sender, id) orelse blk: {
            for (&items, 0..) |*slot, i| {
                if (slot.* != null) continue;
                slot.* = Item{};
                copyZ(&slot.*.?.owner, sender);
                copyZ(&slot.*.?.id, id);
                // Drop the extension's items when it disconnects.
                slot.*.?.watch = c.g_bus_watch_name_on_connection(connection, sender, @intCast(c.G_BUS_NAME_WATCHER_FLAGS_NONE), null, &onOwnerVanished, null, null);
                break :blk i;
            }
            return c.g_dbus_method_invocation_return_dbus_error(invocation, "org.calide.Shell.Error.TooMany", "Too many top bar items");
        };
        const item = &items[index].?;
        copyZ(&item.icon, icon);
        copyZ(&item.label, label);
        copyZ(&item.tooltip, tooltip);
        rebuild(index);
    } else if (std.mem.eql(u8, name, "SetMenu")) {
        var id: [*c]const u8 = null;
        var iter: ?*c.GVariantIter = null;
        c.g_variant_get(params, "(&sas)", &id, &iter);
        defer c.g_variant_iter_free(iter);
        const index = find(sender, id) orelse return c.g_dbus_method_invocation_return_dbus_error(invocation, "org.calide.Shell.Error.NoItem", "Call SetItem first");
        const item = &items[index].?;
        item.n_rows = 0;
        var row: [*c]const u8 = null;
        while (c.g_variant_iter_next(iter, "&s", &row) != 0) {
            if (item.n_rows == max_rows) break;
            copyZ(&item.rows[item.n_rows], row);
            item.n_rows += 1;
        }
    } else if (std.mem.eql(u8, name, "RemoveItem")) {
        var id: [*c]const u8 = null;
        c.g_variant_get(params, "(&s)", &id);
        if (find(sender, id)) |i| remove(i);
    }
    c.g_dbus_method_invocation_return_value(invocation, null);
}

fn onOwnerVanished(_: ?*c.GDBusConnection, name: [*c]const u8, _: c.gpointer) callconv(.C) void {
    for (&items, 0..) |*slot, i| {
        const item = &(slot.* orelse continue);
        if (std.mem.eql(u8, std.mem.sliceTo(&item.owner, 0), std.mem.span(name))) remove(i);
    }
}

fn remove(index: usize) void {
    const item = &(items[index] orelse return);
    if (item.actor) |a| c.clutter_actor_destroy(a);
    if (item.watch != 0) c.g_bus_unwatch_name(item.watch);
    items[index] = null;
    relayout();
    plugin.restyleClock();
}

/// Draws (or redraws) one item: an icon, a label, or both.
fn rebuild(index: usize) void {
    const b = box orelse return;
    const item = &(items[index] orelse return);
    const h: f32 = @floatFromInt(config.panelHeight());
    const actor = c.clutter_actor_new();
    const layout = c.clutter_box_layout_new();
    c.clutter_box_layout_set_spacing(@ptrCast(@alignCast(layout)), 5);
    c.clutter_actor_set_layout_manager(actor, layout);
    c.clutter_actor_set_height(actor, h);
    if (item.icon[0] != 0) {
        const icon_name: [*:0]const u8 = @ptrCast(&item.icon);
        const glyph = if (item.icon[0] == '/') ui.image(icon_name, 16) else ui.icon(icon_name, 16, true, 0xffffff);
        c.clutter_actor_set_y_align(glyph, c.CLUTTER_ACTOR_ALIGN_CENTER);
        c.clutter_actor_add_child(actor, glyph);
    }
    if (item.label[0] != 0) {
        const text = ui.label(@ptrCast(&item.label), config.font(.bold, 0));
        c.clutter_actor_set_y_align(text, c.CLUTTER_ACTOR_ALIGN_CENTER);
        c.clutter_actor_add_child(actor, text);
    }
    c.clutter_actor_set_reactive(actor, 1);
    const name: [*:0]const u8 = if (item.tooltip[0] != 0) @ptrCast(&item.tooltip) else if (item.label[0] != 0) @ptrCast(&item.label) else @ptrCast(&item.id);
    ui.accessible(actor, c.ATK_ROLE_PUSH_BUTTON, name);
    plugin.connect(actor, "button-release-event", &onClicked, @ptrFromInt(index + 1));

    if (item.actor) |old| {
        c.clutter_actor_insert_child_above(b, actor, old);
        c.clutter_actor_destroy(old);
    } else c.clutter_actor_add_child(b, actor);
    item.actor = actor;
    relayout();
    plugin.restyleClock();
}

fn emit(index: usize, row: i32) void {
    const item = &(items[index] orelse return);
    _ = c.g_dbus_connection_emit_signal(connection, @ptrCast(&item.owner), object_path, iface, "Activated", c.g_variant_new("(si)", @as([*:0]const u8, @ptrCast(&item.id)), row), null);
}

fn onClicked(actor: ?*c.ClutterActor, _: ?*c.ClutterEvent, data: c.gpointer) callconv(.C) c.gboolean {
    const index = @intFromPtr(data) - 1;
    const item = &(items[index] orelse return 1);
    if (item.on_click) |f| {
        f();
        return 1;
    }
    if (item.n_rows == 0) {
        emit(index, -1);
        return 1;
    }
    // A menu under the item.
    var x: f32 = 0;
    var y: f32 = 0;
    c.clutter_actor_get_transformed_position(actor, &x, &y);
    var labels: [max_rows][*:0]const u8 = undefined;
    for (0..item.n_rows) |i| labels[i] = @ptrCast(&item.rows[i]);
    menu_item = index;
    ui.menu(x, y + @as(f32, @floatFromInt(config.panelHeight())), labels[0..item.n_rows], &onMenuRow);
    return 1;
}

fn onMenuRow(row: usize) void {
    emit(menu_item, @intCast(row));
}
