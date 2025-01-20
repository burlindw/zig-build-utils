const std = @import("std");

const fs = std.fs;
const mem = std.mem;
const gzip = std.compress.gzip;
const flate = std.compress.flate;

const ArchiveStep = @This();
const Build = std.Build;
const Step = Build.Step;
const LazyPath = Build.LazyPath;
const GeneratedFile = Build.GeneratedFile;

const initTarBuilder = @import("tar_builder.zig").initTarBuilder;
const initZipBuilder = @import("zip_builder.zig").initZipBuilder;

step: Step,

name: []const u8,
format: Format,

input_files: std.ArrayListUnmanaged(File),
input_artifacts: std.ArrayListUnmanaged(Artifact),

generated_archive: GeneratedFile,

pub const base_id: Step.Id = .custom;

pub const Format = union(enum) {
    tar_gz: gzip.Options,
    zip: flate.Options,

    pub fn extension(self: Format) []const u8 {
        return switch (self) {
            .tar_gz => ".tar.gz",
            .zip => ".zip",
        };
    }
};

pub const File = struct {
    subdir: []const u8,
    source: LazyPath,

    fn addToManifest(self: File, manifest: *Build.Cache.Manifest, step: *Step) !void {
        const path = self.source.getPath3(step.owner, step);
        manifest.hash.addBytes(self.subdir);
        _ = try manifest.addFilePath(path, null);
        try step.addWatchInput(self.source);
    }

    fn addToArchive(self: File, builder: anytype, step: *Step) !void {
        const alloc = step.owner.allocator;
        const source = self.source.getPath3(step.owner, step);

        const file = try source.root_dir.handle.openFile(source.sub_path, .{});
        defer file.close();

        const name = fs.path.basename(source.sub_path);
        const subpath = try fs.path.join(alloc, &.{ self.subdir, name });

        try builder.writeFile(subpath, file);
    }
};

pub const Artifact = struct {
    artifact: *Step.Compile,

    bin: ?File,
    pdb: ?File,
    implib: ?File,
    header: ?File,
};

pub const CreateOptions = struct {
    name: []const u8,
    format: Format = .{ .tar_gz = .{ .level = .best } },
};

pub fn create(owner: *Build, options: CreateOptions) *ArchiveStep {
    const self = owner.allocator.create(ArchiveStep) catch @panic("OOM");
    self.* = .{
        .step = Step.init(.{
            .id = base_id,
            .name = owner.fmt("archive {s}", .{options.name}),
            .owner = owner,
            .makeFn = make,
        }),
        .name = options.name,
        .format = options.format,
        .input_files = .{},
        .input_artifacts = .{},
        .generated_archive = .{ .step = &self.step },
    };
    return self;
}

pub const AddFileOptions = struct {
    /// Place the item in a subdirectory of the archive.
    subdir: []const u8 = "",
};

pub fn addFile(self: *ArchiveStep, source: LazyPath, options: AddFileOptions) void {
    const b = self.step.owner;
    const alloc = b.allocator;

    self.input_files.append(alloc, File{
        .subdir = options.subdir,
        .source = source,
    }) catch @panic("OOM");

    source.addStepDependencies(&self.step);
}

pub const AddArtifactOptions = struct {
    bin_dir: Directory = .default,
    pdb_dir: Directory = .default,
    header_dir: Directory = .default,
    implib_dir: Directory = .default,

    pub const Directory = union(enum) {
        disabled,
        default,
        override: []const u8,
    };
};

pub fn addArtifact(self: *ArchiveStep, artifact: *Step.Compile, options: AddArtifactOptions) void {
    const b = self.step.owner;
    const alloc = b.allocator;

    self.input_artifacts.append(alloc, Artifact{
        .artifact = artifact,
        .bin = switch (options.bin_dir) {
            .disabled => null,
            .default => File{
                .subdir = switch (artifact.kind) {
                    .obj => "obj",
                    .exe, .@"test" => "bin",
                    .lib => if (artifact.isDll()) "bin" else "lib",
                },
                .source = artifact.getEmittedBin(),
            },
            .override => |override| File{
                .subdir = override,
                .source = artifact.getEmittedBin(),
            },
        },
        .pdb = switch (options.pdb_dir) {
            .disabled => null,
            .default => if (artifact.producesPdbFile()) File{
                .subdir = "bin",
                .source = artifact.getEmittedPdb(),
            } else null,
            .override => |override| File{
                .subdir = override,
                .source = artifact.getEmittedPdb(),
            },
        },
        .implib = switch (options.implib_dir) {
            .disabled => null,
            .default => if (artifact.producesImplib()) File{
                .subdir = "lib",
                .source = artifact.getEmittedImplib(),
            } else null,
            .override => |override| File{
                .subdir = override,
                .source = artifact.getEmittedImplib(),
            },
        },
        .header = switch (options.header_dir) {
            .disabled => null,
            .default => if (artifact.kind == .lib) File{
                .subdir = "include",
                .source = artifact.getEmittedH(),
            } else null,
            .override => |override| File{
                .subdir = override,
                .source = artifact.getEmittedH(),
            },
        },
    }) catch @panic("OOM");

    self.step.dependOn(&artifact.step);
}

pub fn getEmittedArchive(self: *ArchiveStep) LazyPath {
    return LazyPath{ .generated = .{ .file = &self.generated_archive } };
}

pub fn getArchiveFileName(self: *ArchiveStep) []const u8 {
    const b = self.step.owner;
    return b.fmt("{s}{s}", .{ self.name, self.format.extension() });
}

fn make(step: *Step, _: Step.MakeOptions) !void {
    const b = step.owner;
    const alloc = b.allocator;
    const self: *ArchiveStep = @fieldParentPtr("step", step);
    step.clearWatchInputs();

    // Generate the cache manifest for this step. This allows us to potentially
    // skip this step if the result is cached and the inputs haven't been updated.
    var manifest = b.graph.cache.obtain();
    defer manifest.deinit();

    for (self.input_files.items) |file| {
        try file.addToManifest(&manifest, step);
    }

    for (self.input_artifacts.items) |item| {
        if (item.bin) |bin| try bin.addToManifest(&manifest, step);
        if (item.pdb) |pdb| try pdb.addToManifest(&manifest, step);
        if (item.implib) |implib| try implib.addToManifest(&manifest, step);
        if (item.header) |header| try header.addToManifest(&manifest, step);
    }

    // step.cacheHit() needs to be called BEFORE manifest.final() to ensure that
    // the manifest file actually exists, but we still need to set the generated
    // archive's path, regardless of whether there is a cache hit or not.
    const cache_hit = try step.cacheHit(&manifest);

    const fullname = self.getArchiveFileName();
    const cache_path = "o" ++ std.fs.path.sep_str ++ manifest.final();
    self.generated_archive.path = try b.cache_root.join(alloc, &.{ cache_path, fullname });

    if (cache_hit) return;

    // Create the actual entry in the cache and write the archive to it.
    var cache_dir = try b.cache_root.handle.makeOpenPath(cache_path, .{});
    defer cache_dir.close();

    const archive_file = try cache_dir.createFile(fullname, .{});
    defer archive_file.close();

    var buffer = std.io.bufferedWriter(archive_file.writer());

    switch (self.format) {
        .tar_gz => |options| {
            var compressor = try gzip.compressor(buffer.writer(), options);
            var builder = initTarBuilder(b.allocator, compressor.writer().any());
            defer builder.deinit();

            try builder.setRoot(self.name);
            try self.addInputsToArchive(&builder);
            try compressor.finish();
        },
        .zip => |options| {
            var builder = initZipBuilder(b.allocator, buffer.writer(), options);
            defer builder.deinit();

            try builder.setRoot(self.name);
            try self.addInputsToArchive(&builder);
            try builder.finish();
        },
    }

    try buffer.flush();
    try step.writeManifest(&manifest);
}

fn addInputsToArchive(self: *ArchiveStep, builder: anytype) !void {
    for (self.input_files.items) |item| {
        try item.addToArchive(builder, &self.step);
    }

    for (self.input_artifacts.items) |item| {
        if (item.bin) |bin| try bin.addToArchive(builder, &self.step);
        if (item.pdb) |pdb| try pdb.addToArchive(builder, &self.step);
        if (item.implib) |implib| try implib.addToArchive(builder, &self.step);
        if (item.header) |header| try header.addToArchive(builder, &self.step);
    }
}
