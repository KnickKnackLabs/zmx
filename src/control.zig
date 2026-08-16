const std = @import("std");
const Cfg = @import("cfg.zig");
const loop = @import("loop.zig");
const socket = @import("socket.zig");

pub const frame = @import("control/frame.zig");
pub const adapter = @import("control/adapter.zig");
pub const daemon = @import("control/daemon.zig");
pub const client = @import("control/client.zig");

pub const protocol = "zmx-control/v1";

pub const Args = struct {
    protocol_name: []const u8 = protocol,
    session_name: ?[]const u8 = null,
    command_args: []const []const u8 = &.{},
    help: bool = false,
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
        if (parsed.session_name != null) {
            parsed.command_args = args[i..];
            break;
        }

        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            parsed.help = true;
        } else if (std.mem.eql(u8, arg, "--probe")) {
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
        } else {
            parsed.session_name = arg;
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

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *Cfg,
    shell: []const u8,
    args: Args,
) !void {
    const session_name = args.session_name orelse return error.SessionNameRequired;
    const sesh = try socket.getSeshName(gpa, session_name);
    defer gpa.free(sesh);

    const socket_path = socket.getSocketPath(gpa, cfg.socket_dir, sesh) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(io, sesh, cfg.socket_dir),
        error.OutOfMemory => return err,
    };

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
    const command: ?[]const []const u8 = if (args.command_args.len > 0) args.command_args else null;

    var session = loop.Daemon.init(io, cfg, sesh, socket_path);
    session.command = command;
    session.start_child_on_control = command != null;
    session.setCwd(cwd_buf[0..cwd_len]);
    session.shell = shell;

    const ensured = try session.ensureSessionResult(io, false);
    if (ensured.is_daemon) return;

    // ensureSession may fork. Use the libc allocator for all client-side state
    // created after that boundary, matching the terminal client loop.
    const layout = try client.detectLayout(std.heap.c_allocator, socket_path);
    const client_fd = try socket.sessionConnect(socket_path);
    std.log.info("control attached session={s} protocol={s}", .{ sesh, args.protocol_name });
    try client.run(client_fd, layout, .{
        .rows = args.rows,
        .cols = args.cols,
        .drain_after_stdin_eof = ensured.created and command != null,
    });
}

test "control args preserve protocol, size, and command" {
    const parsed = try parseArgs(&.{ "--protocol", "v1", "--rows", "40", "--cols=120", "dev", "nvim", "--clean" });
    try std.testing.expectEqualStrings(protocol, parsed.protocol_name);
    try std.testing.expectEqual(@as(?u16, 40), parsed.rows);
    try std.testing.expectEqual(@as(?u16, 120), parsed.cols);
    try std.testing.expectEqualStrings("dev", parsed.session_name.?);
    try std.testing.expectEqualSlices([]const u8, &.{ "nvim", "--clean" }, parsed.command_args);
}

test "control args preserve command options after the session name" {
    const parsed = try parseArgs(&.{ "dev", "tool", "--help", "--rows=5" });
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "tool", "--help", "--rows=5" },
        parsed.command_args,
    );
    try std.testing.expect(!parsed.help);
    try std.testing.expectEqual(@as(?u16, null), parsed.rows);
}

test "control args recognize help and reject unsupported values" {
    try std.testing.expect((try parseArgs(&.{"--help"})).help);
    try std.testing.expectError(error.UnsupportedControlProtocol, parseArgs(&.{ "--protocol", "v2", "dev" }));
    try std.testing.expectError(error.ControlSizeOutOfRange, parseArgs(&.{ "--rows=0", "dev" }));
}

test "control probe advertises the stable contract" {
    const text = probeText();
    try std.testing.expect(std.mem.indexOf(u8, text, "protocol=zmx-control/v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tier=control\n") != null);
}
