//! The people in Contacts, held in memory for scoped rows ("Messages ›
//! sha" lists Shawn): names and their phone numbers and email addresses,
//! nothing else. Filled off the main thread (into_mac.zig) once Contacts
//! access is granted; never written anywhere, never sent anywhere.
const std = @import("std");
const search = @import("search.zig");

pub const Handle = struct {
    /// A phone number as Contacts keeps it ("+1 (555) 010-0000"), or an email.
    value: []const u8,
    email: bool,
    /// Contacts' label for it, plain: "mobile", "home", "" for none.
    label: []const u8 = "",
};

pub const Person = struct {
    name: []const u8,
    /// Into `Book.handles`.
    first: u32,
    count: u16,
};

pub const Book = struct {
    arena: std.heap.ArenaAllocator,
    people: std.ArrayList(Person) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    handles: std.ArrayList(Handle) = .empty,

    pub fn init(gpa: std.mem.Allocator) Book {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(b: *Book) void {
        b.arena.deinit();
    }

    /// One person with their handles. Copies everything. People with no
    /// name or no handle are left out: no row could do anything with them.
    pub fn add(b: *Book, name_in: []const u8, handles: []const Handle) !void {
        const name = std.mem.trim(u8, name_in, " \t\r\n");
        if (name.len == 0 or handles.len == 0) return;
        const a = b.arena.allocator();
        const first: u32 = @intCast(b.handles.items.len);
        var count: u16 = 0;
        for (handles) |h| {
            const v = std.mem.trim(u8, h.value, " \t\r\n");
            if (v.len == 0 or count == std.math.maxInt(u16)) continue;
            try b.handles.append(a, .{ .value = try a.dupe(u8, v), .email = h.email, .label = try a.dupe(u8, h.label) });
            count += 1;
        }
        if (count == 0) return;
        const own = try a.dupe(u8, name);
        try b.people.append(a, .{ .name = own, .first = first, .count = count });
        try b.names.append(a, own);
    }

    pub fn handlesOf(b: *const Book, p: Person) []const Handle {
        return b.handles.items[p.first..][0..p.count];
    }

    /// The best `out.len` people for `query`, best first.
    pub fn find(b: *const Book, query: []const u8, out: []search.Ranked) usize {
        if (std.mem.trim(u8, query, " ").len == 0) return 0;
        return search.rank(query, b.names.items, &.{}, out);
    }

    /// Their first handle of the kind wanted: an email for Mail, a phone
    /// (else an email, which iMessage takes too) for Messages and FaceTime.
    pub fn best(b: *const Book, p: Person, email: bool) ?Handle {
        const hs = b.handlesOf(p);
        for (hs) |h| if (h.email == email) return h;
        if (email) return null;
        return if (hs.len > 0) hs[0] else null;
    }
};

/// A phone number as an address: digits, and a leading `+`.
pub fn dialable(buf: []u8, phone: []const u8) []const u8 {
    var n: usize = 0;
    for (phone) |ch| {
        if (n == buf.len) break;
        if (std.ascii.isDigit(ch) or (ch == '+' and n == 0)) {
            buf[n] = ch;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Contacts' labels look like `_$!<Mobile>!$_`; this is "mobile".
pub fn plainLabel(buf: []u8, raw: []const u8) []const u8 {
    var s = raw;
    if (std.mem.startsWith(u8, s, "_$!<") and std.mem.endsWith(u8, s, ">!$_")) s = s[4 .. s.len - 4];
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

test "people are found by name, initials and typos, with their best handle" {
    const t = std.testing;
    var b: Book = .init(t.allocator);
    defer b.deinit();
    try b.add("Shawn Georgie", &.{ .{ .value = "shawn@example.com", .email = true }, .{ .value = "+1 (555) 010-0000", .email = false, .label = "mobile" } });
    try b.add("Sunny", &.{.{ .value = "+1 555 010 0001", .email = false }});
    try b.add("No Handles", &.{});
    try b.add("  ", &.{.{ .value = "x@y.z", .email = true }});
    try t.expectEqual(@as(usize, 2), b.people.items.len);
    var out: [4]search.Ranked = undefined;
    try t.expect(b.find("sha", &out) >= 1);
    try t.expectEqualStrings("Shawn Georgie", b.people.items[out[0].index].name);
    try t.expect(b.find("sg", &out) >= 1);
    try t.expectEqualStrings("Shawn Georgie", b.people.items[out[0].index].name);
    try t.expectEqual(@as(usize, 0), b.find("", &out));
    const shawn = b.people.items[0];
    try t.expectEqualStrings("+1 (555) 010-0000", b.best(shawn, false).?.value);
    try t.expectEqualStrings("shawn@example.com", b.best(shawn, true).?.value);
    try t.expect(b.best(b.people.items[1], true) == null);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("+15550100000", dialable(&buf, "+1 (555) 010-0000"));
    try t.expectEqualStrings("5550100001", dialable(&buf, "(555) 010-0001"));
    try t.expectEqualStrings("mobile", plainLabel(&buf, "_$!<Mobile>!$_"));
    try t.expectEqualStrings("work", plainLabel(&buf, "Work"));
}
