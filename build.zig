const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pcre_pkg = b.dependency("libpcre_zig", .{ .optimize = optimize, .target = target });
    const chrono_pkg = b.dependency("chrono", .{ .optimize = optimize, .target = target });
    const koino_pkg = b.dependency("koino", .{ .optimize = optimize, .target = target });
    const uuid_pkg = b.dependency("zig_uuid", .{ .optimize = optimize, .target = target });

    const Mod = struct { name: []const u8, mod: *std.Build.Module };

    const mod_deps = &[_]Mod{
        .{ .name = "libpcre", .mod = pcre_pkg.module("libpcre") },
        .{ .name = "chrono", .mod = chrono_pkg.module("chrono") },
        .{ .name = "koino", .mod = koino_pkg.module("koino") },
        .{ .name = "uuid", .mod = uuid_pkg.module("uuid") },
    };

    const exe = b.addExecutable(.{
        .name = "obsidian2web",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    for (mod_deps) |dep| {
        exe.root_module.addImport(dep.name, dep.mod);
    }

    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    for (mod_deps) |dep| {
        unit_tests.root_module.addImport(dep.name, dep.mod);
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
