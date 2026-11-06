//! Clipboard history: the text copied lately, newest first, and what a
//! query finds in it. "clip" lists the latest; "clip words" those with the
//! words in them. Copying something again brings it back to the top. The
//! watching and the file are clipboard_live.zig's; this is the list.
const std = @import("std");

/// Entries kept: the oldest go first.
pub const max_entries = 300;
/// Longer copies (a whole file, a log) aren't kept.
pub const max_len = 32 * 1024;

pub const Entry = struct {
    text: []u8,
    /// When it was copied, in seconds since 1970.
    at: i64,
    /// Its own for as long as it is kept: rows hold this, not its place,
    /// which moves as more is copied.
    id: u32,
};

pub const History = struct {
    gpa: std.mem.Allocator,
    /// Newest first.
    entries: std.ArrayList(Entry) = .empty,
    next_id: u32 = 1,

    pub fn deinit(h: *History) void {
        for (h.entries.items) |e| h.gpa.free(e.text);
        h.entries.deinit(h.gpa);
    }

    /// Keeps `text`, copied `at`, on top. Nothing blank or too long; the
    /// same text again moves up rather than being kept twice. False when
    /// nothing changed.
    pub fn add(h: *History, text: []const u8, at: i64) bool {
        if (text.len == 0 or text.len > max_len) return false;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return false;
        if (!std.unicode.utf8ValidateSlice(text)) return false;
        for (h.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.text, text)) {
            if (i == 0) return false;
            const moved = h.entries.orderedRemove(i);
            h.entries.insert(h.gpa, 0, .{ .text = moved.text, .at = at, .id = moved.id }) catch {
                h.gpa.free(moved.text);
                return true;
            };
            return true;
        };
        const copy = h.gpa.dupe(u8, text) catch return false;
        h.entries.insert(h.gpa, 0, .{ .text = copy, .at = at, .id = h.next_id }) catch {
            h.gpa.free(copy);
            return false;
        };
        h.next_id +%= 1;
        while (h.entries.items.len > max_entries) h.gpa.free(h.entries.pop().?.text);
        return true;
    }

    /// The entry with this `id`, if it is still kept.
    pub fn get(h: *const History, id: u32) ?Entry {
        for (h.entries.items) |e| if (e.id == id) return e;
        return null;
    }

    /// The ids of the entries that hold `query` (any case), newest first,
    /// into `out`; with no words, the latest. Returns how many.
    pub fn find(h: *const History, query: []const u8, out: []u32) usize {
        const q = std.mem.trim(u8, query, " ");
        var n: usize = 0;
        for (h.entries.items, 0..) |e, i| {
            if (n == out.len) break;
            if (q.len == 0 or holds(e.text, q)) {
                out[n] = h.entries.items[i].id;
                n += 1;
            }
        }
        return n;
    }

    fn holds(hay: []const u8, needle: []const u8) bool {
        if (needle.len > hay.len) return false;
        for (0..hay.len - needle.len + 1) |i| {
            if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
        }
        return false;
    }

    /// As the file keeps them: per entry a line "<at> <len>", the text, a
    /// newline.
    pub fn encode(h: *const History, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // Oldest first, so decoding adds them in order.
        var i = h.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = h.entries.items[i];
            try w.print("{d} {d}\n", .{ e.at, e.text.len });
            try w.writeAll(e.text);
            try w.writeByte('\n');
        }
    }

    /// Adds what `encode` wrote; stops at the first entry it can't read.
    pub fn decode(h: *History, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return;
            var head = std.mem.splitScalar(u8, rest[0..nl], ' ');
            const at = std.fmt.parseInt(i64, head.next() orelse return, 10) catch return;
            const len = std.fmt.parseInt(usize, head.next() orelse return, 10) catch return;
            if (len > max_len) return;
            rest = rest[nl + 1 ..];
            if (len >= rest.len or rest[len] != '\n') return;
            _ = h.add(rest[0..len], at);
            rest = rest[len + 1 ..];
        }
    }
};

/// The words after "clip" or "clipboard" when the query asks for the
/// history ("clip", "clip invoice"), else null.
pub fn words(query: []const u8) ?[]const u8 {
    const q = std.mem.trimStart(u8, query, " ");
    for ([_][]const u8{ "clipboard", "clip" }) |k| {
        if (q.len < k.len or !std.ascii.eqlIgnoreCase(q[0..k.len], k)) continue;
        if (q.len == k.len) return "";
        if (q[k.len] == ' ') return std.mem.trim(u8, q[k.len..], " ");
    }
    return null;
}

/// `text` on one line for a row: runs of whitespace as one space, cut to
/// fit `buf`.
pub fn oneLine(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var space = false;
    for (std.mem.trim(u8, text, " \t\r\n")) |ch| {
        if (n == buf.len) break;
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
            space = true;
            continue;
        }
        if (space and n + 1 < buf.len) {
            buf[n] = ' ';
            n += 1;
        }
        space = false;
        buf[n] = ch;
        n += 1;
    }
    // Not halfway through a character.
    while (n > 0 and !std.unicode.utf8ValidateSlice(buf[0..n])) n -= 1;
    return buf[0..n];
}

/// How long ago `at` was, as a row says it: "Just now", "5 min ago",
/// "3 h ago", "2 d ago".
pub fn ago(buf: []u8, at: i64, now: i64) []const u8 {
    const s = @max(0, now -| at);
    if (s < 60) return "Just now";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d} min ago", .{@divTrunc(s, 60)}) catch "";
    if (s < 86400) return std.fmt.bufPrint(buf, "{d} h ago", .{@divTrunc(s, 3600)}) catch "";
    return std.fmt.bufPrint(buf, "{d} d ago", .{@divTrunc(s, 86400)}) catch "";
}

test "the history keeps the newest on top, once each, and lets the oldest go" {
    const t = std.testing;
    var h: History = .{ .gpa = t.allocator };
    defer h.deinit();
    try t.expect(h.add("one", 1));
    try t.expect(h.add("two", 2));
    try t.expect(!h.add("two", 3)); // already on top
    try t.expect(!h.add("   \n", 4));
    try t.expect(!h.add("", 4));
    try t.expect(h.add("one", 5)); // up again
    try t.expectEqual(@as(usize, 2), h.entries.items.len);
    try t.expectEqualStrings("one", h.entries.items[0].text);
    try t.expectEqual(@as(i64, 5), h.entries.items[0].at);
    for (0..max_entries + 5) |i| {
        var b: [16]u8 = undefined;
        _ = h.add(try std.fmt.bufPrint(&b, "e{d}", .{i}), @intCast(10 + i));
    }
    try t.expectEqual(@as(usize, max_entries), h.entries.items.len);
    const big = try t.allocator.alloc(u8, max_len + 1);
    defer t.allocator.free(big);
    @memset(big, 'x');
    try t.expect(!h.add(big, 0));
}

test "it finds words in any case, newest first, and lists the latest for none" {
    const t = std.testing;
    var h: History = .{ .gpa = t.allocator };
    defer h.deinit();
    _ = h.add("Invoice 2041", 1);
    _ = h.add("ssh george@opti", 2);
    _ = h.add("invoice total: $40", 3);
    var out: [8]u32 = undefined;
    const n = h.find(" INVOICE ", &out);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqualStrings("invoice total: $40", h.get(out[0]).?.text);
    try t.expectEqualStrings("Invoice 2041", h.get(out[1]).?.text);
    // Copying more moves places, not ids.
    _ = h.add("new", 4);
    try t.expectEqualStrings("Invoice 2041", h.get(out[1]).?.text);
    try t.expectEqual(@as(usize, 4), h.find("", &out));
    var two: [2]u32 = undefined;
    try t.expectEqual(@as(usize, 2), h.find("", &two));
}

test "the file reads back as it was written, even with newlines in an entry" {
    const t = std.testing;
    var h: History = .{ .gpa = t.allocator };
    defer h.deinit();
    _ = h.add("first\nline two", 100);
    _ = h.add("second", 200);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try h.encode(&w);
    var back: History = .{ .gpa = t.allocator };
    defer back.deinit();
    back.decode(w.buffered());
    try t.expectEqual(@as(usize, 2), back.entries.items.len);
    try t.expectEqualStrings("second", back.entries.items[0].text);
    try t.expectEqualStrings("first\nline two", back.entries.items[1].text);
    try t.expectEqual(@as(i64, 100), back.entries.items[1].at);
    // A cut-off file keeps what came before the cut.
    var cut: History = .{ .gpa = t.allocator };
    defer cut.deinit();
    cut.decode(w.buffered()[0 .. w.buffered().len - 3]);
    try t.expectEqual(@as(usize, 1), cut.entries.items.len);
    // Nonsense lengths and times are refused or harmless.
    var bad: History = .{ .gpa = t.allocator };
    defer bad.deinit();
    bad.decode("1 18446744073709551615\nxx\n");
    bad.decode("1 5\nabc");
    bad.decode("1 3\nabc");
    try t.expectEqual(@as(usize, 0), bad.entries.items.len);
    bad.decode("-9223372036854775808 2\nok\n");
    var ab: [24]u8 = undefined;
    _ = ago(&ab, bad.entries.items[0].at, std.math.maxInt(i64));
}

test "\"clip\" asks for the history; other words don't" {
    const t = std.testing;
    try t.expectEqualStrings("", words("clip").?);
    try t.expectEqualStrings("", words("Clipboard ").?);
    try t.expectEqualStrings("invoice 20", words("clip  invoice 20").?);
    try t.expectEqualStrings("x", words("clipboard x").?);
    try t.expect(words("clips") == null);
    try t.expect(words("clipper") == null);
    try t.expect(words("safari") == null);
}

test "a row shows an entry on one line, and how long ago" {
    const t = std.testing;
    var buf: [12]u8 = undefined;
    try t.expectEqualStrings("a b c", oneLine(&buf, "  a\n\n b\tc \n"));
    try t.expectEqualStrings("0123456789ab", oneLine(&buf, "0123456789abcdef"));
    // Never half of "é".
    try t.expectEqualStrings("01234567890", oneLine(&buf, "01234567890é"));
    var ab: [24]u8 = undefined;
    try t.expectEqualStrings("Just now", ago(&ab, 100, 130));
    try t.expectEqualStrings("5 min ago", ago(&ab, 0, 300));
    try t.expectEqualStrings("3 h ago", ago(&ab, 0, 3 * 3600 + 5));
    try t.expectEqualStrings("2 d ago", ago(&ab, 0, 2 * 86400));
}
