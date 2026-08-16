const std = @import("std");
const frame = @import("frame.zig");
const ipc = @import("../ipc.zig");

/// Internal daemon wire layout selected through a capability probe before a
/// control connection is opened. The legacy layout is never guessed from a
/// failed control handshake because its init tag collides with current Send.
pub const InternalLayout = enum {
    legacy_kkl,
    current,
};

const LegacyResize = packed struct {
    rows: u16,
    cols: u16,
};

pub fn appendInit(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    layout: InternalLayout,
    resize: ipc.Resize,
) !void {
    switch (layout) {
        .current => try ipc.appendMessage(alloc, out, .ControlInit, std.mem.asBytes(&resize)),
        .legacy_kkl => {
            const legacy = LegacyResize{ .rows = resize.rows, .cols = resize.cols };
            // Numeric tag 18 is safe only after the ordered capability probe
            // identifies the legacy KKL layout. Current daemons use 18 as Send.
            try ipc.appendMessage(alloc, out, @enumFromInt(18), std.mem.asBytes(&legacy));
        },
    }
}

/// Translate accepted public input into the selected daemon IPC layout.
/// Unknown and output-only public tags are ignored for forward compatibility.
pub fn appendInput(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    layout: InternalLayout,
    external: frame.Frame,
) !bool {
    switch (external.tag) {
        .input => try ipc.appendMessage(alloc, out, .Input, external.payload),
        .resize => {
            if (external.payload.len != 4) return error.InvalidControlResize;
            const rows = std.mem.readInt(u16, external.payload[0..2], .little);
            const cols = std.mem.readInt(u16, external.payload[2..4], .little);
            if (rows == 0 or cols == 0) return error.ControlSizeOutOfRange;

            switch (layout) {
                .current => {
                    const resize = ipc.Resize{
                        .rows = rows,
                        .cols = cols,
                        .xpixel = 0,
                        .ypixel = 0,
                    };
                    try ipc.appendMessage(alloc, out, .Resize, std.mem.asBytes(&resize));
                },
                .legacy_kkl => {
                    const resize = LegacyResize{ .rows = rows, .cols = cols };
                    try ipc.appendMessage(alloc, out, .Resize, std.mem.asBytes(&resize));
                },
            }
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
    layout: InternalLayout,
    message: ipc.SocketMsg,
) !bool {
    const external_tag: frame.Tag = switch (layout) {
        .current => switch (message.header.tag) {
            .Output => .output,
            .History => .history,
            .ControlViewport => .viewport_snapshot,
            .ControlLive => .live_output,
            .ControlHistoryChunk => .history_chunk,
            .ControlHistoryEnd => .history_end,
            else => return false,
        },
        .legacy_kkl => switch (@intFromEnum(message.header.tag)) {
            1 => .output,
            8 => .history,
            14 => .viewport_snapshot,
            15 => .live_output,
            16 => .history_chunk,
            17 => .history_end,
            else => return false,
        },
    };
    try frame.append(alloc, out, external_tag, message.payload);
    return true;
}

test "external resize expands to current internal resize without tag reuse" {
    const alloc = std.testing.allocator;
    var internal = std.ArrayList(u8).empty;
    defer internal.deinit(alloc);

    const payload = [_]u8{ 40, 0, 120, 0 };
    try std.testing.expect(try appendInput(
        alloc,
        &internal,
        .current,
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
        appendInput(alloc, &internal, .current, .{ .tag = .history, .payload = &.{3} }),
    );
    try std.testing.expectError(
        error.InvalidControlHistory,
        appendInput(alloc, &internal, .current, .{ .tag = .history, .payload = &.{ 0, 1 } }),
    );
    try std.testing.expectEqual(@as(usize, 0), internal.items.len);
}

test "output mapping keeps internal and external semantic tags separate" {
    const alloc = std.testing.allocator;
    var external = std.ArrayList(u8).empty;
    defer external.deinit(alloc);

    const message = ipc.SocketMsg{
        .header = .{ .tag = .ControlViewport, .len = 4 },
        .payload = "view",
    };
    try std.testing.expect(try appendOutput(alloc, &external, .current, message));
    try std.testing.expectEqual(@as(u8, 14), external.items[0]);
}

test "legacy adapter preserves old init resize and semantic output values" {
    const alloc = std.testing.allocator;
    var internal = std.ArrayList(u8).empty;
    defer internal.deinit(alloc);

    const size = ipc.Resize{ .rows = 40, .cols = 120, .xpixel = 7, .ypixel = 9 };
    try appendInit(alloc, &internal, .legacy_kkl, size);
    const init_header = std.mem.bytesToValue(ipc.Header, internal.items[0..@sizeOf(ipc.Header)]);
    try std.testing.expectEqual(@as(u8, 18), @intFromEnum(init_header.tag));
    try std.testing.expectEqual(@as(u32, @sizeOf(LegacyResize)), init_header.len);

    internal.clearRetainingCapacity();
    const resize_payload = [_]u8{ 40, 0, 120, 0 };
    try std.testing.expect(try appendInput(
        alloc,
        &internal,
        .legacy_kkl,
        .{ .tag = .resize, .payload = &resize_payload },
    ));
    const resize_header = std.mem.bytesToValue(ipc.Header, internal.items[0..@sizeOf(ipc.Header)]);
    try std.testing.expectEqual(@as(u32, @sizeOf(LegacyResize)), resize_header.len);

    var external = std.ArrayList(u8).empty;
    defer external.deinit(alloc);
    const old_viewport = ipc.SocketMsg{
        .header = .{ .tag = @enumFromInt(14), .len = 4 },
        .payload = "view",
    };
    try std.testing.expect(try appendOutput(alloc, &external, .legacy_kkl, old_viewport));
    try std.testing.expectEqual(@as(u8, 14), external.items[0]);
}
