//! Currency typed into the bar: "100 USD to EUR", answered from
//! Frankfurter's ECB daily rates (api.frankfurter.dev). No key, no
//! invented numbers: a missing or failed rate leaves the row waiting, or
//! says the rates are away.
const std = @import("std");

/// How long a cached answer is kept before asking again (one day).
pub const fresh_s: i64 = 24 * 60 * 60;
/// A longer answer is not read.
pub const max_bytes = 8 * 1024;
/// How long typing pauses before asking, as suggest.zig does.
pub const pause_ms = 90;

/// ISO codes Frankfurter publishes (ECB). Anything else is not a conversion.
const codes = [_][]const u8{
    "AUD", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD",
    "HUF", "IDR", "ILS", "INR", "ISK", "JPY", "KRW", "MXN", "MYR", "NOK",
    "NZD", "PHP", "PLN", "RON", "SEK", "SGD", "THB", "TRY", "USD", "ZAR",
};

pub const Query = struct {
    amount: f64,
    from: [3]u8,
    to: [3]u8,

    pub fn fromSlice(q: *const Query) []const u8 {
        return q.from[0..3];
    }
    pub fn toSlice(q: *const Query) []const u8 {
        return q.to[0..3];
    }
};

pub const Answer = struct {
    /// The converted amount (Frankfurter's `rates.to`).
    value: f64 = 0,
    /// The amount that was asked.
    amount: f64 = 0,
    from: [3]u8 = .{ 'U', 'S', 'D' },
    to: [3]u8 = .{ 'E', 'U', 'R' },
    /// ECB's rate date, "YYYY-MM-DD".
    date: [10]u8 = undefined,
    date_len: u8 = 0,
    /// When this answer was kept, unix seconds (0 = unset).
    at: i64 = 0,

    pub fn dateSlice(a: *const Answer) []const u8 {
        return a.date[0..a.date_len];
    }

    pub fn fromSlice(a: *const Answer) []const u8 {
        return a.from[0..3];
    }

    pub fn toSlice(a: *const Answer) []const u8 {
        return a.to[0..3];
    }

    pub fn matches(a: *const Answer, q: Query) bool {
        return a.amount == q.amount and std.mem.eql(u8, a.fromSlice(), q.fromSlice()) and std.mem.eql(u8, a.toSlice(), q.toSlice());
    }
};

/// One remembered answer: enough for a burst of keys on the same pair.
pub const Cache = struct {
    last: ?Answer = null,

    pub fn get(c: *const Cache, q: Query) ?Answer {
        const a = c.last orelse return null;
        if (!a.matches(q)) return null;
        return a;
    }

    pub fn put(c: *Cache, a: Answer) void {
        c.last = a;
    }
};

/// Whether `s` is one of Frankfurter's codes (ASCII, case-folded).
pub fn isCode(s: []const u8) bool {
    if (s.len != 3) return false;
    var buf: [3]u8 = undefined;
    for (s, 0..) |ch, i| {
        if (!std.ascii.isAlphabetic(ch)) return false;
        buf[i] = std.ascii.toUpper(ch);
    }
    for (codes) |c| if (std.mem.eql(u8, c, &buf)) return true;
    return false;
}

fn foldCode(out: *[3]u8, s: []const u8) void {
    out.* = .{ std.ascii.toUpper(s[0]), std.ascii.toUpper(s[1]), std.ascii.toUpper(s[2]) };
}

/// `query` as a conversion, or null. Forms:
///   100 USD to EUR
///   100usd in sgd
///   50 EUR GBP
/// Math (`2^10 * 3`) is left to calc.zig; bare amounts stay searches.
pub fn parse(query: []const u8) ?Query {
    const s = std.mem.trim(u8, query, " \t=");
    if (s.len < 7) return null;

    // Optional leading amount glued to a code: "100usd to eur".
    var i: usize = 0;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.' or s[i] == ',' or s[i] == '-' or s[i] == '+')) i += 1;
    if (i == 0 or i == s.len) return null;

    var amount_buf: [32]u8 = undefined;
    var an: usize = 0;
    for (s[0..i]) |ch| {
        if (ch == ',') continue;
        if (an == amount_buf.len) return null;
        amount_buf[an] = ch;
        an += 1;
    }
    const amount = std.fmt.parseFloat(f64, amount_buf[0..an]) catch return null;
    if (std.math.isNan(amount) or std.math.isInf(amount)) return null;

    var rest = std.mem.trim(u8, s[i..], " \t");
    var from_s: []const u8 = undefined;
    if (rest.len >= 3 and isCode(rest[0..3]) and (rest.len == 3 or !std.ascii.isAlphabetic(rest[3]))) {
        from_s = rest[0..3];
        rest = std.mem.trim(u8, rest[3..], " \t");
    } else return null;

    // Optional "to" / "in" / "as" / "into".
    for ([_][]const u8{ "into", "to", "in", "as" }) |w| {
        if (rest.len >= w.len and std.ascii.eqlIgnoreCase(rest[0..w.len], w)) {
            const after = if (rest.len == w.len) "" else rest[w.len..];
            if (after.len == 0 or after[0] == ' ' or after[0] == '\t') {
                rest = std.mem.trim(u8, after, " \t");
                break;
            }
        }
    }

    if (rest.len < 3 or !isCode(rest[0..3])) return null;
    // Nothing after the second code (except spaces).
    const tail = std.mem.trim(u8, rest[3..], " \t");
    if (tail.len != 0) return null;
    const to_s = rest[0..3];
    if (std.ascii.eqlIgnoreCase(from_s, to_s)) return null;

    var q: Query = .{ .amount = amount, .from = undefined, .to = undefined };
    foldCode(&q.from, from_s);
    foldCode(&q.to, to_s);
    return q;
}

/// The address that converts `amount` of `from` into `to`.
pub fn url(buf: []u8, amount: f64, from: []const u8, to: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "https://api.frankfurter.dev/v1/latest?amount={d}&from={s}&to={s}", .{ amount, from, to }) catch "";
}

/// Frankfurter's JSON (`{"amount", "base", "date", "rates": {to: n}}`) as an
/// answer for `q`. False when it isn't one, or answers other codes.
pub fn decode(body: []const u8, q: Query, out: *Answer) bool {
    if (body.len == 0 or body.len > max_bytes) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return false;
    defer parsed.deinit();
    const v = parsed.value;
    if (v != .object) return false;
    const base = v.object.get("base") orelse return false;
    const date = v.object.get("date") orelse return false;
    const rates = v.object.get("rates") orelse return false;
    if (base != .string or date != .string or rates != .object) return false;
    if (!std.ascii.eqlIgnoreCase(base.string, q.fromSlice())) return false;
    if (date.string.len != 10) return false;
    const rate = rates.object.get(q.toSlice()) orelse return false;
    const value: f64 = switch (rate) {
        .float => rate.float,
        .integer => @floatFromInt(rate.integer),
        .number_string => std.fmt.parseFloat(f64, rate.number_string) catch return false,
        else => return false,
    };
    if (std.math.isNan(value) or std.math.isInf(value)) return false;
    out.* = .{
        .value = value,
        .amount = q.amount,
        .from = q.from,
        .to = q.to,
        .date_len = 10,
        .at = 0,
    };
    @memcpy(out.date[0..10], date.string[0..10]);
    return true;
}

/// The converted amount as the row shows it (grouped) or the clipboard takes it.
pub fn format(buf: []u8, v: f64, grouped: bool) []const u8 {
    return @import("calc.zig").format(buf, v, grouped);
}

/// A short chip under the answer: "ECB · 2026-11-05", or a status.
pub fn note(buf: []u8, a: Answer) []const u8 {
    if (a.date_len == 0) return "ECB";
    return std.fmt.bufPrint(buf, "ECB · {s}", .{a.dateSlice()}) catch "ECB";
}

test "conversions parse; math and names do not" {
    const t = std.testing;
    const a = parse("100 USD to EUR").?;
    try t.expectEqual(@as(f64, 100), a.amount);
    try t.expectEqualStrings("USD", a.fromSlice());
    try t.expectEqualStrings("EUR", a.toSlice());
    try t.expect(parse("100usd in sgd") != null);
    try t.expect(parse("50 EUR GBP") != null);
    try t.expect(parse("1,000 jpy to usd") != null);
    try t.expect(parse("100 USD to USD") == null);
    try t.expect(parse("100 XYZ to EUR") == null);
    try t.expect(parse("100 USD") == null);
    try t.expect(parse("2^10 * 3") == null);
    try t.expect(parse("safari") == null);
    try t.expect(parse("42") == null);
    try t.expect(isCode("usd") and isCode("EUR") and !isCode("USDT") and !isCode("XY"));
}

test "Frankfurter's answer is read; a wrong base is not" {
    const t = std.testing;
    const q = parse("100 USD to EUR").?;
    var a: Answer = .{};
    const body =
        \\{"amount":100.0,"base":"USD","date":"2026-11-05","rates":{"EUR":89.09}}
    ;
    try t.expect(decode(body, q, &a));
    try t.expectEqual(@as(f64, 89.09), a.value);
    try t.expectEqualStrings("2026-11-05", a.dateSlice());
    try t.expect(a.matches(q));
    const wrong =
        \\{"amount":100.0,"base":"EUR","date":"2026-11-05","rates":{"USD":1.12}}
    ;
    try t.expect(!decode(wrong, q, &a));
    try t.expect(!decode("not json", q, &a));
    try t.expect(!decode("", q, &a));
}

test "a cache keeps the last matching answer" {
    const t = std.testing;
    const q = parse("10 SGD to USD").?;
    var c: Cache = .{};
    var a: Answer = .{ .value = 7.5, .amount = 10, .from = q.from, .to = q.to, .date_len = 10 };
    @memcpy(a.date[0..10], "2026-11-05");
    c.put(a);
    try t.expect(c.get(q) != null);
    try t.expect(c.get(parse("10 SGD to EUR").?) == null);
}
