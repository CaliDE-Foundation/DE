//! Cali's own look-and-behavior settings, as the compositor uses them. Filled
//! in by settings.zig from cali-settingsd; every module reads from here.

const std = @import("std");

// ---- Appearance
pub var corner_radius: f32 = 18;
var font_family: [64]u8 = ("Adwaita Sans" ++ "\x00" ** (64 - 12)).*;
pub var font_size: f32 = 11;

// ---- Top bar
pub var panel_height: f32 = 32;
pub var panel_opacity: f32 = 1;
pub const ClockPosition = enum { center, left, right };
pub var clock_position: ClockPosition = .center;
pub var show_workspace_dots = true;
pub var show_battery_percentage = false;
pub var show_keyboard_indicator = true;

// ---- Overview and dock
pub var overview_search = true;
pub var overview_dim: f32 = 0.43;
pub var overview_gap: f32 = 32;
pub var app_folders = true;
pub var dock_icon_size: f32 = 48;
pub var dock_running_dots = true;
pub var media_controls = true;
pub var media_top_bar = false;
pub const DockMode = enum { overview, always, autohide };
pub const DockPosition = enum { bottom, left, right };
pub var dock_mode: DockMode = .overview;
pub var dock_position: DockPosition = .bottom;

// ---- Windows
pub const OpenAnimation = enum { scale, fade, slide, none };
pub const CloseAnimation = enum { scale, fade, none };
pub const MinimizeAnimation = enum { dock, fade, none };
pub var open_animation: OpenAnimation = .scale;
pub var close_animation: CloseAnimation = .scale;
pub var minimize_animation: MinimizeAnimation = .dock;
pub var wobbly = false;
pub var wobbly_strength: f32 = 0.5;
pub var wobbly_friction: f32 = 0.25;
pub var dynamic_workspaces = true;

// ---- Tiling
pub const TilingMode = enum { off, dwindle, scrolling };
pub var tiling_mode: TilingMode = .off;
pub var tiling_new_tiled = true;
pub var tiling_gap: f32 = 8;
pub var tiling_outer_gap: f32 = 12;
pub var tiling_split: f32 = 0.5;
pub var tiling_column: f32 = 0.5;

// ---- Behavior
pub var alt_tab_windows = false;
pub var alt_tab_current_workspace = true;
pub var notifications_top_right = false;
pub const SwipeAction = enum { overview, apps, close, none };
pub var gestures = true;
pub var gesture_fingers: c_uint = 3;
pub var swipe_up: SwipeAction = .overview;
pub var swipe_down: SwipeAction = .close;
pub var swipe_sideways = true;

// ---- Colors (0xRRGGBB)
pub var surface_rgb: u32 = 0x2e2e32;
pub var panel_rgb: u32 = 0x000000;

/// Parses "#rrggbb" (or "rrggbb").
pub fn parseHex(text: []const u8) ?u32 {
    const t = if (text.len > 0 and text[0] == '#') text[1..] else text;
    if (t.len != 6) return null;
    return std.fmt.parseInt(u32, t, 16) catch null;
}

// ---- Accessibility
pub var high_contrast = false;
pub var large_text = false;
pub var reduce_motion = false;
pub var screen_reader = false;
pub var focus_outlines = true;

/// The bar height in whole pixels.
pub fn panelHeight() c_int {
    return @intFromFloat(panel_height);
}

/// A smaller radius for small surfaces (menus, buttons): same feel, scaled.
pub fn radius(scale: f32) f32 {
    return corner_radius * scale;
}

pub fn setFont(family: []const u8) void {
    const n = @min(family.len, font_family.len - 1);
    if (n == 0) return;
    @memcpy(font_family[0..n], family[0..n]);
    font_family[n] = 0;
}

pub const Weight = enum { regular, bold };

var font_ring: [24][96]u8 = undefined;
var font_next: usize = 0;

/// A Pango font name with the shell font, e.g. "Adwaita Sans Bold 11".
/// `delta` is points relative to the base size. The text stays valid long
/// enough to hand to Clutter (which copies it).
pub fn font(weight: Weight, delta: f32) [*:0]const u8 {
    const buf = &font_ring[font_next];
    font_next = (font_next + 1) % font_ring.len;
    const family = std.mem.sliceTo(&font_family, 0);
    const scale: f32 = if (large_text) 1.25 else 1.0;
    const size = @round(@max(6, font_size + delta) * scale * 10) / 10;
    const text = std.fmt.bufPrintZ(buf, "{s}{s} {d}", .{ family, if (weight == .bold) " Bold" else "", size }) catch return "Sans 11";
    return text.ptr;
}

/// Matches a choice setting to an enum by name ("scale" -> .scale).
pub fn parseEnum(comptime E: type, name: []const u8, fallback: E) E {
    inline for (@typeInfo(E).Enum.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
    }
    if (std.mem.eql(u8, name, "top-right")) return fallback;
    return fallback;
}
