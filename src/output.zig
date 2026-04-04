const std = @import("std");
const zigcli = @import("zigcli");
const pretty_table = zigcli.pretty_table;

/// Whether stdout is a TTY (and should use ANSI colors).
pub fn useColor() bool {
    return std.posix.isatty(std.posix.STDOUT_FILENO);
}

/// Print a success message (green checkmark when color is enabled).
pub fn printSuccess(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    if (useColor()) {
        try w.interface.print("\x1b[32m✓\x1b[0m " ++ fmt ++ "\n", args);
    } else {
        try w.interface.print("✓ " ++ fmt ++ "\n", args);
    }
    try w.interface.flush();
}

/// Print an error message (red ✗ when color is enabled).
pub fn printError(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    if (useColor()) {
        try w.interface.print("\x1b[31m✗\x1b[0m " ++ fmt ++ "\n", args);
    } else {
        try w.interface.print("✗ " ++ fmt ++ "\n", args);
    }
    try w.interface.flush();
}

/// Print an info/status message (dim prefix when color is enabled).
pub fn printInfo(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    if (useColor()) {
        try w.interface.print("\x1b[2m▸\x1b[0m " ++ fmt ++ "\n", args);
    } else {
        try w.interface.print("▸ " ++ fmt ++ "\n", args);
    }
    try w.interface.flush();
}

/// Print a warning message (yellow ⚠ when color is enabled).
pub fn printWarn(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    if (useColor()) {
        try w.interface.print("\x1b[33m⚠\x1b[0m " ++ fmt ++ "\n", args);
    } else {
        try w.interface.print("⚠ " ++ fmt ++ "\n", args);
    }
    try w.interface.flush();
}

/// Print version info as a styled table.
pub fn printVersionTable(alloc: std.mem.Allocator, ver: []const u8, ghostty_ver: []const u8, socket_dir: []const u8, log_dir: []const u8) !void {
    const color = useColor();
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);

    var table = pretty_table.Table(2).Owned.init(.{
        .mode = .ascii,
        .padding = 1,
    });

    if (color) {
        table.setHeader(.{
            pretty_table.Cell.init("COMPONENT").withBold(),
            pretty_table.Cell.init("VALUE").withBold(),
        });
    } else {
        table.setHeader(.{ "COMPONENT", "VALUE" });
    }

    if (color) {
        try table.addRow(alloc, .{
            pretty_table.Cell.init("zmx").withBold(),
            pretty_table.Cell.init(ver),
        });
    } else {
        try table.addRow(alloc, .{ "zmx", ver });
    }
    try table.addRow(alloc, .{ "ghostty_vt", ghostty_ver });
    try table.addRow(alloc, .{ "socket_dir", socket_dir });
    try table.addRow(alloc, .{ "log_dir", log_dir });

    try table.format(&w.interface);
    try w.interface.flush();
}
