//! Lock screen and idle: Super+L (or idle time) locks; the password is
//! checked through PAM by cali-shell on a thread. While locked, windows and
//! the top bar are hidden, all input goes to the lock screen and every
//! keybinding is blocked (plugin keybinding filter).

const std = @import("std");
const plugin = @import("plugin.zig");
const ui = @import("ui.zig");
const c = plugin.c;
const config = @import("config.zig");

pub var locked = false;

var display: ?*c.MetaDisplay = null;
var stage: ?*c.ClutterActor = null;
var panel: ?*c.ClutterActor = null;
var action_lock: c_uint = 0;

var screen: ?*c.ClutterActor = null;
var grab: ?*c.ClutterGrab = null;
var entry: ?*c.ClutterActor = null;
var message: ?*c.ClutterActor = null;
var clock_label: ?*c.ClutterActor = null;
var date_label: ?*c.ClutterActor = null;
var timer: c_uint = 0;
var checking = false;

// Idle
var idle_minutes: f64 = 5;
var lock_on_idle = true;
var idle_watch: c_uint = 0;
var active_watch: c_uint = 0;
var blanker: ?*c.ClutterActor = null;

pub fn init(d: ?*c.MetaDisplay, s: ?*c.ClutterActor, p: ?*c.ClutterActor) void {
    display = d;
    stage = s;
    panel = p;
    @import("keys.zig").bind(d, "key-lock", "<Super>l", &action_lock);
    plugin.connect(d, "accelerator-activated", &onAccelerator, null);
    setIdle(idle_minutes, lock_on_idle);

    // CALI_DEBUG_LOCK=<seconds> locks; CALI_DEBUG_UNLOCK=<password> then
    // types it in 3 seconds later.
    if (std.posix.getenv("CALI_DEBUG_LOCK")) |value| {
        const seconds = std.fmt.parseInt(c_uint, value, 10) catch 3;
        _ = c.g_timeout_add_seconds(seconds, &debugLock, null);
    }
}

fn onAccelerator(_: ?*c.MetaDisplay, action: c_uint, _: ?*c.ClutterInputDevice, _: c_uint, _: c.gpointer) callconv(.C) void {
    if (action != 0 and action == action_lock) lock();
}

fn debugLock(_: c.gpointer) callconv(.C) c.gboolean {
    lock();
    if (std.posix.getenv("CALI_DEBUG_UNLOCK") != null) _ = c.g_timeout_add_seconds(3, &debugType, null);
    return 0;
}

fn debugType(_: c.gpointer) callconv(.C) c.gboolean {
    const password = std.posix.getenv("CALI_DEBUG_UNLOCK") orelse return 0;
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{password}) catch return 0;
    if (entry) |e| c.clutter_text_set_text(@ptrCast(@alignCast(e)), z.ptr);
    submit();
    return 0;
}

// ---- Locking --------------------------------------------------------------------------

pub fn lock() void {
    if (locked) return;
    const s = stage orelse return;
    const d = display orelse return;
    locked = true;
    @import("ui.zig").closePopup();

    var w: f32 = 0;
    var h: f32 = 0;
    c.clutter_actor_get_size(s, &w, &h);

    const root = c.clutter_actor_new();
    c.clutter_actor_set_size(root, w, h);
    c.clutter_actor_set_reactive(root, 1);

    const background = c.meta_background_group_new();
    c.clutter_actor_add_child(root, background);
    plugin.fillBackground(background);
    const dim = c.clutter_actor_new();
    c.clutter_actor_set_size(dim, w, h);
    c.clutter_actor_set_background_color(dim, &c.CoglColor{ .red = 0, .green = 0, .blue = 0, .alpha = 140 });
    c.clutter_actor_add_child(root, dim);

    // Center column: clock, date, user, password field, message.
    const column_y = h * 0.28;
    clock_label = ui.label("", config.font(.bold, 53));
    date_label = ui.label("", config.font(.regular, 5));
    var user_buf: [128]u8 = undefined;
    _ = c.cali_shell_current_user(&user_buf, user_buf.len);
    const user = ui.label(@ptrCast(&user_buf), config.font(.bold, 2));
    for ([_]?*c.ClutterActor{ clock_label, date_label, user }) |a| {
        ui.center(a, root, c.CLUTTER_ALIGN_X_AXIS);
        c.clutter_actor_add_child(root, a);
    }
    c.clutter_actor_set_y(clock_label, column_y);
    c.clutter_actor_set_y(date_label, column_y + 100);
    c.clutter_actor_set_y(user, column_y + 196);

    const field_w: f32 = 300;
    const field_h: f32 = 40;
    const field = ui.roundedRect(field_w, field_h, field_h / 2, 0xffffff26);
    c.clutter_actor_set_position(field, (w - field_w) / 2, column_y + 224);
    const text = c.clutter_text_new_full(config.font(.regular, 1), "", &ui.white);
    const t: *c.ClutterText = @ptrCast(@alignCast(text));
    c.clutter_text_set_editable(t, 1);
    c.clutter_text_set_activatable(t, 1);
    c.clutter_text_set_password_char(t, 0x25cf); // ●
    c.clutter_text_set_single_line_mode(t, 1);
    c.clutter_actor_set_reactive(text, 1);
    c.clutter_actor_set_position(text, 18, 0);
    c.clutter_actor_set_size(text, field_w - 36, field_h);
    c.clutter_actor_set_y_align(text, @intCast(c.CLUTTER_ACTOR_ALIGN_CENTER));
    c.clutter_actor_add_child(field, text);
    c.clutter_actor_add_child(root, field);
    plugin.connect(text, "activate", &onActivate, null);
    entry = text;

    const msg = ui.label("Enter your password to unlock", config.font(.regular, 0));
    c.clutter_actor_set_opacity(msg, 190);
    ui.center(msg, root, c.CLUTTER_ALIGN_X_AXIS);
    c.clutter_actor_set_y(msg, column_y + 278);
    c.clutter_actor_add_child(root, msg);
    message = msg;

    plugin.connect(root, "key-press-event", &onKey, null);
    c.clutter_actor_add_child(s, root);
    screen = root;

    // Hide everything behind it.
    c.clutter_actor_hide(c.meta_compositor_get_window_group(c.meta_display_get_compositor(d)));
    if (panel) |p| c.clutter_actor_hide(p);

    grab = c.clutter_stage_grab(@ptrCast(@alignCast(s)), root);
    c.clutter_stage_set_key_focus(@ptrCast(@alignCast(s)), text);

    _ = tick(null);
    timer = c.g_timeout_add(250, &tick, null);

    c.clutter_actor_set_opacity(root, 0);
    ui.ease(root, 250, c.CLUTTER_EASE_OUT_QUAD);
    c.clutter_actor_set_opacity(root, 255);
    c.clutter_actor_restore_easing_state(root);
    std.log.debug("lock: locked", .{});
}

fn unlock() void {
    const d = display orelse return;
    if (grab) |g| {
        c.clutter_grab_dismiss(g);
        c.g_object_unref(g);
        grab = null;
    }
    if (timer != 0) _ = c.g_source_remove(timer);
    timer = 0;
    if (screen) |root| c.clutter_actor_destroy(root);
    screen = null;
    entry = null;
    message = null;
    clock_label = null;
    date_label = null;
    checking = false;
    c.clutter_actor_show(c.meta_compositor_get_window_group(c.meta_display_get_compositor(d)));
    if (panel) |p| c.clutter_actor_show(p);
    locked = false;
    std.log.debug("lock: unlocked", .{});
}

fn setMessage(text: [*:0]const u8) void {
    if (message) |m| c.clutter_text_set_text(@ptrCast(@alignCast(m)), text);
}

fn onKey(_: ?*c.ClutterActor, event: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    if (c.clutter_event_get_key_symbol(event) == c.CLUTTER_KEY_Escape) {
        if (entry) |e| c.clutter_text_set_text(@ptrCast(@alignCast(e)), "");
        return 1;
    }
    return 0;
}

fn onActivate(_: ?*c.ClutterText, _: c.gpointer) callconv(.C) void {
    submit();
}

fn submit() void {
    const e = entry orelse return;
    if (checking) return;
    const password = c.clutter_text_get_text(@ptrCast(@alignCast(e)));
    if (password == null or std.mem.span(password).len == 0) return;
    if (!c.cali_shell_auth_start(password)) return;
    checking = true;
    c.clutter_text_set_editable(@ptrCast(@alignCast(e)), 0);
    setMessage("Checking\xe2\x80\xa6");
}

/// Clock update and password-check polling.
fn tick(_: c.gpointer) callconv(.C) c.gboolean {
    var buf: [128]u8 = undefined;
    if (clock_label) |l| {
        _ = c.cali_shell_format_date(0, 0, 0, "%H:%M", &buf, buf.len);
        c.clutter_text_set_text(@ptrCast(@alignCast(l)), @ptrCast(&buf));
    }
    if (date_label) |l| {
        _ = c.cali_shell_format_date(0, 0, 0, "%A, %B %-d", &buf, buf.len);
        c.clutter_text_set_text(@ptrCast(@alignCast(l)), @ptrCast(&buf));
    }
    if (checking) {
        switch (c.cali_shell_auth_poll()) {
            1 => {
                unlock();
                return 0; // timer removed in unlock()
            },
            0 => {
                checking = false;
                if (entry) |e| {
                    const t: *c.ClutterText = @ptrCast(@alignCast(e));
                    c.clutter_text_set_text(t, "");
                    c.clutter_text_set_editable(t, 1);
                }
                setMessage("Wrong password, try again");
                std.log.debug("lock: wrong password", .{});
            },
            else => {},
        }
    }
    return 1;
}

// ---- Idle ------------------------------------------------------------------------------

fn idleMonitor() ?*c.MetaIdleMonitor {
    const d = display orelse return null;
    return c.meta_backend_get_core_idle_monitor(c.meta_context_get_backend(c.meta_display_get_context(d)));
}

/// Applies the idle-delay (minutes, 0 = never) and lock-on-idle settings.
pub fn setIdle(minutes: f64, lock_too: bool) void {
    idle_minutes = minutes;
    lock_on_idle = lock_too;
    const monitor = idleMonitor() orelse return;
    if (idle_watch != 0) _ = c.meta_idle_monitor_remove_watch(monitor, idle_watch);
    idle_watch = 0;
    if (minutes <= 0) return;
    const ms: u64 = @intFromFloat(minutes * 60_000);
    idle_watch = c.meta_idle_monitor_add_idle_watch(monitor, ms, &onIdle, null, null);
}

fn onIdle(monitor: ?*c.MetaIdleMonitor, _: c_uint, _: c.gpointer) callconv(.C) void {
    blank();
    if (active_watch == 0) active_watch = c.meta_idle_monitor_add_user_active_watch(monitor, &onActive, null, null);
}

fn onActive(_: ?*c.MetaIdleMonitor, _: c_uint, _: c.gpointer) callconv(.C) void {
    active_watch = 0; // user-active watches fire once
    unblank();
}

/// Fades the screen to black (and locks underneath, if set).
pub fn blank() void {
    const s = stage orelse return;
    if (lock_on_idle) lock();
    if (blanker != null) return;
    var w: f32 = 0;
    var h: f32 = 0;
    c.clutter_actor_get_size(s, &w, &h);
    const b = c.clutter_actor_new();
    c.clutter_actor_set_size(b, w, h);
    c.clutter_actor_set_background_color(b, &c.CoglColor{ .red = 0, .green = 0, .blue = 0, .alpha = 255 });
    c.clutter_actor_set_opacity(b, 0);
    c.clutter_actor_add_child(s, b);
    ui.ease(b, 1000, c.CLUTTER_EASE_IN_QUAD);
    c.clutter_actor_set_opacity(b, 255);
    c.clutter_actor_restore_easing_state(b);
    blanker = b;
}

fn unblank() void {
    const b = blanker orelse return;
    blanker = null;
    c.clutter_actor_destroy(b);
}
