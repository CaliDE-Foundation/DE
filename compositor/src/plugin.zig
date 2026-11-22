//! CaliPlugin: Cali's Sookie plugin (a MetaPlugin subclass).
//!
//! It draws the background and the top bar, and animates windows. What the
//! bar shows comes from cali-shell (Rust); this file only draws it with Clutter.

const std = @import("std");

pub const c = @cImport({
    @cDefine("CLUTTER_ENABLE_EXPERIMENTAL_API", "1");
    @cDefine("COGL_ENABLE_EXPERIMENTAL_API", "1");
    @cInclude("meta/meta-plugin.h");
    @cInclude("meta/display.h");
    @cInclude("meta/compositor.h");
    @cInclude("meta/meta-context.h");
    @cInclude("meta/meta-backend.h");
    @cInclude("meta/meta-monitor-manager.h");
    @cInclude("meta/meta-background.h");
    @cInclude("meta/meta-background-actor.h");
    @cInclude("meta/meta-background-content.h");
    @cInclude("meta/meta-background-group.h");
    @cInclude("meta/meta-workspace-manager.h");
    @cInclude("meta/meta-window-actor.h");
    @cInclude("meta/workspace.h");
    @cInclude("meta/window.h");
    @cInclude("clutter/clutter.h");
    @cInclude("clutter/clutter-pango.h");
    @cInclude("cali_shell.h");
});

// ---- Look ------------------------------------------------------------------

const background_top = c.CoglColor{ .red = 0x2c, .green = 0x4a, .blue = 0x86, .alpha = 255 };
const background_bottom = c.CoglColor{ .red = 0xe2, .green = 0x7d, .blue = 0x60, .alpha = 255 };
const panel_color = c.CoglColor{ .red = 0, .green = 0, .blue = 0, .alpha = 255 };
const panel_text_color = c.CoglColor{ .red = 255, .green = 255, .blue = 255, .alpha = 255 };
const panel_font = "Adwaita Sans Bold 11";

const map_duration_ms = 180;
const map_start_scale = 0.94;

// ---- State (Sookie creates exactly one plugin instance) ---------------------

var display: ?*c.MetaDisplay = null;
var background_group: ?*c.ClutterActor = null;
var panel: ?*c.ClutterActor = null;
var clock: ?*c.ClutterActor = null;
var panel_rect = c.MtkRectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };

const map_handler_key = "cali-map-handler";

// ---- GObject type -------------------------------------------------------------

var plugin_type: c.GType = 0;

/// The CaliPlugin GType, registered on first use.
pub fn getType() c.GType {
    if (plugin_type == 0) {
        plugin_type = c.g_type_register_static_simple(
            c.meta_plugin_get_type(),
            "CaliPlugin",
            @sizeOf(c.MetaPluginClass),
            &classInit,
            @sizeOf(c.MetaPlugin),
            null,
            0,
        );
    }
    return plugin_type;
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.C) void {
    const k: *c.MetaPluginClass = @ptrCast(@alignCast(klass));
    k.start = &start;
    k.map = &map;
    k.kill_window_effects = &killWindowEffects;
}

// ---- Startup ------------------------------------------------------------------

fn start(plugin: ?*c.MetaPlugin) callconv(.C) void {
    const d = c.meta_plugin_get_display(plugin);
    display = d;
    const backend = c.meta_context_get_backend(c.meta_display_get_context(d));
    const compositor = c.meta_display_get_compositor(d);
    const monitor_manager = c.meta_backend_get_monitor_manager(backend);
    const stage = c.meta_backend_get_stage(backend);

    const group = c.meta_background_group_new();
    c.clutter_actor_insert_child_below(c.meta_compositor_get_window_group(compositor), group, null);
    background_group = group;

    createPanel(stage);

    connect(monitor_manager, "monitors-changed", &onMonitorsChanged, null);
    connect(c.meta_display_get_workspace_manager(d), "workspace-added", &onWorkspaceAdded, null);
    onMonitorsChanged(monitor_manager, null);

    _ = c.g_timeout_add_seconds(1, &tickClock, null);
    c.clutter_actor_show(stage);
}

fn connect(instance: anytype, signal: [*:0]const u8, handler: anytype, data: c.gpointer) void {
    _ = c.g_signal_connect_data(instance, signal, @ptrCast(handler), data, null, 0);
}

// ---- Background -----------------------------------------------------------------

fn onMonitorsChanged(_: ?*c.MetaMonitorManager, _: c.gpointer) callconv(.C) void {
    const d = display orelse return;
    const group = background_group orelse return;

    c.clutter_actor_destroy_all_children(group);
    const n = c.meta_display_get_n_monitors(d);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        var rect: c.MtkRectangle = undefined;
        c.meta_display_get_monitor_geometry(d, i, &rect);

        const actor = c.meta_background_actor_new(d, i);
        c.clutter_actor_set_position(actor, @floatFromInt(rect.x), @floatFromInt(rect.y));
        c.clutter_actor_set_size(actor, @floatFromInt(rect.width), @floatFromInt(rect.height));

        var top = background_top;
        var bottom = background_bottom;
        const background = c.meta_background_new(d);
        c.meta_background_set_gradient(background, @intCast(c.G_DESKTOP_BACKGROUND_SHADING_VERTICAL), &top, &bottom);

        const content: *c.MetaBackgroundContent = @ptrCast(@alignCast(c.clutter_actor_get_content(actor)));
        c.meta_background_content_set_background(content, background);
        c.g_object_unref(background);

        c.clutter_actor_add_child(group, actor);
    }

    layoutPanel();
}

// ---- Top bar ---------------------------------------------------------------------

fn createPanel(stage: ?*c.ClutterActor) void {
    const p = c.clutter_actor_new();
    c.clutter_actor_set_background_color(p, &panel_color);

    const text = c.clutter_text_new_full(panel_font, "", &panel_text_color);
    c.clutter_actor_add_child(p, text);
    c.clutter_actor_add_constraint(text, c.clutter_align_constraint_new(p, @intCast(c.CLUTTER_ALIGN_BOTH), 0.5));

    c.clutter_actor_add_child(stage, p);
    panel = p;
    clock = text;
    _ = tickClock(null);
}

fn layoutPanel() void {
    const d = display orelse return;
    const p = panel orelse return;
    // Monitors can be missing early in startup (e.g. before a virtual monitor is added).
    if (c.meta_display_get_n_monitors(d) == 0) return;
    const primary = c.meta_display_get_primary_monitor(d);
    if (primary < 0) return;

    var rect: c.MtkRectangle = undefined;
    c.meta_display_get_monitor_geometry(d, primary, &rect);
    const height: c_int = @intCast(c.cali_shell_panel_height());

    c.clutter_actor_set_position(p, @floatFromInt(rect.x), @floatFromInt(rect.y));
    c.clutter_actor_set_size(p, @floatFromInt(rect.width), @floatFromInt(height));
    panel_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = height };
    applyStruts();
}

/// Reserve the bar's area on every workspace so windows stay below it.
fn applyStruts() void {
    const d = display orelse return;
    const manager = c.meta_display_get_workspace_manager(d);

    var strut = c.MetaStrut{ .rect = panel_rect, .side = @intCast(c.META_SIDE_TOP) };
    const list = c.g_slist_append(null, &strut);
    defer c.g_slist_free(list); // Sookie copies the list.

    const n = c.meta_workspace_manager_get_n_workspaces(manager);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        c.meta_workspace_set_builtin_struts(c.meta_workspace_manager_get_workspace_by_index(manager, i), list);
    }
}

fn onWorkspaceAdded(_: ?*c.MetaWorkspaceManager, _: c_int, _: c.gpointer) callconv(.C) void {
    applyStruts();
}

fn tickClock(_: c.gpointer) callconv(.C) c.gboolean {
    const text = clock orelse return 0;
    var buf: [64]u8 = undefined;
    if (c.cali_shell_clock_text(&buf, buf.len) > 0) {
        c.clutter_text_set_text(@ptrCast(@alignCast(text)), &buf);
    }
    return 1; // keep ticking
}

// ---- Window animations -----------------------------------------------------------

fn sameEnum(a: anytype, b: anytype) bool {
    return @as(i64, @intCast(a)) == @as(i64, @intCast(b));
}

fn shouldAnimate(window_actor: ?*c.MetaWindowActor) bool {
    const kind = c.meta_window_get_window_type(c.meta_window_actor_get_meta_window(window_actor));
    return sameEnum(kind, c.META_WINDOW_NORMAL) or
        sameEnum(kind, c.META_WINDOW_DIALOG) or
        sameEnum(kind, c.META_WINDOW_MODAL_DIALOG);
}

/// New windows fade in while growing slightly, like GNOME.
fn map(plugin: ?*c.MetaPlugin, window_actor: ?*c.MetaWindowActor) callconv(.C) void {
    if (!shouldAnimate(window_actor)) {
        c.meta_plugin_map_completed(plugin, window_actor);
        return;
    }

    const actor: *c.ClutterActor = @ptrCast(@alignCast(window_actor));
    c.clutter_actor_set_pivot_point(actor, 0.5, 0.5);
    c.clutter_actor_set_opacity(actor, 0);
    c.clutter_actor_set_scale(actor, map_start_scale, map_start_scale);
    c.clutter_actor_show(actor);

    c.clutter_actor_save_easing_state(actor);
    c.clutter_actor_set_easing_mode(actor, @intCast(c.CLUTTER_EASE_OUT_QUAD));
    c.clutter_actor_set_easing_duration(actor, map_duration_ms);
    c.clutter_actor_set_opacity(actor, 255);
    c.clutter_actor_set_scale(actor, 1.0, 1.0);
    c.clutter_actor_restore_easing_state(actor);

    const id = c.g_signal_connect_data(actor, "transitions-completed", @ptrCast(&onMapDone), plugin, null, 0);
    c.g_object_set_data(@ptrCast(@alignCast(actor)), map_handler_key, @ptrFromInt(id));
}

fn onMapDone(actor: ?*c.ClutterActor, plugin: c.gpointer) callconv(.C) void {
    finishMap(actor, @ptrCast(@alignCast(plugin)));
}

fn finishMap(actor: ?*c.ClutterActor, plugin: ?*c.MetaPlugin) void {
    const object: *c.GObject = @ptrCast(@alignCast(actor));
    const id = c.g_object_get_data(object, map_handler_key) orelse return;
    c.g_signal_handler_disconnect(object, @intFromPtr(id));
    c.g_object_set_data(object, map_handler_key, null);
    c.meta_plugin_map_completed(plugin, @ptrCast(@alignCast(actor)));
}

/// Sookie asks to stop effects early (window closed, moved, ...).
fn killWindowEffects(plugin: ?*c.MetaPlugin, window_actor: ?*c.MetaWindowActor) callconv(.C) void {
    const actor: *c.ClutterActor = @ptrCast(@alignCast(window_actor));
    if (c.g_object_get_data(@ptrCast(@alignCast(actor)), map_handler_key) == null) return;

    c.clutter_actor_remove_all_transitions(actor);
    c.clutter_actor_set_opacity(actor, 255);
    c.clutter_actor_set_scale(actor, 1.0, 1.0);
    finishMap(actor, plugin);
}
