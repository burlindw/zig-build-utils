const std = @import("std");

const compress = std.compress;
const epoch = time.epoch;
const flate = compress.flate;
const fs = std.fs;
const hash = std.hash;
const io = std.io;
const math = std.math;
const mem = std.mem;
const time = std.time;
const zip = std.zip;

const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const CentralDirectoryFileHeader = zip.CentralDirectoryFileHeader;
const Crc32 = hash.Crc32;
const EndLocator64 = zip.EndLocator64;
const EndRecord = zip.EndRecord;
const EndRecord64 = zip.EndRecord64;
const File = fs.File;
const LocalFileHeader = zip.LocalFileHeader;

pub fn initZipBuilder(gpa: Allocator, writer: anytype, options: flate.Options) ZipBuilder(@TypeOf(writer)) {
    return ZipBuilder(@TypeOf(writer)).init(gpa, writer, options);
}

pub fn ZipBuilder(comptime InnerWriter: type) type {
    return struct {
        const Self = @This();
        const CountingWriter = io.CountingWriter(InnerWriter);

        const Entry = struct {
            filename: []const u8,
            original_size: u64,
            compress_size: u64,
            offset: u64,
            mtime: u64,
            crc32: u32,
        };

        gpa: Allocator,
        strs: ArenaAllocator,
        options: flate.Options,
        inner: CountingWriter,
        entries: std.ArrayList(Entry),
        root: []const u8,

        pub fn init(gpa: Allocator, writer: InnerWriter, options: flate.Options) Self {
            return Self{
                .gpa = gpa,
                .strs = ArenaAllocator.init(gpa),
                .options = options,
                .inner = io.countingWriter(writer),
                .entries = std.ArrayList(Entry).init(gpa),
                .root = "",
            };
        }

        pub fn deinit(self: *Self) void {
            self.strs.deinit();
            self.entries.deinit();
        }

        pub fn finish(self: *Self) !void {
            const writer = self.inner.writer();
            const cd_start = self.inner.bytes_written;
            const total_entries = self.entries.items.len;

            for (self.entries.items) |entry| {
                const dostime: u16 = @bitCast(DosTime.init(entry.mtime));
                const dosdate: u16 = @bitCast(DosDate.init(entry.mtime));

                var extra_buffer: [32]u8 = undefined;
                const extra = extraField(
                    entry.original_size,
                    entry.compress_size,
                    entry.offset,
                    &extra_buffer,
                );

                try writer.writeStructEndian(CentralDirectoryFileHeader{
                    .signature = zip.central_file_header_sig,
                    .version_made_by = 45,
                    .version_needed_to_extract = 45,
                    .flags = @bitCast(@as(u16, 0)),
                    .compression_method = .deflate,
                    .last_modification_time = dostime,
                    .last_modification_date = dosdate,
                    .crc32 = entry.crc32,
                    .compressed_size = saturate(u32, entry.compress_size),
                    .uncompressed_size = saturate(u32, entry.original_size),
                    .filename_len = @intCast(entry.filename.len),
                    .extra_len = @intCast(extra.len),
                    .comment_len = 0,
                    .disk_number = 0,
                    .internal_file_attributes = 0,
                    .external_file_attributes = 0,
                    .local_file_header_offset = saturate(u32, entry.offset),
                }, .little);
                try writer.writeAll(entry.filename);
                try writer.writeAll(extra);
            }

            const cd_end = self.inner.bytes_written;
            const cd_size = cd_end - cd_start;

            const er = EndRecord{
                .signature = zip.end_record_sig,
                .disk_number = 0,
                .central_directory_disk_number = 0,
                .record_count_disk = saturate(u16, total_entries),
                .record_count_total = saturate(u16, total_entries),
                .central_directory_size = saturate(u32, cd_size),
                .central_directory_offset = saturate(u32, cd_start),
                .comment_len = 0,
            };

            if (er.record_count_disk == math.maxInt(u16) or
                er.central_directory_size == math.maxInt(u32) or
                er.central_directory_offset == math.maxInt(u32))
            {
                try writer.writeStructEndian(EndRecord64{
                    .signature = zip.end_record64_sig,
                    .end_record_size = @sizeOf(EndRecord64) - 12,
                    .version_made_by = 45,
                    .version_needed_to_extract = 45,
                    .disk_number = 0,
                    .central_directory_disk_number = 0,
                    .record_count_disk = total_entries,
                    .record_count_total = total_entries,
                    .central_directory_size = cd_size,
                    .central_directory_offset = cd_start,
                }, .little);

                try writer.writeStructEndian(EndLocator64{
                    .signature = zip.end_locator64_sig,
                    .zip64_disk_count = 0,
                    .record_file_offset = cd_end,
                    .total_disk_count = 1,
                }, .little);
            }

            try writer.writeStructEndian(er, .little);
        }

        pub fn writeFile(self: *Self, sub_path: []const u8, file: File) !void {
            const arena = self.strs.allocator();
            const filename = try fs.path.join(arena, &.{ self.root, sub_path });
            if (filename.len > math.maxInt(u16)) return error.NameTooLong;

            const stat = try file.stat();
            const mtime = math.cast(u64, @divFloor(stat.mtime, time.ns_per_s)) orelse
                return error.Overflow;

            const dostime: u16 = @bitCast(DosTime.init(mtime));
            const dosdate: u16 = @bitCast(DosDate.init(mtime));

            var hasher = Crc32.init();
            var buffer_reader = io.bufferedReader(file.reader());
            var hashed_reader = compress.hashedReader(buffer_reader.reader(), &hasher);

            var content = std.ArrayList(u8).init(self.gpa);
            defer content.deinit();
            try flate.compress(hashed_reader.reader(), content.writer(), self.options);

            try self.entries.append(Entry{
                .filename = filename,
                .original_size = stat.size,
                .compress_size = content.items.len,
                .offset = self.inner.bytes_written,
                .mtime = mtime,
                .crc32 = hasher.final(),
            });

            var extra_buffer: [32]u8 = undefined;
            const extra = extraField(stat.size, content.items.len, 0, &extra_buffer);

            const writer = self.inner.writer();
            try writer.writeStructEndian(LocalFileHeader{
                .signature = zip.local_file_header_sig,
                .version_needed_to_extract = 45,
                .flags = @bitCast(@as(u16, 0)),
                .compression_method = .deflate,
                .last_modification_time = dostime,
                .last_modification_date = dosdate,
                .crc32 = hasher.final(),
                .compressed_size = saturate(u32, content.items.len),
                .uncompressed_size = saturate(u32, stat.size),
                .filename_len = @intCast(filename.len),
                .extra_len = @intCast(extra.len),
            }, .little);
            try writer.writeAll(filename);
            try writer.writeAll(extra);
            try writer.writeAll(content.items);
        }

        pub fn setRoot(self: *Self, root: []const u8) !void {
            const arena = self.strs.allocator();
            self.root = try arena.dupe(u8, root);
        }
    };
}

fn saturate(comptime T: type, value: anytype) T {
    return @intCast(@min(math.maxInt(T), value));
}

fn extraField(original_size: u64, compress_size: u64, offset: u64, buffer: *[32]u8) []u8 {
    var length: u16 = 0;
    if (original_size > math.maxInt(u32)) length += @sizeOf(u64);
    if (compress_size > math.maxInt(u32)) length += @sizeOf(u64);
    if (offset > math.maxInt(u32)) length += @sizeOf(u64);

    if (length == 0) return &.{};

    var fbs = io.fixedBufferStream(buffer);
    const writer = fbs.writer();

    writer.writeInt(u16, 0x0001, .little) catch unreachable;
    writer.writeInt(u16, length, .little) catch unreachable;

    if (original_size > math.maxInt(u32)) {
        writer.writeInt(u64, original_size, .little) catch unreachable;
    }
    if (compress_size > math.maxInt(u32)) {
        writer.writeInt(u64, compress_size, .little) catch unreachable;
    }
    if (offset > math.maxInt(u32)) {
        writer.writeInt(u64, offset, .little) catch unreachable;
    }
    return fbs.getWritten();
}

const DosDate = packed struct(u16) {
    day: u5,
    month: u4,
    year: u7,

    fn init(ts: u64) DosDate {
        const es = epoch.EpochSeconds{ .secs = ts };
        const ed = es.getEpochDay();
        const yd = ed.calculateYearDay();
        const md = yd.calculateMonthDay();
        return DosDate{
            .day = md.day_index,
            .month = @intFromEnum(md.month),
            .year = @intCast(yd.year - 1980),
        };
    }
};

const DosTime = packed struct(u16) {
    second: u5,
    minute: u6,
    hour: u5,

    fn init(ts: u64) DosTime {
        const es = epoch.EpochSeconds{ .secs = ts };
        const ds = es.getDaySeconds();
        return DosTime{
            .second = @intCast(ds.getSecondsIntoMinute() / 2),
            .minute = ds.getMinutesIntoHour(),
            .hour = ds.getHoursIntoDay(),
        };
    }
};
