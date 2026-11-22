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

    // Link and start Sookie. Needs libsookie-52 (see `make compositor-sookie`).
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
        // Found through pkg-config (libsookie-52.pc). Run `make sookie-fetch`
        // to get a prebuilt Sookie, or install one system-wide.
        exe.linkSystemLibrary2("libsookie-52", .{ .use_pkg_config = .force });
    }

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run cali-compositor").dependOn(&run.step);
}
