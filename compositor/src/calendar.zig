//! The date menu: click the clock for today's date and a month calendar.
//! The month grid and date text come from cali-shell (Rust).

const std = @import("std");
const plugin = @import("plugin.zig");
const ui = @import("ui.zig");
const c = plugin.c;

const width: f32 = 340;
const padding: f32 = 18;
const cell_w: f32 = (width - 2 * padding) / 7;
const cell_h: f32 = 36;
const accent: u32 = 0xe2725bff; // Cali coral
const background: u32 = 0x2e2e32f8;

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
    c.cali_shell_calendar_today(&shown_year, &shown_month, null);
    ui.openPopup(build(), &onClosed);
    open = true;
}

fn onClosed() void {
    open = false;
}

fn format(year: c_int, month: c_uint, day: c_uint, fmt: [*:0]const u8, buf: []u8) [*:0]const u8 {
    _ = c.cali_shell_format_date(year, month, day, fmt, buf.ptr, buf.len);
    return @ptrCast(buf.ptr);
}

fn build() *c.ClutterActor {
    var buf: [128]u8 = undefined;
    var y: f32 = padding;

    // Today: weekday, then the full date.
    const weekday = ui.label(format(0, 0, 0, "%A", &buf), "Adwaita Sans 10");
    c.clutter_actor_set_position(weekday, padding, y);
    c.clutter_actor_set_opacity(weekday, 200);
    y += ui.preferredHeight(weekday) + 2;
    const date = ui.label(format(0, 0, 0, "%B %-d %Y", &buf), "Adwaita Sans Bold 16");
    c.clutter_actor_set_position(date, padding, y);
    y += ui.preferredHeight(date) + 14;

    // Month header with previous / next buttons.
    const header_y = y;
    const prev = ui.iconButton("go-previous-symbolic", 30, &onPrev, null);
    c.clutter_actor_set_position(prev, padding, header_y);
    const next = ui.iconButton("go-next-symbolic", 30, &onNext, null);
    c.clutter_actor_set_position(next, width - padding - 30, header_y);
    const title = ui.label(format(shown_year, shown_month, 1, "%B %Y", &buf), "Adwaita Sans Bold 11");
    c.clutter_actor_set_position(title, (width - ui.preferredWidth(title)) / 2, header_y + (30 - ui.preferredHeight(title)) / 2);
    y += 30 + 10;

    // Weekday initials, Sunday first (Nov 1 2026 is a Sunday).
    var letters: [7]*c.ClutterActor = undefined;
    for (0..7) |i| {
        const name = format(2026, 11, @intCast(i + 1), "%a", &buf);
        // First character only (may be several bytes in UTF-8).
        const span = std.mem.span(name);
        const len = std.unicode.utf8ByteSequenceLength(span[0]) catch 1;
        buf[@min(len, span.len)] = 0;
        const l = ui.label(@ptrCast(&buf), "Adwaita Sans Bold 9");
        c.clutter_actor_set_opacity(l, 160);
        c.clutter_actor_set_position(l, padding + @as(f32, @floatFromInt(i)) * cell_w + (cell_w - ui.preferredWidth(l)) / 2, y);
        letters[i] = l;
    }
    y += 22;

    // The month grid.
    var days: [42]c.CaliDay = undefined;
    _ = c.cali_shell_calendar_grid(shown_year, shown_month, &days);
    const grid_y = y;
    y += 6 * cell_h + padding;

    const card = ui.roundedRect(width, y, 20, background);
    for ([_]*c.ClutterActor{ weekday, date, prev, next, title }) |a| c.clutter_actor_add_child(card, a);
    for (letters) |l| c.clutter_actor_add_child(card, l);

    for (days, 0..) |day, i| {
        const col: f32 = @floatFromInt(i % 7);
        const row: f32 = @floatFromInt(i / 7);
        const cx = padding + col * cell_w;
        const cy = grid_y + row * cell_h;
        if (day.today) {
            const d: f32 = 30;
            const dot = ui.roundedRect(d, d, d / 2, accent);
            c.clutter_actor_set_position(dot, cx + (cell_w - d) / 2, cy + (cell_h - d) / 2);
            c.clutter_actor_add_child(card, dot);
        }
        var num: [4]u8 = undefined;
        const text = std.fmt.bufPrintZ(&num, "{d}", .{day.day}) catch continue;
        const l = ui.label(text.ptr, if (day.today) "Adwaita Sans Bold 10" else "Adwaita Sans 10");
        c.clutter_actor_set_position(l, cx + (cell_w - ui.preferredWidth(l)) / 2, cy + (cell_h - ui.preferredHeight(l)) / 2);
        if (!day.in_month) c.clutter_actor_set_opacity(l, 90);
        c.clutter_actor_add_child(card, l);
    }

    // Centered under the clock.
    var stage_w: f32 = 0;
    var stage_h: f32 = 0;
    c.clutter_actor_get_size(stage, &stage_w, &stage_h);
    c.clutter_actor_set_position(card, (stage_w - width) / 2, @as(f32, @floatFromInt(c.cali_shell_panel_height())) + 6);
    return card;
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
