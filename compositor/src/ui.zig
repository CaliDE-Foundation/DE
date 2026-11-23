//! Small UI helpers on top of Clutter: textures from cali-shell pixels,
//! rounded shapes, icons and labels.

const std = @import("std");
const c = @import("plugin.zig").c;

/// Textures are rendered at this multiple of their logical size so they stay
/// sharp when scaled.
const render_scale = 2;

var stage: ?*c.ClutterActor = null;

/// Animation speed from settings (1 = normal, 0 = off).
pub var speed: f32 = 1.0;
/// Accent color from settings, 0xRRGGBBAA.
pub var accent: u32 = 0xe2725bff;

/// A duration scaled by the animation speed. Never 0: effects wait for
/// "transitions-completed", which an instant change wouldn't send.
pub fn ms(base: c_uint) c_uint {
    if (speed <= 0.01) return 1;
    const scaled = @as(f32, @floatFromInt(base)) / speed;
    return @max(1, @as(c_uint, @intFromFloat(@min(scaled, 10000))));
}

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
pub fn ease(actor: ?*c.ClutterActor, duration: c_uint, mode: c_uint) void {
    c.clutter_actor_save_easing_state(actor);
    c.clutter_actor_set_easing_mode(actor, @intCast(mode));
    c.clutter_actor_set_easing_duration(actor, ms(duration));
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

// ---- Popups ---------------------------------------------------------------------------
// One popup at a time (system menu, calendar, ...). It takes all input until
// closed; a click outside it or Escape closes it.

const plugin = @import("plugin.zig");

var popup_catcher: ?*c.ClutterActor = null;
var popup_content: ?*c.ClutterActor = null;
var popup_grab: ?*c.ClutterGrab = null;
var popup_on_close: ?*const fn () void = null;

pub fn popupIsOpen() bool {
    return popup_catcher != null;
}

/// Shows `content` (already positioned in stage coordinates) as the popup,
/// closing any other popup first. `on_close` runs when it closes.
pub fn openPopup(content: *c.ClutterActor, on_close: ?*const fn () void) void {
    closePopup();
    const s = stage orelse return;
    var w: f32 = 0;
    var h: f32 = 0;
    c.clutter_actor_get_size(s, &w, &h);

    const catcher = c.clutter_actor_new();
    c.clutter_actor_set_size(catcher, w, h);
    c.clutter_actor_set_reactive(catcher, 1);
    c.clutter_actor_add_child(s, catcher);
    plugin.connect(catcher, "button-release-event", &onPopupOutside, null);
    plugin.connect(catcher, "key-press-event", &onPopupKey, null);
    popup_grab = c.clutter_stage_grab(@ptrCast(@alignCast(s)), catcher);
    c.clutter_stage_set_key_focus(@ptrCast(@alignCast(s)), catcher);
    popup_catcher = catcher;
    popup_on_close = on_close;

    setPopupContent(content);

    // Grow in from the top.
    c.clutter_actor_set_pivot_point(content, 0.5, 0.0);
    c.clutter_actor_set_opacity(content, 0);
    c.clutter_actor_set_scale(content, 0.95, 0.95);
    ease(content, 150, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(content, 255);
    c.clutter_actor_set_scale(content, 1.0, 1.0);
    c.clutter_actor_restore_easing_state(content);
}

/// Swaps what the open popup shows (e.g. the next month, a confirmation).
pub fn setPopupContent(content: *c.ClutterActor) void {
    const catcher = popup_catcher orelse return;
    if (popup_content) |old| c.clutter_actor_destroy(old);
    c.clutter_actor_set_reactive(content, 1); // clicks inside don't close it
    plugin.connect(content, "button-release-event", &swallowClick, null);
    c.clutter_actor_add_child(catcher, content);
    popup_content = content;
}

pub fn closePopup() void {
    if (popup_grab) |g| {
        c.clutter_grab_dismiss(g);
        c.g_object_unref(g);
        popup_grab = null;
    }
    const catcher = popup_catcher orelse return;
    popup_catcher = null;
    popup_content = null;
    c.clutter_actor_destroy(catcher);
    const on_close = popup_on_close;
    popup_on_close = null;
    if (on_close) |f| f();
}

fn swallowClick(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    return 1;
}

fn onPopupOutside(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    closePopup();
    return 1;
}

fn onPopupKey(_: ?*c.ClutterActor, event: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    if (c.clutter_event_get_key_symbol(event) == c.CLUTTER_KEY_Escape) {
        closePopup();
        return 1;
    }
    return 0;
}

/// A rounded button showing a white symbolic icon; `handler` gets `data`.
pub fn iconButton(name: [*:0]const u8, size: f32, handler: anytype, data: c.gpointer) *c.ClutterActor {
    const button = roundedRect(size, size, size / 2, 0xffffff14);
    const glyph = icon(name, 16, true, 0xffffff);
    center(glyph, button, c.CLUTTER_ALIGN_BOTH);
    c.clutter_actor_add_child(button, glyph);
    c.clutter_actor_set_reactive(button, 1);
    plugin.connect(button, "button-release-event", handler, data);
    return button;
}

// ---- Context menus ------------------------------------------------------------------------

pub const MenuCallback = *const fn (index: usize) void;
var menu_callback: ?MenuCallback = null;

/// A small menu at (x, y) with `labels`; `callback` gets the chosen index.
pub fn menu(x: f32, y: f32, labels: []const [*:0]const u8, callback: MenuCallback) void {
    const s = stage orelse return;
    const row_h: f32 = 36;
    const pad: f32 = 6;
    var w: f32 = 160;
    for (labels) |l| {
        const probe = label(l, "Adwaita Sans 11");
        w = @max(w, preferredWidth(probe) + 40);
        c.clutter_actor_destroy(probe);
    }
    const h = @as(f32, @floatFromInt(labels.len)) * row_h + 2 * pad;
    var sw: f32 = 0;
    var sh: f32 = 0;
    c.clutter_actor_get_size(s, &sw, &sh);

    const card = roundedRect(w, h, 14, 0x2e2e32f8);
    c.clutter_actor_set_position(card, @min(x, sw - w - 4), @min(y, sh - h - 4));
    for (labels, 0..) |l, i| {
        const row = c.clutter_actor_new();
        c.clutter_actor_set_position(row, pad, pad + @as(f32, @floatFromInt(i)) * row_h);
        c.clutter_actor_set_size(row, w - 2 * pad, row_h);
        const hover = roundedRect(w - 2 * pad, row_h, 9, 0xffffff1f);
        c.clutter_actor_set_opacity(hover, 0);
        c.clutter_actor_add_child(row, hover);
        const text = label(l, "Adwaita Sans 11");
        c.clutter_actor_set_x(text, 14);
        center(text, row, c.CLUTTER_ALIGN_Y_AXIS);
        c.clutter_actor_add_child(row, text);
        c.clutter_actor_set_reactive(row, 1);
        plugin.connect(row, "enter-event", &onMenuEnter, hover);
        plugin.connect(row, "leave-event", &onMenuLeave, hover);
        plugin.connect(row, "button-release-event", &onMenuRow, @ptrFromInt(i + 1));
        c.clutter_actor_add_child(card, row);
    }
    menu_callback = callback;
    openPopup(card, null);
}

fn onMenuRow(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, data: c.gpointer) callconv(.C) c.gboolean {
    const cb = menu_callback;
    closePopup();
    if (cb) |f| f(@intFromPtr(data) - 1);
    return 1;
}

fn onMenuEnter(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, hover: c.gpointer) callconv(.C) c.gboolean {
    c.clutter_actor_set_opacity(@ptrCast(@alignCast(hover)), 255);
    return 0;
}

fn onMenuLeave(_: ?*c.ClutterActor, _: ?*c.ClutterEvent, hover: c.gpointer) callconv(.C) c.gboolean {
    c.clutter_actor_set_opacity(@ptrCast(@alignCast(hover)), 0);
    return 0;
}

/// Where a pointer event happened, in stage coordinates.
pub fn eventPosition(event: ?*c.ClutterEvent) [2]f32 {
    var x: f32 = 0;
    var y: f32 = 0;
    c.clutter_event_get_coords(event, &x, &y);
    return .{ x, y };
}

/// Right mouse button?
pub fn isSecondary(event: ?*c.ClutterEvent) bool {
    return c.clutter_event_get_button(event) == 3;
}
