//! A command typed in the search: `> git status` or `cmd git status`. It
//! is one row, "Run “git status”"; Return runs it in the panel (your login
//! shell, from your home folder, its output as it prints, script_run.zig),
//! ⌘↩ in Terminal. Nothing runs while typing.
const std = @import("std");

/// The command in `query`, or null when it isn't one: `>` then the command,
/// or `cmd ` (any case) then the command. `>` alone, or `cmd` with nothing
/// after it, is a command still being typed (empty).
pub fn parse(query: []const u8) ?[]const u8 {
    const q = std.mem.trimStart(u8, query, " ");
    if (q.len > 0 and q[0] == '>') return std.mem.trim(u8, q[1..], " ");
    if (q.len >= 3 and std.ascii.eqlIgnoreCase(q[0..3], "cmd")) {
        if (q.len == 3) return "";
        if (q[3] == ' ') return std.mem.trim(u8, q[4..], " ");
    }
    return null;
}

/// The shell it runs in: `$SHELL` if it's a path, else zsh.
pub fn shell(env_shell: ?[]const u8) []const u8 {
    if (env_shell) |s| if (s.len > 1 and s[0] == '/') return s;
    return "/bin/zsh";
}

/// The argv that runs `cmd` in `sh_path` as a login shell (its PATH, Homebrew
/// with it). The runner sends its errors with its output.
pub fn argv(buf: *[4][]const u8, sh_path: []const u8, cmd: []const u8) []const []const u8 {
    buf.* = .{ sh_path, "-l", "-c", cmd };
    return buf;
}

/// A Terminal script that runs `cmd` from home, then leaves a shell open:
/// the `.command` file ⌘↩ opens (in whatever opens `.command` files).
pub fn terminalScript(a: std.mem.Allocator, sh_path: []const u8, cmd: []const u8) ![]u8 {
    // It deletes itself first: the file is only the way in.
    return std.fmt.allocPrint(a, "#!{s} -l\nrm -f -- \"$0\"\ncd ~ || exit\nclear\n{s}\nexec {s} -l\n", .{ sh_path, cmd, sh_path });
}

/// The rows' title: the command on one line, at most `buf.len` bytes.
pub fn oneLine(buf: []u8, cmd: []const u8) []const u8 {
    var n: usize = 0;
    for (cmd) |ch| {
        if (n == buf.len) break;
        buf[n] = if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch;
        n += 1;
    }
    // Never half a UTF-8 character at the end: cut before the one the
    // next byte continues.
    while (n > 0 and n < cmd.len and (cmd[n] & 0xC0) == 0x80) n -= 1;
    return buf[0..n];
}

test "commands are typed after > or cmd" {
    const t = std.testing;
    try t.expectEqualStrings("git status", parse("> git status").?);
    try t.expectEqualStrings("git status", parse(">git status").?);
    try t.expectEqualStrings("ls -la", parse("  cmd ls -la ").?);
    try t.expectEqualStrings("echo hi", parse("CMD echo hi").?);
    try t.expectEqualStrings("", parse(">").?);
    try t.expectEqualStrings("", parse("cmd").?);
    try t.expectEqualStrings("", parse("cmd ").?);
    // Words that only start like it are searches.
    try t.expect(parse("cmdline tools") == null);
    try t.expect(parse("safari") == null);
    try t.expect(parse("") == null);
    try t.expect(parse("2 > 1") == null);
}

test "the shell and what it's given" {
    const t = std.testing;
    try t.expectEqualStrings("/opt/homebrew/bin/fish", shell("/opt/homebrew/bin/fish"));
    try t.expectEqualStrings("/bin/zsh", shell(null));
    try t.expectEqualStrings("/bin/zsh", shell("zsh"));
    var b: [4][]const u8 = undefined;
    const v = argv(&b, "/bin/zsh", "echo $HOME | wc -c");
    try t.expectEqual(@as(usize, 4), v.len);
    try t.expectEqualStrings("-l", v[1]);
    try t.expectEqualStrings("echo $HOME | wc -c", v[3]);
    const s = try terminalScript(t.allocator, "/bin/zsh", "brew upgrade");
    defer t.allocator.free(s);
    try t.expect(std.mem.startsWith(u8, s, "#!/bin/zsh -l\n"));
    try t.expect(std.mem.indexOf(u8, s, "\nbrew upgrade\n") != null);
    var lb: [8]u8 = undefined;
    try t.expectEqualStrings("a b c", oneLine(&lb, "a\nb\tc"));
    try t.expectEqualStrings("caf", oneLine(lb[0..4], "café"));
}
