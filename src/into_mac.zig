//! The Mac's side of going into an app (into.zig): the people in Contacts,
//! read into memory off the main thread once access is granted; the app
//! started in the background as soon as Tab goes into it; and, on Return,
//! an address opened (imessage:, mailto:, maps:), an address opened in a
//! browser, or what was typed put into the app's own search through
//! Accessibility: its search field found and focused, else ⌘F, then the
//! words typed into it. Nothing typed is sent anywhere but the app.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const into = @import("into.zig");
const contacts = @import("contacts.zig");
const apps = @import("apps.zig");
const Live = @import("main.zig").Live;
const panel = @import("panel_mac.zig");

// ----- Contacts -----

/// CNEntityTypeContacts.
const entity_contacts: objc.NSInteger = 0;

pub const State = struct {
    /// Counts apps started ahead, and the last one acted on or left (the
    /// panel is then not brought back for it).
    warming: u32 = 0,
    acted: u32 = 0,
    book: ?*contacts.Book = null,
    loading: bool = false,
    /// When it was last read (Unix seconds): it is read again on showing,
    /// at most this often.
    loaded_at: i64 = 0,
};
const reload_after_s = 5 * 60;

pub fn access() into.Access {
    const status = objc.msg(objc.NSInteger, objc.class("CNContactStore"), "authorizationStatusForEntityType:", .{entity_contacts});
    return switch (status) {
        0 => .unknown,
        // Authorized, or limited to some people.
        3, 4 => .granted,
        else => .denied,
    };
}

/// At launch, and each time the panel shows: read Contacts again if access
/// is granted and it has been a while. Never asks.
pub fn refresh(l: *Live) void {
    // Whether an app's search row can promise to type.
    const typing = trusted(false);
    if (typing != l.s.can_type) {
        l.s.can_type = typing;
        l.s.built = 1;
    }
    const a = access();
    if (a != l.s.contacts_access and a != .granted) l.s.contactsChanged(l.s.book, a);
    if (a != .granted or l.people.loading) return;
    if (l.people.book != null and @import("account.zig").now() - l.people.loaded_at < reload_after_s) return;
    load(l);
}

/// The row that asks for Contacts: the system's prompt, then the people.
pub fn ask(ctx: *anyopaque) void {
    const l: *Live = @ptrCast(@alignCast(ctx));
    if (access() == .granted) return load(l);
    const pool = objc.Pool.push();
    defer pool.pop();
    const store = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("CNContactStore"), "alloc", .{}), "init", .{});
    defer objc.release(store);
    var block = objc.Block(Live, &.{ objc.BOOL, ?objc.Object }).init(l, answered);
    objc.msg(void, store, "requestAccessForEntityType:completionHandler:", .{ entity_contacts, @as(*anyopaque, @ptrCast(&block)) });
}

fn answered(l: *Live, granted: objc.BOOL, _: ?objc.Object) void {
    _ = granted;
    // Any queue: the rest is the main thread's.
    nanoui.App.after(0, l, struct {
        fn f(c: ?*anyopaque) callconv(.c) void {
            const live: *Live = @ptrCast(@alignCast(c.?));
            const a = access();
            live.s.contactsChanged(live.s.book, a);
            if (a == .granted) load(live);
            if (live.window) |w| w.redraw();
        }
    }.f);
}

fn load(l: *Live) void {
    if (l.people.loading) return;
    l.people.loading = true;
    const t = std.Thread.spawn(.{}, readAll, .{l}) catch {
        l.people.loading = false;
        return;
    };
    t.detach();
}

const Reading = struct { book: *contacts.Book };

/// Off the main thread: every person with a phone or an email.
fn readAll(l: *Live) void {
    const gpa = l.app.gpa;
    const book = gpa.create(contacts.Book) catch return finish(l, null);
    book.* = .init(gpa);
    const pool = objc.Pool.push();
    defer pool.pop();
    const store = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("CNContactStore"), "alloc", .{}), "init", .{});
    defer objc.release(store);
    const key_names = [_][]const u8{ "givenName", "familyName", "nickname", "organizationName", "phoneNumbers", "emailAddresses" };
    var keys: [key_names.len]objc.Object = undefined;
    for (key_names, 0..) |k, i| keys[i] = objc.nsString(k);
    const arr = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObjects:count:", .{ @as([*]const objc.Object, &keys), @as(objc.NSUInteger, keys.len) });
    const req = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("CNContactFetchRequest"), "alloc", .{}), "initWithKeysToFetch:", .{arr});
    defer objc.release(req);
    var reading: Reading = .{ .book = book };
    var block = objc.Block(Reading, &.{ objc.Object, *objc.BOOL }).init(&reading, onePerson);
    var err: ?objc.Object = null;
    const ok = objc.msg(objc.BOOL, store, "enumerateContactsWithFetchRequest:error:usingBlock:", .{ req, &err, @as(*anyopaque, @ptrCast(&block)) });
    if (!ok) {
        book.deinit();
        gpa.destroy(book);
        return finish(l, null);
    }
    finish(l, book);
}

fn str(o: ?objc.Object) []const u8 {
    const s = o orelse return "";
    const p = objc.msg(?[*:0]const u8, s, "UTF8String", .{}) orelse return "";
    return std.mem.sliceTo(p, 0);
}

fn onePerson(r: *Reading, c: objc.Object, _: *objc.BOOL) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    var name_buf: [256]u8 = undefined;
    const given = str(objc.msg(?objc.Object, c, "givenName", .{}));
    const family = str(objc.msg(?objc.Object, c, "familyName", .{}));
    var name: []const u8 = std.fmt.bufPrint(&name_buf, "{s}{s}{s}", .{ given, if (given.len > 0 and family.len > 0) " " else "", family }) catch given;
    if (name.len == 0) name = str(objc.msg(?objc.Object, c, "nickname", .{}));
    if (name.len == 0) name = str(objc.msg(?objc.Object, c, "organizationName", .{}));
    var hs: [24]contacts.Handle = undefined;
    var labels: [24][32]u8 = undefined;
    var n: usize = 0;
    inline for (.{ "phoneNumbers", "emailAddresses" }) |which| {
        const list = objc.msg(?objc.Object, c, which, .{});
        if (list) |ls| for (0..objc.msg(objc.NSUInteger, ls, "count", .{})) |i| {
            if (n == hs.len) break;
            const lv = objc.msg(objc.Object, ls, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
            const v = objc.msg(?objc.Object, lv, "value", .{});
            const email = comptime std.mem.eql(u8, which, "emailAddresses");
            const value = if (email) str(v) else if (v) |pn| str(objc.msg(?objc.Object, pn, "stringValue", .{})) else "";
            hs[n] = .{ .value = value, .email = email, .label = contacts.plainLabel(&labels[n], str(objc.msg(?objc.Object, lv, "label", .{}))) };
            n += 1;
        };
    }
    r.book.add(name, hs[0..n]) catch {};
}

const Done = struct { l: *Live, book: ?*contacts.Book };

fn finish(l: *Live, book: ?*contacts.Book) void {
    const d = l.app.gpa.create(Done) catch {
        if (book) |b| {
            b.deinit();
            l.app.gpa.destroy(b);
        }
        l.people.loading = false;
        return;
    };
    d.* = .{ .l = l, .book = book };
    nanoui.App.after(0, d, struct {
        fn f(c: ?*anyopaque) callconv(.c) void {
            const done: *Done = @ptrCast(@alignCast(c.?));
            const live = done.l;
            defer live.app.gpa.destroy(done);
            live.people.loading = false;
            const b = done.book orelse return;
            const old = live.people.book;
            live.people.book = b;
            live.people.loaded_at = @import("account.zig").now();
            live.s.contactsChanged(b, .granted);
            if (old) |o| {
                o.deinit();
                live.app.gpa.destroy(o);
            }
            if (live.window) |w| w.redraw();
        }
    }.f);
}

pub fn deinit(l: *Live) void {
    if (l.people.book) |b| {
        b.deinit();
        l.app.gpa.destroy(b);
        l.people.book = null;
    }
}

// ----- the app -----

fn bundleId(path: []const u8) ?objc.Object {
    const b = objc.msg(?objc.Object, objc.class("NSBundle"), "bundleWithPath:", .{objc.nsString(path)}) orelse return null;
    return objc.msg(?objc.Object, b, "bundleIdentifier", .{});
}

fn running(path: []const u8) ?objc.Object {
    const id = bundleId(path) orelse return null;
    const list = objc.msg(objc.Object, objc.class("NSRunningApplication"), "runningApplicationsWithBundleIdentifier:", .{id});
    if (objc.msg(objc.NSUInteger, list, "count", .{}) == 0) return null;
    return objc.msg(objc.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
}

fn openApp(path: []const u8, activate: bool) void {
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    const config = objc.msg(objc.Object, objc.class("NSWorkspaceOpenConfiguration"), "configuration", .{});
    objc.msg(void, config, "setActivates:", .{if (activate) objc.YES else objc.NO});
    // Started ahead: hidden too, so it doesn't take the keys (and with
    // them the panel, which goes when another app is in front).
    if (!activate) {
        objc.msg(void, config, "setHides:", .{objc.YES});
        objc.msg(void, config, "setAddsToRecentItems:", .{objc.NO});
    }
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    objc.msg(void, ws, "openApplicationAtURL:configuration:completionHandler:", .{ url, config, @as(?*anyopaque, null) });
}

/// Tab went into an app: start it, unseen, so Return finds it ready.
pub fn warm(ctx: *anyopaque, path: []const u8) void {
    const l: *Live = @ptrCast(@alignCast(ctx));
    const pool = objc.Pool.push();
    defer pool.pop();
    if (running(path) != null) return;
    openApp(path, false);
    // Some apps come forward as they start whatever they are asked: the
    // panel comes back, still inside the app, as it was.
    l.people.warming +%= 1;
    inline for (.{ 250, 700, 1400 }) |delay| nanoui.App.after(delay, l, keepPanel);
}

fn keepPanel(c: ?*anyopaque) callconv(.c) void {
    const l: *Live = @ptrCast(@alignCast(c.?));
    const w = l.window orelse return;
    // Only while still inside the app with nothing done: Return, Esc or
    // the hot key since mean the panel is meant to be away.
    if (l.s.scope == null or l.people.acted == l.people.warming) return;
    if (w.isVisible() and panel.focused(w)) return;
    panel.place(w);
    w.show();
    panel.shown(w);
}

/// Return on an app's row.
pub fn run(ctx: *anyopaque, item: *const into.Item, path: []const u8) void {
    const l: *Live = @ptrCast(@alignCast(ctx));
    l.people.acted = l.people.warming;
    const pool = objc.Pool.push();
    defer pool.pop();
    switch (item.go) {
        .ask_contacts => ask(l),
        .url => _ = nanoui.shell.openUrl(item.target()),
        .url_in_app => {
            const u = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(item.target())}) orelse return;
            const app_url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
            const urls = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{u});
            const config = objc.msg(objc.Object, objc.class("NSWorkspaceOpenConfiguration"), "configuration", .{});
            const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
            objc.msg(void, ws, "openURLs:withApplicationAtURL:configuration:completionHandler:", .{ urls, app_url, config, @as(?*anyopaque, null) });
        },
        .open_app => openApp(path, true),
        .search_in_app => {
            openApp(path, true);
            const text = item.target();
            if (text.len == 0) return;
            // Without Accessibility nothing can be typed for it: the words
            // go on the clipboard, a ⌘V away, and the Accessibility pane
            // opens (macOS may add Nanolight there switched off, unasked).
            if (!trusted(true)) {
                copy(text);
                _ = nanoui.shell.openUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility");
                return;
            }
            const job = l.app.gpa.create(Job) catch return;
            job.* = .{ .gpa = l.app.gpa, .len = @intCast(@min(text.len, job.text.len)) };
            @memcpy(job.text[0..job.len], text[0..job.len]);
            const p = @min(path.len, job.path.len);
            @memcpy(job.path[0..p], path[0..p]);
            job.path_len = @intCast(p);
            const t = std.Thread.spawn(.{}, Job.run, .{job}) catch {
                l.app.gpa.destroy(job);
                return copy(text);
            };
            t.detach();
        },
    }
}

fn copy(text: []const u8) void {
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    _ = objc.msg(objc.NSInteger, pb, "clearContents", .{});
    _ = objc.msg(objc.BOOL, pb, "setString:forType:", .{ objc.nsString(text), objc.nsString("public.utf8-plain-text") });
}

// ----- Accessibility -----

const AXUIElementRef = *opaque {};
const CFTypeRef = *anyopaque;
extern "c" fn AXIsProcessTrustedWithOptions(options: ?objc.Object) bool;
extern "c" fn AXUIElementCreateApplication(pid: i32) AXUIElementRef;
extern "c" fn AXUIElementCopyAttributeValue(el: AXUIElementRef, attr: objc.Object, value: *?CFTypeRef) i32;
extern "c" fn AXUIElementSetAttributeValue(el: AXUIElementRef, attr: objc.Object, value: CFTypeRef) i32;
extern "c" fn AXUIElementSetMessagingTimeout(el: AXUIElementRef, seconds: f32) i32;
extern "c" fn CFRelease(cf: *anyopaque) void;
extern "c" fn CFRetain(cf: *anyopaque) *anyopaque;
extern "c" fn CFEqual(a: *anyopaque, b: *anyopaque) bool;
extern "c" var kCFBooleanTrue: CFTypeRef;
extern "c" fn CGEventCreateKeyboardEvent(source: ?*anyopaque, key: u16, down: bool) ?*anyopaque;
extern "c" fn CGEventKeyboardSetUnicodeString(ev: *anyopaque, len: c_ulong, chars: [*]const u16) void;
extern "c" fn CGEventSetFlags(ev: *anyopaque, flags: u64) void;
extern "c" fn CGEventPostToPid(pid: i32, ev: *anyopaque) void;
extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

const cmd_flag: u64 = 0x100000;
const key_f: u16 = 3;
const key_a: u16 = 0;

/// Whether Nanolight may drive other apps; `prompt` has the system ask.
fn trusted(prompt: bool) bool {
    if (!prompt) return AXIsProcessTrustedWithOptions(null);
    const key = objc.nsString("AXTrustedCheckOptionPrompt");
    const yes = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES});
    const opts = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ yes, key });
    return AXIsProcessTrustedWithOptions(opts);
}

fn ms(n: u64) void {
    const ts: std.c.timespec = .{ .sec = @intCast(n / 1000), .nsec = @intCast((n % 1000) * std.time.ns_per_ms) };
    _ = nanosleep(&ts, null);
}

fn attr(el: AXUIElementRef, name: []const u8) ?CFTypeRef {
    var v: ?CFTypeRef = null;
    if (AXUIElementCopyAttributeValue(el, objc.nsString(name), &v) != 0) return null;
    return v;
}

/// An attribute that is a string, compared without case.
fn attrHas(el: AXUIElementRef, name: []const u8, comptime want: []const u8, contains: bool) bool {
    const v = attr(el, name) orelse return false;
    defer CFRelease(v);
    const o: objc.Object = @ptrCast(v);
    if (!objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class("NSString")})) return false;
    const s = str(o);
    return if (contains) containsFold(s, want) else std.ascii.eqlIgnoreCase(s, want);
}

fn containsFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    for (0..hay.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    return false;
}

/// A one-line field: a search field, a text field or a combo box, never
/// a text area (a document, a message).
fn isSearchLike(el: AXUIElementRef) bool {
    if (attrHas(el, "AXRole", "AXTextArea", false)) return false;
    if (attrHas(el, "AXSubrole", "AXSearchField", false)) return true;
    inline for (.{ "AXTextField", "AXSearchField", "AXComboBox" }) |r| if (attrHas(el, "AXRole", r, false)) return true;
    return false;
}

fn isSearch(el: AXUIElementRef) bool {
    if (attrHas(el, "AXSubrole", "AXSearchField", false)) return true;
    if (!attrHas(el, "AXRole", "AXTextField", false)) return false;
    inline for (.{ "AXIdentifier", "AXDescription", "AXPlaceholderValue", "AXTitle" }) |a| if (attrHas(el, a, "search", true)) return true;
    return false;
}

/// The first search field under `root`, breadth first, within a budget:
/// a big window's tree is thousands of elements.
fn findSearch(root: AXUIElementRef) ?AXUIElementRef {
    var queue: [512]AXUIElementRef = undefined;
    var head: usize = 0;
    var tail: usize = 0;
    var visited: usize = 0;
    queue[tail] = root;
    tail += 1;
    var found: ?AXUIElementRef = null;
    while (head < tail and visited < 1500) : (visited += 1) {
        const el = queue[head];
        head += 1;
        if (found == null and el != root and isSearch(el)) {
            found = el;
            break;
        }
        const kids_v = attr(el, "AXChildren") orelse continue;
        defer CFRelease(kids_v);
        const kids: objc.Object = @ptrCast(kids_v);
        if (!objc.msg(objc.BOOL, kids, "isKindOfClass:", .{objc.class("NSArray")})) continue;
        for (0..objc.msg(objc.NSUInteger, kids, "count", .{})) |i| {
            if (tail == queue.len) break;
            const k: AXUIElementRef = @ptrCast(objc.msg(objc.Object, kids, "objectAtIndex:", .{@as(objc.NSUInteger, i)}));
            // Kept past the array's release.
            _ = CFRetain(k);
            queue[tail] = k;
            tail += 1;
        }
    }
    // Every element but the one found (and the root, the caller's) goes.
    for (queue[1..tail]) |el| if (found == null or el != found.?) CFRelease(el);
    return found;
}

/// Typed into whatever has the keys in `pid`: the words as Unicode, a
/// few characters an event, so no keyboard layout gets in the way.
fn typeText(pid: i32, text: []const u8) void {
    var units: [1024]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&units, text) catch return;
    var i: usize = 0;
    while (i < n) {
        const k = @min(n - i, 16);
        inline for (.{ true, false }) |down| {
            const ev = CGEventCreateKeyboardEvent(null, 0, down) orelse return;
            CGEventSetFlags(ev, 0);
            CGEventKeyboardSetUnicodeString(ev, k, units[i..].ptr);
            CGEventPostToPid(pid, ev);
            CFRelease(ev);
        }
        i += k;
        ms(2);
    }
}

fn press(pid: i32, key: u16, flags: u64) void {
    inline for (.{ true, false }) |down| {
        const ev = CGEventCreateKeyboardEvent(null, key, down) orelse return;
        CGEventSetFlags(ev, flags);
        CGEventPostToPid(pid, ev);
        CFRelease(ev);
    }
}

/// Words to put into an app, once it is up.
const Job = struct {
    gpa: std.mem.Allocator,
    text: [512]u8 = undefined,
    len: u16,
    path: [1024]u8 = undefined,
    path_len: u16 = 0,

    fn run(j: *Job) void {
        defer j.gpa.destroy(j);
        const pool = objc.Pool.push();
        defer pool.pop();
        const text = j.text[0..j.len];
        const path = j.path[0..j.path_len];
        // The app, up and in front with a window, for up to 6 s (a cold
        // start); polled every 15 ms, so a warm one is at once.
        var pid: i32 = 0;
        var window: ?CFTypeRef = null;
        var waited: u64 = 0;
        while (waited < 6000) : (waited += 15) {
            if (pid == 0) if (running(path)) |a| {
                if (objc.msg(objc.BOOL, a, "isFinishedLaunching", .{})) pid = objc.msg(i32, a, "processIdentifier", .{});
            };
            if (pid != 0) {
                const app = AXUIElementCreateApplication(pid);
                defer CFRelease(app);
                _ = AXUIElementSetMessagingTimeout(app, 0.5);
                window = attr(app, "AXFocusedWindow") orelse attr(app, "AXMainWindow");
                if (window != null) break;
            }
            ms(15);
        }
        const win = window orelse return copy(text);
        defer CFRelease(win);
        // A cold start's window is drawn before it takes keys.
        if (waited > 300) ms(120);
        const app = AXUIElementCreateApplication(pid);
        defer CFRelease(app);
        // The field to type into must be one Nanolight knows is a search:
        // the one found, or what ⌘F moved the keys to. Never the field the
        // keys were already in (a document's text, which ⌘A would select
        // and the words replace), and never a text area.
        const before = attr(app, "AXFocusedUIElement");
        defer if (before) |b| CFRelease(b);
        var target: ?CFTypeRef = null;
        if (findSearch(@ptrCast(win))) |field| {
            _ = AXUIElementSetAttributeValue(field, objc.nsString("AXFocused"), kCFBooleanTrue);
            ms(40);
            target = @ptrCast(field);
        } else {
            press(pid, key_f, cmd_flag);
            ms(160);
            const after = attr(app, "AXFocusedUIElement") orelse return copy(text);
            const moved = if (before) |b| !CFEqual(b, after) else true;
            if (!moved or !isSearchLike(@ptrCast(after))) {
                CFRelease(after);
                return copy(text);
            }
            target = after;
        }
        defer CFRelease(target.?);
        // The keys must be in that field now, and nowhere else.
        const f = attr(app, "AXFocusedUIElement") orelse return copy(text);
        defer CFRelease(f);
        if (!CFEqual(f, target.?) or !isSearchLike(@ptrCast(f))) return copy(text);
        // What the search held before gives way to the words.
        press(pid, key_a, cmd_flag);
        typeText(pid, text);
    }
};
