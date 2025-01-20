# zig-build-utils

A collection of common utilities for Zig build scripts inspired by the build
scripts used by [Zig](https://github.com/ziglang/zig) and [ZLS](https://github.com/zigtools/zls).

## How to use

Run the following command from a project's root to add `zig-build-utils` as
as dependency:

```sh
zig fetch --save git+https://github.com/burlindw/zig-build-utils.git
```

Import `build-utils` in `build.zig`. It is not necessary to call `std.Build.dependency()`
as there are no exported modules or artifacts.

```zig
const std = @import("std");
const utils = @import("build-utils");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the project version using a combination of the 'build.zig.zon'
    // manifest file, the git history, and git tags.
    const version = utils.getBuildVersion(b);

    const exe = b.addExecutable(.{
        .name = "example",
        .target = target,
        .optimize = optimize,
        .version = version,
        .root_source_file = b.path("src/main.zig"),
    });
    b.installArtifact(exe);

    // Compress the binary (and any associated pdb, h, or lib files) into
    // a zip file or tarball (depending on the target) and install it in the
    // prefix directory. The subdirectory within the prefix directory and
    // the layout within the archive are both configurable.
    utils.installArchivedArtifact(exe, .{});
}
```




