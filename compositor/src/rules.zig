//! Window rules (the window-rules setting): when a window opens, apply the
//! actions of every rule matching its app, class or title. Parsing and
//! matching live in cali-shell (rules.rs).

const std = @import("std");
const plugin = @import("plugin.zig");
const dock = @import("dock.zig");
const ui = @import("ui.zig");
const c = plugin.c;

/// Called from settings with the rules, one per line.
pub fn set(text: [*:0]const u8) void {
    c.cali_shell_set_window_rules(text);
}

/// Returns the rule's tiling choice (-1 none, 0 tile, 1 float) for tiling.zig.
pub fn apply(window: ?*c.MetaWindow) i8 {
    const w = window orelse return -1;
    var app_id: [*c]const u8 = null;
    const info = dock.appForWindow(w);
    defer if (info) |i| c.g_object_unref(i);
    if (info) |i| app_id = c.g_app_info_get_id(i);
    var a: c.CaliRuleActions = undefined;
    const matched = c.cali_shell_window_rules_for(app_id, c.meta_window_get_wm_class(w), c.meta_window_get_title(w), &a);
    const class = c.meta_window_get_wm_class(w);
    std.log.debug("rules: app={s} class={s} matched={}", .{ if (app_id != null) std.mem.span(app_id) else "-", if (class != null) std.mem.span(class) else "-", matched });
    if (!matched) return -1;

    // Act once the window has finished opening (moving or resizing it in
    // the middle of the opening animation leaves it invisible).
    const pending = std.heap.c_allocator.create(Pending) catch return a.floating;
    pending.* = .{ .window = @ptrCast(@alignCast(c.g_object_ref(w))), .actions = a };
    _ = c.g_timeout_add(ui.ms(300) + 60, &applyLater, pending);
    return a.floating;
}

const Pending = struct { window: *c.MetaWindow, actions: c.CaliRuleActions };

fn applyLater(data: c.gpointer) callconv(.C) c.gboolean {
    const pending: *Pending = @ptrCast(@alignCast(data));
    defer std.heap.c_allocator.destroy(pending);
    const w = pending.window;
    defer c.g_object_unref(w);
    if (c.meta_window_get_compositor_private(w) == null) return 0; // closed meanwhile
    const a = pending.actions;
    if (a.workspace > 0) c.meta_window_change_workspace_by_index(w, a.workspace - 1, 1);
    if (a.sticky) c.meta_window_stick(w);
    if (a.above) c.meta_window_make_above(w);
    if (a.width > 0 or a.center) {
        var frame: c.MtkRectangle = undefined;
        c.meta_window_get_frame_rect(w, &frame);
        const width = if (a.width > 0) a.width else frame.width;
        const height = if (a.height > 0) a.height else frame.height;
        var area: c.MtkRectangle = undefined;
        c.meta_workspace_get_work_area_for_monitor(c.meta_window_get_workspace(w), c.meta_window_get_monitor(w), &area);
        const x = if (a.center) area.x + @divTrunc(area.width - width, 2) else frame.x;
        const y = if (a.center) area.y + @divTrunc(area.height - height, 2) else frame.y;
        c.meta_window_move_resize_frame(w, 1, x, y, width, height);
    }
    if (a.maximize) c.meta_window_maximize(w);
    if (a.fullscreen) c.meta_window_make_fullscreen(w);
    if (a.opacity >= 0) {
        const value: usize = @intFromFloat(a.opacity * 255);
        if (c.meta_window_get_compositor_private(w)) |actor| c.clutter_actor_set_opacity(@ptrCast(@alignCast(actor)), @intCast(value));
    }
    return 0;
}
