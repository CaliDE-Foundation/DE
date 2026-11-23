//! Touchpad gestures, like GNOME's: swipe up with three fingers (or four,
//! gesture-fingers) for the overview and again for the app grid, down to
//! close it, left/right to change workspace. Each swipe can be changed or
//! turned off in Cali Settings > Behavior.

const std = @import("std");
const plugin = @import("plugin.zig");
const config = @import("config.zig");
const overview = @import("overview.zig");
const c = plugin.c;

const threshold: f64 = 80; // touchpad units before a swipe counts

var display: ?*c.MetaDisplay = null;
var dx: f64 = 0;
var dy: f64 = 0;
var tracking = false;

pub fn init(d: ?*c.MetaDisplay, stage: ?*c.ClutterActor) void {
    display = d;
    // Before windows see it, like GNOME Shell's swipe tracker.
    plugin.connect(stage, "captured-event", &onEvent, null);
}

fn onEvent(_: ?*c.ClutterActor, event: ?*c.ClutterEvent, _: c.gpointer) callconv(.C) c.gboolean {
    if (c.clutter_event_type(event) != c.CLUTTER_TOUCHPAD_SWIPE) return 0;
    if (!config.gestures) return 0;
    if (c.clutter_event_get_touchpad_gesture_finger_count(event) != config.gesture_fingers) return 0;
    switch (c.clutter_event_get_gesture_phase(event)) {
        c.CLUTTER_TOUCHPAD_GESTURE_PHASE_BEGIN => {
            dx = 0;
            dy = 0;
            tracking = true;
        },
        c.CLUTTER_TOUCHPAD_GESTURE_PHASE_UPDATE => {
            var x: f64 = 0;
            var y: f64 = 0;
            c.clutter_event_get_gesture_motion_delta_unaccelerated(event, &x, &y);
            dx += x;
            dy += y;
        },
        c.CLUTTER_TOUCHPAD_GESTURE_PHASE_END => {
            if (tracking) finish();
            tracking = false;
        },
        else => tracking = false, // cancelled
    }
    return 1; // ours: windows don't also get it
}

fn finish() void {
    if (@abs(dy) > @abs(dx) and @abs(dy) > threshold) {
        run(if (dy < 0) config.swipe_up else config.swipe_down);
    } else if (@abs(dx) > threshold and config.swipe_sideways) {
        // Natural scrolling: fingers left shows the workspace to the right.
        switchWorkspace(if (dx < 0) c.META_MOTION_RIGHT else c.META_MOTION_LEFT);
    }
}

fn run(action: config.SwipeAction) void {
    switch (action) {
        // Like GNOME: once for the overview, again for the app grid.
        .overview => if (overview.isOpen()) overview.showApps() else overview.toggle(),
        .apps => overview.showApps(),
        .close => overview.closeTo(null),
        .none => {},
    }
}

fn switchWorkspace(direction: c_int) void {
    const d = display orelse return;
    const manager = c.meta_display_get_workspace_manager(d);
    const current = c.meta_workspace_manager_get_active_workspace(manager);
    const next = c.meta_workspace_get_neighbor(current, direction);
    if (next != null and next != current) c.meta_workspace_activate(next, c.meta_display_get_current_time_roundtrip(d));
}
