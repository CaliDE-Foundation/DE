//! On-screen display for volume and brightness: a pill near the bottom of
//! the screen with an icon and a level bar. It fades out after a moment.

const std = @import("std");
const plugin = @import("plugin.zig");
const ui = @import("ui.zig");
const c = plugin.c;

const width: f32 = 300;
const height: f32 = 56;
const bar_x: f32 = 54;
const bar_w: f32 = width - bar_x - 22;
const bar_h: f32 = 6;
const visible_ms = 1500;

var stage: ?*c.ClutterActor = null;
var card: ?*c.ClutterActor = null;
var track: ?*c.ClutterActor = null;
var fill: ?*c.ClutterActor = null;
var icon: ?*c.ClutterActor = null;
var hide_source: c_uint = 0;

pub fn init(s: ?*c.ClutterActor) void {
    stage = s;
    // CALI_DEBUG_OSD=<seconds> shows a volume OSD, for testing.
    if (std.posix.getenv("CALI_DEBUG_OSD")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugShow, null);
    }
}

fn debugShow(_: c.gpointer) callconv(.C) c.gboolean {
    show(c.cali_shell_volume_icon(0.6, false), 0.6);
    return 0;
}

/// Shows `icon_name` with `level` (0-1; negative hides the bar).
pub fn show(icon_name: [*:0]const u8, level: f32) void {
    const s = stage orelse return;
    if (card == null) build(s);
    const k = card orelse return;

    if (icon) |old| c.clutter_actor_destroy(old);
    const glyph = ui.icon(icon_name, 20, true, 0xffffff);
    c.clutter_actor_set_position(glyph, 20, (height - 20) / 2);
    c.clutter_actor_add_child(k, glyph);
    icon = glyph;

    if (track) |t| {
        c.clutter_actor_set_opacity(t, if (level >= 0) 255 else 0);
        // Re-render the fill at its exact width so the rounded ends stay round.
        if (fill) |old| c.clutter_actor_destroy(old);
        const f = ui.roundedRect(@max(bar_h, std.math.clamp(level, 0, 1) * bar_w), bar_h, bar_h / 2, 0xffffffff);
        c.clutter_actor_add_child(t, f);
        fill = f;
    }

    c.clutter_actor_set_child_above_sibling(s, k, null);
    ui.ease(k, 120, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(k, 255);
    c.clutter_actor_restore_easing_state(k);

    if (hide_source != 0) _ = c.g_source_remove(hide_source);
    hide_source = c.g_timeout_add(visible_ms, &fadeOut, null);
}

fn build(s: *c.ClutterActor) void {
    var sw: f32 = 0;
    var sh: f32 = 0;
    c.clutter_actor_get_size(s, &sw, &sh);
    const k = ui.roundedRect(width, height, height / 2, 0x2e2e32f0);
    c.clutter_actor_set_position(k, (sw - width) / 2, sh - height - 96);
    c.clutter_actor_set_opacity(k, 0);

    const t = ui.roundedRect(bar_w, bar_h, bar_h / 2, 0xffffff40);
    c.clutter_actor_set_position(t, bar_x, (height - bar_h) / 2);
    c.clutter_actor_add_child(k, t);

    c.clutter_actor_add_child(s, k);
    card = k;
    track = t;
}

fn fadeOut(_: c.gpointer) callconv(.C) c.gboolean {
    hide_source = 0;
    if (card) |k| {
        ui.ease(k, 250, c.CLUTTER_EASE_OUT_QUAD);
        c.clutter_actor_set_opacity(k, 0);
        c.clutter_actor_restore_easing_state(k);
    }
    return 0;
}
