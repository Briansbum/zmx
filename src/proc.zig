/// Foreground process inspection for session context capture.
const builtin = @import("builtin");
const std = @import("std");
const cross = @import("cross.zig");
const lib_posix = @import("posix.zig");

// CTL_KERN=1, KERN_PROCARGS2=49, KERN_ARGMAX=8 (stable macOS ABI values;
// sys/sysctl.h is unavailable when cross-compiling, see cross.zig)
const CTL_KERN: c_int = 1;
const KERN_ARGMAX: c_int = 8;
const KERN_PROCARGS2: c_int = 49;

/// Returns the argv of the foreground process group leader on the pty, or
/// null when the shell itself is in the foreground, the leader is gone, or
/// the platform is unsupported. Caller owns the result; free with freeArgv.
pub fn foregroundArgv(
    gpa: std.mem.Allocator,
    io: std.Io,
    pty_fd: i32,
    shell_pid: lib_posix.pid_t,
) ?[][]const u8 {
    var pgrp: lib_posix.pid_t = 0;
    if (cross.c.ioctl(pty_fd, cross.c.TIOCGPGRP, &pgrp) != 0) return null;
    if (pgrp <= 0 or pgrp == shell_pid) return null;

    return switch (builtin.os.tag) {
        .linux => linuxArgv(gpa, io, pgrp),
        .macos => macosArgv(gpa, pgrp),
        else => null,
    };
}

pub fn freeArgv(gpa: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| gpa.free(arg);
    gpa.free(argv);
}

fn linuxArgv(gpa: std.mem.Allocator, io: std.Io, pid: lib_posix.pid_t) ?[][]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return null;

    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = file.readStreaming(io, &.{buf[len..]}) catch return null;
        if (n == 0) break;
        len += n;
    }
    if (len == 0) return null;

    return parseCmdline(gpa, buf[0..len]) catch null;
}

fn macosArgv(gpa: std.mem.Allocator, pid: lib_posix.pid_t) ?[][]const u8 {
    var argmax: c_int = 0;
    var argmax_len: usize = @sizeOf(c_int);
    var argmax_mib = [_]c_int{ CTL_KERN, KERN_ARGMAX };
    if (std.c.sysctl(&argmax_mib, argmax_mib.len, &argmax, &argmax_len, null, 0) != 0) return null;
    if (argmax <= 0) return null;

    const buf = gpa.alloc(u8, @intCast(argmax)) catch return null;
    defer gpa.free(buf);

    var buf_len: usize = buf.len;
    var mib = [_]c_int{ CTL_KERN, KERN_PROCARGS2, @intCast(pid) };
    if (std.c.sysctl(&mib, mib.len, buf.ptr, &buf_len, null, 0) != 0) return null;

    return parseProcArgs2(gpa, buf[0..buf_len]) catch null;
}

/// Parses /proc/<pid>/cmdline: NUL-separated argv, possibly NUL-terminated.
pub fn parseCmdline(gpa: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| gpa.free(arg);
        args.deinit(gpa);
    }

    var it = std.mem.splitScalar(u8, bytes, 0);
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        try args.append(gpa, try gpa.dupe(u8, arg));
    }
    if (args.items.len == 0) return error.EmptyCmdline;

    return try args.toOwnedSlice(gpa);
}

/// Parses the KERN_PROCARGS2 buffer: i32 argc, NUL-terminated exec path,
/// NUL padding, then argc NUL-terminated args (environment follows, ignored).
pub fn parseProcArgs2(gpa: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    if (bytes.len < 4) return error.InvalidProcArgs;
    const argc_i32 = std.mem.readInt(i32, bytes[0..4], builtin.cpu.arch.endian());
    if (argc_i32 <= 0) return error.InvalidProcArgs;
    const argc: usize = @intCast(argc_i32);

    var i: usize = 4;
    while (i < bytes.len and bytes[i] != 0) i += 1; // exec path
    while (i < bytes.len and bytes[i] == 0) i += 1; // padding

    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| gpa.free(arg);
        args.deinit(gpa);
    }

    while (args.items.len < argc and i < bytes.len) {
        const start = i;
        while (i < bytes.len and bytes[i] != 0) i += 1;
        try args.append(gpa, try gpa.dupe(u8, bytes[start..i]));
        i += 1;
    }
    if (args.items.len != argc) return error.InvalidProcArgs;

    return try args.toOwnedSlice(gpa);
}

test "parseCmdline splits NUL-separated argv" {
    const gpa = std.testing.allocator;
    const argv = try parseCmdline(gpa, "npm\x00run\x00dev\x00");
    defer freeArgv(gpa, argv);

    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("npm", argv[0]);
    try std.testing.expectEqualStrings("run", argv[1]);
    try std.testing.expectEqualStrings("dev", argv[2]);
}

test "parseCmdline rejects empty input" {
    try std.testing.expectError(error.EmptyCmdline, parseCmdline(std.testing.allocator, ""));
    try std.testing.expectError(error.EmptyCmdline, parseCmdline(std.testing.allocator, "\x00"));
}

test "parseProcArgs2 extracts argc args after exec path" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    var argc_bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &argc_bytes, 2, builtin.cpu.arch.endian());
    try buf.appendSlice(gpa, &argc_bytes);
    try buf.appendSlice(gpa, "/usr/bin/vim\x00\x00\x00");
    try buf.appendSlice(gpa, "vim\x00notes.md\x00");
    try buf.appendSlice(gpa, "HOME=/Users/x\x00");

    const argv = try parseProcArgs2(gpa, buf.items);
    defer freeArgv(gpa, argv);

    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("vim", argv[0]);
    try std.testing.expectEqualStrings("notes.md", argv[1]);
}

test "parseProcArgs2 rejects truncated buffers" {
    try std.testing.expectError(error.InvalidProcArgs, parseProcArgs2(std.testing.allocator, "\x01"));
    var argc_bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &argc_bytes, 3, builtin.cpu.arch.endian());
    var buf: [10]u8 = undefined;
    @memcpy(buf[0..4], &argc_bytes);
    @memcpy(buf[4..10], "vim\x00a\x00");
    try std.testing.expectError(error.InvalidProcArgs, parseProcArgs2(std.testing.allocator, &buf));
}
