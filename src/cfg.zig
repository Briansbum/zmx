/// Cfg is zmx's configuration container.
///
/// The purpose of this container is to hold anything that can be modified by the user.
pub const Cfg = @This();

const std = @import("std");
const lib_posix = @import("posix.zig");
const cross = @import("cross.zig");

socket_dir: []const u8,
log_dir: []const u8,
max_scrollback_lines: usize = 2_000, // same default as tmux
dir_mode: u32 = 0o750,
log_mode: u32 = 0o640,
tracked_envs: []const u8 = "DISPLAY,SSH_AUTH_SOCK,SSH_AGENT_PID,SSH_CONNECTION,WINDOWID,XAUTHORITY,KITTY_LISTEN_ON,KITTY_PID,KITTY_WINDOW_ID",
restore_enabled: bool = false,
restore_cmd: bool = false,
restore_interval_s: u32 = 5,
restore_dir: []const u8 = "",

pub fn init(alloc: std.mem.Allocator, io: std.Io) !Cfg {
    const socket_dir = try socketDir(alloc);
    errdefer alloc.free(socket_dir);
    const log_dir = try logDir(alloc);
    errdefer alloc.free(log_dir);

    const dir_mode = if (lib_posix.getenv("ZMX_DIR_MODE")) |m|
        std.fmt.parseInt(u32, m, 8) catch 0o750
    else
        0o750;

    const log_mode = if (lib_posix.getenv("ZMX_LOG_MODE")) |m|
        std.fmt.parseInt(u32, m, 8) catch 0o640
    else
        0o640;

    const restore_interval_s: u32 = if (lib_posix.getenv("ZMX_RESTORE_INTERVAL")) |i|
        @max(1, std.fmt.parseInt(u32, i, 10) catch 5)
    else
        5;

    const restore_dir = if (lib_posix.getenv("ZMX_RESTORE_DIR")) |d|
        try alloc.dupe(u8, d)
    else
        try std.fmt.allocPrint(alloc, "{s}/restore", .{socket_dir});
    errdefer alloc.free(restore_dir);

    var cfg = Cfg{
        .socket_dir = socket_dir,
        .log_dir = log_dir,
        .dir_mode = dir_mode,
        .log_mode = log_mode,
        .restore_enabled = lib_posix.getenv("ZMX_RESTORE") != null,
        .restore_cmd = lib_posix.getenv("ZMX_RESTORE_CMD") != null,
        .restore_interval_s = restore_interval_s,
        .restore_dir = restore_dir,
    };

    try cfg.mkdir(io);

    return cfg;
}

fn socketDir(alloc: std.mem.Allocator) ![]const u8 {
    const tmpdir = std.mem.trimEnd(u8, lib_posix.getenv("TMPDIR") orelse "/tmp", "/");
    const uid = lib_posix.getuid();

    const socket_dir: []const u8 = if (lib_posix.getenv("ZMX_DIR")) |zmxdir|
        try alloc.dupe(u8, zmxdir)
    else if (lib_posix.getenv("XDG_RUNTIME_DIR")) |xdg_runtime|
        try std.fmt.allocPrint(alloc, "{s}/zmx", .{xdg_runtime})
    else
        try std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });

    return socket_dir;
}

fn logDir(alloc: std.mem.Allocator) ![]const u8 {
    const log_dir = if (lib_posix.getenv("ZMX_DIR")) |zmxdir|
        try std.fmt.allocPrint(alloc, "{s}/logs", .{zmxdir})
    else if (lib_posix.getenv("XDG_STATE_HOME")) |xdg_state_home|
        try std.fmt.allocPrint(alloc, "{s}/zmx/logs", .{xdg_state_home})
    else if (lib_posix.getenv("HOME")) |home_dir|
        try std.fmt.allocPrint(alloc, "{s}/.local/state/zmx/logs", .{home_dir})
    else fallback: {
        // This is the last resort: falling back to /tmp/$UID if HOME is unset.
        const tmpdir = std.mem.trimEnd(u8, lib_posix.getenv("TMPDIR") orelse "/tmp", "/");
        const uid = lib_posix.getuid();
        break :fallback try std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });
    };

    return log_dir;
}

pub fn deinit(self: *Cfg, alloc: std.mem.Allocator) void {
    if (self.socket_dir.len > 0) alloc.free(self.socket_dir);
    if (self.log_dir.len > 0) alloc.free(self.log_dir);
    if (self.restore_dir.len > 0) alloc.free(self.restore_dir);
}

pub fn mkdir(self: *Cfg, io: std.Io) !void {
    const sock_perms = std.Io.Dir.Permissions.fromMode(@intCast(self.dir_mode));
    try mkdirAll(io, self.socket_dir, sock_perms);
    const log_perms = std.Io.Dir.Permissions.fromMode(@intCast(self.dir_mode));
    try mkdirAll(io, self.log_dir, log_perms);
}

pub fn mkdirAll(io: std.Io, sub_dir_path: []const u8, permissions: std.Io.Dir.Permissions) !void {
    var it = std.fs.path.componentIterator(sub_dir_path);
    var component = it.last() orelse return error.BadPathName;
    while (true) {
        std.Io.Dir.createDirAbsolute(io, component.path, permissions) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.FileNotFound => |e| {
                component = it.previous() orelse return e;
                continue;
            },
            else => |e| return e,
        };
        component = it.next() orelse return;
    }
}

test "Cfg.init restore defaults when env vars are not set" {
    const alloc = std.testing.allocator;

    _ = cross.c.unsetenv("ZMX_RESTORE");
    _ = cross.c.unsetenv("ZMX_RESTORE_CMD");
    _ = cross.c.unsetenv("ZMX_RESTORE_INTERVAL");
    _ = cross.c.unsetenv("ZMX_RESTORE_DIR");

    var cfg = try Cfg.init(alloc, std.testing.io);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(false, cfg.restore_enabled);
    try std.testing.expectEqual(false, cfg.restore_cmd);
    try std.testing.expectEqual(@as(u32, 5), cfg.restore_interval_s);
    try std.testing.expect(std.mem.startsWith(u8, cfg.restore_dir, cfg.socket_dir));
    try std.testing.expect(std.mem.endsWith(u8, cfg.restore_dir, "/restore"));
}

test "Cfg.init restore custom values from env vars" {
    const alloc = std.testing.allocator;

    _ = cross.c.setenv("ZMX_RESTORE", "1", 1);
    _ = cross.c.setenv("ZMX_RESTORE_CMD", "1", 1);
    _ = cross.c.setenv("ZMX_RESTORE_INTERVAL", "30", 1);
    _ = cross.c.setenv("ZMX_RESTORE_DIR", "/tmp/zmx-restore-test", 1);
    defer {
        _ = cross.c.unsetenv("ZMX_RESTORE");
        _ = cross.c.unsetenv("ZMX_RESTORE_CMD");
        _ = cross.c.unsetenv("ZMX_RESTORE_INTERVAL");
        _ = cross.c.unsetenv("ZMX_RESTORE_DIR");
    }

    var cfg = try Cfg.init(alloc, std.testing.io);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(true, cfg.restore_enabled);
    try std.testing.expectEqual(true, cfg.restore_cmd);
    try std.testing.expectEqual(@as(u32, 30), cfg.restore_interval_s);
    try std.testing.expectEqualStrings("/tmp/zmx-restore-test", cfg.restore_dir);
}

test "Cfg.init clamps restore interval to at least 1 second" {
    const alloc = std.testing.allocator;

    _ = cross.c.setenv("ZMX_RESTORE_INTERVAL", "0", 1);
    defer _ = cross.c.unsetenv("ZMX_RESTORE_INTERVAL");

    var cfg = try Cfg.init(alloc, std.testing.io);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 1), cfg.restore_interval_s);
}

test "Cfg.init uses default modes when env vars are not set" {
    const alloc = std.testing.allocator;

    // Ensure they are not set
    _ = cross.c.unsetenv("ZMX_DIR_MODE");
    _ = cross.c.unsetenv("ZMX_LOG_MODE");

    var cfg = try Cfg.init(alloc, std.testing.io);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0o750), cfg.dir_mode);
    try std.testing.expectEqual(@as(u32, 0o640), cfg.log_mode);
}

test "Cfg.init uses custom modes from env vars" {
    const alloc = std.testing.allocator;

    // Set custom octal values
    _ = cross.c.setenv("ZMX_DIR_MODE", "770", 1);
    _ = cross.c.setenv("ZMX_LOG_MODE", "660", 1);
    defer {
        _ = cross.c.unsetenv("ZMX_DIR_MODE");
        _ = cross.c.unsetenv("ZMX_LOG_MODE");
    }

    var cfg = try Cfg.init(alloc, std.testing.io);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0o770), cfg.dir_mode);
    try std.testing.expectEqual(@as(u32, 0o660), cfg.log_mode);
}
