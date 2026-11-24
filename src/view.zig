//! The launcher panel: the query, then what it finds in sections, then a
//! footer naming what Return does. Neutral glass, a hairline rim, 40-point
//! rows, the selection a grey step on its row. Nothing moves
//! while nothing happens: frames come from keys.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const Index = @import("apps.zig").Index;
const results = @import("results.zig");
const files = @import("files.zig");
const files_view = @import("files_view.zig");
const answers = @import("answers.zig");
const row_window = @import("row_window.zig");
const suggest = @import("suggest.zig");
const text = @import("text.zig");
const settings_view = @import("settings_view.zig");
const clipboard = @import("clipboard.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const into = @import("into.zig");
const contacts = @import("contacts.zig");
const Row = results.Row;

/// What the panel asks of whatever shows it (the window, or the film).
pub const Host = struct {
    ctx: *anyopaque,
    /// Opens an app's path or a URL.
    open: *const fn (ctx: *anyopaque, target: []const u8) void,
    hide: *const fn (ctx: *anyopaque) void,
    /// The panel's height changed: a window follows it.
    resize: ?*const fn (ctx: *anyopaque, h: f32) void = null,
    /// Request completions, returned through `Nanolight.answered`.
    suggest: ?*const fn (ctx: *anyopaque, query: []const u8) void = null,
    /// Request a currency conversion, returned through `Nanolight.ratesAnswered`.
    rates: ?*const fn (ctx: *anyopaque, amount: f64, from: []const u8, to: []const u8) void = null,
    files: ?*const fn (ctx: *anyopaque, query: []const u8) void = null,
    /// Shows a search's page in the panel, over `webArea`; null takes it
    /// away. Without it, searches open in the browser.
    preview: ?*const fn (ctx: *anyopaque, url: ?[]const u8) void = null,
    /// Settings callbacks; without them, changes are not persisted.
    settings: ?*const SettingsHost = null,
    /// Does an app's action (into.zig): an address, its search, its
    /// message field. Without it, addresses and apps go to `open`.
    into: ?*const fn (ctx: *anyopaque, item: *const into.Item, app_path: []const u8) void = null,
    /// Starts an app in the background: an action in it is a key away.
    warm: ?*const fn (ctx: *anyopaque, app_path: []const u8) void = null,
    /// Asks for Contacts access; `Nanolight.contactsChanged` follows.
    contacts: ?*const fn (ctx: *anyopaque) void = null,
};

pub const width: f32 = 680;

/// The app's icon (icon.png, made smaller), for the panel and the film.
pub const icon_png = @embedFile("icon-256.png");

/// The app's icon, `size` points square.
pub fn appIcon(c: *ui.Context, size: f32) void {
    _ = ui.image(c, .{ .key = "nanolight-icon", .bytes = icon_png, .max_width = size, .max_height = size, .radius = 0, .scale = 2 });
}
pub const header_h = 58;
const row_h = 40;
const calc_h = 92;
const section_h = 28;
pub const footer_h = 38;
const list_pad = 6;
/// The room a window leaves round the panel for its shadow (`Nanolight.margin`).
pub const shadow_margin: f32 = 40;
/// The panel with its rows: one height, whatever they are: eight rows and
/// two section heads, so a full list of apps ends in the search for what was
/// typed and a completion, with no gap under them. A longer list shows the
/// whole rows that fit (row_window.zig).
pub const rows_height: f32 = header_h + footer_h + 2 + list_h;
const list_h: f32 = list_pad * 2 + 8 * row_h + 2 * section_h;
/// The tallest the panel gets: a search's page, or Settings. The window is
/// this tall.
pub const max_height: f32 = header_h + footer_h + 2 + list_pad * 2 + results.max_rows * row_h + 3 * section_h;

/// Where a search's page goes in a panel `h` tall: from `y` down from its
/// top, `h` tall, between the header and the footer, the panel's width.
pub fn webArea(h: f32) struct { y: f32, h: f32 } {
    return .{ .y = header_h + 1, .h = @max(0, h - header_h - footer_h - 2) };
}
/// Opening: snappy, a touch under critical damping.
pub const spring: motion.Spring = .{ .stiffness = 320, .damping = 32 };

pub const Palette = @import("palette.zig").Palette;
pub const palette = @import("palette.zig").palette;
pub const Theme = @import("palette.zig").Theme;

pub const Nanolight = struct {
    index: *Index,
    query: ui.TextBuffer = .{},
    res: results.Results = .{},
    sel: usize = 0,
    /// The query the rows were built for.
    built: u64 = 1,
    host: ?Host = null,
    /// Draws its own Liquid Glass (over a desktop nanoui painted, as the
    /// film does); otherwise the window's system glass is under it.
    own_glass: bool = false,
    /// Clear room round the panel in its window, for its shadow.
    margin: f32 = 0,
    /// The window fades in as it shows, the system's glass with it
    /// (panel_mac.zig): the panel has no entrance of its own (issue #9).
    window_fades: bool = false,
    /// Return sends a Google search to the browser and ⌘↩ shows it in
    /// the panel, the other way round from the default (issue #10).
    searches_out: bool = false,
    /// Claude's row is listed, under Grok's (`nanolight.claude`).
    claude_on: bool = false,
    /// The panel's tint, chosen in Settings (`nanolight.theme`).
    theme: Theme = .system,
    /// Each showing gets a new one: the panel comes in again.
    shown: u32 = 0,
    copied_at: f64 = -10,
    kv: ?nanoui.kv.Store = null,
    spans: [results.max_rows][16]ui.Span = undefined,
    url_buf: [1024]u8 = undefined,
    last_h: f32 = 0,
    /// Counts the lists shown.
    list_gen: u32 = 0,
    /// The rows of a long list in view.
    in_view: row_window.Window = .{},
    /// The query as it was shown: selected, so no completion after it yet.
    revealed: u64 = 0,
    /// Said in the footer in place of the name ("Updated to 0.1.3"), if set.
    note: []const u8 = "",
    /// The first-run welcome, drawn while it is active.
    onboard: ?*@import("onboard.zig").Onboard = null,
    /// Local file search is opt-in on this Mac.
    files_on: bool = false,
    found: files.List = .{},
    /// Google's completions: whether to ask, those listed, the answers.
    suggest_on: bool = true,
    web: suggest.List = .{},
    cache: suggest.Cache = .{},
    /// Currency: last answer, cache, and whether a fetch is out / failed.
    fx: ?@import("currency.zig").Answer = null,
    fx_cache: @import("currency.zig").Cache = .{},
    fx_pending: bool = false,
    fx_failed: bool = false,
    /// A search's page is in the panel, for the query as it was then.
    previewing: bool = false,
    preview_q: u64 = 0,
    preview_buf: [1024]u8 = undefined,
    preview_url: []const u8 = "",
    /// Settings, drawn in the panel in place of the rows.
    settings_ui: settings_view.Settings = .{},
    ext: ?*@import("raycast_view.zig").Ext = null,
    /// What was copied lately, listed for "clip" (clipboard_live.zig);
    /// null where nothing watches the clipboard.
    clips: ?*clipboard.History = null,
    /// The time, for how long ago each was copied.
    clock: *const fn () i64 = @import("account.zig").now,
    /// Each row's text, kept until it is drawn.
    clip_lines: [results.max_rows][160]u8 = undefined,
    clip_ago: [results.max_rows][24]u8 = undefined,
    /// Inside an app (Tab on its row): which, and what it lists for the
    /// query (into.zig). Typed in full ("messages to shawn"), the list
    /// holds the rows put among the others.
    scope: ?u32 = null,
    into_list: into.List = .{},
    /// The people in Contacts, once access is granted (into_mac.zig).
    book: ?*const contacts.Book = null,
    contacts_access: into.Access = .unknown,
    placeholder_buf: [96]u8 = undefined,

    /// Called as it is shown: the query selected, the keys its own.
    pub fn reveal(s: *Nanolight) void {
        s.back();
        s.settings_ui.hide();
        s.shown +%= 1;
        // Suggestions follow what was opened since.
        s.built = 1;
        s.revealed = std.hash.Wyhash.hash(0, s.query.text());
        s.query.want_selection = .{ 0, s.query.text().len };
        s.query.focus();
    }

    /// The panel's height for what it shows.
    pub fn height(s: *const Nanolight) f32 {
        if (s.settings_ui.open) return settings_view.height;
        if (s.ext) |e| if (e.open) return e.height();
        if (s.previewing) return max_height;
        return rows_height;
    }

    /// The window's view: the panel, `margin` in from the window's edges.
    pub fn view(s: *Nanolight, c: *ui.Context) void {
        ui.key(c, c.print("panel-{d}", .{s.shown}));
        const entrance: motion.Target = .{ .opacity = 0, .y = -6, .scale = 0.985 };
        const f = motion.frame(c, .{ .initial = if (s.window_fades) null else entrance, .transition = .{ .spring = spring } });
        const root = ui.div(c).wFull().p(s.margin).motion(f);
        defer root.end();
        s.panel(c);
    }

    pub fn panel(s: *Nanolight, c: *ui.Context) void {
        const p = palette(c.theme.dark, s.theme);
        const shell = ui.div(c).column().w(width).rounded(s.theme.radius()).border(p.hair).clip();
        if (s.own_glass) {
            _ = shell.glass(.{ .tint = @import("palette.zig").tint(c.theme.dark, s.theme) })
                .shadows(&.{ .{ .color = .{ .a = 0.22 }, .blur = 4, .y = 1 }, .{ .color = .{ .a = 0.28 }, .blur = 40, .y = 18 } });
        } else {
            // The system's shadow is off (its outline drew a black ring
            // round the panel): this one is soft, and outside the panel
            // only, so the glass under it stays clear.
            _ = shell.bg(p.fill).shadows(&.{
                .{ .color = .{ .a = 0.16 }, .blur = 3, .y = 1, .knockout = true },
                .{ .color = .{ .a = 0.24 }, .blur = 28, .y = 12, .knockout = true },
            });
        }
        defer shell.end();
        if (s.onboard) |o| if (o.active) {
            const h = s.follow(o.height());
            const body = ui.div(c).column().wFull().h(h).clip();
            defer body.end();
            o.view(c, s, p);
            return;
        };
        if (s.settings_ui.open) return s.settings_ui.inPanel(c, s, p);
        // A Raycast extension's command, while it runs (raycast_view.zig).
        if (s.ext) |e| if (e.open) return e.panel(c, s, p);

        s.keys(c);
        const submitted = s.header(c, p);
        s.rebuild();
        // Typing takes the page away: the rows are for the new words.
        if (s.previewing and std.hash.Wyhash.hash(0, s.query.text()) != s.preview_q) s.back();
        if (submitted) s.activate(c);
        const h = s.follow(s.height());
        {
            const body = ui.div(c).column().wFull().h(h - header_h).clip();
            defer body.end();
            if (s.previewing) {
                // Under the page, until it draws.
                ui.div(c).wFull().h(1).bg(p.hair).end();
                const wait = ui.div(c).wFull().h(webArea(h).h).center();
                defer wait.end();
                ui.text(c, "Searching Google…", .{ .size = 13, .color = p.sub.alpha(0.8) });
            } else if (s.res.n > 0) {
                ui.div(c).wFull().h(1).bg(p.hair).end();
                s.list(c, p);
            } else if (clipboard.words(s.query.text())) |w| {
                ui.div(c).wFull().h(1).bg(p.hair).end();
                const empty = ui.div(c).wFull().h(list_h).center();
                defer empty.end();
                ui.text(c, if (s.clips == null) "Clipboard history is off" else if (w.len > 0) "Nothing copied matches" else "Nothing copied yet", .{ .size = 13, .color = p.sub.alpha(0.8) });
            }
            ui.spacer(c);
            s.footer(c, p);
        }
    }

    /// The panel's height: `target`, at once, as the rows it fits are there
    /// at once (easing to it only made each key wait); a window follows it.
    pub fn follow(s: *Nanolight, target: f32) f32 {
        const h = @min(target, max_height);
        if (s.host) |host| if (host.resize) |f| if (@abs(h - s.last_h) > 0.25) {
            s.last_h = h;
            f(host.ctx, h);
        };
        return h;
    }

    /// Arrows, ^N/^P and Escape, before the field sees them.
    fn keys(s: *Nanolight, c: *ui.Context) void {
        const S = ui.Shortcut;
        if (s.previewing) {
            if (c.shortcut(.{ .key = S.enter, .cmd = true })) s.go(s.preview_url);
            if (c.shortcut(.{ .key = S.escape })) s.back();
            return;
        }
        // ⌘,: Settings, as on the Mac. The comma never reaches the field.
        if (c.shortcut(.{ .key = ',', .cmd = true })) return s.openSettings();
        // ⌘↩: a search in the browser rather than in the panel.
        if (c.shortcut(.{ .key = S.enter, .cmd = true })) s.activateOut(c);
        // Tab goes into the selected app; inside one, or on anything else,
        // it takes the faint completion, as → does. ⇧Tab comes back out.
        if (!files_view.takeOnTab(s, c)) {
            if (s.scope != null and c.shortcut(.{ .key = S.tab, .shift = true })) {
                s.leave(true);
            } else if (s.intoTarget()) |t| {
                if (c.shortcut(.{ .key = S.tab })) s.enter(t.app, t.rest);
            } else {
                const more = s.completion();
                if (more.len > 0 and c.shortcut(.{ .key = S.tab })) {
                    // A person's name as Contacts writes it.
                    if (s.scope != null) {
                        const name = s.into_list.items[s.res.rows[0].into].title();
                        var buf: [160]u8 = undefined;
                        @memcpy(buf[0..name.len], name);
                        s.query.set(buf[0..name.len]);
                        s.query.want_selection = .{ name.len, name.len };
                    } else s.take(more);
                }
            }
        }
        // Delete in an empty field inside an app comes back out, to its name.
        if (s.scope != null and s.query.text().len == 0) for (c.input.ops) |op| {
            if (op == .command and (op.command == .delete_backward or op.command == .delete_word_backward)) {
                c.input.ops = &.{};
                s.leave(true);
                break;
            }
        };
        const n = s.res.n;
        if (c.shortcut(.{ .key = S.down }) or c.shortcut(.{ .key = 'n', .ctrl = true })) {
            if (n > 0) s.sel = (s.sel + 1) % n;
        }
        if (c.shortcut(.{ .key = S.up }) or c.shortcut(.{ .key = 'p', .ctrl = true })) {
            if (n > 0) s.sel = (s.sel + n - 1) % n;
        }
        // ⌘1…⌘9: the row of that number, at once.
        for (0..@min(n, 9)) |k| if (c.shortcut(.{ .key = @intCast('1' + k), .cmd = true })) {
            s.sel = k;
            s.activate(c);
        };
        if (c.shortcut(.{ .key = S.escape })) {
            if (s.query.text().len > 0) s.query.clear() else if (s.scope != null) s.leave(false) else if (s.host) |h| h.hide(h.ctx);
        }
    }

    fn header(s: *Nanolight, c: *ui.Context, p: Palette) bool {
        const bar = ui.div(c).row().wFull().h(header_h).px(18).gap(12).itemsCenter();
        defer bar.end();
        // The theme's glyph, in its hue; System's grey lens otherwise.
        ui.icon(c, s.theme.glyph(), .{ .size = 19, .weight = .medium, .color = s.theme.hue(c.theme.dark) orelse p.sub, .frame = 22 });
        s.rebuild();
        if (s.scopeOf()) |sc| s.chip(c, p, sc);
        const r = ui.textField(c, &s.query, .{
            .suggestion = s.completion(),
            .bare = true,
            .size = s.theme.fieldSize(),
            .width = .fill,
            .placeholder = s.placeholder(),
            .placeholder_color = p.sub.alpha(0.75),
            .color = p.text,
        });
        return r.submitted;
    }

    /// What the query is the start of, drawn faintly after the caret; →
    /// or Tab takes it. The top app's name when one is listed first ("saf"
    /// → "ari"), else Google's first completion that goes on from the
    /// words ("liquid gl" → "ass"), so it is one key away, not a walk
    /// down the rows. Return never takes it: Return is the selected row.
    fn completion(s: *const Nanolight) []const u8 {
        const q = s.query.text();
        if (q.len == 0 or s.res.n == 0 or std.hash.Wyhash.hash(0, q) == s.revealed) return "";
        const r = s.res.rows[0];
        // Inside an app: the rest of the first person's name.
        if (s.scope != null) {
            if (r.kind != .into) return "";
            const it = &s.into_list.items[r.into];
            const name = it.title();
            if (!it.person or name.len <= q.len or !text.utf8StartsWithFold(name, q)) return "";
            return name[q.len..];
        }
        if (r.kind == .app) {
            const name = s.index.apps.items[r.app].name;
            if (name.len <= q.len or !text.utf8StartsWithFold(name, q)) return "";
            return name[q.len..];
        }
        if (r.kind != .search_web) return "";
        for (0..s.web.n) |i| {
            const w = s.web.get(i);
            if (w.len > q.len and text.utf8StartsWithFold(w, q)) return w[q.len..];
        }
        return "";
    }

    fn take(s: *Nanolight, more: []const u8) void {
        var buf: [suggest.max_len * 2]u8 = undefined;
        const q = s.query.text();
        if (q.len + more.len > buf.len) return;
        @memcpy(buf[0..q.len], q);
        @memcpy(buf[q.len..][0..more.len], more);
        const len = q.len + more.len;
        s.query.set(buf[0..len]);
        s.query.want_selection = .{ len, len };
    }

    /// Rebuild changed queries, asking for missing completions.
    pub fn rebuild(s: *Nanolight) void {
        const q = s.query.text();
        // The same words inside an app and out of it are two lists.
        const h = std.hash.Wyhash.hash(if (s.scope) |a| @as(u64, a) + 1 else 0, q);
        if (h == s.built) return;
        s.built = h;
        // Inside an app: its own rows, and nothing asked of the web.
        if (s.scope != null) {
            s.found.deinit();
            s.web.n = 0;
            s.fx = null;
            s.fx_pending = false;
            s.fx_failed = false;
            s.fill();
            s.sel = 0;
            return;
        }
        // The clipboard's history stays here: no files, rates or Google.
        if (clipboard.words(q) != null) {
            s.found.deinit();
            s.web.n = 0;
            s.fx = null;
            s.fx_pending = false;
            s.fx_failed = false;
            s.fill();
            s.sel = 0;
            return;
        }
        files_view.rebuild(s);
        const was = s.web;
        s.web.n = 0;
        const currency = @import("currency.zig");
        s.fx = null;
        s.fx_pending = false;
        s.fx_failed = false;
        if (currency.parse(q)) |fxq| {
            if (s.fx_cache.get(fxq)) |a| {
                s.fx = a;
            } else if (s.host) |host| {
                if (host.rates) |ask| {
                    s.fx_pending = true;
                    ask(host.ctx, fxq.amount, fxq.fromSlice(), fxq.toSlice());
                } else s.fx_failed = true;
            } else s.fx_failed = true;
        }
        if (s.host) |host| if (host.suggest) |ask| if (s.suggest_on and suggest.eligible(q) and @import("calc.zig").eval(q) == null and @import("currency.zig").parse(q) == null) {
            if (!s.cache.lookup(q, &s.web)) {
                answers.hold(&s.web, &was, q);
                ask(host.ctx, q);
            }
        };
        s.fill();
        // The first row: an app, the answer, or the search for what was
        // typed; never a completion nobody picked (they come after it).
        s.sel = 0;
    }

    pub fn fill(s: *Nanolight) void {
        s.list_gen +%= 1;
        if (s.scopeOf()) |sc| {
            into.build(&s.into_list, sc, s.query.text(), s.book, s.contacts_access);
            s.res.intoRows(s.into_list.n, sc.name);
            return;
        }
        if (clipboard.words(s.query.text())) |w| {
            var found: [results.max_rows]u32 = undefined;
            const n = if (s.clips) |h| h.find(w, &found) else 0;
            s.res.clips(found[0..n]);
            return;
        }
        var sug: [results.max_apps]u32 = undefined;
        const ns = s.index.suggestions(&sug);
        var web: [suggest.max_rows][]const u8 = undefined;
        s.res.claude = s.claude_on;
        s.res.build(s.query.text(), s.index, sug[0..ns], s.web.slices(&web), &s.found);
        s.typedInto();
        if (s.res.n > 0 and s.res.rows[0].kind == .currency) {
            if (s.fx) |a| {
                s.res.answer = @import("currency.zig").format(&s.res.answer_buf, a.value, true);
                s.res.hex = @import("currency.zig").note(&s.res.hex_buf, a);
            } else if (s.fx_pending) {
                s.res.answer = "…";
                s.res.hex = "Fetching rates";
            } else {
                s.res.answer = "—";
                s.res.hex = "Rates unavailable";
            }
        }
    }

    /// Something was copied while "clip" is typed: the rows again, the
    /// selection on the entry it was on.
    pub fn clipsChanged(s: *Nanolight) void {
        if (clipboard.words(s.query.text()) == null) return;
        const was: ?u32 = if (s.sel < s.res.n and s.res.rows[s.sel].kind == .clip) s.res.rows[s.sel].clip else null;
        s.fill();
        s.sel = 0;
        const id = was orelse return;
        for (s.res.slice(), 0..) |r, i| if (r.clip == id) {
            s.sel = i;
            return;
        };
    }

    pub const answered = answers.answered;
    pub const unanswered = answers.unanswered;
    pub const filesAnswered = files_view.filesAnswered;

    /// A rate for `amount from→to` landed: keep it and redraw if still typed.
    pub fn ratesAnswered(s: *Nanolight, amount: f64, from: []const u8, to: []const u8, a: @import("currency.zig").Answer) void {
        s.fx_cache.put(a);
        const q = @import("currency.zig").parse(s.query.text()) orelse return;
        if (q.amount != amount or !std.mem.eql(u8, q.fromSlice(), from) or !std.mem.eql(u8, q.toSlice(), to)) return;
        s.fx = a;
        s.fx_pending = false;
        s.fx_failed = false;
        s.fill();
    }

    /// The rate ask failed or was empty: keep an honest empty answer.
    pub fn ratesFailed(s: *Nanolight, amount: f64, from: []const u8, to: []const u8) void {
        const q = @import("currency.zig").parse(s.query.text()) orelse return;
        if (q.amount != amount or !std.mem.eql(u8, q.fromSlice(), from) or !std.mem.eql(u8, q.toSlice(), to)) return;
        s.fx = null;
        s.fx_pending = false;
        s.fx_failed = true;
        s.fill();
    }

    fn list(s: *Nanolight, c: *ui.Context, p: Palette) void {
        const box = ui.div(c).column().wFull().h(list_h).p(list_pad);
        defer box.end();
        const rows = s.res.slice();
        var heights: [results.max_rows]f32 = undefined;
        for (rows, 0..) |r, i| {
            const rh: f32 = if (r.kind == .calc or r.kind == .currency) calc_h else row_h;
            const head: f32 = if (s.res.section(i) != null) section_h else 0;
            heights[i] = rh + head;
        }
        const room = list_h - list_pad * 2;
        // Nothing scrolls here, so the wheel comes to the view.
        c.wants_wheel = true;
        s.in_view.update(heights[0..rows.len], s.sel, s.list_gen, room, c.input.scroll.y, c.input.precise);
        const first = s.in_view.first;
        const after = row_window.end(heights[0..rows.len], first, room);
        for (rows[first..after], first..) |r, i| {
            if (s.res.section(i)) |name| {
                const head = ui.div(c).row().wFull().h(section_h).px(12).pb(6).itemsEnd();
                defer head.end();
                ui.text(c, name, .{ .size = 11.5, .weight = .semibold, .color = p.sub.alpha(0.85) });
            }
            s.row(c, p, i, r);
        }
        // More than fits: where the rows in view are in the list.
        if (after - first < rows.len) {
            const per = room / @as(f32, @floatFromInt(rows.len));
            ui.div(c).absolute().offset(width - list_pad * 2 + 1, per * @as(f32, @floatFromInt(first))).w(3)
                .h(per * @as(f32, @floatFromInt(after - first))).roundedFull().bg(p.sub.alpha(0.35)).end();
        }
    }

    fn row(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
        const big = r.kind == .calc or r.kind == .currency;
        const d = ui.div(c).row().wFull().h(if (big) calc_h else row_h).px(10).gap(12).itemsCenter().control();
        defer d.end();
        if (i == s.sel) _ = d.rounded(10).bg(p.sel).border(p.rim);
        if (d.clicked()) {
            s.sel = i;
            s.activate(c);
        }
        if (r.kind == .calc or r.kind == .currency) return s.calcCard(c, p);
        s.tile(c, p, r);
        const q = s.query.text();
        switch (r.kind) {
            .calc, .currency => unreachable,
            .app => {
                const a = s.index.apps.items[r.app];
                ui.richText(c, a.name, s.highlight(i, r, p), .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82) });
                ui.text(c, a.folder, .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .pane => {
                const pane = @import("settings_panes.zig").all[r.app];
                ui.richText(c, pane.name, s.highlight(i, r, p), .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82) });
                ui.text(c, "System Settings", .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .file => files_view.row(s, c, p, i, r),
            .into => {
                const it = &s.into_list.items[r.into];
                if (it.person) {
                    var m = r;
                    m.match = it.match;
                    ui.richText(c, it.title(), s.highlight(i, m, p), .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82), .truncate = .ellipsis });
                } else ui.text(c, it.title(), .{ .size = 13.5, .weight = .medium, .color = p.text, .truncate = .ellipsis });
                ui.text(c, it.sub(), .{ .size = 12, .color = p.sub.alpha(0.8), .truncate = .ellipsis });
            },
            .clip => if (s.clips) |h| if (h.get(r.clip)) |e| {
                ui.text(c, clipboard.oneLine(&s.clip_lines[i], e.text), .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82), .truncate = .ellipsis });
                ui.text(c, clipboard.ago(&s.clip_ago[i], e.at, s.clock()), .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .settings => {
                ui.text(c, "Nanolight Settings", .{ .size = 13.5, .weight = .medium, .color = p.text });
                ui.text(c, "Shortcut, sync, updates", .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .suggest => {
                const w = s.web.get(r.web);
                ui.richText(c, w, s.added(i, w, p), .{ .size = 13.5, .color = p.text.alpha(0.72), .truncate = .ellipsis });
            },
            .ask_grok, .ask_claude, .search_x, .search_web => {
                const verb = switch (r.kind) {
                    .ask_grok => "Ask Grok",
                    .ask_claude => "Ask Claude",
                    .search_x => "Search X for",
                    else => "Search Google for",
                };
                ui.textf(c, .{ .size = 13.5, .weight = .medium, .color = p.text, .truncate = .ellipsis }, "{s} “{s}”", .{ verb, std.mem.trim(u8, q, " ") });
                ui.text(c, switch (r.kind) {
                    .ask_grok => "grok.com",
                    .ask_claude => "claude.ai",
                    .search_x => "x.com · Latest",
                    else => "google.com",
                }, .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
        }
        ui.spacer(c);
        if (i == s.sel) {
            ui.text(c, if (r.kind == .into) s.into_list.items[r.into].verb else if (r.kind == .clip) "Copy" else if (r.kind == .app or r.kind == .file or r.kind == .settings or r.kind == .pane) "Open" else "Go", .{ .size = 12, .weight = .medium, .color = p.sub });
            ui.kbd(c, "↩");
        } else if (i < 9) ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.5), .tabular = true }, "{s}{d}", .{ results.mod, i + 1 });
    }

    fn calcCard(s: *Nanolight, c: *ui.Context, p: Palette) void {
        @import("calc_card.zig").draw(c, p, s.query.text(), s.res.answer, s.res.hex, c.time - s.copied_at < 1.4);
    }

    /// The row's picture: the app's icon, or a symbol on a quiet tile.
    fn tile(s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
        // A pane: System Settings' own icon.
        if (r.kind == .into) {
            const it = &s.into_list.items[r.into];
            if (it.person) {
                var ib: [8]u8 = undefined;
                const box = ui.div(c).size(26, 26).roundedFull().bg(p.tile).center();
                defer box.end();
                ui.text(c, it.initials(&ib), .{ .size = 11, .weight = .semibold, .color = p.text });
                return;
            }
        }
        const app = if (r.kind == .pane) s.index.find("System Settings") else if (r.kind == .app) r.app else if (r.kind == .into and s.into_list.items[r.into].symbol.len == 0) s.into_list.items[r.into].app else null;
        if (app) |a| if (s.index.icon(a)) |png| {
            const box = ui.div(c).size(26, 26).center();
            defer box.end();
            _ = ui.image(c, .{ .key = s.index.apps.items[a].path, .bytes = png, .max_width = 26, .max_height = 26, .radius = 0, .scale = 1 });
            return;
        };
        if (r.kind == .file) return files_view.tile(s, c, p, r);
        const big = r.kind == .calc or r.kind == .currency;
        const side: f32 = if (big) 34 else 26;
        const box = ui.div(c).size(side, side).rounded(if (big) 9 else 7).bg(p.tile).center();
        defer box.end();
        if (r.kind == .search_x) {
            ui.text(c, "𝕏", .{ .size = 15, .weight = .bold, .color = p.text });
            return;
        }
        ui.icon(c, switch (r.kind) {
            .calc => "plus.forwardslash.minus",
            .currency => "plus.forwardslash.minus",
            .ask_grok => "sparkles",
            .ask_claude => "sun.max",
            .search_web => "globe",
            .suggest => "magnifyingglass",
            .settings => "gearshape",
            .clip => "doc.on.clipboard",
            .into => s.into_list.items[r.into].symbol,
            else => "app.dashed",
        }, .{ .size = if (big) 16 else 13, .weight = .medium, .color = p.text });
    }

    /// The matched letters, full strength and heavier.
    pub fn highlight(s: *Nanolight, i: usize, r: Row, p: Palette) []const ui.Span {
        const hits = r.match.matched();
        var n: usize = 0;
        var k: usize = 0;
        while (k < hits.len and n < s.spans[i].len) {
            var end = k + 1;
            while (end < hits.len and hits[end] == hits[end - 1] + 1) end += 1;
            s.spans[i][n] = .{ .start = hits[k], .end = @as(u32, hits[end - 1]) + 1, .color = p.text, .weight = .semibold };
            n += 1;
            k = end;
        }
        return s.spans[i][0..n];
    }

    /// A completion as a search box shows it: the words typed plain, what
    /// it adds stronger.
    fn added(s: *Nanolight, i: usize, w: []const u8, p: Palette) []const ui.Span {
        const q = std.mem.trim(u8, s.query.text(), " ");
        if (q.len == 0 or w.len <= q.len or !text.utf8StartsWithFold(w, q)) return &.{};
        s.spans[i][0] = .{ .start = @intCast(q.len), .end = @intCast(w.len), .color = p.text, .weight = .semibold };
        return s.spans[i][0..1];
    }

    fn footer(s: *Nanolight, c: *ui.Context, p: Palette) void {
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const bar = ui.div(c).row().wFull().h(footer_h).px(16).gap(8).itemsCenter();
        defer bar.end();
        appIcon(c, 16);
        ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.8) }, "{s} · {d} apps", .{ if (s.note.len > 0) s.note else "Nanolight", s.index.apps.items.len });
        ui.spacer(c);
        {
            ui.key(c, "settings-gear");
            const g = ui.div(c).size(26, 26).rounded(7).center().control().hover(p.sel);
            defer g.end();
            if (g.clicked()) s.openSettings();
            ui.icon(c, "gearshape", .{ .size = 13, .weight = .medium, .color = p.sub });
            ui.text(c, "Settings", .{ .size = 1, .color = p.sub.alpha(0) });
        }
        if (s.previewing) {
            ui.text(c, "Open in Browser", .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) });
            ui.kbd(c, results.mod ++ "↩");
            ui.div(c).w(1).h(14).bg(p.hair).end();
            ui.text(c, "Back", .{ .size = 12, .color = p.sub.alpha(0.8) });
            ui.kbd(c, "esc");
            return;
        }
        if (s.res.n == 0) return;
        const sel_row = s.res.rows[@min(s.sel, s.res.n - 1)];
        ui.text(c, if (sel_row.kind == .into) s.into_list.items[sel_row.into].verb else sel_row.kind.action(), .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) });
        ui.kbd(c, "↩");
        ui.div(c).w(1).h(14).bg(p.hair).end();
        ui.text(c, "Close", .{ .size = 12, .color = p.sub.alpha(0.8) });
        ui.kbd(c, "esc");
    }

    /// Return on the selected row.
    pub fn activate(s: *Nanolight, c: *ui.Context) void {
        if (s.res.n == 0) return;
        const r = s.res.rows[@min(s.sel, s.res.n - 1)];
        switch (r.kind) {
            .calc => {
                var buf: [64]u8 = undefined;
                const v = @import("calc.zig").eval(s.query.text()) orelse return;
                c.clipboard.write(c.clipboard.ctx, @import("calc.zig").format(&buf, v, false));
                s.copied_at = c.time;
                return;
            },
            .currency => {
                const a = s.fx orelse return;
                var buf: [64]u8 = undefined;
                c.clipboard.write(c.clipboard.ctx, @import("currency.zig").format(&buf, a.value, false));
                s.copied_at = c.time;
                return;
            },
            .app => {
                s.index.opened(r.app, s.kv);
                s.go(s.index.apps.items[r.app].path);
            },
            .file => s.go(s.found.entries[r.file].path()),
            .into => s.runInto(r.into),
            .ask_grok, .ask_claude, .search_x => s.go(results.url(&s.url_buf, r.kind, s.query.text())),
            .search_web => s.search(s.query.text(), !s.searches_out),
            .settings => s.openSettings(),
            .pane => s.go(@import("settings_panes.zig").urls[r.app]),
            .clip => {
                // Copied again, so it comes back to the top as the watcher sees it.
                const h = s.clips orelse return;
                // The entry this row shows, wherever it is now; gone, nothing.
                const e = h.get(r.clip) orelse return;
                c.clipboard.write(c.clipboard.ctx, e.text);
                s.copied_at = c.time;
                if (s.host) |host| host.hide(host.ctx);
            },
            .suggest => {
                // Its words fill the field, as a search box's would.
                s.query.set(s.web.get(r.web));
                s.search(s.query.text(), !s.searches_out);
            },
        }
    }

    /// ⌘↩ on the selected row: a search goes where Return doesn't send it.
    fn activateOut(s: *Nanolight, c: *ui.Context) void {
        if (s.res.n == 0) return;
        const r = s.res.rows[@min(s.sel, s.res.n - 1)];
        switch (r.kind) {
            .search_web => s.search(s.query.text(), s.searches_out),
            .suggest => s.search(s.web.get(r.web), s.searches_out),
            else => s.activate(c),
        }
    }

    /// Google's page for `words`: in the panel when `in_panel` and the host
    /// can show it there, else in the browser.
    fn search(s: *Nanolight, words: []const u8, in_panel: bool) void {
        const h = s.host orelse return;
        const u = results.url(&s.preview_buf, .search_web, words);
        const show = (if (in_panel) h.preview else null) orelse return s.go(u);
        s.preview_url = u;
        s.previewing = true;
        s.preview_q = std.hash.Wyhash.hash(0, s.query.text());
        show(h.ctx, u);
    }

    // ----- into an app (into.zig) -----

    pub fn scopeOf(s: *const Nanolight) ?into.Scope {
        const a = s.scope orelse return null;
        if (a >= s.index.apps.items.len) return null;
        const name = s.index.apps.items[a].name;
        return .{ .app = a, .name = name, .handler = into.Handler.of(name) };
    }

    /// An app Tab can go into: a real one (not a command among the apps).
    fn canEnter(s: *const Nanolight, a: u32) bool {
        return a < s.index.apps.items.len and std.mem.endsWith(u8, s.index.apps.items[a].path, ".app");
    }

    /// What Tab would go into, from the selected row: an app, or the app
    /// a row typed in full is for, with the words after its name.
    fn intoTarget(s: *const Nanolight) ?struct { app: u32, rest: []const u8 } {
        if (s.scope != null or s.sel >= s.res.n) return null;
        const r = s.res.rows[s.sel];
        if (r.kind == .app and s.canEnter(r.app)) return .{ .app = r.app, .rest = "" };
        if (r.kind == .into) if (into.parseInline(s.query.text(), s.index)) |m| return .{ .app = m.app, .rest = m.rest };
        return null;
    }

    /// Into app `a`, the field holding `rest`.
    pub fn enter(s: *Nanolight, a: u32, rest: []const u8) void {
        if (!s.canEnter(a)) return;
        // `rest` may be the field's own text.
        var buf: [256]u8 = undefined;
        const n = @min(rest.len, buf.len);
        @memcpy(buf[0..n], rest[0..n]);
        s.back();
        s.scope = a;
        s.query.set(buf[0..n]);
        s.query.want_selection = .{ n, n };
        s.revealed = 0;
        const sc = s.scopeOf().?;
        if (sc.handler.warms()) if (s.host) |h| if (h.warm) |f| f(h.ctx, s.index.apps.items[a].path);
        s.rebuild();
    }

    /// Out of the app: the field holds its name again (`restore`), as
    /// before Tab, or nothing.
    pub fn leave(s: *Nanolight, restore: bool) void {
        const a = s.scope orelse return;
        s.scope = null;
        if (restore and a < s.index.apps.items.len) {
            const name = s.index.apps.items[a].name;
            s.query.set(name);
            s.query.want_selection = .{ name.len, name.len };
        } else s.query.clear();
        s.revealed = std.hash.Wyhash.hash(0, s.query.text());
        s.rebuild();
    }

    /// Contacts access changed, or the people in it did: the rows again.
    pub fn contactsChanged(s: *Nanolight, book: ?*const contacts.Book, access: into.Access) void {
        s.book = book;
        s.contacts_access = access;
        s.built = 1;
        s.rebuild();
    }

    /// "messages to shawn", "text shawn", "safari apple.com": the app's
    /// rows among the others. A person, an address or a pane named by the
    /// app's whole name (or a verb for it) leads; the app's own search
    /// for the words comes after the apps otherwise.
    fn typedInto(s: *Nanolight) void {
        s.into_list.n = 0;
        if (s.res.n == 0 or s.res.rows[0].kind == .calc or s.res.rows[0].kind == .currency) return;
        const m = into.parseInline(s.query.text(), s.index) orelse return;
        if (!s.canEnter(m.app)) return;
        const name = s.index.apps.items[m.app].name;
        into.build(&s.into_list, .{ .app = m.app, .name = name, .handler = m.handler }, m.rest, s.book, s.contacts_access);
        var lead: usize = 0;
        if (m.sure) for (s.into_list.slice()) |it| {
            const precise = switch (it.go) {
                .url, .url_in_app => true,
                .ask_contacts => m.person,
                .search_in_app, .open_app => false,
            };
            if (!precise or lead == 3) break;
            lead += 1;
        };
        if (lead > 0) {
            s.into_list.n = lead;
            s.res.insertInto(0, lead, name);
            return;
        }
        // Its own search, under the apps, before Google's.
        const own = for (s.into_list.slice(), 0..) |it, i| {
            if (it.go == .search_in_app or it.go == .url_in_app) break i;
        } else return;
        s.into_list.items[0] = s.into_list.items[own];
        s.into_list.n = 1;
        const at = for (s.res.slice(), 0..) |r, i| {
            if (r.kind == .search_web) break i;
        } else s.res.n;
        // Never the first row: with no app listed, Return still searches
        // Google for what was typed, as it always did.
        s.res.insertInto(@max(at, @min(1, s.res.n)), 1, name);
    }

    fn runInto(s: *Nanolight, k: u8) void {
        const h = s.host orelse return;
        const it = &s.into_list.items[k];
        if (it.go == .ask_contacts) {
            if (h.contacts) |f| f(h.ctx);
            return;
        }
        s.index.opened(it.app, s.kv);
        const path = s.index.apps.items[it.app].path;
        if (h.into) |f| f(h.ctx, it, path) else h.open(h.ctx, switch (it.go) {
            .url, .url_in_app => it.target(),
            else => path,
        });
        // Done in it: the next showing starts outside, empty.
        if (s.scope != null) s.leave(false);
        h.hide(h.ctx);
    }

    /// The app the field is in, before it: its icon and name.
    fn chip(s: *Nanolight, c: *ui.Context, p: Palette, sc: into.Scope) void {
        ui.key(c, "into-chip");
        const d = ui.div(c).row().h(28).px(8).gap(6).rounded(8).bg(p.tile).itemsCenter().control();
        defer d.end();
        if (d.clicked()) s.leave(true);
        if (s.index.icon(sc.app)) |png| {
            _ = ui.image(c, .{ .key = s.index.apps.items[sc.app].path, .bytes = png, .max_width = 18, .max_height = 18, .radius = 0, .scale = 1 });
        }
        ui.text(c, sc.name, .{ .size = 13.5, .weight = .semibold, .color = p.text });
    }

    fn placeholder(s: *Nanolight) []const u8 {
        const sc = s.scopeOf() orelse return "Search apps, do math, ask Grok…";
        return switch (sc.handler) {
            .messages => "Someone, or someone and what to say",
            .mail => "Someone, or an email address",
            .facetime => "Who to call",
            .browser => "An address, or what to search",
            .maps => "A place or an address",
            .settings => "A setting",
            .generic => std.fmt.bufPrint(&s.placeholder_buf, "Search {s}…", .{sc.name}) catch "Search…",
        };
    }

    pub fn openSettings(s: *Nanolight) void {
        s.back();
        s.settings_ui.show();
    }

    /// The rows again, the page gone.
    pub fn back(s: *Nanolight) void {
        if (!s.previewing) return;
        s.previewing = false;
        if (s.host) |h| if (h.preview) |f| f(h.ctx, null);
    }

    fn go(s: *Nanolight, target: []const u8) void {
        const h = s.host orelse return;
        h.open(h.ctx, target);
        h.hide(h.ctx);
    }
};
