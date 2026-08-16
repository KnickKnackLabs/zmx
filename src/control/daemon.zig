const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("../ipc.zig");
const util = @import("../util.zig");

pub const render_backlog_limit = 1024 * 1024;

pub fn shouldCoalesce(pending_bytes: usize, incoming_bytes: usize) bool {
    if (pending_bytes > render_backlog_limit) return true;
    return incoming_bytes > render_backlog_limit - pending_bytes;
}

pub fn queueReady(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try ipc.appendMessage(alloc, out, .ControlReady, "");
}

pub fn queueViewport(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    term: *ghostty_vt.Terminal,
) !bool {
    const snapshot = util.serializeViewportSnapshot(alloc, term) orelse return false;
    defer alloc.free(snapshot);

    const restore_data = util.rewritePromptRedraw(alloc, snapshot) orelse snapshot;
    defer if (restore_data.ptr != snapshot.ptr) alloc.free(restore_data);
    try ipc.appendMessage(alloc, out, .ControlViewport, restore_data);
    return true;
}

pub fn queueLive(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    payload: []const u8,
) !void {
    try ipc.appendMessage(alloc, out, .ControlLive, payload);
}

fn replaceRenderWithViewport(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    viewport: []const u8,
) !void {
    var replacement = try std.ArrayList(u8).initCapacity(alloc, out.items.len + viewport.len);
    errdefer replacement.deinit(alloc);

    var offset: usize = 0;
    while (offset < out.items.len) {
        const remaining = out.items[offset..];
        const message_len = ipc.expectedLength(remaining) orelse return error.InvalidControlBacklog;
        if (message_len > remaining.len) return error.InvalidControlBacklog;
        const header = std.mem.bytesToValue(ipc.Header, remaining[0..@sizeOf(ipc.Header)]);
        if (header.tag != .ControlViewport and header.tag != .ControlLive) {
            try replacement.appendSlice(alloc, remaining[0..message_len]);
        }
        offset += message_len;
    }
    try ipc.appendMessage(alloc, &replacement, .ControlViewport, viewport);

    out.deinit(alloc);
    out.* = replacement;
}

pub fn queuePtyOutput(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    term: *ghostty_vt.Terminal,
    payload: []const u8,
) !void {
    if (!shouldCoalesce(out.items.len, payload.len)) return queueLive(alloc, out, payload);

    const snapshot = util.serializeViewportSnapshot(alloc, term) orelse return queueLive(alloc, out, payload);
    defer alloc.free(snapshot);
    const restore_data = util.rewritePromptRedraw(alloc, snapshot) orelse snapshot;
    defer if (restore_data.ptr != snapshot.ptr) alloc.free(restore_data);
    try replaceRenderWithViewport(alloc, out, restore_data);
}

pub fn queueHistory(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    term: *ghostty_vt.Terminal,
    format: util.HistoryFormat,
) !void {
    if (util.serializeTerminal(alloc, term, format)) |history| {
        defer alloc.free(history);
        try ipc.appendMessage(alloc, out, .ControlHistoryChunk, history);
    }
    try ipc.appendMessage(alloc, out, .ControlHistoryEnd, "");
}

test "control daemon handshake uses a new internal tag" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    try queueReady(alloc, &out);
    const header = std.mem.bytesToValue(ipc.Header, out.items[0..@sizeOf(ipc.Header)]);
    try std.testing.expectEqual(ipc.Tag.ControlReady, header.tag);
    try std.testing.expectEqual(@as(u32, 0), header.len);
}

test "control live output uses an internal semantic tag" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    try queueLive(alloc, &out, "hello");
    const header = std.mem.bytesToValue(ipc.Header, out.items[0..@sizeOf(ipc.Header)]);
    try std.testing.expectEqual(ipc.Tag.ControlLive, header.tag);
    try std.testing.expectEqualStrings("hello", out.items[@sizeOf(ipc.Header)..]);
}

test "control render backlog boundary is exact without integer overflow" {
    try std.testing.expect(!shouldCoalesce(render_backlog_limit - 10, 10));
    try std.testing.expect(shouldCoalesce(render_backlog_limit - 10, 11));
    try std.testing.expect(shouldCoalesce(std.math.maxInt(usize), 1));
}

test "coalescing replaces only render frames" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    try ipc.appendMessage(alloc, &out, .ControlReady, "");
    try ipc.appendMessage(alloc, &out, .ControlLive, "stale");
    try ipc.appendMessage(alloc, &out, .ControlHistoryEnd, "");
    try replaceRenderWithViewport(alloc, &out, "latest");

    var messages = try ipc.SocketBuffer.init(alloc);
    defer messages.deinit();
    try messages.buf.appendSlice(alloc, out.items);
    try std.testing.expectEqual(ipc.Tag.ControlReady, messages.next().?.header.tag);
    try std.testing.expectEqual(ipc.Tag.ControlHistoryEnd, messages.next().?.header.tag);
    const viewport = messages.next().?;
    try std.testing.expectEqual(ipc.Tag.ControlViewport, viewport.header.tag);
    try std.testing.expectEqualStrings("latest", viewport.payload);
    try std.testing.expectEqual(@as(?ipc.SocketMsg, null), messages.next());
}
