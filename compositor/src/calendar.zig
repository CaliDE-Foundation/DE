//! The date menu: click the clock for notifications (with Do Not Disturb
//! and Clear) beside today's date and a month calendar, like GNOME. The
//! month grid and date text come from cali-shell (Rust).

const std = @import("std");
const plugin = @import("plugin.zig");
const ui = @import("ui.zig");
const notifications = @import("notifications.zig");
const settings = @import("settings.zig");
const c = plugin.c;
const config = @import("config.zig");

const cal_w: f32 = 340;
const list_w: f32 = 380;
const width: f32 = list_w + cal_w;
const padding: f32 = 18;
const cell_w: f32 = (cal_w - 2 * padding) / 7;
const cell_h: f32 = 36;
const background: u32 = 0x2e2e32f8;
const shown_notifications = 5;

var stage: ?*c.ClutterActor = null;
var open = false;
var shown_year: c_int = 0;
var shown_month: c_uint = 0;

pub fn init(s: ?*c.ClutterActor, clock: ?*c.ClutterActor) void {
    stage = s;
    c.clutter_actor_set_reactive(clock, 1);
    plugin.connect(clock, "button-release-event", &onClockClicked, null);

    // CALI_DEBUG_CALENDAR=<seconds> opens it, for testing.
    if (std.posix.getenv("CALI_DEBUG_CALENDAR")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugOpen, null);
    }
}

fn onClockClicked(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    if (open) ui.closePopup() else show();
    return 1;
}

fn debugOpen(_: c.gpointer) callconv(.C) c.gboolean {
    if (!open) show();
    return 0;
}

fn show() void {
    notifications.hide(); // the list shows it now
    c.cali_shell_calendar_today(&shown_year, &shown_month, null);
    ui.openPopup(build(), &onClosed);
    open = true;
}

/// Redraws an open date menu (notifications or Do Not Disturb changed).
pub fn refresh() void {
    if (open) ui.setPopupContent(build());
}

fn onClosed() void {
    open = false;
}

fn format(year: c_int, month: c_uint, day: c_uint, fmt: [*:0]const u8, buf: []u8) [*:0]const u8 {
    _ = c.cali_shell_format_date(year, month, day, fmt, buf.ptr, buf.len);
    return @ptrCast(buf.ptr);
}

fn build() *c.ClutterActor {
    const cal = buildCalendar();
    const height = c.clutter_actor_get_height(cal);
    const card = ui.roundedRect(width, height, config.radius(1.1), background);
    c.clutter_actor_set_x(cal, list_w);
    c.clutter_actor_add_child(card, cal);

    const list = buildNotifications(height);
    c.clutter_actor_add_child(card, list);

    const divider = c.clutter_actor_new();
    c.clutter_actor_set_background_color(divider, &c.CoglColor{ .red = 255, .green = 255, .blue = 255, .alpha = 26 });
    c.clutter_actor_set_position(divider, list_w, padding);
    c.clutter_actor_set_size(divider, 1, height - 2 * padding);
    c.clutter_actor_add_child(card, divider);

    // Centered under the clock.
    var stage_w: f32 = 0;
    var stage_h: f32 = 0;
    c.clutter_actor_get_size(stage, &stage_w, &stage_h);
    c.clutter_actor_set_position(card, (stage_w - width) / 2, @as(f32, @floatFromInt(@import("config.zig").panelHeight())) + 6);
    return card;
}

// ---- Notifications column ----------------------------------------------------------------

fn buildNotifications(height: f32) *c.ClutterActor {
    const col = c.clutter_actor_new();
    c.clutter_actor_set_size(col, list_w, height);
    const inner = list_w - 2 * padding;
    var y: f32 = padding;

    // What's playing, above the notifications.
    const media = @import("media.zig");
    const with_media = config.media_controls and media.active();
    if (with_media) {
        const m = media.card(inner);
        c.clutter_actor_set_position(m, padding, y);
        c.clutter_actor_add_child(col, m);
        y += media.height + 10;
    }
    const max_shown: usize = if (with_media) 2 else shown_notifications;

    if (notifications.n_items == 0 and !with_media) {
        const icon = ui.icon("preferences-system-notifications-symbolic", 48, true, 0xffffff);
        c.clutter_actor_set_opacity(icon, 90);
        c.clutter_actor_set_position(icon, (list_w - 48) / 2, height / 2 - 70);
        c.clutter_actor_add_child(col, icon);
        const empty = ui.label("No Notifications", config.font(.bold, 1));
        c.clutter_actor_set_opacity(empty, 150);
        c.clutter_actor_set_position(empty, (list_w - ui.preferredWidth(empty)) / 2, height / 2 - 10);
        c.clutter_actor_add_child(col, empty);
    }

    for (notifications.items[0..@min(notifications.n_items, max_shown)]) |*item| {
        const card_h: f32 = 64;
        const card = ui.roundedRect(inner, card_h, 14, 0xffffff12);
        c.clutter_actor_set_position(card, padding, y);
        const icon_span = std.mem.sliceTo(&item.icon, 0);
        const glyph = notifications.bannerIcon("", @ptrCast(icon_span), 28);
        c.clutter_actor_set_position(glyph, 12, (card_h - 28) / 2);
        c.clutter_actor_add_child(card, glyph);
        const tx: f32 = 52;
        const tw = inner - tx - 12;
        const time = ui.label(@ptrCast(&item.time), config.font(.regular, -2));
        c.clutter_actor_set_opacity(time, 150);
        const time_w = ui.preferredWidth(time);
        c.clutter_actor_set_position(time, inner - 12 - time_w, 12);
        c.clutter_actor_add_child(card, time);
        const summary = ui.label(@ptrCast(&item.summary), config.font(.bold, -1));
        c.clutter_actor_set_width(summary, @min(ui.preferredWidth(summary), tw - time_w - 8));
        c.clutter_actor_set_position(summary, tx, 12);
        c.clutter_actor_add_child(card, summary);
        const body = ui.label(@ptrCast(&item.body), config.font(.regular, -1));
        c.clutter_actor_set_width(body, @min(ui.preferredWidth(body), tw));
        c.clutter_actor_set_opacity(body, 200);
        c.clutter_actor_set_position(body, tx, 34);
        c.clutter_actor_add_child(card, body);
        c.clutter_actor_add_child(col, card);
        y += card_h + 8;
    }

    // Bottom row: Do Not Disturb, Clear.
    const row_y = height - padding - 34;
    const dnd = ui.roundedRect(170, 34, 17, if (notifications.do_not_disturb) ui.accent else 0xffffff1a);
    c.clutter_actor_set_position(dnd, padding, row_y);
    const moon = ui.icon("notifications-disabled-symbolic", 16, true, 0xffffff);
    c.clutter_actor_set_position(moon, 12, 9);
    c.clutter_actor_add_child(dnd, moon);
    const dnd_label = ui.label("Do Not Disturb", config.font(.bold, -1));
    c.clutter_actor_set_x(dnd_label, 36);
    ui.center(dnd_label, dnd, c.CLUTTER_ALIGN_Y_AXIS);
    c.clutter_actor_add_child(dnd, dnd_label);
    c.clutter_actor_set_reactive(dnd, 1);
    plugin.connect(dnd, "button-release-event", &onDoNotDisturb, null);
    c.clutter_actor_add_child(col, dnd);

    if (notifications.n_items > 0) {
        const clear = ui.roundedRect(80, 34, 17, 0xffffff1a);
        c.clutter_actor_set_position(clear, list_w - padding - 80, row_y);
        const clear_label = ui.label("Clear", config.font(.bold, -1));
        ui.center(clear_label, clear, c.CLUTTER_ALIGN_BOTH);
        c.clutter_actor_add_child(clear, clear_label);
        c.clutter_actor_set_reactive(clear, 1);
        plugin.connect(clear, "button-release-event", &onClear, null);
        c.clutter_actor_add_child(col, clear);
    }
    return col;
}

fn onDoNotDisturb(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    notifications.do_not_disturb = !notifications.do_not_disturb;
    settings.set("do-not-disturb", c.g_variant_new_boolean(@intFromBool(notifications.do_not_disturb)));
    refresh();
    return 1;
}

fn onClear(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    notifications.clearAll();
    refresh();
    return 1;
}

// ---- Calendar column ------------------------------------------------------------------------

fn buildCalendar() *c.ClutterActor {
    const col = c.clutter_actor_new();
    var buf: [128]u8 = undefined;
    var y: f32 = padding;

    // Today: weekday, then the full date.
    const weekday = ui.label(format(0, 0, 0, "%A", &buf), config.font(.regular, -1));
    c.clutter_actor_set_position(weekday, padding, y);
    c.clutter_actor_set_opacity(weekday, 200);
    c.clutter_actor_add_child(col, weekday);
    y += ui.preferredHeight(weekday) + 2;
    const date = ui.label(format(0, 0, 0, "%B %-d %Y", &buf), config.font(.bold, 5));
    c.clutter_actor_set_position(date, padding, y);
    c.clutter_actor_add_child(col, date);
    y += ui.preferredHeight(date) + 14;

    // Month header with previous / next buttons.
    const prev = ui.iconButton("go-previous-symbolic", 30, &onPrev, null);
    c.clutter_actor_set_position(prev, padding, y);
    const next = ui.iconButton("go-next-symbolic", 30, &onNext, null);
    c.clutter_actor_set_position(next, cal_w - padding - 30, y);
    const title = ui.label(format(shown_year, shown_month, 1, "%B %Y", &buf), config.font(.bold, 0));
    c.clutter_actor_set_position(title, (cal_w - ui.preferredWidth(title)) / 2, y + (30 - ui.preferredHeight(title)) / 2);
    for ([_]*c.ClutterActor{ prev, next, title }) |a| c.clutter_actor_add_child(col, a);
    y += 30 + 10;

    // Weekday initials, Sunday first (Nov 1 2026 is a Sunday).
    for (0..7) |i| {
        const name = format(2026, 11, @intCast(i + 1), "%a", &buf);
        const span = std.mem.span(name);
        const len = std.unicode.utf8ByteSequenceLength(span[0]) catch 1;
        buf[@min(len, span.len)] = 0;
        const l = ui.label(@ptrCast(&buf), config.font(.bold, -2));
        c.clutter_actor_set_opacity(l, 160);
        c.clutter_actor_set_position(l, padding + @as(f32, @floatFromInt(i)) * cell_w + (cell_w - ui.preferredWidth(l)) / 2, y);
        c.clutter_actor_add_child(col, l);
    }
    y += 22;

    // The month grid.
    var days: [42]c.CaliDay = undefined;
    _ = c.cali_shell_calendar_grid(shown_year, shown_month, &days);
    for (days, 0..) |day, i| {
        const cx = padding + @as(f32, @floatFromInt(i % 7)) * cell_w;
        const cy = y + @as(f32, @floatFromInt(i / 7)) * cell_h;
        if (day.today) {
            const d: f32 = 30;
            const dot = ui.roundedRect(d, d, d / 2, ui.accent);
            c.clutter_actor_set_position(dot, cx + (cell_w - d) / 2, cy + (cell_h - d) / 2);
            c.clutter_actor_add_child(col, dot);
        }
        var num: [4]u8 = undefined;
        const text = std.fmt.bufPrintZ(&num, "{d}", .{day.day}) catch continue;
        const l = ui.label(text.ptr, if (day.today) config.font(.bold, -1) else config.font(.regular, -1));
        c.clutter_actor_set_position(l, cx + (cell_w - ui.preferredWidth(l)) / 2, cy + (cell_h - ui.preferredHeight(l)) / 2);
        if (!day.in_month) c.clutter_actor_set_opacity(l, 90);
        c.clutter_actor_add_child(col, l);
    }
    y += 6 * cell_h + padding;
    c.clutter_actor_set_size(col, cal_w, y);
    return col;
}

fn onPrev(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    c.cali_shell_calendar_add_months(&shown_year, &shown_month, -1);
    ui.setPopupContent(build());
    return 1;
}

fn onNext(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    c.cali_shell_calendar_add_months(&shown_year, &shown_month, 1);
    ui.setPopupContent(build());
    return 1;
}
