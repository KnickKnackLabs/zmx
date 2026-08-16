const std = @import("std");
const adapter = @import("adapter.zig");
const frame = @import("frame.zig");
const ipc = @import("../ipc.zig");
const posix = @import("../posix.zig");

const layout_probe_timeout_ms = 1000;
const ready_timeout_ms = 1000;
const eof_drain_ms = 250;

pub const Options = struct {
    rows: ?u16 = null,
    cols: ?u16 = null,
    drain_after_stdin_eof: bool = false,
};

/// LabelGet was introduced before tag 18 became Send. Known current daemons
/// therefore answer LabelData before the following Info response, while the
/// legacy KKL control layout ignores numeric tag 14 and answers only Info.
fn classifyLayoutProbe(tag: ipc.Tag) ?adapter.InternalLayout {
    return switch (tag) {
        .LabelData => .current,
        .Info => .legacy_kkl,
        else => null,
    };
}

pub fn detectLayout(alloc: std.mem.Allocator, socket_path: []const u8) !adapter.InternalLayout {
    const fd = try ipc.connectSession(socket_path);
    defer posix.close(fd);

    // Ordering is the capability proof: do not reverse these requests or infer
    // a legacy layout from timeout alone. Legacy init 18 is current Send.
    try ipc.send(fd, .LabelGet, "");
    try ipc.send(fd, .Info, "");

    var incoming = try ipc.SocketBuffer.init(alloc);
    defer incoming.deinit();

    while (true) {
        var poll_fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = try posix.poll(&poll_fds, layout_probe_timeout_ms);
        if (ready == 0) return error.ControlLayoutProbeTimeout;

        const n = try incoming.read(fd);
        if (n == 0) return error.ControlLayoutProbeClosed;
        while (incoming.next()) |message| {
            if (classifyLayoutProbe(message.header.tag)) |layout| return layout;
        }
    }
}

fn setNonBlocking(fd: i32) !usize {
    const original = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, original | posix.O_NONBLOCK);
    return original;
}

fn consumePrefix(alloc: std.mem.Allocator, bytes: *std.ArrayList(u8), len: usize) !void {
    if (len > bytes.items.len) return error.InvalidControlBuffer;
    try bytes.replaceRange(alloc, 0, len, &.{});
}

fn flushOutput(alloc: std.mem.Allocator, bytes: *std.ArrayList(u8)) !void {
    while (bytes.items.len > 0) {
        const n = posix.write(posix.STDOUT_FILENO, bytes.items) catch |err| {
            if (err != error.WouldBlock) return err;
            var poll_fds = [_]posix.pollfd{.{
                .fd = posix.STDOUT_FILENO,
                .events = posix.POLL.OUT,
                .revents = 0,
            }};
            _ = try posix.poll(&poll_fds, -1);
            continue;
        };
        if (n == 0) return error.ControlOutputClosed;
        try consumePrefix(alloc, bytes, n);
    }
}

pub fn run(
    client_fd: i32,
    layout: adapter.InternalLayout,
    options: Options,
) !void {
    // The client may run after ensureSession forked. Keep post-fork allocation
    // independent from the threaded allocator owned by main.
    const alloc = std.heap.c_allocator;
    defer posix.close(client_fd);

    const socket_flags = try setNonBlocking(client_fd);
    defer _ = posix.fcntl(client_fd, posix.F.SETFL, socket_flags) catch {};

    const stdin_flags = try setNonBlocking(posix.STDIN_FILENO);
    defer _ = posix.fcntl(posix.STDIN_FILENO, posix.F.SETFL, stdin_flags) catch {};

    const stdout_flags = try setNonBlocking(posix.STDOUT_FILENO);
    defer _ = posix.fcntl(posix.STDOUT_FILENO, posix.F.SETFL, stdout_flags) catch {};

    var to_daemon = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer to_daemon.deinit(alloc);
    var to_adapter = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer to_adapter.deinit(alloc);

    var adapter_input = try frame.Decoder.init(alloc);
    defer adapter_input.deinit();
    var daemon_input = try ipc.SocketBuffer.init(alloc);
    defer daemon_input.deinit();

    var size = ipc.getTerminalSize(posix.STDOUT_FILENO);
    if (options.rows) |rows| size.rows = rows;
    if (options.cols) |cols| size.cols = cols;
    try adapter.appendInit(alloc, &to_daemon, layout, size);

    var handshake_ready = layout == .legacy_kkl;
    var stdin_open = true;
    var stdin_eof = false;
    var drain_after_eof = options.drain_after_stdin_eof;
    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(alloc, 3);
    defer poll_fds.deinit(alloc);

    while (true) {
        poll_fds.clearRetainingCapacity();

        const stdin_index: ?usize = if (stdin_open and handshake_ready) poll_fds.items.len else null;
        if (stdin_index != null) {
            try poll_fds.append(alloc, .{
                .fd = posix.STDIN_FILENO,
                .events = posix.POLL.IN,
                .revents = 0,
            });
        }

        const socket_index = poll_fds.items.len;
        var socket_events: i16 = posix.POLL.IN;
        if (to_daemon.items.len > 0) socket_events |= posix.POLL.OUT;
        try poll_fds.append(alloc, .{
            .fd = client_fd,
            .events = socket_events,
            .revents = 0,
        });

        const stdout_index: ?usize = if (to_adapter.items.len > 0) poll_fds.items.len else null;
        if (stdout_index != null) {
            try poll_fds.append(alloc, .{
                .fd = posix.STDOUT_FILENO,
                .events = posix.POLL.OUT,
                .revents = 0,
            });
        }

        const timeout: i32 = if (!handshake_ready)
            ready_timeout_ms
        else if (stdin_eof and !drain_after_eof)
            eof_drain_ms
        else
            -1;
        const poll_count = posix.poll(poll_fds.items, timeout) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };
        if (poll_count == 0) {
            if (!handshake_ready) return error.ControlReadyTimeout;
            if (stdin_eof and to_daemon.items.len == 0 and to_adapter.items.len == 0) return;
            continue;
        }

        if (poll_fds.items[socket_index].revents & posix.POLL.IN != 0) {
            const n = daemon_input.read(client_fd) catch |err| {
                if (err == error.WouldBlock) continue;
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                    try flushOutput(alloc, &to_adapter);
                    return;
                }
                return err;
            };
            if (n == 0) {
                if (!handshake_ready) return error.ControlReadyClosed;
                try flushOutput(alloc, &to_adapter);
                return;
            }

            while (daemon_input.next()) |message| {
                if (layout == .current and message.header.tag == .ControlReady) {
                    handshake_ready = true;
                    continue;
                }
                _ = try adapter.appendOutput(
                    alloc,
                    &to_adapter,
                    layout,
                    message,
                );
            }
        }

        if (stdin_index) |idx| {
            if (poll_fds.items[idx].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                var bytes: [4096]u8 = undefined;
                const n = posix.read(posix.STDIN_FILENO, &bytes) catch |err| {
                    if (err == error.WouldBlock) continue;
                    return err;
                };
                if (n == 0) {
                    stdin_open = false;
                    stdin_eof = true;
                } else {
                    try adapter_input.append(bytes[0..n]);
                    while (try adapter_input.next()) |external| {
                        _ = try adapter.appendInput(
                            alloc,
                            &to_daemon,
                            layout,
                            external,
                        );
                        if (external.tag == .close) {
                            stdin_open = false;
                            stdin_eof = true;
                            drain_after_eof = true;
                        }
                    }
                }
            }
        }

        if (poll_fds.items[socket_index].revents & posix.POLL.OUT != 0 and to_daemon.items.len > 0) {
            const n = posix.write(client_fd, to_daemon.items) catch |err| {
                if (err == error.WouldBlock) continue;
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) return;
                return err;
            };
            if (n > 0) try consumePrefix(alloc, &to_daemon, n);
        }

        if (stdout_index) |idx| {
            if (poll_fds.items[idx].revents & posix.POLL.OUT != 0 and to_adapter.items.len > 0) {
                const n = posix.write(posix.STDOUT_FILENO, to_adapter.items) catch |err| {
                    if (err == error.WouldBlock) continue;
                    return err;
                };
                if (n == 0) return error.ControlOutputClosed;
                try consumePrefix(alloc, &to_adapter, n);
            }
        }

        if (poll_fds.items[socket_index].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
            if (!handshake_ready) return error.ControlReadyClosed;
            try flushOutput(alloc, &to_adapter);
            return;
        }
    }
}

test "layout probe distinguishes known current and legacy tag maps" {
    try std.testing.expectEqual(adapter.InternalLayout.current, classifyLayoutProbe(.LabelData).?);
    try std.testing.expectEqual(adapter.InternalLayout.legacy_kkl, classifyLayoutProbe(.Info).?);
    try std.testing.expectEqual(@as(?adapter.InternalLayout, null), classifyLayoutProbe(.Output));
}
