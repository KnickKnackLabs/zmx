const std = @import("std");

pub const frame = @import("control/frame.zig");
pub const daemon = @import("control/daemon.zig");

pub const protocol = "zmx-control/v1";

pub const Args = struct {
    protocol_name: []const u8 = protocol,
    session_name: ?[]const u8 = null,
    command_args: []const []const u8 = &.{},
    probe: bool = false,
    rows: ?u16 = null,
    cols: ?u16 = null,
};

fn canonicalProtocol(value: []const u8) ![]const u8 {
    if (std.mem.eql(u8, value, "v1") or std.mem.eql(u8, value, protocol)) {
        return protocol;
    }
    return error.UnsupportedControlProtocol;
}

fn positiveSize(value: u16) !u16 {
    if (value == 0) return error.ControlSizeOutOfRange;
    return value;
}

pub fn parseArgs(args: []const []const u8) !Args {
    var parsed = Args{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--probe")) {
            parsed.probe = true;
        } else if (std.mem.eql(u8, arg, "--protocol")) {
            i += 1;
            if (i >= args.len) return error.ControlProtocolRequired;
            parsed.protocol_name = try canonicalProtocol(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--protocol=")) {
            parsed.protocol_name = try canonicalProtocol(arg["--protocol=".len..]);
        } else if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i >= args.len) return error.ControlRowsRequired;
            parsed.rows = try positiveSize(try std.fmt.parseInt(u16, args[i], 10));
        } else if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= args.len) return error.ControlColsRequired;
            parsed.cols = try positiveSize(try std.fmt.parseInt(u16, args[i], 10));
        } else if (std.mem.startsWith(u8, arg, "--rows=")) {
            parsed.rows = try positiveSize(try std.fmt.parseInt(u16, arg["--rows=".len..], 10));
        } else if (std.mem.startsWith(u8, arg, "--cols=")) {
            parsed.cols = try positiveSize(try std.fmt.parseInt(u16, arg["--cols=".len..], 10));
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownControlOption;
        } else if (parsed.session_name == null) {
            parsed.session_name = arg;
        } else {
            parsed.command_args = args[i..];
            break;
        }
    }
    return parsed;
}

pub fn probeText() []const u8 {
    return "protocol=" ++ protocol ++ "\n" ++
        "tier=control\n" ++
        "features=viewport_snapshot.v1,live_output.v1,priority_input.v1,adapter_sequence.v1,history_chunks.v1,latest_viewport_coalesce.v1\n";
}

pub fn printProbe(io: std.Io) !void {
    var buf: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    try writer.interface.writeAll(probeText());
    try writer.interface.flush();
}

test "control args preserve protocol, size, and command" {
    const parsed = try parseArgs(&.{ "--protocol", "v1", "--rows", "40", "--cols=120", "dev", "nvim", "--clean" });
    try std.testing.expectEqualStrings(protocol, parsed.protocol_name);
    try std.testing.expectEqual(@as(?u16, 40), parsed.rows);
    try std.testing.expectEqual(@as(?u16, 120), parsed.cols);
    try std.testing.expectEqualStrings("dev", parsed.session_name.?);
    try std.testing.expectEqualSlices([]const u8, &.{ "nvim", "--clean" }, parsed.command_args);
}

test "control args reject unsupported protocols and zero sizes" {
    try std.testing.expectError(error.UnsupportedControlProtocol, parseArgs(&.{ "--protocol", "v2", "dev" }));
    try std.testing.expectError(error.ControlSizeOutOfRange, parseArgs(&.{ "--rows=0", "dev" }));
}

test "control probe advertises the stable contract" {
    const text = probeText();
    try std.testing.expect(std.mem.indexOf(u8, text, "protocol=zmx-control/v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tier=control\n") != null);
}
