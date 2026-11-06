//! The panel under keys, the wheel and answers in any order. Each seed plays
//! a long, repeatable run; after every step the panel must be one a person
//! could explain: its height at once, nothing on its way, no row cut by the
//! header or the footer, and the selection in view unless the wheel moved.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const suggest = @import("suggest.zig");
const results = @import("results.zig");
const tests = @import("tests.zig");

const expect = std.testing.expect;

const Run = struct {
    ix: Index,
    web: tests.Web = .{},
    s: view.Nanolight,
    t: ui.Tester = undefined,
    /// The wheel moved since the selection or the list last changed: the
    /// selection may be out of view.
    looked: bool = false,

    fn clear(r: *Run) void {
        r.t.textOps(&.{ .{ .command = .select_all }, .{ .command = .delete_backward } });
    }

    fn say(r: *Run, words: []const []const u8) void {
        var said: suggest.List = .{};
        for (words) |w| said.push(w);
        r.s.answered(r.s.query.text(), &said);
    }

    /// A step of the run.
    fn step(r: *Run, op: u8) !void {
        const t = &r.t;
        const s = &r.s;
        const was = .{ s.list_gen, s.sel };
        defer if (was[0] != s.list_gen or was[1] != s.sel) {
            r.looked = false;
        };
        switch (op) {
            0...5 => {
                if (s.query.text().len > 10) r.clear();
                const letters = "aemsqx ";
                t.textOps(&.{.{ .insert = letters[op .. op + 1] }});
            },
            6 => t.textOps(&.{.{ .command = .delete_backward }}),
            7, 8 => _ = t.shortcut(.{ .key = ui.Shortcut.down }),
            9 => _ = t.shortcut(.{ .key = ui.Shortcut.up }),
            10 => {
                t.scroll(view.width / 2, 200, -40);
                r.looked = true;
            },
            11 => {
                t.scroll(view.width / 2, 200, 17);
                r.looked = true;
            },
            12 => r.say(&.{ "aa one", "aa two", "aa three", "aa four" }),
            13 => r.say(&.{}),
            14 => s.unanswered(s.query.text()),
            // About other words, typed since: nothing changes.
            15 => {
                var said: suggest.List = .{};
                said.push("old words");
                s.answered("old", &said);
            },
            16 => {
                r.clear();
                t.textOps(&.{.{ .insert = "2+2" }});
            },
            // Opening again: off the Mac the panel has an entrance, and only that.
            17 => {
                s.reveal();
                t.settle(1);
            },
            18 => {
                s.openSettings();
                t.frame();
                // At its height at once, with no slide of its own.
                try std.testing.expectEqual(@import("settings_view.zig").height, s.last_h);
                try expect(!t.ctx.animating);
                s.settings_ui.hide();
                // The field's focus eases back: frames, but the same pixels.
                t.settle(1);
            },
            19 => {
                for (0..s.res.n) |_| {
                    if (s.res.rows[s.sel].kind == .search_web) break;
                    _ = t.shortcut(.{ .key = ui.Shortcut.down });
                }
                if (s.res.n == 0 or s.res.rows[s.sel].kind != .search_web) return;
                t.textOps(&.{.{ .command = .insert_newline }});
                t.frame();
                if (s.previewing) try std.testing.expectEqual(view.max_height, s.last_h);
                s.back();
            },
            else => unreachable,
        }
        t.frame();
    }

    fn check(r: *Run) !void {
        const s = &r.s;
        try std.testing.expectEqual(s.height(), s.last_h);
        try std.testing.expectEqual(view.rows_height, s.last_h);
        try expect(!r.t.ctx.animating);
        if (s.res.n > 0) try expect(s.sel < s.res.n);
        const top: f32 = view.header_h + 1;
        const fold = view.rows_height - view.footer_h - 1;
        for (r.t.ctx.nodes.items) |n| if (n.content == .text) {
            // In the header, in the footer, or wholly in the list.
            const b = n.rect.y + n.rect.h;
            if (b <= top or n.rect.y >= fold) continue;
            try expect(n.rect.y >= top and b <= fold);
        };
        // The selected row says what Return does (the math's card doesn't).
        if (!r.looked and s.res.n > 0 and s.res.rows[s.sel].kind != .calc and s.res.rows[s.sel].kind != .currency)
            try expect(r.t.hasText("Open") or r.t.hasText("Go"));
    }
};

test "any keys, wheel and answers leave a panel that can be explained" {
    const gpa = std.testing.allocator;
    for ([_]u64{ 1, 2, 3, 0x20261104 }) |seed| {
        var r: Run = .{ .ix = .init(gpa), .s = undefined };
        defer r.ix.deinit();
        for ([_][]const u8{ "Safari", "Mail", "Maps", "Music", "Notes", "Numbers", "Pages", "Photos", "Calendar", "Calculator", "Messages", "Safe" }) |n| {
            var buf: [64]u8 = undefined;
            try r.ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
        }
        r.s = .{ .index = &r.ix };
        defer r.s.query.deinit();
        r.s.host = r.web.host();
        r.s.host.?.resize = struct {
            fn f(_: *anyopaque, _: f32) void {}
        }.f;
        r.s.reveal();
        try r.t.init(gpa, .init(&r.s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .scale = 1 });
        defer r.t.deinit();
        r.t.settle(1);
        var prng: std.Random.DefaultPrng = .init(seed);
        const rand = prng.random();
        for (0..600) |i| {
            try r.step(rand.intRangeLessThan(u8, 0, 20));
            r.check() catch |e| {
                std.debug.print("seed {d}, step {d}, query \"{s}\", row {d} of {d}\n", .{ seed, i, r.s.query.text(), r.s.sel, r.s.res.n });
                return e;
            };
            // Now and then: the pixels are the state's, not on their way.
            if (i % 40 == 0) {
                const now = try r.t.render(gpa);
                defer now.deinit(gpa);
                r.t.advance(2);
                const later = try r.t.render(gpa);
                defer later.deinit(gpa);
                const from = @as(usize, view.header_h + 1) * now.width * 4;
                try std.testing.expectEqualSlices(u8, later.bytes[from..], now.bytes[from..]);
            }
        }
    }
}

test "a failed answer leaves no words from before, only what is known" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height });
    defer t.deinit();
    t.settle(1);
    tests.press(&t, &.{.{ .insert = "liq" }});
    var said: suggest.List = .{};
    for ([_][]const u8{ "liquid", "liqueur" }) |w| said.push(w);
    s.answered("liq", &said);
    t.frame();
    // A letter neither has: they hold while it's asked, then go.
    tests.press(&t, &.{.{ .insert = "x" }});
    try expect(t.hasText("liqueur"));
    // An answer to older words changes nothing.
    s.unanswered("liq");
    t.frame();
    try expect(t.hasText("liqueur"));
    s.unanswered("liqx");
    t.frame();
    try expect(!t.hasText("liqueur"));
    try std.testing.expectEqual(@as(usize, 0), s.web.n);
    // Words typed over don't hold at all.
    s.answered("liqx", &said);
    t.frame();
    try expect(t.hasText("liqueur"));
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "pizza" } });
    try expect(!t.hasText("liqueur"));
    // Suggestions turned off while one was on its way: it doesn't land.
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "zebra" } });
    s.suggest_on = false;
    var late: suggest.List = .{};
    late.push("zebra crossing");
    s.answered("zebra", &late);
    t.frame();
    try expect(!t.hasText("zebra crossing"));
}

test "a full list has no gap under it, and a selected row doesn't shift" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    for ([_][]const u8{ "Safari", "Mail", "Maps", "Music", "Notes", "Numbers", "Pages", "Photos", "Calendar", "Calculator" }) |n| {
        var buf: [64]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height });
    defer t.deinit();
    t.settle(1);
    tests.press(&t, &.{.{ .insert = "a" }});
    var four: suggest.List = .{};
    for ([_][]const u8{ "a1", "a2", "a3", "a4" }) |w| four.push(w);
    s.answered("a", &four);
    t.frame();
    // A full list: the apps, the search, a completion, and no gap under it.
    const first = s.res.rows[0];
    try std.testing.expectEqual(results.Kind.app, first.kind);
    try expect(t.hasText("Search Google for “a”"));
    try expect(t.hasText("a1"));
    try expect(!t.hasText("a2"));
    // A selected row's text sits where it did unselected.
    const name = "Search Google for “a”";
    const before = t.findText(name).?;
    while (s.res.rows[s.sel].kind != .search_web) _ = t.shortcut(.{ .key = ui.Shortcut.down });
    t.frame();
    const selected = t.findText(name).?;
    try std.testing.expectEqual(before.x, selected.x);
    try std.testing.expectEqual(before.y, selected.y);
}
