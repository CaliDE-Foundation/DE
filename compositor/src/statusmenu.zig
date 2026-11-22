//! Status icons on the right of the top bar and the system menu they open:
//! Settings, Log Out, Restart, Power Off (the last three ask first).

const std = @import("std");
const plugin = @import("plugin.zig");
const ui = @import("ui.zig");
const c = plugin.c;

const font = "Adwaita Sans 11";
const title_font = "Adwaita Sans Bold 11";
const right_margin: f32 = 14;
const icon_spacing: f32 = 10;

var display: ?*c.MetaDisplay = null;
var stage: ?*c.ClutterActor = null;
var panel: ?*c.ClutterActor = null;
var style: c.CaliMenuStyle = undefined;

var popup: ?*c.ClutterActor = null; // our content while the menu is open

pub fn init(d: ?*c.MetaDisplay, s: ?*c.ClutterActor, p: ?*c.ClutterActor) void {
    display = d;
    stage = s;
    panel = p;
    style = c.cali_shell_menu_style();

    const box = c.clutter_actor_new();
    const layout = c.clutter_box_layout_new();
    c.clutter_box_layout_set_spacing(@ptrCast(@alignCast(layout)), @intFromFloat(icon_spacing));
    c.clutter_actor_set_layout_manager(box, layout);
    var i: usize = 0;
    while (c.cali_shell_status_icon(i)) |name| : (i += 1) {
        const icon = ui.icon(name, style.status_icon_size, true, 0xffffff);
        c.clutter_actor_set_y_align(icon, @intCast(c.CLUTTER_ACTOR_ALIGN_CENTER));
        c.clutter_actor_add_child(box, icon);
    }
    c.clutter_actor_set_height(box, @floatFromInt(c.cali_shell_panel_height()));
    c.clutter_actor_add_constraint(box, c.clutter_align_constraint_new(p, @intCast(c.CLUTTER_ALIGN_X_AXIS), 1.0));
    c.clutter_actor_set_translation(box, -right_margin, 0, 0);
    c.clutter_actor_set_reactive(box, 1);
    plugin.connect(box, "button-release-event", &onStatusClicked, null);
    c.clutter_actor_add_child(p, box);

    // CALI_DEBUG_MENU=<seconds> opens the menu, for testing.
    if (std.posix.getenv("CALI_DEBUG_MENU")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugOpen, null);
    }
}

fn onStatusClicked(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    if (popup == null) open() else close();
    return 1;
}

fn debugOpen(_: c.gpointer) callconv(.C) c.gboolean {
    if (popup == null) open();
    return 0;
}

// ---- Popup -------------------------------------------------------------------------------

const Row = struct { label: [*:0]const u8, action: c_int, bold: bool = false };
const confirm_cancel = -1;
const no_action = 0;

fn open() void {
    var rows: [8]Row = undefined;
    var n: usize = 0;
    var action: c.CaliMenuAction = undefined;
    while (n < rows.len) : (n += 1) {
        const text = c.cali_shell_menu_entry(n, &action) orelse break;
        rows[n] = .{ .label = text, .action = @intCast(action) };
    }
    show(rows[0..n]);
}

/// Replaces the menu content with `rows` (opening it if needed).
fn show(rows: []const Row) void {
    const s = stage orelse return;
    var stage_w: f32 = 0;
    var stage_h: f32 = 0;
    c.clutter_actor_get_size(s, &stage_w, &stage_h);

    const n: f32 = @floatFromInt(rows.len);
    const height = n * style.row_height + 2 * style.padding;
    const p = ui.roundedRect(style.width, height, style.corner_radius, style.background);
    const top: f32 = @as(f32, @floatFromInt(c.cali_shell_panel_height())) + 6;
    c.clutter_actor_set_position(p, stage_w - style.width - 8, top);

    const row_w = style.width - 2 * style.padding;
    for (rows, 0..) |row, i| {
        const r = c.clutter_actor_new();
        c.clutter_actor_set_position(r, style.padding, style.padding + @as(f32, @floatFromInt(i)) * style.row_height);
        c.clutter_actor_set_size(r, row_w, style.row_height);

        const text = ui.label(row.label, if (row.bold) title_font else font);
        c.clutter_actor_set_x(text, 14);
        ui.center(text, r, c.CLUTTER_ALIGN_Y_AXIS);

        if (row.action != no_action) {
            const hover = ui.roundedRect(row_w, style.row_height, 10, style.hover);
            c.clutter_actor_set_opacity(hover, 0);
            c.clutter_actor_add_child(r, hover);
            c.clutter_actor_set_reactive(r, 1);
            plugin.connect(r, "enter-event", &onRowEnter, hover);
            plugin.connect(r, "leave-event", &onRowLeave, hover);
            plugin.connect(r, "button-release-event", &onRowClicked, @ptrFromInt(@as(usize, @bitCast(@as(isize, row.action)))));
        }
        c.clutter_actor_add_child(r, text);
        c.clutter_actor_add_child(p, r);
    }

    if (popup == null) ui.openPopup(p, &onClosed) else ui.setPopupContent(p);
    popup = p;
}

fn onClosed() void {
    popup = null;
}

pub fn close() void {
    ui.closePopup();
}

fn onRowEnter(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, hover: c.gpointer) callconv(.C) c.gboolean {
    const h: ?*c.ClutterActor = @ptrCast(@alignCast(hover));
    ui.ease(h, 100, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(h, 255);
    c.clutter_actor_restore_easing_state(h);
    return 0;
}

fn onRowLeave(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, hover: c.gpointer) callconv(.C) c.gboolean {
    const h: ?*c.ClutterActor = @ptrCast(@alignCast(hover));
    ui.ease(h, 100, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(h, 0);
    c.clutter_actor_restore_easing_state(h);
    return 0;
}

// ---- Actions -------------------------------------------------------------------------------

/// Confirmed actions are stored negated-and-offset so they're distinct from
/// first clicks: first click shows "…now?", the second carries it out.
const confirmed_offset = 100;

fn onRowClicked(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, data: c.gpointer) callconv(.C) c.gboolean {
    const action: c_int = @intCast(@as(isize, @bitCast(@intFromPtr(data))));
    if (action == confirm_cancel) {
        close();
        return 1;
    }
    if (action > confirmed_offset) {
        close();
        run(action - confirmed_offset);
        return 1;
    }
    switch (action) {
        c.CALI_MENU_SETTINGS => {
            close();
            _ = ui.launchId(display, "org.gnome.Settings.desktop");
        },
        c.CALI_MENU_LOG_OUT => confirm("Log out now?", "Log Out", action),
        c.CALI_MENU_RESTART => confirm("Restart now?", "Restart", action),
        c.CALI_MENU_POWER_OFF => confirm("Power off now?", "Power Off", action),
        else => close(),
    }
    return 1;
}

fn confirm(question: [*:0]const u8, verb: [*:0]const u8, action: c_int) void {
    show(&[_]Row{
        .{ .label = question, .action = no_action, .bold = true },
        .{ .label = verb, .action = action + confirmed_offset },
        .{ .label = "Cancel", .action = confirm_cancel },
    });
}

fn run(action: c_int) void {
    const d = display orelse return;
    switch (action) {
        c.CALI_MENU_LOG_OUT => c.meta_context_terminate(c.meta_display_get_context(d)),
        c.CALI_MENU_RESTART => logind("Reboot"),
        c.CALI_MENU_POWER_OFF => logind("PowerOff"),
        else => {},
    }
}

/// Asks systemd-logind to reboot or power off. Systems without logind
/// (other init systems) just log a warning for now.
fn logind(method: [*:0]const u8) void {
    var err: ?*c.GError = null;
    const bus = c.g_bus_get_sync(@intCast(c.G_BUS_TYPE_SYSTEM), null, @ptrCast(&err)) orelse {
        if (err) |e| {
            std.log.warn("system menu: no system bus: {s}", .{e.message});
            c.g_error_free(e);
        }
        return;
    };
    defer c.g_object_unref(bus);
    c.g_dbus_connection_call(
        bus,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
        method,
        c.g_variant_new("(b)", @as(c.gboolean, 1)),
        null,
        @intCast(c.G_DBUS_CALL_FLAGS_NONE),
        -1,
        null,
        null,
        null,
    );
}
