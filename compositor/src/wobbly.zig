//! Wobbly windows: while you drag a window it bends like jelly, and wobbles
//! back into shape when you let go. A ClutterDeformEffect subclass bends the
//! window's mesh; the spring math lives in cali-shell (Rust).

const std = @import("std");
const plugin = @import("plugin.zig");
const config = @import("config.zig");
const c = plugin.c;

const effect_name = "cali-wobbly";
const tiles = 10;
const frame_ms = 16;

/// The effect instance: Clutter's deform effect plus our spring state.
const Wobbly = extern struct {
    parent: c.ClutterDeformEffect,
    state: c.CaliWobble,
    grab_x: f32,
    grab_y: f32,
};

var effect_type: c.GType = 0;
var logged_vertex = false;

fn getType() c.GType {
    if (effect_type == 0) {
        effect_type = c.g_type_register_static_simple(
            c.clutter_deform_effect_get_type(),
            "CaliWobblyEffect",
            @sizeOf(c.ClutterDeformEffectClass),
            &classInit,
            @sizeOf(Wobbly),
            null,
            0,
        );
    }
    return effect_type;
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.C) void {
    const k: *c.ClutterDeformEffectClass = @ptrCast(@alignCast(klass));
    k.deform_vertex = &deformVertex;
    const effect_class: *c.ClutterEffectClass = @ptrCast(@alignCast(klass));
    effect_class.modify_paint_volume = &modifyPaintVolume;
}

/// The bent corners reach outside the window; grow the area Clutter redraws
/// so they don't leave trails behind.
fn modifyPaintVolume(_: ?*c.ClutterEffect, volume: ?*c.ClutterPaintVolume) callconv(.C) c.gboolean {
    const v = volume orelse return 1;
    const pad: f32 = 170; // a little over the largest lag (cali-shell's MAX_LAG)
    var origin: c.graphene_point3d_t = undefined;
    c.clutter_paint_volume_get_origin(v, &origin);
    origin.x -= pad;
    origin.y -= pad;
    const w = c.clutter_paint_volume_get_width(v);
    const h = c.clutter_paint_volume_get_height(v);
    c.clutter_paint_volume_set_origin(v, &origin);
    c.clutter_paint_volume_set_width(v, w + 2 * pad);
    c.clutter_paint_volume_set_height(v, h + 2 * pad);
    return 1;
}

fn deformVertex(deform: ?*c.ClutterDeformEffect, width: f32, height: f32, vertex: ?*c.ClutterTextureVertex) callconv(.C) void {
    const self: *Wobbly = @ptrCast(@alignCast(deform));
    const v = vertex orelse return;
    if (!logged_vertex) {
        logged_vertex = true;
        std.log.debug("wobbly: deform_vertex called {d}x{d}", .{ width, height });
    }
    var ox: f32 = 0;
    var oy: f32 = 0;
    c.cali_shell_wobble_offset(&self.state, v.*.x, v.*.y, self.grab_x, self.grab_y, width, height, &ox, &oy);
    v.*.x += ox;
    v.*.y += oy;
}

// ---- Driving it -----------------------------------------------------------------------

var display: ?*c.MetaDisplay = null;
var window: ?*c.MetaWindow = null; // the one wobbling
var effect: ?*Wobbly = null;
var dragging = false;
var last_x: c_int = 0;
var last_y: c_int = 0;
var timer: c_uint = 0;
var tick_count: u32 = 0;

pub fn init(d: ?*c.MetaDisplay) void {
    display = d;
    plugin.connect(d, "grab-op-begin", &onGrabBegin, null);
    plugin.connect(d, "grab-op-end", &onGrabEnd, null);
    // CALI_DEBUG_WOBBLE=<seconds>: drag the focused window around by script.
    if (std.posix.getenv("CALI_DEBUG_WOBBLE")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugStart, null);
    }
}

fn isMove(op: c_uint) bool {
    return op == c.META_GRAB_OP_MOVING or op == c.META_GRAB_OP_KEYBOARD_MOVING or op == c.META_GRAB_OP_MOVING_UNCONSTRAINED;
}

fn onGrabBegin(_: ?*c.MetaDisplay, w: ?*c.MetaWindow, op: c_uint, _: ?*anyopaque, _: c.gpointer) callconv(.C) void {
    if (!config.wobbly or !isMove(op)) return;
    start(w orelse return);
}

fn onGrabEnd(_: ?*c.MetaDisplay, w: ?*c.MetaWindow, _: c_uint, _: c.gpointer) callconv(.C) void {
    if (w == window) dragging = false;
}

fn start(w: *c.MetaWindow) void {
    stop();
    const actor: *c.ClutterActor = @ptrCast(@alignCast(c.meta_window_get_compositor_private(w) orelse return));
    const e: *Wobbly = @ptrCast(@alignCast(c.g_object_new(getType(), null)));
    e.state = std.mem.zeroes(c.CaliWobble);

    // Bend around the point under the pointer (window-relative).
    var pos = c.graphene_point_t{ .x = 0, .y = 0 };
    if (display) |d| {
        const backend = c.meta_context_get_backend(c.meta_display_get_context(d));
        c.meta_cursor_tracker_get_pointer(c.meta_backend_get_cursor_tracker(backend), &pos, null);
    }
    var ax: f32 = 0;
    var ay: f32 = 0;
    c.clutter_actor_get_position(actor, &ax, &ay);
    var aw: f32 = 0;
    var ah: f32 = 0;
    c.clutter_actor_get_size(actor, &aw, &ah);
    e.grab_x = pos.x - ax;
    e.grab_y = pos.y - ay;
    // Pointer not on the window (a keyboard move, or a scripted one): bend
    // around the middle of the titlebar, where windows are usually grabbed.
    if (e.grab_x < 0 or e.grab_y < 0 or e.grab_x > aw or e.grab_y > ah) {
        e.grab_x = aw / 2;
        e.grab_y = 40;
    }

    c.clutter_deform_effect_set_n_tiles(@ptrCast(e), tiles, tiles);
    // Effects start with a floating reference; the actor sinks it and owns it.
    c.clutter_actor_add_effect_with_name(actor, effect_name, @ptrCast(e));
    effect = e;
    window = w;
    dragging = true;
    var rect: c.MtkRectangle = undefined;
    c.meta_window_get_frame_rect(w, &rect);
    last_x = rect.x;
    last_y = rect.y;
    timer = c.g_timeout_add(frame_ms, &tick, null);
    std.log.debug("wobbly: started", .{});
}

fn stop() void {
    if (timer != 0) _ = c.g_source_remove(timer);
    timer = 0;
    if (window) |w| {
        if (c.meta_window_get_compositor_private(w)) |obj| {
            c.clutter_actor_remove_effect_by_name(@ptrCast(@alignCast(obj)), effect_name);
        }
    }
    window = null;
    effect = null;
    dragging = false;
}

fn tick(_: c.gpointer) callconv(.C) c.gboolean {
    const w = window orelse return 0;
    const e = effect orelse return 0;
    var rect: c.MtkRectangle = undefined;
    c.meta_window_get_frame_rect(w, &rect);
    const dx: f32 = @floatFromInt(rect.x - last_x);
    const dy: f32 = @floatFromInt(rect.y - last_y);
    last_x = rect.x;
    last_y = rect.y;
    if (frozen) return 1; // debug: hold the current bend for a screenshot
    const settled = c.cali_shell_wobble_step(&e.state, dx, dy, @as(f32, frame_ms) / 1000.0, config.wobbly_strength, config.wobbly_friction);
    c.clutter_deform_effect_invalidate(@ptrCast(e));
    tick_count += 1;
    if (tick_count % 20 == 0) std.log.debug("wobbly: dx={d} lag={d:.1},{d:.1}", .{ dx, e.state.lag_x, e.state.lag_y });
    if (!dragging and settled) {
        timer = 0; // this source ends now
        stop();
        return 0;
    }
    return 1;
}

// ---- Debug: a scripted drag ---------------------------------------------------------------

var debug_steps: u32 = 0;
var frozen = false;

fn debugStart(_: c.gpointer) callconv(.C) c.gboolean {
    const d = display orelse return 0;
    const w = c.meta_display_get_focus_window(d) orelse return 0;
    start(w);
    debug_steps = 0;
    _ = c.g_timeout_add(frame_ms, &debugMove, null);
    return 0;
}

fn debugMove(_: c.gpointer) callconv(.C) c.gboolean {
    const w = window orelse return 0;
    var rect: c.MtkRectangle = undefined;
    c.meta_window_get_frame_rect(w, &rect);
    // Sweep right for ~2.4 s, then let go.
    c.meta_window_move_frame(w, 1, rect.x - 9, rect.y + 2); // like a pointer drag (a user move)
    debug_steps += 1;
    // CALI_DEBUG_WOBBLE_FREEZE: stop mid-drag and hold the bend still.
    if (debug_steps == 30 and std.posix.getenv("CALI_DEBUG_WOBBLE_FREEZE") != null) {
        frozen = true;
        std.log.debug("wobbly: frozen lag={d:.1},{d:.1}", .{ effect.?.state.lag_x, effect.?.state.lag_y });
        return 0;
    }
    if (debug_steps < 150) return 1;
    dragging = false;
    std.log.debug("wobbly: let go", .{});
    return 0;
}
