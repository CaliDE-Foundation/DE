//! cali-compositor: the Cali session process.
//! It links libsookie (our Mutter fork) and drives cali-shell through its C ABI.

const std = @import("std");
const build_options = @import("build_options");

const shell = @cImport({
    @cInclude("cali_shell.h");
});

pub fn main() !u8 {
    const stdout = std.io.getStdOut().writer();
    const version = std.mem.span(shell.cali_shell_version());
    try stdout.print("cali-compositor 0.1.0 (shell {s})\n", .{version});

    const s = shell.cali_shell_new() orelse return error.ShellInitFailed;
    defer shell.cali_shell_free(s);

    if (!shell.cali_shell_start(s)) {
        std.log.err("cali-shell failed to start", .{});
        return 1;
    }

    if (!build_options.with_sookie) {
        std.log.warn("built without Sookie (-Dsookie=false); no display server started", .{});
        return 0;
    }

    // TODO: meta_context_new("Cali"), register the Cali MetaPlugin,
    // meta_context_setup / start / run_main_loop.
    return 0;
}
