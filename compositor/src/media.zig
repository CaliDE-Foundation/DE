//! What's playing, from cali-statusd (MPRIS), and the media card shown in
//! the calendar popup: artwork, "Listening from <app>", title, artist,
//! previous / play / next, a seek bar and the audio output.

const std = @import("std");
const plugin = @import("plugin.zig");
const bus = @import("bus.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");
const c = plugin.c;

const dest = "org.calide.Status";
const path = "/org/calide/Status";
const iface = "org.calide.Status";

pub const State = struct {
    identity: [128]u8 = .{0} ** 128,
    icon: [512]u8 = .{0} ** 512,
    title: [256]u8 = .{0} ** 256,
    artist: [256]u8 = .{0} ** 256,
    art: [512]u8 = .{0} ** 512,
    output: [128]u8 = .{0} ** 128,
    players: [1024]u8 = .{0} ** 1024, // "busname\tapp" per line
    length: i64 = 0,
    position: i64 = 0,
    playing: bool = false,
    updated: i64 = 0, // monotonic µs when position was read
};
pub var state = State{};
var timer: c_uint = 0;

pub fn init() void {
    bus.subscribe(dest, iface, "MediaChanged", &onChanged);
    bus.watch(dest, &onAppeared);
    timer = c.g_timeout_add_seconds(1, &tick, null);
}

/// Something is playing (or paused) with a title.
pub fn active() bool {
    return state.title[0] != 0;
}

/// The playback position now, counting time since it was last reported.
pub fn position() i64 {
    if (!state.playing) return state.position;
    return @min(state.position + (c.g_get_monotonic_time() - state.updated), @max(state.length, state.position));
}

fn onAppeared(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: c.gpointer) callconv(.C) void {
    bus.call(dest, path, iface, "GetMedia", null, &onGetMedia, null);
}

fn onGetMedia(_: ?*c.GObject, result: ?*c.GAsyncResult, _: c.gpointer) callconv(.C) void {
    const reply = bus.finish(result) orelse return;
    defer c.g_variant_unref(reply);
    update(reply);
}

fn onChanged(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, params: ?*c.GVariant, _: c.gpointer) callconv(.C) void {
    update(params);
}

fn copyZ(dest_buf: []u8, src: [*c]const u8) void {
    const s = std.mem.span(src);
    const n = @min(s.len, dest_buf.len - 1);
    @memcpy(dest_buf[0..n], s[0..n]);
    dest_buf[n] = 0;
}

fn update(tuple: ?*c.GVariant) void {
    bus.forEachEntry(tuple, &apply);
    state.updated = c.g_get_monotonic_time();
    updateTopBar();
    @import("calendar.zig").refresh();
}

fn apply(key: [:0]const u8, v: ?*c.GVariant) void {
    const eql = std.mem.eql;
    const is = struct {
        fn f(value: ?*c.GVariant, t: [*:0]const u8) bool {
            return c.g_variant_is_of_type(value, @ptrCast(t)) != 0;
        }
    }.f;
    if (is(v, "s")) {
        const text = c.g_variant_get_string(v, null);
        if (eql(u8, key, "identity")) copyZ(&state.identity, text);
        if (eql(u8, key, "title")) copyZ(&state.title, text);
        if (eql(u8, key, "artist")) copyZ(&state.artist, text);
        if (eql(u8, key, "art")) copyZ(&state.art, text);
        if (eql(u8, key, "output")) copyZ(&state.output, text);
        if (eql(u8, key, "icon")) copyZ(&state.icon, text);
        if (eql(u8, key, "players")) copyZ(&state.players, text);
    } else if (is(v, "x")) {
        if (eql(u8, key, "length")) state.length = c.g_variant_get_int64(v);
        if (eql(u8, key, "position")) state.position = c.g_variant_get_int64(v);
    } else if (is(v, "b") and eql(u8, key, "playing")) {
        state.playing = c.g_variant_get_boolean(v) != 0;
    }
}

/// While playing, keep an open calendar's seek bar moving.
fn tick(_: c.gpointer) callconv(.C) c.gboolean {
    if (state.playing and config.media_controls and active()) @import("calendar.zig").refresh();
    return 1;
}

fn call(method: [*:0]const u8) void {
    bus.call(dest, path, iface, method, null, null, null);
}

// ---- The card ----------------------------------------------------------------------------

const art_size: f32 = 112;
pub const height: f32 = 176;

fn formatTime(us: i64, buf: []u8) [*:0]const u8 {
    const total: u64 = @intCast(@divTrunc(@max(us, 0), 1_000_000));
    const text = std.fmt.bufPrintZ(buf, "{d}:{d:0>2}", .{ @divTrunc(total, 60), @mod(total, 60) }) catch return "";
    return text.ptr;
}

/// A pill with a label, and an icon before it when `icon` isn't empty (a file
/// path or an icon name).
fn chip(text: [*:0]const u8, icon: [*:0]const u8, color: u32, max_w: f32) *c.ClutterActor {
    const icon_size: f32 = 16;
    const label = ui.label(text, config.font(.regular, -1));
    const lead: f32 = if (icon[0] != 0) icon_size + 6 else 0;
    const w = @min(ui.preferredWidth(label), max_w - lead);
    c.clutter_actor_set_width(label, w);
    const h = @max(ui.preferredHeight(label), icon_size) + 8;
    const pill = ui.roundedRect(w + lead + 20, h, h / 2, color);
    if (icon[0] != 0) {
        const glyph = if (icon[0] == '/') ui.image(icon, icon_size) else ui.icon(icon, icon_size, false, 0);
        c.clutter_actor_set_position(glyph, 8, (h - icon_size) / 2);
        c.clutter_actor_add_child(pill, glyph);
    }
    c.clutter_actor_set_position(label, 10 + lead, (h - ui.preferredHeight(label)) / 2);
    c.clutter_actor_add_child(pill, label);
    return pill;
}

fn button(icon_name: [*:0]const u8, w: f32, h: f32, color: u32, handler: anytype) *c.ClutterActor {
    const b = ui.roundedRect(w, h, config.radius(0.6), color);
    const glyph = ui.icon(icon_name, 16, true, 0xffffff);
    ui.center(glyph, b, c.CLUTTER_ALIGN_BOTH);
    c.clutter_actor_add_child(b, glyph);
    c.clutter_actor_set_reactive(b, 1);
    plugin.connect(b, "button-release-event", handler, null);
    return b;
}

/// The media card, `width` wide (inspired by DankLinuxShell's media tab).
pub fn card(width: f32) *c.ClutterActor {
    const k = ui.roundedRect(width, height, config.radius(0.8), 0xffffff12);
    const pad: f32 = 14;

    // Artwork, or a music note.
    const art: *c.ClutterActor = if (state.art[0] != 0) ui.image(@ptrCast(&state.art), art_size) else blk: {
        const box = ui.roundedRect(art_size, art_size, config.radius(0.6), 0xffffff1a);
        const note = ui.icon("audio-x-generic-symbolic", 40, true, 0xffffff);
        ui.center(note, box, c.CLUTTER_ALIGN_BOTH);
        c.clutter_actor_add_child(box, note);
        break :blk box;
    };
    c.clutter_actor_set_position(art, pad, pad);
    c.clutter_actor_add_child(k, art);

    const tx = pad + art_size + 14;
    const tw = width - tx - pad;
    var buf: [160]u8 = undefined;
    _ = std.fmt.bufPrintZ(&buf, "Listening from {s}", .{std.mem.sliceTo(&state.identity, 0)}) catch {
        @memcpy(buf[0..10], "Listening\x00");
    };
    const several = playerCount() > 1;
    if (several) {
        const n = std.mem.indexOfScalar(u8, &buf, 0) orelse 0;
        if (n + 4 < buf.len) {
            @memcpy(buf[n .. n + 4], " \u{25be}"[0..4]); // ▾: there's a choice
            buf[n + 4] = 0;
        }
    }
    const from = chip(@ptrCast(&buf), @ptrCast(&state.icon), (ui.accent & 0xffffff00) | 0x66, tw - 20);
    c.clutter_actor_set_position(from, tx, pad);
    if (several) {
        c.clutter_actor_set_reactive(from, 1);
        ui.accessible(from, c.ATK_ROLE_PUSH_BUTTON, "Choose which player to control");
        plugin.connect(from, "button-release-event", &onPickPlayer, null);
    }
    c.clutter_actor_add_child(k, from);

    const title = ui.label(@ptrCast(&state.title), config.font(.bold, 3));
    c.clutter_actor_set_width(title, @min(ui.preferredWidth(title), tw));
    c.clutter_actor_set_position(title, tx, pad + 32);
    c.clutter_actor_add_child(k, title);
    const artist = ui.label(@ptrCast(&state.artist), config.font(.regular, -1));
    c.clutter_actor_set_opacity(artist, 190);
    c.clutter_actor_set_width(artist, @min(ui.preferredWidth(artist), tw));
    c.clutter_actor_set_position(artist, tx, pad + 56);
    c.clutter_actor_add_child(k, artist);

    // Controls: previous, play/pause (accent), next.
    const by = pad + 82;
    const bh: f32 = 34;
    const side = (tw - 16) / 4;
    const prev = button("media-skip-backward-symbolic", side, bh, 0xffffff1a, &onPrevious);
    const play = button(if (state.playing) "media-playback-pause-symbolic" else "media-playback-start-symbolic", tw - 2 * side - 16, bh, ui.accent, &onPlayPause);
    const next = button("media-skip-forward-symbolic", side, bh, 0xffffff1a, &onNext);
    c.clutter_actor_set_position(prev, tx, by);
    c.clutter_actor_set_position(play, tx + side + 8, by);
    c.clutter_actor_set_position(next, tx + tw - side, by);
    for ([_]*c.ClutterActor{ prev, play, next }) |b| c.clutter_actor_add_child(k, b);

    // Seek bar with times; the output device under the artwork.
    const sy = height - pad - 12;
    var t1: [16]u8 = undefined;
    var t2: [16]u8 = undefined;
    const now = ui.label(formatTime(position(), &t1), config.font(.regular, -2));
    const total = ui.label(formatTime(state.length, &t2), config.font(.regular, -2));
    c.clutter_actor_set_opacity(now, 180);
    c.clutter_actor_set_opacity(total, 180);
    c.clutter_actor_set_position(now, tx, sy - 6);
    c.clutter_actor_set_position(total, width - pad - ui.preferredWidth(total), sy - 6);
    c.clutter_actor_add_child(k, now);
    c.clutter_actor_add_child(k, total);
    const bar_x = tx + ui.preferredWidth(now) + 10;
    const bar_w = width - pad - ui.preferredWidth(total) - 10 - bar_x;
    const track = ui.roundedRect(bar_w, 4, 2, 0xffffff33);
    c.clutter_actor_set_position(track, bar_x, sy);
    c.clutter_actor_add_child(k, track);
    if (state.length > 0) {
        const frac = std.math.clamp(@as(f32, @floatFromInt(position())) / @as(f32, @floatFromInt(state.length)), 0, 1);
        const fill = ui.roundedRect(@max(4, frac * bar_w), 4, 2, ui.accent);
        c.clutter_actor_add_child(track, fill);
    }
    if (state.output[0] != 0) {
        const out = chip(@ptrCast(&state.output), "audio-headphones-symbolic", 0xffffff1a, art_size - 20);
        c.clutter_actor_set_position(out, pad, height - pad - c.clutter_actor_get_height(out) + 2);
        c.clutter_actor_add_child(k, out);
        c.clutter_actor_set_y(art, pad - 4);
        c.clutter_actor_set_size(art, art_size - 18, art_size - 18);
        c.clutter_actor_set_x(art, pad + 9);
    }
    return k;
}

fn onPlayPause(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    state.playing = !state.playing;
    call("MediaPlayPause");
    @import("calendar.zig").refresh();
    return 1;
}

fn onNext(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    call("MediaNext");
    return 1;
}

fn onPrevious(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    call("MediaPrevious");
    return 1;
}

// ---- Several players ---------------------------------------------------------------------

fn playerCount() usize {
    const text = std.mem.sliceTo(&state.players, 0);
    if (text.len == 0) return 0;
    return std.mem.count(u8, text, "\n") + 1;
}

var menu_names: [8][128]u8 = undefined;
var menu_labels: [8][128]u8 = undefined;

fn onPickPlayer(actor: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    var labels: [8][*:0]const u8 = undefined;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.sliceTo(&state.players, 0), '\n');
    while (lines.next()) |line| {
        if (n == labels.len) break;
        var parts = std.mem.splitScalar(u8, line, '\t');
        const name = parts.next() orelse continue;
        const app = parts.next() orelse name;
        const ln = @min(app.len, 127);
        @memcpy(menu_labels[n][0..ln], app[0..ln]);
        menu_labels[n][ln] = 0;
        const nn = @min(name.len, 127);
        @memcpy(menu_names[n][0..nn], name[0..nn]);
        menu_names[n][nn] = 0;
        labels[n] = @ptrCast(&menu_labels[n]);
        n += 1;
    }
    var x: f32 = 0;
    var y: f32 = 0;
    c.clutter_actor_get_transformed_position(actor, &x, &y);
    ui.menu(x, y + 30, labels[0..n], &onPlayerChosen);
    return 1;
}

fn onPlayerChosen(index: usize) void {
    bus.call(dest, path, iface, "MediaSelect", c.g_variant_new("(s)", @as([*:0]const u8, @ptrCast(&menu_names[index]))), null, null);
    // Reopen the date menu on the new player.
    _ = c.g_timeout_add(150, &reopen, null);
}

fn reopen(_: c.gpointer) callconv(.C) c.gboolean {
    @import("calendar.zig").toggle();
    return 0;
}

// ---- Top bar chip (media-in-top-bar) ------------------------------------------------------

var shown_in_bar = false;

/// Shows "♪ Title – Artist" in the top bar while something is playing.
pub fn updateTopBar() void {
    const items = @import("panelitems.zig");
    const want = config.media_top_bar and active() and state.playing;
    if (!want) {
        if (shown_in_bar) items.removeLocal("media");
        shown_in_bar = false;
        return;
    }
    var buf: [200]u8 = undefined;
    const artist = std.mem.sliceTo(&state.artist, 0);
    const title = std.mem.sliceTo(&state.title, 0);
    const text = (if (artist.len > 0)
        std.fmt.bufPrintZ(&buf, "{s} \u{2013} {s}", .{ title[0..@min(title.len, 40)], artist[0..@min(artist.len, 30)] })
    else
        std.fmt.bufPrintZ(&buf, "{s}", .{title[0..@min(title.len, 60)]})) catch return;
    items.setLocal("media", "audio-x-generic-symbolic", text.ptr, "Now playing", &openCalendar);
    shown_in_bar = true;
}

fn openCalendar() void {
    @import("calendar.zig").toggle();
}
