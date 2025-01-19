const std = @import("std");

const Ast = std.zig.Ast;
const mem = std.mem;

const manifest_filename = "build.zig.zon";
const manifest_max_size = 10 * 1024 * 1024;

pub fn packageReleaseBinaries(b: *std.Build, compile_steps: []*std.Build.Step.Compile) void {
    const release_step = b.step("release", "Build and compress release binaries");

    for (compile_steps) |binary| {
        const target = binary.rootModuleTarget();
        const is_windows = target.os.tag == .windows;
        const version = binary.version.?;

        const binary_name = switch (binary.kind) {
            .exe => b.fmt("{s}{s}", .{ binary.name, target.exeFileExt() }),
            .lib => switch (binary.linkage.?) {
                .static => b.fmt("{s}{s}{s}", .{ target.libPrefix(), binary.name, target.staticLibSuffix() }),
                .dynamic => b.fmt("{s}{s}{s}", .{ target.libPrefix(), binary.name, target.dynamicLibSuffix() }),
            },
            else => quit("Binaries of type '{s}' are unsupported", .{@tagName(binary.kind)}),
        };

        const artifact_name = b.fmt("{s}-{s}-{s}-{}.{s}", .{
            binary.name,
            @tagName(target.os.tag),
            @tagName(target.cpu.arch),
            version,
            if (is_windows) "zip" else "tar.gz",
        });

        const cmd = std.Build.Step.Run.create(b, artifact_name);
        var output: std.Build.LazyPath = undefined;

        if (is_windows) {
            cmd.addArgs(&.{ "7z", "a" });
            output = cmd.addOutputFileArg(artifact_name);
            cmd.addArtifactArg(binary);
            cmd.addFileArg(binary.getEmittedPdb());
        } else {
            cmd.addArgs(&.{ "tar", "caf" });
            output = cmd.addOutputFileArg(artifact_name);
            cmd.addPrefixedDirectoryArg("-C", binary.getEmittedBinDirectory());
            cmd.addArg(binary_name);
        }

        const install = b.addInstallFileWithDir(output, .{ .custom = "release" }, artifact_name);
        release_step.dependOn(&install.step);
    }
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
