//! Input methods' candidate windows over the panel (issue #39). The panel
//! is a popover at the pop-up menu level (101); the system's candidate
//! window, Chinese Pinyin's row of characters, sits at level 20, behind
//! it, unless the text input client says how high its window is. AppKit
//! asks with NSTextInputClient's optional `windowLevel` and lifts the
//! input method's window above that level. nanoui's view doesn't answer
//! it, so the panel's view class gets it here: no activation, the panel
//! keeps its level and stays non-activating.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

extern "c" fn object_getClass(obj: objc.Object) objc.Class;
extern "c" fn class_addMethod(cls: objc.Class, name: objc.SEL, imp: *const anyopaque, types: [*:0]const u8) objc.BOOL;
extern "c" fn class_getInstanceMethod(cls: objc.Class, name: objc.SEL) ?*anyopaque;

/// Gives `view`'s class `windowLevel` (its window's level, 0 when it has
/// none), unless the class already has one. Returns whether it added it.
pub fn answerWindowLevel(view: objc.Object) bool {
    const cls = object_getClass(view);
    const s = objc.sel("windowLevel");
    if (class_getInstanceMethod(cls, s) != null) return false;
    return class_addMethod(cls, s, @ptrCast(&windowLevel), "q@:");
}

fn windowLevel(self: objc.Object, _: objc.SEL) callconv(.c) objc.NSInteger {
    const w = objc.msg(?objc.Object, self, "window", .{}) orelse return 0;
    return objc.msg(objc.NSInteger, w, "level", .{});
}

test "the panel's view tells input methods its window's level" {
    const pool = objc.Pool.push();
    defer pool.pop();
    // A view class of its own, as nanoui's: NSView has no windowLevel.
    const cls = objc.defineClass(.{ .name = "NanolightImeLevelTestView", .superclass = "NSView", .methods = &.{} });
    const view = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "init", .{});
    defer objc.release(view);
    try std.testing.expect(!objc.msg(objc.BOOL, view, "respondsToSelector:", .{objc.sel("windowLevel")}));

    try std.testing.expect(answerWindowLevel(view));
    try std.testing.expect(objc.msg(objc.BOOL, view, "respondsToSelector:", .{objc.sel("windowLevel")}));
    // No window yet: level 0, not a crash.
    try std.testing.expectEqual(@as(objc.NSInteger, 0), objc.msg(objc.NSInteger, view, "windowLevel", .{}));

    // In a popover-level panel, as Nanolight's: its level, 101.
    const rect: objc.CGRect = .{ .size = .{ .width = 100, .height = 100 } };
    const panel = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSPanel"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{
        rect, @as(objc.NSUInteger, 1 << 7), @as(objc.NSUInteger, 2), objc.YES,
    });
    defer objc.msg(void, panel, "close", .{});
    objc.msg(void, panel, "setReleasedWhenClosed:", .{objc.NO});
    objc.msg(void, panel, "setLevel:", .{@as(objc.NSInteger, 101)});
    objc.msg(void, panel, "setContentView:", .{view});
    try std.testing.expectEqual(@as(objc.NSInteger, 101), objc.msg(objc.NSInteger, view, "windowLevel", .{}));

    // Once is enough, and a class's own windowLevel is left alone.
    try std.testing.expect(!answerWindowLevel(view));
}
