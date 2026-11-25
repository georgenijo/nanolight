//! Into an app: Tab on an app's row puts the field inside it ("Messages ›"),
//! and what is typed next lists what that app can do with it. Each app gets
//! a handler: Messages, Mail and FaceTime find people in Contacts and open
//! their conversation by its address; a browser opens an address or a
//! search in itself; Maps searches or gives directions; System Settings
//! lists its panes; any other app is opened and what was typed goes into
//! its own search (into_mac.zig, through Accessibility).
//!
//! Typed in full, "messages to shawn", "text shawn" or "safari apple.com"
//! lists the same rows without Tab (`parseInline`).
//!
//! All of it is local and plain code: a row is listed in the frame the
//! key was pressed in, and nothing typed leaves the computer.
const std = @import("std");
const search = @import("search.zig");
const contacts = @import("contacts.zig");
const results = @import("results.zig");
const panes = @import("settings_panes.zig");
const Index = @import("apps.zig").Index;

pub const Handler = enum {
    messages,
    mail,
    facetime,
    browser,
    maps,
    settings,
    generic,

    const browsers = [_][]const u8{
        "Safari",          "Safari Technology Preview", "Google Chrome", "Google Chrome Canary", "Google Chrome Beta",
        "Chromium",        "Arc",                       "Firefox",       "Firefox Developer Edition", "Firefox Nightly",
        "Brave Browser",   "Microsoft Edge",            "Dia",           "Orion",                 "Zen",
        "Zen Browser",     "Vivaldi",                   "Opera",         "Helium",                "Comet",
    };

    /// What an app's name says it can do.
    pub fn of(name: []const u8) Handler {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(name, "Messages")) return .messages;
        if (eq(name, "Mail")) return .mail;
        if (eq(name, "FaceTime")) return .facetime;
        if (eq(name, "Maps")) return .maps;
        if (eq(name, "System Settings") or eq(name, "System Preferences")) return .settings;
        for (browsers) |b| if (eq(name, b)) return .browser;
        return .generic;
    }

    /// Finds people in Contacts.
    pub fn people(h: Handler) bool {
        return h == .messages or h == .mail or h == .facetime;
    }

    /// Whether Nanolight drives the app itself on Return (and so starts it
    /// as soon as the field goes into it, to have it ready).
    pub fn warms(h: Handler) bool {
        return h != .browser and h != .settings;
    }
};

pub const Go = enum {
    /// `target` is an address the system opens (imessage:, mailto:, maps:).
    url,
    /// `target` is opened by the app itself (a browser).
    url_in_app,
    /// The app comes forward and `target` is typed into its search.
    search_in_app,
    /// The app comes forward.
    open_app,
    /// Asks for Contacts access.
    ask_contacts,
};

/// Contacts access, as the system has it.
pub const Access = enum { unknown, denied, granted };

pub const Item = struct {
    go: Go,
    /// The app's index.
    app: u32,
    /// What Return does, for the footer: "Message", "Search", "Open".
    verb: []const u8,
    /// A person's row: its title is their name, Tab completes to it, and
    /// its tile is their initials.
    person: bool = false,
    symbol: []const u8 = "",
    match: search.Match = .{ .score = 0 },
    title_buf: [160]u8 = undefined,
    title_len: u8 = 0,
    sub_buf: [160]u8 = undefined,
    sub_len: u8 = 0,
    target_buf: [1024]u8 = undefined,
    target_len: u16 = 0,

    pub fn title(i: *const Item) []const u8 {
        return i.title_buf[0..i.title_len];
    }
    pub fn sub(i: *const Item) []const u8 {
        return i.sub_buf[0..i.sub_len];
    }
    pub fn target(i: *const Item) []const u8 {
        return i.target_buf[0..i.target_len];
    }

    fn setTitle(i: *Item, comptime fmt: []const u8, args: anytype) void {
        i.title_len = @intCast(clip(&i.title_buf, fmt, args).len);
    }
    fn setSub(i: *Item, comptime fmt: []const u8, args: anytype) void {
        i.sub_len = @intCast(clip(&i.sub_buf, fmt, args).len);
    }
    fn setTarget(i: *Item, comptime fmt: []const u8, args: anytype) void {
        i.target_len = @intCast(clip(&i.target_buf, fmt, args).len);
    }

    /// The person's initials, for their tile: "SG".
    pub fn initials(i: *const Item, buf: *[8]u8) []const u8 {
        var n: usize = 0;
        var count: usize = 0;
        var words = std.mem.tokenizeScalar(u8, i.title(), ' ');
        while (words.next()) |w| {
            if (count == 2) break;
            const len = std.unicode.utf8ByteSequenceLength(w[0]) catch continue;
            if (len > w.len or n + len > buf.len) break;
            if (len == 1) {
                if (!std.ascii.isAlphanumeric(w[0])) continue;
                buf[n] = std.ascii.toUpper(w[0]);
            } else @memcpy(buf[n..][0..len], w[0..len]);
            n += len;
            count += 1;
        }
        return buf[0..n];
    }
};

/// The rows it lists, at most a full panel's.
pub const max = results.max_rows;
/// People listed at once, leaving room for the app's own search.
pub const max_people = 6;

pub const List = struct {
    items: [max]Item = undefined,
    n: usize = 0,

    pub fn slice(l: *const List) []const Item {
        return l.items[0..l.n];
    }

    fn push(l: *List, go: Go, app: u32, verb: []const u8) ?*Item {
        if (l.n == max) return null;
        l.items[l.n] = .{ .go = go, .app = app, .verb = verb };
        l.n += 1;
        return &l.items[l.n - 1];
    }
};

pub const Scope = struct {
    app: u32,
    name: []const u8,
    handler: Handler,
};

pub const Book = contacts.Book;

/// Lists what `sc`'s app does with `query_in`.
/// `can_type`: Accessibility lets Nanolight type into the app's search;
/// without it the words are copied for ⌘V.
pub fn build(l: *List, sc: Scope, query_in: []const u8, book: ?*const Book, access: Access, can_type: bool) void {
    l.n = 0;
    const q = std.mem.trim(u8, query_in, " \t\r\n");
    switch (sc.handler) {
        .messages, .mail, .facetime => people(l, sc, q, book, access),
        .browser => browser(l, sc, q),
        .maps => maps(l, sc, q),
        .settings => settings(l, sc, q),
        .generic => {},
    }
    // Every app keeps its own search for what was typed, and itself.
    if (q.len > 0 and sc.handler != .browser and sc.handler != .settings and sc.handler != .maps) if (l.push(.search_in_app, sc.app, "Search")) |it| {
        it.setTitle("Search {s} for “{s}”", .{ sc.name, q });
        if (can_type)
            it.setSub("Types it into {s}'s search", .{sc.name})
        else
            it.setSub("Copies it for ⌘V (Accessibility is off)", .{});
        it.setTarget("{s}", .{q});
        it.symbol = "magnifyingglass";
    };
    if (l.push(.open_app, sc.app, "Open")) |it| {
        it.setTitle("Open {s}", .{sc.name});
        it.setSub("Application", .{});
    }
}

/// The words people put before a name: "to shawn", "with sunny".
fn stripLead(q: []const u8) []const u8 {
    const leads = [_][]const u8{ "to ", "with ", "for ", "@" };
    for (leads) |w| if (q.len > w.len and std.ascii.startsWithIgnoreCase(q, w)) return std.mem.trimStart(u8, q[w.len..], " ");
    return q;
}

fn people(l: *List, sc: Scope, q_in: []const u8, book: ?*const Book, access: Access) void {
    const q = stripLead(q_in);
    if (q.len == 0) {
        switch (sc.handler) {
            .messages => if (l.push(.url, sc.app, "New Message")) |it| {
                it.setTitle("New Message", .{});
                it.setSub("Messages", .{});
                it.setTarget("imessage://", .{});
                it.symbol = "square.and.pencil";
            },
            .mail => if (l.push(.url, sc.app, "New Email")) |it| {
                it.setTitle("New Email", .{});
                it.setSub("Mail", .{});
                it.setTarget("mailto:", .{});
                it.symbol = "square.and.pencil";
            },
            else => {},
        }
        return;
    }
    // An address typed in full: a number or an email, as it is.
    var dial: [64]u8 = undefined;
    const digits = contacts.dialable(&dial, q);
    const is_phone = digits.len >= 5 and onlyPhone(q);
    const is_email = looksEmail(q);
    if (is_phone and sc.handler != .mail) addressRow(l, sc, digits, q);
    if (is_email) addressRow(l, sc, q, q);
    if (is_phone or is_email) return;
    const b = book orelse {
        if (l.push(if (access == .denied) .url else .ask_contacts, sc.app, if (access == .denied) "Open Privacy Settings" else "Allow")) |it| {
            it.setTitle("Find people in Contacts", .{});
            if (access == .denied)
                it.setSub("Turn on Contacts for Nanolight in Privacy & Security", .{})
            else
                it.setSub("Nanolight keeps them on this Mac and sends them nowhere", .{});
            it.setTarget("x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts", .{});
            it.symbol = "person.crop.circle.badge.plus";
        }
        return;
    };
    // "shawn running late": a person, then what to tell them (Messages).
    if (sc.handler == .messages) if (split(b, q)) |sp| {
        const p = b.people.items[sp.person];
        if (b.best(p, false)) |h| if (l.push(.url, sc.app, "Write Message")) |it| {
            it.person = true;
            it.match = sp.match;
            it.setTitle("{s}", .{p.name});
            it.setSub("“{s}” · written for you, not sent", .{sp.body});
            // Messages opens the conversation with the words in its field.
            var d: [64]u8 = undefined;
            var w: std.Io.Writer = .fixed(&it.target_buf);
            w.print("sms://open?addresses={s}&body=", .{if (h.email) h.value else contacts.dialable(&d, h.value)}) catch {};
            percent(&w, sp.body);
            it.target_len = @intCast(w.buffered().len);
        };
    };
    var ranked: [max_people]search.Ranked = undefined;
    const n = b.find(q, &ranked);
    for (ranked[0..n]) |r| {
        const p = b.people.items[r.index];
        const email = sc.handler == .mail;
        const h = b.best(p, email) orelse continue;
        const verb: []const u8 = switch (sc.handler) {
            .messages => "Message",
            .mail => "New Email",
            else => "FaceTime",
        };
        const it = l.push(.url, sc.app, verb) orelse return;
        it.person = true;
        it.match = r.match;
        it.setTitle("{s}", .{p.name});
        var lb: [32]u8 = undefined;
        const label = contacts.plainLabel(&lb, h.label);
        if (label.len > 0) it.setSub("{s} · {s}", .{ label, h.value }) else it.setSub("{s}", .{h.value});
        setAddress(it, sc.handler, h);
        // FaceTime: an audio call too, for the best match.
        if (sc.handler == .facetime and r.index == ranked[0].index) if (l.push(.url, sc.app, "Call")) |a| {
            a.person = true;
            a.match = r.match;
            a.setTitle("{s}", .{p.name});
            a.setSub("FaceTime Audio · {s}", .{h.value});
            var d: [64]u8 = undefined;
            a.setTarget("facetime-audio://{s}", .{if (h.email) h.value else contacts.dialable(&d, h.value)});
        };
    }
}

fn addressRow(l: *List, sc: Scope, addr: []const u8, shown: []const u8) void {
    const it = l.push(.url, sc.app, switch (sc.handler) {
        .mail => "New Email",
        .facetime => "FaceTime",
        else => "Message",
    }) orelse return;
    it.setTitle("{s}", .{shown});
    it.setSub("{s}", .{sc.name});
    it.symbol = "person.crop.circle";
    it.setTarget("{s}{s}", .{ scheme(sc.handler), addr });
}

fn scheme(h: Handler) []const u8 {
    return switch (h) {
        .mail => "mailto:",
        .facetime => "facetime://",
        else => "imessage://",
    };
}

fn setAddress(it: *Item, h: Handler, handle: contacts.Handle) void {
    var d: [64]u8 = undefined;
    it.setTarget("{s}{s}", .{ scheme(h), if (handle.email) handle.value else contacts.dialable(&d, handle.value) });
}

const Split = struct { person: u32, match: search.Match, body: []const u8 };

/// The longest run of first words that names someone well (their name or
/// a word of it from its start), and the words after it.
fn split(b: *const Book, q: []const u8) ?Split {
    // "shawn georgie" is Shawn, not Shawn told "georgie".
    for (b.names.items) |n| if (search.score(q, n)) |m| if (m.score >= 700) return null;
    var cut: usize = q.len;
    while (std.mem.lastIndexOfScalar(u8, q[0..cut], ' ')) |sp| {
        cut = sp;
        const name = std.mem.trim(u8, q[0..sp], " ");
        const rest = std.mem.trim(u8, q[sp + 1 ..], " ");
        if (name.len < 2 or rest.len == 0) continue;
        var best: ?Split = null;
        for (b.names.items, 0..) |n, i| {
            const m = search.score(name, n) orelse continue;
            // A whole name, or the start of one of its words.
            if (m.score < 700) continue;
            if (best == null or m.score > best.?.match.score) best = .{ .person = @intCast(i), .match = m, .body = rest };
        }
        if (best) |x| return x;
    }
    return null;
}

/// `s` as a URL's value, every byte that isn't plain as `%XX` (spaces too:
/// Messages takes `+` for itself).
fn percent(w: *std.Io.Writer, s: []const u8) void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            w.writeByte(ch) catch return;
        } else w.print("%{X:0>2}", .{ch}) catch return;
    }
}

fn onlyPhone(q: []const u8) bool {
    for (q) |ch| if (!(std.ascii.isDigit(ch) or ch == '+' or ch == ' ' or ch == '-' or ch == '(' or ch == ')' or ch == '.')) return false;
    return true;
}

fn looksEmail(q: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, q, '@') orelse return false;
    if (at == 0 or std.mem.indexOfScalar(u8, q, ' ') != null) return false;
    const dot = std.mem.lastIndexOfScalar(u8, q, '.') orelse return false;
    return dot > at + 1 and dot + 1 < q.len;
}

/// An address rather than words to search: "apple.com", "localhost:3000",
/// "https://…".
pub fn looksAddress(q: []const u8) bool {
    if (q.len == 0 or std.mem.indexOfAny(u8, q, " \t") != null) return false;
    if (std.mem.indexOf(u8, q, "://") != null) return true;
    if (std.ascii.startsWithIgnoreCase(q, "localhost")) return true;
    const host_end = std.mem.indexOfAny(u8, q, "/?#") orelse q.len;
    const host = q[0..host_end];
    const dot = std.mem.lastIndexOfScalar(u8, host, '.') orelse return false;
    if (dot == 0 or dot + 1 >= host.len) return false;
    // The part after the last dot: letters (a domain) or digits (an IP).
    const tld = host[dot + 1 ..];
    const colon = std.mem.indexOfScalar(u8, tld, ':') orelse tld.len;
    for (tld[0..colon]) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    if (std.ascii.isDigit(tld[0])) return std.mem.count(u8, host, ".") == 3;
    return colon >= 2;
}

fn browser(l: *List, sc: Scope, q: []const u8) void {
    if (q.len == 0) return;
    if (looksAddress(q)) if (l.push(.url_in_app, sc.app, "Open")) |it| {
        it.setTitle("Open {s}", .{q});
        it.setSub("in {s}", .{sc.name});
        const has_scheme = std.mem.indexOf(u8, q, "://") != null;
        const local = std.ascii.startsWithIgnoreCase(q, "localhost") or std.mem.indexOfScalar(u8, q, ':') != null;
        it.setTarget("{s}{s}", .{ if (has_scheme) "" else if (local) "http://" else "https://", q });
        it.symbol = "safari";
    };
    inline for (.{ .search_web, .search_x, .ask_grok }) |k| if (l.push(.url_in_app, sc.app, "Search")) |it| {
        switch (k) {
            .search_web => it.setTitle("Search Google for “{s}”", .{q}),
            .search_x => it.setTitle("Search X for “{s}”", .{q}),
            else => it.setTitle("Ask Grok “{s}”", .{q}),
        }
        it.setSub("in {s}", .{sc.name});
        it.target_len = @intCast(results.url(&it.target_buf, k, q).len);
        it.symbol = switch (k) {
            .search_web => "globe",
            .search_x => "magnifyingglass",
            else => "sparkles",
        };
    };
}

fn maps(l: *List, sc: Scope, q: []const u8) void {
    if (q.len == 0) return;
    const rows = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
        .{ "Search Maps for “{s}”", "maps://?q=", "Search", "map" },
        .{ "Directions to “{s}”", "maps://?daddr=", "Directions", "arrow.triangle.turn.up.right.diamond" },
    };
    inline for (rows) |r| if (l.push(.url, sc.app, r[2])) |it| {
        it.setTitle(r[0], .{q});
        it.setSub("Maps", .{});
        var w: std.Io.Writer = .fixed(&it.target_buf);
        w.writeAll(r[1]) catch {};
        results.escape(&w, q);
        it.target_len = @intCast(w.buffered().len);
        it.symbol = r[3];
    };
}

fn settings(l: *List, sc: Scope, q: []const u8) void {
    if (q.len == 0) return;
    var ranked: [max - 1]search.Ranked = undefined;
    const n = panes.rank(q, &ranked);
    for (ranked[0..n]) |r| {
        const it = l.push(.url, sc.app, "Open") orelse return;
        it.setTitle("{s}", .{panes.all[r.index].name});
        it.setSub("System Settings", .{});
        it.setTarget("{s}", .{panes.urls[r.index]});
        it.match = r.match;
        it.symbol = "gearshape";
    }
}

/// "messages to shawn" typed in full: the app, and what is for it.
pub const Inline = struct {
    app: u32,
    handler: Handler,
    rest: []const u8,
    /// Said by a verb ("text shawn") or the app's whole name, so its rows
    /// can lead; otherwise they come after the apps.
    sure: bool,
    /// Plainly about a person: a verb ("text shawn"), or "to"/"with"
    /// after the name ("messages to shawn"). Only then does asking for
    /// Contacts lead: "mail merge" is not someone to find.
    person: bool = false,
};

const verbs = [_]struct { []const u8, []const u8 }{
    .{ "text", "Messages" },    .{ "message", "Messages" }, .{ "msg", "Messages" },     .{ "imessage", "Messages" },
    .{ "email", "Mail" },       .{ "mail", "Mail" },        .{ "call", "FaceTime" },    .{ "facetime", "FaceTime" },
    .{ "directions", "Maps" },  .{ "map", "Maps" },        .{ "settings", "System Settings" },
};

/// The app a query starts with, by a verb for it or its name (whole, or a
/// word of it no other app has, four letters or more: "chrome"), and
/// what comes after it.
pub fn parseInline(query_in: []const u8, ix: *const Index) ?Inline {
    const q = std.mem.trim(u8, query_in, " \t\r\n");
    // The longest name first: "google chrome x" before "google".
    var cut: usize = q.len;
    while (std.mem.lastIndexOfScalar(u8, q[0..cut], ' ')) |sp| {
        cut = sp;
        const head = std.mem.trim(u8, q[0..sp], " ");
        const rest = std.mem.trim(u8, q[sp + 1 ..], " ");
        if (head.len < 3 or rest.len == 0) continue;
        if (ix.find(head)) |a| {
            const h = Handler.of(ix.apps.items[a].name);
            return .{ .app = a, .handler = h, .rest = rest, .sure = true, .person = stripLead(rest).len < rest.len };
        }
        for (verbs) |v| if (std.ascii.eqlIgnoreCase(head, v[0])) {
            const a = ix.find(v[1]) orelse break;
            return .{ .app = a, .handler = Handler.of(v[1]), .rest = rest, .sure = true, .person = true };
        };
        if (head.len >= 4 and std.mem.indexOfScalar(u8, head, ' ') == null) if (byWord(ix, head)) |a| {
            return .{ .app = a, .handler = Handler.of(ix.apps.items[a].name), .rest = rest, .sure = false };
        };
    }
    return null;
}

/// The one app with `word` as a word of its name.
fn byWord(ix: *const Index, word: []const u8) ?u32 {
    var found: ?u32 = null;
    for (ix.apps.items, 0..) |a, i| {
        var words = std.mem.tokenizeScalar(u8, a.name, ' ');
        const has = while (words.next()) |w| {
            if (std.ascii.eqlIgnoreCase(w, word)) break true;
        } else false;
        if (!has) continue;
        if (found != null) return null;
        found = @intCast(i);
    }
    return found;
}

fn clip(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(fmt, args) catch {};
    // Cut where it filled, at a whole character.
    const n = utf8Floor(w.buffered(), w.buffered().len);
    return buf[0..n];
}

/// The most of `s` up to `cap` bytes that ends on a character's boundary.
fn utf8Floor(s: []const u8, cap: usize) usize {
    var n = @min(s.len, cap);
    if (n == s.len) return n;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

fn testIndex(a: std.mem.Allocator, names: []const []const u8) !Index {
    var ix: Index = .init(a);
    for (names) |n| {
        var buf: [128]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    return ix;
}

fn testBook(a: std.mem.Allocator) !Book {
    var b: Book = .init(a);
    try b.add("Shawn Georgie", &.{ .{ .value = "+1 (555) 010-0000", .email = false, .label = "_$!<Mobile>!$_" }, .{ .value = "shawn@example.com", .email = true } });
    try b.add("Sunny", &.{.{ .value = "+1 555 010 0001", .email = false }});
    try b.add("Lavan Prem Kumar", &.{.{ .value = "lavan@example.com", .email = true }});
    return b;
}

test "Messages finds people and opens their conversation by its address" {
    const t = std.testing;
    var b = try testBook(t.allocator);
    defer b.deinit();
    var l: List = .{};
    const sc: Scope = .{ .app = 3, .name = "Messages", .handler = .messages };
    build(&l, sc, "sha", &b, .granted, true);
    try t.expectEqual(Go.url, l.items[0].go);
    try t.expect(l.items[0].person);
    try t.expectEqualStrings("Shawn Georgie", l.items[0].title());
    try t.expectEqualStrings("imessage://+15550100000", l.items[0].target());
    try t.expectEqualStrings("mobile · +1 (555) 010-0000", l.items[0].sub());
    // Its own search for what was typed, and itself, last.
    try t.expectEqual(Go.search_in_app, l.items[l.n - 2].go);
    try t.expectEqualStrings("sha", l.items[l.n - 2].target());
    try t.expectEqual(Go.open_app, l.items[l.n - 1].go);
    // "to shawn": the word before the name doesn't count.
    build(&l, sc, "to Shawn", &b, .granted, true);
    try t.expectEqualStrings("Shawn Georgie", l.items[0].title());
    // A person, then what to tell them: written, not sent.
    build(&l, sc, "shawn running late", &b, .granted, true);
    try t.expectEqual(Go.url, l.items[0].go);
    try t.expectEqualStrings("sms://open?addresses=+15550100000&body=running%20late", l.items[0].target());
    build(&l, sc, "shawn georgie", &b, .granted, true);
    try t.expectEqualStrings("imessage://+15550100000", l.items[0].target());
    // An email-only person is messaged at their email.
    build(&l, sc, "lavan", &b, .granted, true);
    try t.expectEqualStrings("imessage://lavan@example.com", l.items[0].target());
    // A number typed in full.
    build(&l, sc, "+1 555 010 0002", &b, .granted, true);
    try t.expectEqualStrings("imessage://+15550100002", l.items[0].target());
    // Nothing typed: a new message.
    build(&l, sc, "", &b, .granted, true);
    try t.expectEqualStrings("imessage://", l.items[0].target());
    try t.expectEqual(Go.open_app, l.items[l.n - 1].go);
    // No access yet: a row that asks, never a made-up person.
    build(&l, sc, "sha", null, .unknown, true);
    try t.expectEqual(Go.ask_contacts, l.items[0].go);
    build(&l, sc, "sha", null, .denied, true);
    try t.expectEqual(Go.url, l.items[0].go);
    try t.expect(std.mem.startsWith(u8, l.items[0].target(), "x-apple.systempreferences:"));
}

test "Mail writes to an email, FaceTime calls, Maps searches" {
    const t = std.testing;
    var b = try testBook(t.allocator);
    defer b.deinit();
    var l: List = .{};
    build(&l, .{ .app = 0, .name = "Mail", .handler = .mail }, "sha", &b, .granted, true);
    try t.expectEqualStrings("mailto:shawn@example.com", l.items[0].target());
    build(&l, .{ .app = 0, .name = "Mail", .handler = .mail }, "sunny", &b, .granted, true);
    // Sunny has no email: Mail lists nobody for them.
    try t.expect(!l.items[0].person);
    build(&l, .{ .app = 0, .name = "Mail", .handler = .mail }, "a@b.co", &b, .granted, true);
    try t.expectEqualStrings("mailto:a@b.co", l.items[0].target());
    build(&l, .{ .app = 0, .name = "FaceTime", .handler = .facetime }, "shawn", &b, .granted, true);
    try t.expectEqualStrings("facetime://+15550100000", l.items[0].target());
    try t.expectEqualStrings("facetime-audio://+15550100000", l.items[1].target());
    build(&l, .{ .app = 0, .name = "Maps", .handler = .maps }, "blue bottle coffee", null, .unknown, true);
    try t.expectEqualStrings("maps://?q=blue+bottle+coffee", l.items[0].target());
    try t.expectEqualStrings("maps://?daddr=blue+bottle+coffee", l.items[1].target());
    // Maps' own search is the row above, not typed into it twice.
    for (l.slice()) |it| try t.expect(it.go != .search_in_app);
}

test "a browser opens addresses and searches in itself; System Settings lists panes" {
    const t = std.testing;
    var l: List = .{};
    const sc: Scope = .{ .app = 0, .name = "Safari", .handler = .browser };
    build(&l, sc, "apple.com/mac", null, .unknown, true);
    try t.expectEqual(Go.url_in_app, l.items[0].go);
    try t.expectEqualStrings("https://apple.com/mac", l.items[0].target());
    build(&l, sc, "localhost:3000", null, .unknown, true);
    try t.expectEqualStrings("http://localhost:3000", l.items[0].target());
    build(&l, sc, "liquid glass", null, .unknown, true);
    try t.expectEqualStrings("https://www.google.com/search?q=liquid+glass", l.items[0].target());
    try t.expectEqual(Go.open_app, l.items[l.n - 1].go);
    try t.expect(!looksAddress("hello world"));
    try t.expect(!looksAddress("v1.2"));
    try t.expect(looksAddress("192.168.1.1"));
    try t.expect(looksAddress("ziglang.org"));
    if (@import("builtin").os.tag == .macos) {
        build(&l, .{ .app = 0, .name = "System Settings", .handler = .settings }, "login items", null, .unknown, true);
        try t.expectEqualStrings("Login Items & Extensions", l.items[0].title());
        try t.expect(std.mem.startsWith(u8, l.items[0].target(), panes.url_prefix));
    }
}

test "any other app: its own search for what was typed" {
    const t = std.testing;
    var l: List = .{};
    const sc: Scope = .{ .app = 7, .name = "Notes", .handler = .generic };
    build(&l, sc, "groceries", null, .unknown, true);
    try t.expectEqual(@as(usize, 2), l.n);
    try t.expectEqual(Go.search_in_app, l.items[0].go);
    try t.expectEqualStrings("Search Notes for “groceries”", l.items[0].title());
    try t.expectEqualStrings("groceries", l.items[0].target());
    try t.expectEqual(@as(u32, 7), l.items[0].app);
    build(&l, sc, "  ", null, .unknown, true);
    try t.expectEqual(@as(usize, 1), l.n);
    try t.expectEqual(Go.open_app, l.items[0].go);
}

test "typed in full: an app's name or a verb for it, then the rest" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "Messages", "Mail", "Google Chrome", "Notes", "Maps", "System Settings" });
    defer ix.deinit();
    const m = parseInline("messages to Shawn", &ix).?;
    try t.expectEqual(Handler.messages, m.handler);
    try t.expectEqualStrings("to Shawn", m.rest);
    try t.expect(m.sure and m.person);
    try t.expect(!parseInline("mail merge", &ix).?.person);
    const v = parseInline("text shawn", &ix).?;
    try t.expectEqual(Handler.messages, v.handler);
    try t.expectEqualStrings("shawn", v.rest);
    const c = parseInline("chrome ziglang.org", &ix).?;
    try t.expectEqual(Handler.browser, c.handler);
    try t.expect(!c.sure);
    try t.expectEqual(Handler.browser, parseInline("google chrome ziglang.org", &ix).?.handler);
    try t.expectEqual(Handler.settings, parseInline("settings wifi", &ix).?.handler);
    try t.expect(parseInline("settings wifi", &ix).?.sure);
    try t.expect(parseInline("messages", &ix) == null);
    try t.expect(parseInline("liquid glass", &ix) == null);
    try t.expect(parseInline("ab cd", &ix) == null);
}

test "initials" {
    var it: Item = .{ .go = .url, .app = 0, .verb = "" };
    var buf: [8]u8 = undefined;
    it.setTitle("Shawn Georgie", .{});
    try std.testing.expectEqualStrings("SG", it.initials(&buf));
    it.setTitle("sunny", .{});
    try std.testing.expectEqualStrings("S", it.initials(&buf));
    it.setTitle("(555) 010", .{});
    try std.testing.expectEqualStrings("0", it.initials(&buf));
}
