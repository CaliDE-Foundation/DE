//! Small UI helpers on top of Clutter: textures from cali-shell pixels,
//! rounded shapes, icons and labels.

const std = @import("std");
const c = @import("plugin.zig").c;

/// Textures are rendered at this multiple of their logical size so they stay
/// sharp when scaled.
const render_scale = 2;

var stage: ?*c.ClutterActor = null;

pub fn init(s: ?*c.ClutterActor) void {
    stage = s;
}

/// Uploads premultiplied RGBA pixels as content for an actor.
pub fn contentFromPixels(width: c_int, height: c_int, pixels: [*]const u8) ?*c.ClutterContent {
    const s = stage orelse return null;
    const ctx = c.clutter_backend_get_cogl_context(c.clutter_context_get_backend(c.clutter_actor_get_context(s)));
    var err: ?*c.GError = null;
    const texture = c.cogl_texture_2d_new_from_data(ctx, width, height, @intCast(c.COGL_PIXEL_FORMAT_RGBA_8888_PRE), width * 4, pixels, @ptrCast(&err));
    if (texture == null) {
        if (err) |e| c.g_error_free(e);
        return null;
    }
    defer c.g_object_unref(texture);
    return c.clutter_texture_content_new_from_texture(texture, null);
}

fn withContent(width: f32, height: f32, content: ?*c.ClutterContent) *c.ClutterActor {
    const actor = c.clutter_actor_new();
    c.clutter_actor_set_size(actor, width, height);
    if (content) |cnt| {
        c.clutter_actor_set_content(actor, cnt);
        c.g_object_unref(cnt);
    }
    c.clutter_actor_set_content_scaling_filters(actor, @intCast(c.CLUTTER_SCALING_FILTER_TRILINEAR), @intCast(c.CLUTTER_SCALING_FILTER_LINEAR));
    return actor;
}

/// An actor showing a rounded rectangle. `rgba` is 0xRRGGBBAA.
pub fn roundedRect(width: f32, height: f32, radius: f32, rgba: u32) *c.ClutterActor {
    const w: c_uint = @intFromFloat(@ceil(width * render_scale));
    const h: c_uint = @intFromFloat(@ceil(height * render_scale));
    const len = @as(usize, w) * h * 4;
    var content: ?*c.ClutterContent = null;
    if (len > 0) {
        if (std.heap.c_allocator.alloc(u8, len)) |buf| {
            defer std.heap.c_allocator.free(buf);
            if (c.cali_shell_render_rounded_rect(w, h, radius * render_scale, rgba, buf.ptr, len)) {
                content = contentFromPixels(@intCast(w), @intCast(h), buf.ptr);
            }
        } else |_| {}
    }
    return withContent(width, height, content);
}

/// An actor showing icon `name`. With `recolor`, a symbolic icon is painted
/// `rgb` (0xRRGGBB).
pub fn icon(name: [*:0]const u8, size: f32, recolor: bool, rgb: u32) *c.ClutterActor {
    const px: c_uint = @intFromFloat(@ceil(size * render_scale));
    const len = @as(usize, px) * px * 4;
    var content: ?*c.ClutterContent = null;
    if (std.heap.c_allocator.alloc(u8, len)) |buf| {
        defer std.heap.c_allocator.free(buf);
        if (c.cali_shell_load_icon(name, px, recolor, rgb, buf.ptr, len)) {
            content = contentFromPixels(@intCast(px), @intCast(px), buf.ptr);
        }
    } else |_| {}
    return withContent(size, size, content);
}

pub const white = c.CoglColor{ .red = 255, .green = 255, .blue = 255, .alpha = 255 };

pub fn label(text: [*:0]const u8, font: [*:0]const u8) *c.ClutterActor {
    const actor = c.clutter_text_new_full(font, text, &white);
    c.clutter_text_set_ellipsize(@ptrCast(@alignCast(actor)), @intCast(c.PANGO_ELLIPSIZE_END));
    return actor;
}

pub fn preferredWidth(actor: ?*c.ClutterActor) f32 {
    var min: f32 = 0;
    var natural: f32 = 0;
    c.clutter_actor_get_preferred_width(actor, -1, &min, &natural);
    return natural;
}

pub fn preferredHeight(actor: ?*c.ClutterActor) f32 {
    var min: f32 = 0;
    var natural: f32 = 0;
    c.clutter_actor_get_preferred_height(actor, -1, &min, &natural);
    return natural;
}

/// Centers `child` in `parent` on the given axis (or both) and keeps it there.
pub fn center(child: ?*c.ClutterActor, parent: ?*c.ClutterActor, axis: c_uint) void {
    c.clutter_actor_add_constraint(child, c.clutter_align_constraint_new(parent, @intCast(axis), 0.5));
}

/// Starts an easing block; finish it with `c.clutter_actor_restore_easing_state`.
pub fn ease(actor: ?*c.ClutterActor, ms: c_uint, mode: c_uint) void {
    c.clutter_actor_save_easing_state(actor);
    c.clutter_actor_set_easing_mode(actor, @intCast(mode));
    c.clutter_actor_set_easing_duration(actor, ms);
}

/// Launches an app inside this session (Sookie's launch context points it at
/// our Wayland display, not whatever started us).
pub fn launch(display: ?*c.MetaDisplay, info: ?*c.GAppInfo) void {
    const launcher = c.meta_startup_notification_create_launcher(c.meta_display_get_startup_notification(display));
    defer c.g_object_unref(launcher);
    var err: ?*c.GError = null;
    if (c.g_app_info_launch(info, null, @ptrCast(@alignCast(launcher)), @ptrCast(&err)) == 0) {
        if (err) |e| {
            std.log.warn("could not launch {s}: {s}", .{ c.g_app_info_get_id(info), e.message });
            c.g_error_free(e);
        }
    }
}

/// Opens an app by desktop file ID. Returns false if it isn't installed.
pub fn launchId(display: ?*c.MetaDisplay, id: [*:0]const u8) bool {
    const info = c.g_desktop_app_info_new(id) orelse return false;
    defer c.g_object_unref(info);
    launch(display, @ptrCast(@alignCast(info)));
    return true;
}
