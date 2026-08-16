const std = @import("std");
const ipc = @import("../ipc.zig");

pub const header_len = 5;
pub const max_payload_len = 16 * 1024 * 1024;

/// Public zmx-control/v1 tags. These values are independent of zmx's internal
/// IPC tags and must remain stable for external adapters such as Portl.
pub const Tag = enum(u8) {
    input = 0,
    output = 1,
    resize = 2,
    close = 3,
    history = 8,
    viewport_snapshot = 14,
    live_output = 15,
    history_chunk = 16,
    history_end = 17,
    _,
};

pub const Frame = struct {
    tag: Tag,
    payload: []const u8,
};

/// Incremental decoder for the external five-byte frame format. Returned
/// payloads remain valid until the next append call.
pub const Decoder = struct {
    bytes: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    head: usize = 0,

    pub fn init(alloc: std.mem.Allocator) !Decoder {
        return .{
            .bytes = try std.ArrayList(u8).initCapacity(alloc, 4096),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.bytes.deinit(self.alloc);
    }

    pub fn append(self: *Decoder, data: []const u8) !void {
        if (self.head > 0) {
            const remaining = self.bytes.items.len - self.head;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.bytes.items[0..remaining], self.bytes.items[self.head..]);
                self.bytes.items.len = remaining;
            } else {
                self.bytes.clearRetainingCapacity();
            }
            self.head = 0;
        }
        try self.bytes.appendSlice(self.alloc, data);
    }

    pub fn next(self: *Decoder) !?Frame {
        const available = self.bytes.items[self.head..];
        if (available.len < header_len) return null;

        const payload_len = std.mem.readInt(u32, available[1..header_len], .little);
        if (payload_len > max_payload_len) return error.ControlFrameTooLarge;
        const total = header_len + @as(usize, payload_len);
        if (available.len < total) return null;

        self.head += total;
        return .{
            .tag = @enumFromInt(available[0]),
            .payload = available[header_len..total],
        };
    }
};

pub fn append(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tag: Tag,
    payload: []const u8,
) !void {
    if (payload.len > max_payload_len) return error.ControlFrameTooLarge;

    try out.ensureUnusedCapacity(alloc, header_len + payload.len);
    out.appendAssumeCapacity(@intFromEnum(tag));
    var payload_len: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload_len, @intCast(payload.len), .little);
    out.appendSliceAssumeCapacity(&payload_len);
    out.appendSliceAssumeCapacity(payload);
}

/// Translate one accepted external input frame into current internal IPC.
/// Unknown and output-only external tags are ignored for forward compatibility.
pub fn appendInputAsIpc(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    frame: Frame,
) !bool {
    switch (frame.tag) {
        .input => try ipc.appendMessage(alloc, out, .Input, frame.payload),
        .resize => {
            if (frame.payload.len != 4) return error.InvalidControlResize;
            const resize = ipc.Resize{
                .rows = std.mem.readInt(u16, frame.payload[0..2], .little),
                .cols = std.mem.readInt(u16, frame.payload[2..4], .little),
                .xpixel = 0,
                .ypixel = 0,
            };
            if (resize.rows == 0 or resize.cols == 0) return error.ControlSizeOutOfRange;
            try ipc.appendMessage(alloc, out, .Resize, std.mem.asBytes(&resize));
        },
        .close => try ipc.appendMessage(alloc, out, .Detach, ""),
        .history => {
            if (frame.payload.len > 1) return error.InvalidControlHistory;
            if (frame.payload.len == 1 and frame.payload[0] > 2) return error.InvalidControlHistory;
            try ipc.appendMessage(alloc, out, .History, frame.payload);
        },
        else => return false,
    }
    return true;
}

/// Translate semantic daemon output into the stable external namespace.
pub fn appendOutputFromIpc(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    message: ipc.SocketMsg,
) !bool {
    const tag: Tag = switch (message.header.tag) {
        .Output => .output,
        .History => .history,
        .ControlViewport => .viewport_snapshot,
        .ControlLive => .live_output,
        .ControlHistoryChunk => .history_chunk,
        .ControlHistoryEnd => .history_end,
        else => return false,
    };
    try append(alloc, out, tag, message.payload);
    return true;
}

test "external frame codec uses the exact five-byte little-endian header" {
    const alloc = std.testing.allocator;
    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(alloc);

    try append(alloc, &encoded, .live_output, "abc");
    try std.testing.expectEqualSlices(u8, &.{ 15, 3, 0, 0, 0, 'a', 'b', 'c' }, encoded.items);

    var decoder = try Decoder.init(alloc);
    defer decoder.deinit();
    try decoder.append(encoded.items[0..3]);
    try std.testing.expectEqual(@as(?Frame, null), try decoder.next());
    try decoder.append(encoded.items[3..]);
    const decoded = (try decoder.next()).?;
    try std.testing.expectEqual(Tag.live_output, decoded.tag);
    try std.testing.expectEqualStrings("abc", decoded.payload);
}

test "external resize expands to current internal resize without reusing tags" {
    const alloc = std.testing.allocator;
    var internal = std.ArrayList(u8).empty;
    defer internal.deinit(alloc);

    const payload = [_]u8{ 40, 0, 120, 0 };
    try std.testing.expect(try appendInputAsIpc(alloc, &internal, .{ .tag = .resize, .payload = &payload }));

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
        appendInputAsIpc(alloc, &internal, .{ .tag = .history, .payload = &.{3} }),
    );
    try std.testing.expectError(
        error.InvalidControlHistory,
        appendInputAsIpc(alloc, &internal, .{ .tag = .history, .payload = &.{ 0, 1 } }),
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
    try std.testing.expect(try appendOutputFromIpc(alloc, &external, message));
    try std.testing.expectEqual(@as(u8, 14), external.items[0]);
}
