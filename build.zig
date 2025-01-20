const std = @import("std");

const Ast = std.zig.Ast;
const Compile = std.Build.Step.Compile;
const LazyPath = std.Build.LazyPath;
const mem = std.mem;

const manifest_filename = "build.zig.zon";
const manifest_max_size = 10 * 1024 * 1024;

pub const ArchiveStep = @import("build/ArchiveStep.zig");

pub fn archiveArtifact(
    b: *std.Build,
    artifact: *Compile,
    options: ArchiveStep.AddArtifactOptions,
) *ArchiveStep {
    const target = artifact.rootModuleTarget();

    var name = std.ArrayList(u8).init(b.allocator);
    const writer = name.writer();

    writer.print("{s}-{s}-{s}", .{
        artifact.name,
        @tagName(target.os.tag),
        @tagName(target.cpu.arch),
    }) catch @panic("OOM");

    if (artifact.version) |version| {
        writer.print("-{}", .{version}) catch @panic("OOM");
    }

    const archive = ArchiveStep.create(b, .{
        .name = name.items,
        .format = switch (target.os.tag) {
            .windows => .{ .zip = .{ .level = .best } },
            else => .{ .tar_gz = .{ .level = .best } },
        },
    });
    archive.addArtifact(artifact, options);
    return archive;
}

pub const ArchiveInstallOptions = struct {
    install_dir: std.Build.InstallDir = .prefix,
    install_step: ?*std.Build.Step = null,
    archive_layout: ArchiveStep.AddArtifactOptions = .{},
};

pub fn installArchivedArtifact(
    artifact: *Compile,
    options: ArchiveInstallOptions,
) void {
    const b = artifact.step.owner;
    const archive = archiveArtifact(b, artifact, options.archive_layout);
    const install = b.addInstallFileWithDir(
        archive.getEmittedArchive(),
        options.install_dir,
        archive.getArchiveFileName(),
    );
    const step = options.install_step orelse b.getInstallStep();
    step.dependOn(&install.step);
}

pub fn getBuildVersion(b: *std.Build) std.SemanticVersion {
    if (b.option([]const u8, "version", "Override the build version")) |text| {
        return std.SemanticVersion.parse(text) catch |err| {
            quit("Invalid version option: '{s}' is not a semantic version ({s})", .{ text, @errorName(err) });
        };
    }

    const manifest_version = getProjectVersion(b);
    const build_root = b.pathFromRoot(".");
    const ws = &std.ascii.whitespace;

    var code: u8 = undefined;
    const untrimmed = b.runAllowFail(
        &.{ "git", "-C", build_root, "describe", "--match", "*.*.*", "--tags" },
        &code,
        .Ignore,
    ) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        error.ExitCodeFailure => {
            const height = b.runAllowFail(
                &.{ "git", "-C", build_root, "rev-list", "--count", "HEAD" },
                &code,
                .Ignore,
            ) catch return std.SemanticVersion{ .major = 0, .minor = 0, .patch = 0 };
            const commit = b.runAllowFail(
                &.{ "git", "-C", build_root, "rev-parse", "--short", "HEAD" },
                &code,
                .Ignore,
            ) catch return std.SemanticVersion{ .major = 0, .minor = 0, .patch = 0 };
            return std.SemanticVersion{
                .major = manifest_version.major,
                .minor = manifest_version.minor,
                .patch = manifest_version.patch,
                .pre = b.fmt("dev.{s}", .{mem.trim(u8, height, ws)}),
                .build = mem.trim(u8, commit, ws),
            };
        },
        else => quit("'git describe' failed ({s})\n", .{@errorName(err)}),
    };

    const describe = mem.trim(u8, untrimmed, ws);
    switch (mem.count(u8, describe, "-")) {
        0 => {
            const tagged_version = std.SemanticVersion.parse(describe) catch unreachable;
            if (tagged_version.order(manifest_version) != .eq) {
                quit("Current tagged version ({}) must match the version in build.zig.zon ({})", .{ tagged_version, manifest_version });
            }
            return tagged_version;
        },
        2 => {
            var iter = mem.splitScalar(u8, describe, '-');
            const ancestor_text = iter.first();
            const height = iter.next().?;
            const commit = iter.next().?;

            const ancestor_version = std.SemanticVersion.parse(ancestor_text) catch unreachable;
            if (manifest_version.order(ancestor_version) != .gt) {
                quit("Last tagged version ({}) must be less than the version in build.zig.zon ({})", .{ ancestor_version, manifest_version });
            }

            return std.SemanticVersion{
                .major = manifest_version.major,
                .minor = manifest_version.minor,
                .patch = manifest_version.patch,
                .pre = b.fmt("dev.{s}", .{height}),
                .build = commit[1..],
            };
        },
        else => quit("Unexpected 'git describe' output: '{s}'", .{describe}),
    }
}

pub fn getMinimumZigVersion(b: *std.Build) std.SemanticVersion {
    const content = loadManifestFile(b);
    defer b.allocator.free(content);

    var ast = Ast.parse(b.allocator, content, .zon) catch @panic("OOM");
    defer ast.deinit(b.allocator);

    return getManifestVersionField(b, ast, "minimum_zig_version");
}

pub fn getProjectVersion(b: *std.Build) std.SemanticVersion {
    const content = loadManifestFile(b);
    defer b.allocator.free(content);

    var ast = Ast.parse(b.allocator, content, .zon) catch @panic("OOM");
    defer ast.deinit(b.allocator);

    return getManifestVersionField(b, ast, "version");
}

fn loadManifestFile(b: *std.Build) [:0]const u8 {
    var file = b.build_root.handle.openFile(manifest_filename, .{}) catch |err| {
        quit("Failed to open {s} ({s})", .{ manifest_filename, @errorName(err) });
    };
    defer file.close();

    return file.readToEndAllocOptions(
        b.allocator,
        manifest_max_size,
        null,
        @alignOf(u8),
        0,
    ) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        else => quit("Failed to read contents from {s} ({s})", .{ manifest_filename, @errorName(err) }),
    };
}

fn getManifestVersionField(b: *std.Build, ast: Ast, name: []const u8) std.SemanticVersion {
    const node_data = ast.nodes.items(.data);

    var buf: [2]Ast.Node.Index = undefined;
    const struct_init = ast.fullStructInit(&buf, node_data[0].lhs) orelse {
        quit("Malformed manifest file: top level must be a structure initialization", .{});
    };

    const node = for (struct_init.ast.fields) |field_init| {
        const name_token = ast.firstToken(field_init) - 2;
        const field_name = ast.tokenSlice(name_token);
        if (mem.eql(u8, field_name, name)) break field_init;
    } else {
        quit("Malformed manifest file: manifest must contain a '{s}' field", .{name});
    };

    const node_tags = ast.nodes.items(.tag);
    if (node_tags[node] != .string_literal) {
        quit("Malformed manifest file: '{s}' field must be a valid string literal", .{name});
    }

    const main_tokens = ast.nodes.items(.main_token);
    const token = main_tokens[node];
    const bytes = ast.tokenSlice(token);

    const string = std.zig.string_literal.parseAlloc(b.allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        else => quit("Malformed manifest file: '{s}' field must be a valid string literal", .{name}),
    };

    return std.SemanticVersion.parse(string) catch {
        quit("Malformed manifest file: '{s}' field must be a valid semantic version", .{name});
    };
}

fn quit(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format ++ "\n", args);
    std.process.exit(1);
}

pub fn build(_: *std.Build) void {}
