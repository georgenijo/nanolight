//! The panel's look on Linux, read once, the first time it is asked for.
//!
//! `$XDG_CONFIG_HOME/nanolight/theme.json` (or `~/.config/...`), if there,
//! sets the colors and the corner radius (while the theme in Settings is
//! System) and the font. Anything can write it;
//! Omarchy's sync writes its theme, Hyprland's rounding and its font. A
//! change shows the next time Nanolight starts. Without the file the panel
//! is dark when the desktop says so: nanoui only looks at `$GTK_THEME`,
//! which most desktops leave unset, so gsettings is asked too.
//!
//! ```json
//! { "dark": true, "background": "#1a1b26", "foreground": "#a9b1d6",
//!   "muted": "#565f89", "accent": "#7aa2f7", "selection": "#283457",
//!   "rounding": 10, "font": "JetBrainsMono Nerd Font" }
//! ```
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Palette = @import("palette.zig").Palette;

/// The panel's corners when the file doesn't say.
pub const default_radius: f32 = 18;

const File = struct {
    dark: bool = true,
    background: []const u8 = "#1b1b1c",
    foreground: []const u8 = "#eeeeee",
    muted: []const u8 = "#b5b5b5",
    accent: []const u8 = "#0a84ff",
    selection: []const u8 = "",
    rounding: ?f32 = null,
    font: ?[]const u8 = null,
};

const Look = struct {
    palette: Palette,
    theme: ui.Theme,
    radius: ?f32,
};

var loaded = false;
var look: ?Look = null;
var dark_desktop = false;
var font_buf: [128]u8 = undefined;

fn load() void {
    if (loaded) return;
    loaded = true;
    // Tests draw the built-in look, whatever this machine's file says.
    if (builtin.os.tag != .linux or builtin.is_test) return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var data_buf: [4096]u8 = undefined;
    if (path(&path_buf)) |p| if (read(p, &data_buf)) |data| {
        look = parse(data, &font_buf);
        if (look != null) return;
    };
    dark_desktop = desktopDark();
}

/// The panel's colors from the file, if there is one.
pub fn palette() ?Palette {
    load();
    return if (look) |l| l.palette else null;
}

/// The panel's corner radius.
pub fn radius() f32 {
    load();
    return if (look) |l| l.radius orelse default_radius else default_radius;
}

/// The window's theme: the file's, or dark when the desktop is. Null
/// leaves it to nanoui.
pub fn windowTheme() ?ui.Theme {
    load();
    if (look) |l| return l.theme;
    return if (dark_desktop) .dark_theme else null;
}

fn path(buf: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| if (x[0] != 0)
        return std.fmt.bufPrint(buf, "{s}/nanolight/theme.json", .{std.mem.span(x)}) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/nanolight/theme.json", .{std.mem.span(home)}) catch null;
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn read(p: []const u8, buf: []u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFile(io(), p, buf) catch null;
}

fn rgb(s: []const u8) ?ui.Color {
    const t = if (std.mem.startsWith(u8, s, "#")) s[1..] else s;
    if (t.len != 6) return null;
    return .hex(std.fmt.parseInt(u24, t, 16) catch return null);
}

/// The look a theme.json describes; null if it isn't one. The font's
/// name is copied into `font_out`, which must outlive the look.
fn parse(data: []const u8, font_out: []u8) ?Look {
    var arena_buf: [8192]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&arena_buf);
    const f = std.json.parseFromSliceLeaky(File, fba.allocator(), data, .{ .ignore_unknown_fields = true }) catch return null;
    const bg = rgb(f.background) orelse return null;
    const fg = rgb(f.foreground) orelse return null;
    const muted = rgb(f.muted) orelse fg.alpha(0.7);
    const accent = rgb(f.accent) orelse ui.Color.hex(0x0a84ff);
    const sel = rgb(f.selection) orelse if (f.dark) ui.Color.white.alpha(0.16) else ui.Color.black.alpha(0.08);
    const base = @import("palette.zig").grey(f.dark);
    var t: ui.Theme = if (f.dark) .dark_theme else .light;
    t.background = bg;
    t.surface = sel;
    t.surface_hover = sel;
    t.text = fg;
    t.muted = muted;
    t.accent = accent;
    t.accent_hover = accent;
    t.track = sel;
    if (f.font) |name| if (name.len > 0 and name.len <= font_out.len) {
        @memcpy(font_out[0..name.len], name);
        t.font = font_out[0..name.len];
        t.mono_font = t.font;
    };
    return .{
        // Hairlines, rims and tiles stay the built-in tints of the text's
        // side, so they suit whatever the background is.
        .palette = .{ .text = fg, .sub = muted, .hair = base.hair, .sel = sel, .rim = base.rim, .tile = base.tile, .fill = bg },
        .theme = t,
        .radius = if (f.rounding) |r| std.math.clamp(r, 0, 32) else null,
    };
}

/// Whether gsettings says the desktop is dark (`prefer-dark`, or a GTK
/// theme named dark), or `$GTK_THEME` does.
fn desktopDark() bool {
    if (std.c.getenv("GTK_THEME")) |v| if (std.ascii.findIgnoreCase(std.mem.span(v), "dark") != null) return true;
    return gsettings("color-scheme", "prefer-dark") or gsettings("gtk-theme", "dark");
}

fn gsettings(key: []const u8, needle: []const u8) bool {
    var child = std.process.spawn(io(), .{
        .argv = &.{ "gsettings", "get", "org.gnome.desktop.interface", key },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return false;
    defer _ = child.wait(io()) catch {};
    const out = child.stdout orelse return false;
    var buf: [128]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = out.readStreaming(io(), &.{buf[got..]}) catch break;
        if (n == 0) break;
        got += n;
    }
    return std.ascii.findIgnoreCase(buf[0..got], needle) != null;
}

test "theme.json sets the colors, corners and font" {
    var font: [128]u8 = undefined;
    const l = parse(
        \\{ "dark": true, "background": "#1a1b26", "foreground": "#a9b1d6", "muted": "#565f89",
        \\  "accent": "#7aa2f7", "selection": "#283457", "rounding": 10, "font": "JetBrainsMono Nerd Font",
        \\  "added_later": 1 }
    , &font).?;
    try std.testing.expectEqual(ui.Color.hex(0x1a1b26), l.palette.fill);
    try std.testing.expectEqual(ui.Color.hex(0xa9b1d6), l.palette.text);
    try std.testing.expectEqual(ui.Color.hex(0x283457), l.palette.sel);
    try std.testing.expectEqual(@as(?f32, 10), l.radius);
    try std.testing.expectEqualStrings("JetBrainsMono Nerd Font", l.theme.font.?);
    try std.testing.expect(l.theme.dark);
}

test "a theme.json without rounding keeps the corners; a broken one is ignored" {
    var font: [128]u8 = undefined;
    const l = parse(
        \\{ "dark": false, "background": "#fafafa", "foreground": "#333333" }
    , &font).?;
    try std.testing.expectEqual(@as(?f32, null), l.radius);
    try std.testing.expect(!l.theme.dark);
    try std.testing.expectEqual(@as(?[]const u8, null), l.theme.font);
    try std.testing.expectEqual(@as(?Look, null), parse("{ \"background\": \"red\" }", &font));
    try std.testing.expectEqual(@as(?Look, null), parse("not json", &font));
}
