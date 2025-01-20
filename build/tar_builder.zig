const std = @import("std");

const io = std.io;
const fs = std.fs;
const tar = std.tar;
const time = std.time;

const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const File = fs.File;

pub fn initTarBuilder(gpa: Allocator, writer: anytype) TarBuilder(@TypeOf(writer)) {
    return TarBuilder(@TypeOf(writer)).init(gpa, writer);
}

/// Wrap the standard library's .tar writer with utilities to automatically
/// insert directory records for files with paths.
pub fn TarBuilder(comptime InnerWriter: type) type {
    return struct {
        const Self = @This();
        const InnerBuilder = @TypeOf(tar.writer(@as(InnerWriter, undefined)));

        inner: InnerBuilder,
        dirs: std.StringHashMap(void),
        strs: ArenaAllocator,

        pub fn init(gpa: Allocator, writer: InnerWriter) Self {
            return Self{
                .inner = tar.writer(writer),
                .dirs = std.StringHashMap(void).init(gpa),
                .strs = ArenaAllocator.init(gpa),
            };
        }

        pub fn deinit(self: *Self) void {
            self.dirs.deinit();
            self.strs.deinit();
        }

        pub fn writeFile(self: *Self, sub_path: []const u8, file: File) !void {
            const arena = self.strs.allocator();
            const path = try arena.dupe(u8, sub_path);

            try self.writePath(fs.path.dirname(path));

            var buffer = io.bufferedReader(file.reader());
            const stat = try file.stat();
            try self.inner.writeFileStream(path, stat.size, buffer.reader(), .{
                .mode = @intCast(stat.mode),
                .mtime = @intCast(@divFloor(stat.mtime, time.ns_per_s)),
            });
        }

        pub fn setRoot(self: *Self, root: []const u8) !void {
            try self.inner.setRoot(root);
        }

        fn writePath(self: *Self, sub_path: ?[]const u8) !void {
            const path = sub_path orelse return;
            const slot = try self.dirs.getOrPut(path);
            if (!slot.found_existing) {
                try self.writePath(fs.path.dirname(path));
                try self.inner.writeDir(path, .{});
            }
        }
    };
}
