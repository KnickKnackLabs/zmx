const std = @import("std");
const frame = @import("frame.zig");
const ipc = @import("../ipc.zig");

/// The internal connection requires a matching client and daemon version.
pub fn appendInit(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    resize: ipc.Resize,
) !void {
    try ipc.appendMessage(alloc, out, .ControlInit, std.mem.asBytes(&resize));
}

/// Translate accepted public input into daemon IPC.
/// Unknown and output-only public tags are ignored for forward compatibility.
pub fn appendInput(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    external: frame.Frame,
) !bool {
    switch (external.tag) {
        .input => try ipc.appendMessage(alloc, out, .Input, external.payload),
        .resize => {
            if (external.payload.len != 4) return error.InvalidControlResize;
            const rows = std.mem.readInt(u16, external.payload[0..2], .little);
            const cols = std.mem.readInt(u16, external.payload[2..4], .little);
            if (rows == 0 or cols == 0) return error.ControlSizeOutOfRange;

            const resize = ipc.Resize{ .rows = rows, .cols = cols };
            try ipc.appendMessage(alloc, out, .Resize, std.mem.asBytes(&resize));
        },
        .close => try ipc.appendMessage(alloc, out, .Detach, ""),
        .history => {
            if (external.payload.len > 1) return error.InvalidControlHistory;
            if (external.payload.len == 1 and external.payload[0] > 2) return error.InvalidControlHistory;
            try ipc.appendMessage(alloc, out, .History, external.payload);
        },
        else => return false,
    }
    return true;
}

/// Translate semantic daemon output into the stable public frame namespace.
pub fn appendOutput(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    message: ipc.SocketMsg,
) !bool {
    const external_tag: frame.Tag = switch (message.header.tag) {
        .Output => .output,
        .History => .history,
        .ControlViewport => .viewport_snapshot,
        .ControlLive => .live_output,
        .ControlHistoryChunk => .history_chunk,
        .ControlHistoryEnd => .history_end,
        else => return false,
    };
    try frame.append(alloc, out, external_tag, message.payload);
    return true;
}

test "control init uses the KKL block and full terminal size" {
    const alloc = std.testing.allocator;
    var internal = std.ArrayList(u8).empty;
    defer internal.deinit(alloc);

    const size = ipc.Resize{ .rows = 40, .cols = 120, .xpixel = 7, .ypixel = 9 };
    try appendInit(alloc, &internal, size);
    const header = std.mem.bytesToValue(ipc.Header, internal.items[0..@sizeOf(ipc.Header)]);
    try std.testing.expectEqual(@as(u8, 128), @intFromEnum(header.tag));
    try std.testing.expectEqual(@as(u32, @sizeOf(ipc.Resize)), header.len);
    try std.testing.expectEqual(size, std.mem.bytesToValue(ipc.Resize, internal.items[@sizeOf(ipc.Header)..]));
}

test "external resize expands to internal resize without tag reuse" {
    const alloc = std.testing.allocator;
    var internal = std.ArrayList(u8).empty;
    defer internal.deinit(alloc);

    const payload = [_]u8{ 40, 0, 120, 0 };
    try std.testing.expect(try appendInput(
        alloc,
        &internal,
        .{ .tag = .resize, .payload = &payload },
    ));

    const header = std.mem.bytesToValue(ipc.Header, internal.items[0..@sizeOf(ipc.Header)]);
    try std.testing.expectEqual(ipc.Tag.Resize, header.tag);
    try std.testing.expectEqual(@as(u32, @sizeOf(ipc.Resize)), header.len);
    const resize = std.mem.bytesToValue(ipc.Resize, internal.items[@sizeOf(ipc.Header)..]);
    try std.testing.expectEqual(@as(u16, 40), resize.rows);
    try std.testing.expectEqual(@as(u16, 120), resize.cols);
    try std.testing.expectEqual(@as(u16, 0), resize.xpixel);
    try std.testing.expectEqual(@as(u16, 0), resize.ypixel);
}

test "external history rejects malformed formats before internal IPC" {
    const alloc = std.testing.allocator;
    var internal = std.ArrayList(u8).empty;
    defer internal.deinit(alloc);

    try std.testing.expectError(
        error.InvalidControlHistory,
        appendInput(alloc, &internal, .{ .tag = .history, .payload = &.{3} }),
    );
    try std.testing.expectError(
        error.InvalidControlHistory,
        appendInput(alloc, &internal, .{ .tag = .history, .payload = &.{ 0, 1 } }),
    );
    try std.testing.expectEqual(@as(usize, 0), internal.items.len);
}

test "renumbered internal output preserves public semantic tags" {
    const alloc = std.testing.allocator;
    var external = std.ArrayList(u8).empty;
    defer external.deinit(alloc);

    inline for (.{
        .{ ipc.Tag.ControlViewport, 14 },     .{ ipc.Tag.ControlLive, 15 },
        .{ ipc.Tag.ControlHistoryChunk, 16 }, .{ ipc.Tag.ControlHistoryEnd, 17 },
    }) |pair| {
        external.clearRetainingCapacity();
        const message = ipc.SocketMsg{
            .header = .{ .tag = pair[0], .len = 4 },
            .payload = "data",
        };
        try std.testing.expect(try appendOutput(alloc, &external, message));
        try std.testing.expectEqual(@as(u8, pair[1]), external.items[0]);
    }
}
