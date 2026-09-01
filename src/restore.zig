/// Session context persistence: capture state written by each daemon and
/// read back by `zmx restore` / auto-restore to skeleton sessions after a
/// reboot. One JSON file per session in cfg.restore_dir.
const std = @import("std");
const Cfg = @import("cfg.zig");

pub const SCHEMA_VERSION: u32 = 1;

pub const SessionState = struct {
    version: u32 = SCHEMA_VERSION,
    name: []const u8,
    cwd: []const u8 = "",
    cwd_uri: []const u8 = "",
    shell: []const u8 = "",
    cmd: ?[]const u8 = null,
    argv: ?[]const []const u8 = null,
    captured_at: u64 = 0,
};

pub fn statePath(alloc: std.mem.Allocator, restore_dir: []const u8, name: []const u8) ![]u8 {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
        return error.InvalidSessionName;
    }
    return std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ restore_dir, name });
}

/// Atomically writes the state file: <name>.json.tmp then rename. Creates
/// restore_dir on first use.
pub fn save(
    gpa: std.mem.Allocator,
    io: std.Io,
    restore_dir: []const u8,
    dir_mode: u32,
    file_mode: u32,
    state: SessionState,
) !void {
    const dir_perms = std.Io.Dir.Permissions.fromMode(@intCast(dir_mode));
    try Cfg.mkdirAll(io, restore_dir, dir_perms);

    const path = try statePath(gpa, restore_dir, state.name);
    defer gpa.free(path);
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);

    const json = try std.json.Stringify.valueAlloc(gpa, state, .{ .whitespace = .indent_2 });
    defer gpa.free(json);

    const file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{
        .permissions = std.Io.File.Permissions.fromMode(@intCast(file_mode)),
    });
    errdefer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    defer file.close(io);
    try file.writeStreamingAll(io, json);

    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

/// Best-effort removal of a session's state file.
pub fn remove(gpa: std.mem.Allocator, io: std.Io, restore_dir: []const u8, name: []const u8) void {
    const path = statePath(gpa, restore_dir, name) catch return;
    defer gpa.free(path);
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

/// Loads every valid state file in restore_dir, sorted by session name.
/// Entries with an unknown schema version, a name mismatching the filename,
/// or unparseable content are skipped with a warning. A missing directory
/// yields an empty list. Caller deinits each element and the list.
pub fn loadAll(
    gpa: std.mem.Allocator,
    io: std.Io,
    restore_dir: []const u8,
) !std.ArrayList(std.json.Parsed(SessionState)) {
    var list: std.ArrayList(std.json.Parsed(SessionState)) = .empty;
    errdefer {
        for (list.items) |*p| p.deinit();
        list.deinit(gpa);
    }

    var dir = std.Io.Dir.openDirAbsolute(io, restore_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return list,
        else => return err,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const stem = entry.name[0 .. entry.name.len - ".json".len];
        if (stem.len == 0) continue;

        const contents = readFileAlloc(gpa, io, dir, entry.name) catch |err| {
            std.log.warn("skipping unreadable state file file={s} err={s}", .{ entry.name, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        const parsed = std.json.parseFromSlice(SessionState, gpa, contents, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.warn("skipping invalid state file file={s} err={s}", .{ entry.name, @errorName(err) });
            continue;
        };
        if (parsed.value.version != SCHEMA_VERSION) {
            std.log.warn("skipping state file with unknown version file={s} version={d}", .{ entry.name, parsed.value.version });
            parsed.deinit();
            continue;
        }
        if (!std.mem.eql(u8, parsed.value.name, stem)) {
            std.log.warn("skipping state file with mismatched name file={s} name={s}", .{ entry.name, parsed.value.name });
            parsed.deinit();
            continue;
        }
        try list.append(gpa, parsed);
    }

    std.mem.sort(std.json.Parsed(SessionState), list.items, {}, lessThanByName);
    return list;
}

fn lessThanByName(_: void, a: std.json.Parsed(SessionState), b: std.json.Parsed(SessionState)) bool {
    return std.mem.lessThan(u8, a.value.name, b.value.name);
}

const MAX_STATE_FILE_SIZE: u64 = 1024 * 1024;

fn readFileAlloc(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    const size = (try file.stat(io)).size;
    if (size > MAX_STATE_FILE_SIZE) return error.FileTooBig;

    const buf = try gpa.alloc(u8, @intCast(size));
    errdefer gpa.free(buf);

    var len: usize = 0;
    while (len < buf.len) {
        const n = try file.readStreaming(io, &.{buf[len..]});
        if (n == 0) break;
        len += n;
    }
    if (len != buf.len) return error.UnexpectedEndOfFile;
    return buf;
}

const testing_dir_mode: u32 = 0o750;
const testing_file_mode: u32 = 0o640;

fn testRestoreDir(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    const lib_posix = @import("posix.zig");
    const tmpdir = std.mem.trimEnd(u8, lib_posix.getenv("TMPDIR") orelse "/tmp", "/");
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const suffix = std.mem.readInt(u64, &random_bytes, .little);
    return std.fmt.allocPrint(alloc, "{s}/zmx-restore-test-{d}", .{ tmpdir, suffix });
}

fn cleanupTestDir(alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8) void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        names.append(alloc, alloc.dupe(u8, entry.name) catch return) catch return;
    }
    for (names.items) |n| dir.deleteFile(io, n) catch {};
    dir.close(io);
    std.Io.Dir.deleteDirAbsolute(io, dir_path) catch {};
}

test "save and loadAll round-trip" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const dir_path = try testRestoreDir(alloc, io);
    defer alloc.free(dir_path);
    defer cleanupTestDir(alloc, io, dir_path);

    try save(alloc, io, dir_path, testing_dir_mode, testing_file_mode, .{
        .name = "dev",
        .cwd = "/home/alex/proj",
        .cwd_uri = "file://host/home/alex/proj",
        .shell = "/bin/zsh",
        .cmd = "npm run dev",
        .argv = &.{ "npm", "run", "dev" },
        .captured_at = 1756700000,
    });
    try save(alloc, io, dir_path, testing_dir_mode, testing_file_mode, .{
        .name = "aux",
        .cwd = "/etc",
    });

    var loaded = try loadAll(alloc, io, dir_path);
    defer {
        for (loaded.items) |*p| p.deinit();
        loaded.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 2), loaded.items.len);
    try std.testing.expectEqualStrings("aux", loaded.items[0].value.name);
    try std.testing.expectEqualStrings("dev", loaded.items[1].value.name);
    try std.testing.expectEqualStrings("/home/alex/proj", loaded.items[1].value.cwd);
    try std.testing.expectEqualStrings("npm run dev", loaded.items[1].value.cmd.?);
    try std.testing.expectEqual(@as(usize, 3), loaded.items[1].value.argv.?.len);
    try std.testing.expectEqual(@as(u64, 1756700000), loaded.items[1].value.captured_at);
    try std.testing.expect(loaded.items[0].value.cmd == null);
}

test "save overwrites existing state atomically" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const dir_path = try testRestoreDir(alloc, io);
    defer alloc.free(dir_path);
    defer cleanupTestDir(alloc, io, dir_path);

    try save(alloc, io, dir_path, testing_dir_mode, testing_file_mode, .{ .name = "dev", .cwd = "/a" });
    try save(alloc, io, dir_path, testing_dir_mode, testing_file_mode, .{ .name = "dev", .cwd = "/b" });

    var loaded = try loadAll(alloc, io, dir_path);
    defer {
        for (loaded.items) |*p| p.deinit();
        loaded.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("/b", loaded.items[0].value.cwd);
}

test "loadAll skips tmp files, version mismatches and name mismatches" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const dir_path = try testRestoreDir(alloc, io);
    defer alloc.free(dir_path);
    defer cleanupTestDir(alloc, io, dir_path);

    try save(alloc, io, dir_path, testing_dir_mode, testing_file_mode, .{ .name = "keep" });

    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    const cases = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "stale.json.tmp", .content = "{\"version\":1,\"name\":\"stale\"}" },
        .{ .name = "future.json", .content = "{\"version\":999,\"name\":\"future\"}" },
        .{ .name = "liar.json", .content = "{\"version\":1,\"name\":\"other\"}" },
        .{ .name = "garbage.json", .content = "not json" },
    };
    for (cases) |case| {
        const f = try dir.createFile(io, case.name, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, case.content);
    }

    var loaded = try loadAll(alloc, io, dir_path);
    defer {
        for (loaded.items) |*p| p.deinit();
        loaded.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("keep", loaded.items[0].value.name);
}

test "loadAll on missing directory returns empty list" {
    const alloc = std.testing.allocator;
    var loaded = try loadAll(alloc, std.testing.io, "/nonexistent/zmx-restore-test");
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), loaded.items.len);
}

test "statePath rejects invalid names" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidSessionName, statePath(alloc, "/x", "a/b"));
    try std.testing.expectError(error.InvalidSessionName, statePath(alloc, "/x", ""));
    const ok = try statePath(alloc, "/x", "dev");
    defer alloc.free(ok);
    try std.testing.expectEqualStrings("/x/dev.json", ok);
}

test "remove deletes the state file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const dir_path = try testRestoreDir(alloc, io);
    defer alloc.free(dir_path);
    defer cleanupTestDir(alloc, io, dir_path);

    try save(alloc, io, dir_path, testing_dir_mode, testing_file_mode, .{ .name = "dev" });
    remove(alloc, io, dir_path, "dev");

    var loaded = try loadAll(alloc, io, dir_path);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), loaded.items.len);
}
