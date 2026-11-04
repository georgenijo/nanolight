//! The panel's colors, light and dark: text, rows, hairlines, tiles. A
//! theme other than `system` tints them with its hue, light or dark still
//! as the system is (nanoui's own controls follow the system too).
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Palette = struct { text: ui.Color, sub: ui.Color, hair: ui.Color, sel: ui.Color, rim: ui.Color, tile: ui.Color, fill: ui.Color };

const pc = @import("builtin").os.tag != .macos;

/// The panel's tint, chosen in Settings (`nanolight.theme`).
pub const Theme = enum {
    system,
    ocean,
    forest,
    rose,
    amber,
    violet,

    pub const all = [_]Theme{ .system, .ocean, .forest, .rose, .amber, .violet };

    pub fn title(t: Theme) []const u8 {
        return switch (t) {
            .system => "System",
            .ocean => "Ocean",
            .forest => "Forest",
            .rose => "Rose",
            .amber => "Amber",
            .violet => "Violet",
        };
    }

    /// The theme's hue: brighter over dark, deeper over light. Null for
    /// `system`, which keeps the greys.
    pub fn hue(t: Theme, dark: bool) ?ui.Color {
        const pair: [2]u24 = switch (t) {
            .system => return null,
            .ocean => .{ 0x4aa8ff, 0x0a6fd6 },
            .forest => .{ 0x4fd18b, 0x1e8a50 },
            .rose => .{ 0xff6f9c, 0xd23a6c },
            .amber => .{ 0xffb340, 0xc26a00 },
            .violet => .{ 0xb08cff, 0x7041d9 },
        };
        return .hex(if (dark) pair[0] else pair[1]);
    }

    /// The search bar's glyph, and the menu bar icon's: SF Symbols on the
    /// Mac; off it nanoui draws its own few, the lens among them.
    pub fn glyph(t: Theme) []const u8 {
        return t.glyphOn(!pc);
    }

    fn glyphOn(t: Theme, mac: bool) []const u8 {
        if (!mac) return "magnifyingglass";
        return switch (t) {
            .system => "magnifyingglass",
            .ocean => "sparkle.magnifyingglass",
            .forest => "leaf.fill",
            .rose => "heart.fill",
            .amber => "bolt.fill",
            .violet => "moon.stars.fill",
        };
    }

    /// The panel's corners, and its glass's.
    pub fn radius(t: Theme) f32 {
        return switch (t) {
            // 18, or theme.json's rounding on Linux, as its colors.
            .system => @import("linux_theme.zig").radius(),
            .ocean => 24,
            .forest => 12,
            .rose => 28,
            .amber => 8,
            .violet => 20,
        };
    }

    /// What's typed in the search bar, in points.
    pub fn fieldSize(t: Theme) f32 {
        return switch (t) {
            .system, .amber => 21,
            .ocean, .violet => 22,
            .forest => 20,
            .rose => 23,
        };
    }

    /// The next or previous one, round.
    pub fn step(t: Theme, dir: i8) Theme {
        const n: i8 = all.len;
        const i: i8 = @intCast(@backingInt(t));
        return all[@intCast(@mod(i + dir, n))];
    }
};

/// With the `system` theme, the built-in greys, or on Linux a
/// theme.json's colors (linux_theme.zig). Any other theme tints the greys.
pub fn palette(dark: bool, theme: Theme) Palette {
    const base = grey(dark);
    const h = theme.hue(dark) orelse return @import("linux_theme.zig").palette() orelse base;
    return if (dark) .{
        .text = base.text,
        .sub = base.sub.mix(h, 0.25),
        .hair = h.alpha(0.22),
        .sel = h.alpha(0.3),
        .rim = h.alpha(0.2),
        .tile = h.alpha(0.16),
        .fill = if (pc) ui.Color.hex(0x161616).mix(h, 0.14) else ui.Color.hex(0x141414).mix(h, 0.18).alpha(0.72),
    } else .{
        .text = base.text,
        .sub = base.sub.mix(h, 0.2),
        .hair = h.alpha(0.18),
        .sel = h.alpha(0.18),
        .rim = h.alpha(0.14),
        .tile = h.alpha(0.12),
        .fill = if (pc) ui.Color.hex(0xfafafa).mix(h, 0.08) else ui.Color.white.mix(h, 0.1).alpha(0.7),
    };
}

/// The glass's tint, where the panel draws its own (`Nanolight.own_glass`).
pub fn tint(dark: bool, theme: Theme) ui.Color {
    const h = theme.hue(dark) orelse return if (dark) ui.Color.black.alpha(0.42) else ui.Color.white.alpha(0.5);
    return if (dark) ui.Color.black.mix(h, 0.22).alpha(0.55) else ui.Color.white.mix(h, 0.12).alpha(0.6);
}

pub fn grey(dark: bool) Palette {
    return if (dark) .{
        .text = .hex(0xeeeeee),
        .sub = .hex(0xb5b5b5),
        .hair = ui.Color.white.alpha(0.12),
        .sel = ui.Color.white.alpha(0.16),
        .rim = ui.Color.white.alpha(0.1),
        .tile = ui.Color.white.alpha(0.09),
        // Over the Mac's vibrancy; solid on a PC, whose window is clear.
        .fill = if (pc) ui.Color.hex(0x1b1b1c) else ui.Color.hex(0x1a1a1a).alpha(0.5),
    } else .{
        .text = .hex(0x292929),
        .sub = .hex(0x6f6f6f),
        .hair = ui.Color.black.alpha(0.09),
        .sel = ui.Color.black.alpha(0.08),
        .rim = ui.Color.black.alpha(0.05),
        .tile = ui.Color.black.alpha(0.05),
        .fill = if (pc) ui.Color.hex(0xf9f9fa) else ui.Color.white.alpha(0.45),
    };
}

test "System keeps the greys; a theme tints them and steps round" {
    const t = @import("std").testing;
    try t.expectEqual(grey(true), palette(true, .system));
    try t.expectEqual(grey(false), palette(false, .system));
    try t.expect(!@import("std").meta.eql(grey(true).sel, palette(true, .ocean).sel));
    try t.expectEqual(Theme.violet, Theme.system.step(-1));
    try t.expectEqual(Theme.system, Theme.violet.step(1));
    try t.expectEqual(Theme.ocean, Theme.system.step(1));
}

test "System keeps the bar as it was; each theme has its own" {
    const t = @import("std").testing;
    try t.expectEqualStrings("magnifyingglass", Theme.system.glyph());
    try t.expectEqual(@as(f32, 18), Theme.system.radius());
    try t.expectEqual(@as(f32, 21), Theme.system.fieldSize());
    for (Theme.all[1..], 0..) |a, i| for (Theme.all[i + 2 ..]) |b| {
        try t.expect(!@import("std").mem.eql(u8, a.glyphOn(true), b.glyphOn(true)));
    };
}

test "off the Mac a theme names only an icon nanoui can draw" {
    // nanoui's table (`ui/icons.zig`), embedded as its source.
    const std = @import("std");
    const table = @embedFile("nanoui_icons");
    for (Theme.all) |th| {
        var buf: [64]u8 = undefined;
        const entry = try std.fmt.bufPrint(&buf, ".name = \"{s}\"", .{th.glyphOn(false)});
        try std.testing.expect(std.mem.indexOf(u8, table, entry) != null);
    }
}
