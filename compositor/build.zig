const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Built by `cargo build --release` at the repo root (see Makefile).
    const shell_lib = b.option(
        []const u8,
        "shell-lib",
        "Path to libcali_shell.a",
    ) orelse "../target/release/libcali_shell.a";

    // Turn on once libsookie is installed (make sookie).
    const with_sookie = b.option(bool, "sookie", "Link against libsookie") orelse false;

    const exe = b.addExecutable(.{
        .name = "cali-compositor",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const opts = b.addOptions();
    opts.addOption(bool, "with_sookie", with_sookie);
    exe.root_module.addOptions("build_options", opts);

    exe.linkLibC();
    exe.addIncludePath(b.path("../shell/include"));
    exe.addObjectFile(.{ .cwd_relative = shell_lib });
    // Runtime dependencies of a Rust staticlib.
    exe.linkSystemLibrary("pthread");
    exe.linkSystemLibrary("dl");
    exe.linkSystemLibrary("m");
    exe.linkSystemLibrary("gcc_s"); // unwinder used by Rust std

    if (with_sookie) {
        // Sookie still installs under Mutter's library name for now.
        exe.linkSystemLibrary("libmutter-52");
    }

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run cali-compositor").dependOn(&run.step);
}
