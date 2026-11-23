//! Status icons on the right of the top bar and the system menu they open:
//! quick settings (volume, Wi-Fi, Bluetooth, Dark Style), then Settings,
//! Log Out, Restart, Power Off (the last three ask first).

const std = @import("std");
const plugin = @import("plugin.zig");
const ui = @import("ui.zig");
const status = @import("status.zig");
const settings = @import("settings.zig");
const c = plugin.c;

const font = "Adwaita Sans 11";
const title_font = "Adwaita Sans Bold 11";
const right_margin: f32 = 14;
const icon_spacing: f32 = 10;
const slider_h: f32 = 44;
const toggle_h: f32 = 48;
const toggle_gap: f32 = 10;
const off_color: u32 = 0xffffff1a;

var display: ?*c.MetaDisplay = null;
var stage: ?*c.ClutterActor = null;
var panel: ?*c.ClutterActor = null;
var style: c.CaliMenuStyle = undefined;

var icons_box: ?*c.ClutterActor = null;
var shown_icons: [8]?[*:0]const u8 = .{null} ** 8;
var popup: ?*c.ClutterActor = null; // our content while the menu is open
var confirming = false;
/// 0 = main menu, 1 = Wi-Fi networks, 2 = Bluetooth devices.
var picker: usize = 0;
var shown_layout: [8]u8 = .{0} ** 8;

pub fn init(d: ?*c.MetaDisplay, s: ?*c.ClutterActor, p: ?*c.ClutterActor) void {
    display = d;
    stage = s;
    panel = p;
    style = c.cali_shell_menu_style();

    const box = c.clutter_actor_new();
    const layout = c.clutter_box_layout_new();
    c.clutter_box_layout_set_spacing(@ptrCast(@alignCast(layout)), @intFromFloat(icon_spacing));
    c.clutter_actor_set_layout_manager(box, layout);
    c.clutter_actor_set_height(box, @floatFromInt(c.cali_shell_panel_height()));
    c.clutter_actor_add_constraint(box, c.clutter_align_constraint_new(p, @intCast(c.CLUTTER_ALIGN_X_AXIS), 1.0));
    c.clutter_actor_set_translation(box, -right_margin, 0, 0);
    c.clutter_actor_set_reactive(box, 1);
    plugin.connect(box, "button-release-event", &onStatusClicked, null);
    c.clutter_actor_add_child(p, box);
    icons_box = box;
    refreshIcons();

    // CALI_DEBUG_MENU=<seconds> opens the menu, for testing.
    if (std.posix.getenv("CALI_DEBUG_MENU")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugOpen, null);
    }
}

/// Status or settings changed: update the bar icons and an open menu.
pub fn refresh() void {
    refreshIcons();
    if (popup == null or confirming or dragging) return;
    if (picker != 0) showPicker(picker) else open();
}

/// Rebuilds the top bar icons from the current status, if they changed.
fn refreshIcons() void {
    const box = icons_box orelse return;
    var names: [8]?[*:0]const u8 = .{null} ** 8;
    var i: usize = 0;
    while (i < names.len) : (i += 1) {
        names[i] = c.cali_shell_status_icons(&status.current, i) orelse break;
    }
    var layout_buf: [8]u8 = .{0} ** 8;
    const layout = @import("keyboard.zig").indicator(&layout_buf);
    if (std.mem.eql(?[*:0]const u8, &names, &shown_icons) and std.mem.eql(u8, &layout_buf, &shown_layout)) return;
    shown_icons = names;
    shown_layout = layout_buf;

    c.clutter_actor_destroy_all_children(box);
    if (layout) |text| {
        const label = ui.label(text, "Adwaita Sans Bold 10");
        c.clutter_actor_set_y_align(label, @intCast(c.CLUTTER_ACTOR_ALIGN_CENTER));
        c.clutter_actor_add_child(box, label);
    }
    for (names) |maybe| {
        const name = maybe orelse break;
        const icon = ui.icon(name, style.status_icon_size, true, 0xffffff);
        c.clutter_actor_set_y_align(icon, @intCast(c.CLUTTER_ACTOR_ALIGN_CENTER));
        c.clutter_actor_add_child(box, icon);
    }
}

fn onStatusClicked(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    if (popup == null) open() else close();
    return 1;
}

fn debugOpen(_: c.gpointer) callconv(.C) c.gboolean {
    if (popup == null) open();
    // CALI_DEBUG_PICKER=1 (Wi-Fi) or 2 (Bluetooth) opens that list too.
    if (std.posix.getenv("CALI_DEBUG_PICKER")) |value| {
        const which: usize = if (std.mem.eql(u8, value, "2")) 2 else 1;
        _ = onPickerArrow(null, null, @ptrFromInt(which));
    }
    return 0;
}

// ---- Popup -------------------------------------------------------------------------------

const Row = struct { label: [*:0]const u8, action: c_int, bold: bool = false };
const confirm_cancel = -1;
const no_action = 0;

fn open() void {
    confirming = false;
    picker = 0;
    var rows: [8]Row = undefined;
    var n: usize = 0;
    var action: c.CaliMenuAction = undefined;
    while (n < rows.len) : (n += 1) {
        const text = c.cali_shell_menu_entry(n, &action) orelse break;
        rows[n] = .{ .label = text, .action = @intCast(action) };
    }
    show(rows[0..n], true);
}

/// Replaces the menu content with `rows`, below the quick settings if
/// `quick` (opening the menu if needed).
fn show(rows: []const Row, quick: bool) void {
    const s = stage orelse return;
    var stage_w: f32 = 0;
    var stage_h: f32 = 0;
    c.clutter_actor_get_size(s, &stage_w, &stage_h);

    const inner_w = style.width - 2 * style.padding;
    const quick_h: f32 = if (quick) slider_h + 2 * (toggle_h + toggle_gap) + 14 else 0;
    const n: f32 = @floatFromInt(rows.len);
    const height = quick_h + n * style.row_height + 2 * style.padding;
    const p = ui.roundedRect(style.width, height, style.corner_radius, style.background);
    const top: f32 = @as(f32, @floatFromInt(c.cali_shell_panel_height())) + 6;
    c.clutter_actor_set_position(p, stage_w - style.width - 8, top);

    var y = style.padding;
    if (quick) {
        addVolumeSlider(p, style.padding, y, inner_w);
        y += slider_h;
        const tw = (inner_w - toggle_gap) / 2;
        const toggles = [_]struct { label: [*:0]const u8, icon: [*:0]const u8, on: bool, available: bool, which: usize }{
            .{ .label = "Wi-Fi", .icon = "network-wireless-symbolic", .on = status.current.wifi_enabled, .available = status.current.wifi_available, .which = 1 },
            .{ .label = "Bluetooth", .icon = "bluetooth-active-symbolic", .on = status.current.bluetooth_enabled, .available = status.current.bluetooth_available, .which = 2 },
            .{ .label = "Dark Style", .icon = "weather-clear-night-symbolic", .on = settings.dark_style, .available = true, .which = 3 },
        };
        for (toggles, 0..) |t, i| {
            const x = style.padding + @as(f32, @floatFromInt(i % 2)) * (tw + toggle_gap);
            const ty = y + @as(f32, @floatFromInt(i / 2)) * (toggle_h + toggle_gap);
            addToggle(p, x, ty, tw, t.label, t.icon, t.on, t.available, t.which);
        }
        y += 2 * (toggle_h + toggle_gap);
        const line = c.clutter_actor_new();
        c.clutter_actor_set_background_color(line, &c.CoglColor{ .red = 255, .green = 255, .blue = 255, .alpha = 26 });
        c.clutter_actor_set_position(line, style.padding + 6, y + 6);
        c.clutter_actor_set_size(line, inner_w - 12, 1);
        c.clutter_actor_add_child(p, line);
        y += 14;
    }

    for (rows, 0..) |row, i| {
        const r = c.clutter_actor_new();
        c.clutter_actor_set_position(r, style.padding, y + @as(f32, @floatFromInt(i)) * style.row_height);
        c.clutter_actor_set_size(r, inner_w, style.row_height);

        const text = ui.label(row.label, if (row.bold) title_font else font);
        c.clutter_actor_set_x(text, 14);
        ui.center(text, r, c.CLUTTER_ALIGN_Y_AXIS);

        if (row.action != no_action) {
            const hover = ui.roundedRect(inner_w, style.row_height, 10, style.hover);
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
    confirming = false;
    picker = 0;
}

pub fn close() void {
    ui.closePopup();
}

// ---- Quick settings --------------------------------------------------------------------------

var slider_track: ?*c.ClutterActor = null;
var slider_fill: ?*c.ClutterActor = null;
var slider_knob: ?*c.ClutterActor = null;
var slider_icon: ?*c.ClutterActor = null;
var slider_w: f32 = 0;
const knob: f32 = 18;
const track_h: f32 = 6;

fn addVolumeSlider(parent: *c.ClutterActor, x: f32, y: f32, w: f32) void {
    const available = status.current.volume >= 0;
    const level: f32 = if (available and !status.current.muted) status.current.volume else 0;

    const row = c.clutter_actor_new();
    c.clutter_actor_set_position(row, x, y);
    c.clutter_actor_set_size(row, w, slider_h);
    c.clutter_actor_add_child(parent, row);

    const icon = ui.icon(c.cali_shell_volume_icon(level, status.current.muted), 16, true, 0xffffff);
    c.clutter_actor_set_position(icon, 10, (slider_h - 16) / 2);
    c.clutter_actor_add_child(row, icon);
    slider_icon = icon;

    // The reactive area is taller than the track so it's easy to grab.
    const area = c.clutter_actor_new();
    const left: f32 = 40;
    slider_w = w - left - 12;
    c.clutter_actor_set_position(area, left, 0);
    c.clutter_actor_set_size(area, slider_w, slider_h);
    c.clutter_actor_add_child(row, area);

    const track = ui.roundedRect(slider_w, track_h, track_h / 2, 0xffffff33);
    c.clutter_actor_set_position(track, 0, (slider_h - track_h) / 2);
    c.clutter_actor_add_child(area, track);
    slider_track = track;
    slider_fill = null;

    const k = ui.roundedRect(knob, knob, knob / 2, 0xffffffff);
    c.clutter_actor_set_y(k, (slider_h - knob) / 2);
    c.clutter_actor_add_child(area, k);
    slider_knob = k;
    drawSlider(level);

    if (available) {
        c.clutter_actor_set_reactive(area, 1);
        plugin.connect(area, "button-press-event", &onSliderPress, null);
        plugin.connect(area, "motion-event", &onSliderMotion, null);
        plugin.connect(area, "button-release-event", &onSliderRelease, null);
    } else {
        c.clutter_actor_set_opacity(row, 110);
    }
}

fn drawSlider(level: f32) void {
    const track = slider_track orelse return;
    const l = std.math.clamp(level, 0, 1);
    if (slider_fill) |f| c.clutter_actor_destroy(f);
    const f = ui.roundedRect(@max(track_h, l * slider_w), track_h, track_h / 2, ui.accent);
    c.clutter_actor_add_child(track, f);
    slider_fill = f;
    if (slider_knob) |k| c.clutter_actor_set_x(k, l * (slider_w - knob));
}

fn levelAt(area: ?*c.ClutterActor, event: ?*c.ClutterEvent) f32 {
    var ex: f32 = 0;
    var ey: f32 = 0;
    c.clutter_event_get_coords(event, &ex, &ey);
    var lx: f32 = 0;
    var ly: f32 = 0;
    _ = c.clutter_actor_transform_stage_point(area, ex, ey, &lx, &ly);
    return std.math.clamp((lx - knob / 2) / (slider_w - knob), 0, 1);
}

var dragging = false;

fn onSliderPress(area: ?*c.ClutterActor, event: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    dragging = true;
    const level = levelAt(area, event);
    drawSlider(level);
    status.setVolume(level);
    return 1;
}

fn onSliderMotion(area: ?*c.ClutterActor, event: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    if (!dragging) return 0;
    drawSlider(levelAt(area, event));
    return 1;
}

fn onSliderRelease(area: ?*c.ClutterActor, event: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    if (!dragging) return 1;
    dragging = false;
    const level = levelAt(area, event);
    drawSlider(level);
    status.setVolume(level);
    return 1;
}

fn addToggle(parent: *c.ClutterActor, x: f32, y: f32, w: f32, label: [*:0]const u8, icon_name: [*:0]const u8, on: bool, available: bool, which: usize) void {
    const t = ui.roundedRect(w, toggle_h, toggle_h / 2, if (on and available) ui.accent else off_color);
    c.clutter_actor_set_position(t, x, y);
    const icon = ui.icon(icon_name, 16, true, 0xffffff);
    c.clutter_actor_set_position(icon, 16, (toggle_h - 16) / 2);
    c.clutter_actor_add_child(t, icon);
    const text = ui.label(label, "Adwaita Sans Bold 10");
    c.clutter_actor_set_x(text, 42);
    c.clutter_actor_set_width(text, @min(ui.preferredWidth(text), w - 54));
    ui.center(text, t, c.CLUTTER_ALIGN_Y_AXIS);
    c.clutter_actor_add_child(t, text);
    if (available) {
        c.clutter_actor_set_reactive(t, 1);
        plugin.connect(t, "button-release-event", &onToggle, @ptrFromInt(which));
        // Wi-Fi and Bluetooth: an arrow on the right opens the list.
        if (which == 1 or which == 2) {
            const arrow = ui.roundedRect(toggle_h - 8, toggle_h - 8, (toggle_h - 8) / 2, 0x0000002a);
            c.clutter_actor_set_position(arrow, w - toggle_h + 4, 4);
            const glyph = ui.icon("go-next-symbolic", 14, true, 0xffffff);
            ui.center(glyph, arrow, c.CLUTTER_ALIGN_BOTH);
            c.clutter_actor_add_child(arrow, glyph);
            c.clutter_actor_set_reactive(arrow, 1);
            plugin.connect(arrow, "button-release-event", &onPickerArrow, @ptrFromInt(which));
            c.clutter_actor_add_child(t, arrow);
        }
    } else {
        c.clutter_actor_set_opacity(t, 110);
    }
    c.clutter_actor_add_child(parent, t);
}

fn onToggle(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, data: c.gpointer) callconv(.C) c.gboolean {
    switch (@intFromPtr(data)) {
        1 => status.setWifiEnabled(!status.current.wifi_enabled),
        2 => status.setBluetoothEnabled(!status.current.bluetooth_enabled),
        3 => {
            settings.dark_style = !settings.dark_style;
            settings.set("dark-style", c.g_variant_new_boolean(@intFromBool(settings.dark_style)));
        },
        else => {},
    }
    open(); // redraw with the new state right away
    return 1;
}

// ---- Wi-Fi / Bluetooth pickers ---------------------------------------------------------------

fn onPickerArrow(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, data: c.gpointer) callconv(.C) c.gboolean {
    const which = @intFromPtr(data);
    if (which == 1) status.fetchWifi() else status.fetchBluetooth();
    showPicker(which);
    return 1; // don't also flip the toggle
}

fn signalIcon(strength: u8) [*:0]const u8 {
    if (strength >= 75) return "network-wireless-signal-excellent-symbolic";
    if (strength >= 50) return "network-wireless-signal-good-symbolic";
    if (strength >= 25) return "network-wireless-signal-ok-symbolic";
    return "network-wireless-signal-weak-symbolic";
}

/// A list page in place of the main menu: Wi-Fi networks or Bluetooth devices.
fn showPicker(which: usize) void {
    const s = stage orelse return;
    picker = which;
    var stage_w: f32 = 0;
    var stage_h: f32 = 0;
    c.clutter_actor_get_size(s, &stage_w, &stage_h);

    const inner_w = style.width - 2 * style.padding;
    const count = if (which == 1) status.n_nets else status.n_devs;
    const rows: f32 = @floatFromInt(@max(count, 1));
    const header_h: f32 = 44;
    const height = header_h + rows * style.row_height + 2 * style.padding;
    const p = ui.roundedRect(style.width, height, style.corner_radius, style.background);
    c.clutter_actor_set_position(p, stage_w - style.width - 8, @as(f32, @floatFromInt(c.cali_shell_panel_height())) + 6);

    const back = ui.iconButton("go-previous-symbolic", 32, &onPickerBack, null);
    c.clutter_actor_set_position(back, style.padding, style.padding + 4);
    c.clutter_actor_add_child(p, back);
    const title = ui.label(if (which == 1) "Wi-Fi" else "Bluetooth", title_font);
    c.clutter_actor_set_position(title, style.padding + 44, style.padding + 4 + (32 - ui.preferredHeight(title)) / 2);
    c.clutter_actor_add_child(p, title);

    var y = style.padding + header_h;
    if (count == 0) {
        const none = ui.label(if (which == 1) "No networks found" else "No paired devices", font);
        c.clutter_actor_set_opacity(none, 160);
        c.clutter_actor_set_position(none, style.padding + 14, y + (style.row_height - ui.preferredHeight(none)) / 2);
        c.clutter_actor_add_child(p, none);
    }
    for (0..count) |i| {
        const r = c.clutter_actor_new();
        c.clutter_actor_set_position(r, style.padding, y);
        c.clutter_actor_set_size(r, inner_w, style.row_height);
        const hover = ui.roundedRect(inner_w, style.row_height, 10, style.hover);
        c.clutter_actor_set_opacity(hover, 0);
        c.clutter_actor_add_child(r, hover);

        const on = if (which == 1) status.nets[i].active else status.devs[i].connected;
        const icon_name: [*:0]const u8 = if (which == 1) signalIcon(status.nets[i].strength) else "bluetooth-active-symbolic";
        const icon = ui.icon(icon_name, 16, true, 0xffffff);
        c.clutter_actor_set_position(icon, 12, (style.row_height - 16) / 2);
        c.clutter_actor_add_child(r, icon);
        const name: [*:0]const u8 = if (which == 1) @ptrCast(&status.nets[i].ssid) else @ptrCast(&status.devs[i].name);
        const label = ui.label(name, if (on) title_font else font);
        c.clutter_actor_set_x(label, 40);
        c.clutter_actor_set_width(label, @min(ui.preferredWidth(label), inner_w - 110));
        ui.center(label, r, c.CLUTTER_ALIGN_Y_AXIS);
        c.clutter_actor_add_child(r, label);

        var right = inner_w - 30;
        if (on) {
            const check = ui.icon("object-select-symbolic", 16, true, 0xffffff);
            c.clutter_actor_set_position(check, right, (style.row_height - 16) / 2);
            c.clutter_actor_add_child(r, check);
            right -= 26;
        }
        if (which == 1 and status.nets[i].secured) {
            const padlock = ui.icon("channel-secure-symbolic", 14, true, 0xffffff);
            c.clutter_actor_set_opacity(padlock, 170);
            c.clutter_actor_set_position(padlock, right, (style.row_height - 14) / 2);
            c.clutter_actor_add_child(r, padlock);
        }

        c.clutter_actor_set_reactive(r, 1);
        plugin.connect(r, "enter-event", &onRowEnter, hover);
        plugin.connect(r, "leave-event", &onRowLeave, hover);
        plugin.connect(r, "button-release-event", &onPickerRow, @ptrFromInt(i + 1));
        c.clutter_actor_add_child(p, r);
        y += style.row_height;
    }

    if (popup == null) ui.openPopup(p, &onClosed) else ui.setPopupContent(p);
    popup = p;
}

fn onPickerBack(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    open();
    return 1;
}

fn onPickerRow(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, data: c.gpointer) callconv(.C) c.gboolean {
    const i = @intFromPtr(data) - 1;
    if (picker == 1 and i < status.n_nets) {
        if (!status.nets[i].active) status.connectWifi(@ptrCast(&status.nets[i].ssid));
    } else if (picker == 2 and i < status.n_devs) {
        status.setDeviceConnected(@ptrCast(&status.devs[i].path), !status.devs[i].connected);
    }
    return 1;
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

/// First click shows "…now?"; the confirmed row carries this offset.
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
            // Cali Settings if installed, else GNOME Settings.
            if (!ui.launchId(display, "org.calide.Settings.desktop")) _ = ui.launchId(display, "org.gnome.Settings.desktop");
        },
        c.CALI_MENU_LOG_OUT => confirm("Log out now?", "Log Out", action),
        c.CALI_MENU_RESTART => confirm("Restart now?", "Restart", action),
        c.CALI_MENU_POWER_OFF => confirm("Power off now?", "Power Off", action),
        else => close(),
    }
    return 1;
}

fn confirm(question: [*:0]const u8, verb: [*:0]const u8, action: c_int) void {
    confirming = true;
    show(&[_]Row{
        .{ .label = question, .action = no_action, .bold = true },
        .{ .label = verb, .action = action + confirmed_offset },
        .{ .label = "Cancel", .action = confirm_cancel },
    }, false);
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
    const system = c.g_bus_get_sync(@intCast(c.G_BUS_TYPE_SYSTEM), null, @ptrCast(&err)) orelse {
        if (err) |e| {
            std.log.warn("system menu: no system bus: {s}", .{e.message});
            c.g_error_free(e);
        }
        return;
    };
    defer c.g_object_unref(system);
    c.g_dbus_connection_call(system, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", method, c.g_variant_new("(b)", @as(c.gboolean, 1)), null, @intCast(c.G_DBUS_CALL_FLAGS_NONE), -1, null, null, null);
}
