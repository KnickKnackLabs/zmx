const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("../ipc.zig");
const frame = @import("frame.zig");
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
    sent_bytes: *usize,
    viewport: []const u8,
) !void {
    if (sent_bytes.* > out.items.len) return error.InvalidControlBacklog;

    var replacement = try std.ArrayList(u8).initCapacity(alloc, out.items.len + viewport.len);
    errdefer replacement.deinit(alloc);

    var replacement_sent: usize = 0;
    var offset: usize = 0;
    while (offset < out.items.len) {
        const remaining = out.items[offset..];
        const message_len = ipc.expectedLength(remaining) orelse return error.InvalidControlBacklog;
        if (message_len > remaining.len) return error.InvalidControlBacklog;

        const end = offset + message_len;
        if (end <= sent_bytes.*) {
            offset = end;
            continue;
        }

        const header = std.mem.bytesToValue(ipc.Header, remaining[0..@sizeOf(ipc.Header)]);
        const started = offset < sent_bytes.*;
        const render = header.tag == .ControlViewport or header.tag == .ControlLive;
        if (started or !render) {
            const replacement_start = replacement.items.len;
            try replacement.appendSlice(alloc, remaining[0..message_len]);
            if (started) replacement_sent = replacement_start + sent_bytes.* - offset;
        }
        offset = end;
    }
    try ipc.appendMessage(alloc, &replacement, .ControlViewport, viewport);

    out.deinit(alloc);
    out.* = replacement;
    sent_bytes.* = replacement_sent;
}

pub fn queuePtyOutput(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    sent_bytes: *usize,
    term: *ghostty_vt.Terminal,
    payload: []const u8,
) !void {
    if (sent_bytes.* > out.items.len) return error.InvalidControlBacklog;
    const pending_bytes = out.items.len - sent_bytes.*;
    if (!shouldCoalesce(pending_bytes, payload.len)) return queueLive(alloc, out, payload);

    const snapshot = util.serializeViewportSnapshot(alloc, term) orelse return queueLive(alloc, out, payload);
    defer alloc.free(snapshot);
    const restore_data = util.rewritePromptRedraw(alloc, snapshot) orelse snapshot;
    defer if (restore_data.ptr != snapshot.ptr) alloc.free(restore_data);
    try replaceRenderWithViewport(alloc, out, sent_bytes, restore_data);
}

fn queueHistoryData(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    history: []const u8,
) !void {
    if (history.len == 0) {
        try ipc.appendMessage(alloc, out, .ControlHistoryChunk, "");
    } else {
        var offset: usize = 0;
        while (offset < history.len) {
            const chunk_len = @min(history.len - offset, frame.max_payload_len);
            try ipc.appendMessage(
                alloc,
                out,
                .ControlHistoryChunk,
                history[offset .. offset + chunk_len],
            );
            offset += chunk_len;
        }
    }
    try ipc.appendMessage(alloc, out, .ControlHistoryEnd, "");
}

pub fn queueHistory(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    term: *ghostty_vt.Terminal,
    format: util.HistoryFormat,
) !void {
    if (util.serializeTerminal(alloc, term, format)) |history| {
        defer alloc.free(history);
        return queueHistoryData(alloc, out, history);
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
    var sent_bytes: usize = 0;
    try replaceRenderWithViewport(alloc, &out, &sent_bytes, "latest");

    var messages = try ipc.SocketBuffer.init(alloc);
    defer messages.deinit();
    try messages.buf.appendSlice(alloc, out.items);
    try std.testing.expectEqual(ipc.Tag.ControlReady, messages.next().?.header.tag);
    try std.testing.expectEqual(ipc.Tag.ControlHistoryEnd, messages.next().?.header.tag);
    const viewport = messages.next().?;
    try std.testing.expectEqual(ipc.Tag.ControlViewport, viewport.header.tag);
    try std.testing.expectEqualStrings("latest", viewport.payload);
    try std.testing.expectEqual(@as(?ipc.SocketMsg, null), messages.next());
    try std.testing.expectEqual(@as(usize, 0), sent_bytes);
}

test "coalescing preserves a partially written render frame" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    try ipc.appendMessage(alloc, &out, .ControlReady, "");
    try ipc.appendMessage(alloc, &out, .ControlLive, "started");
    try ipc.appendMessage(alloc, &out, .ControlLive, "stale");
    try ipc.appendMessage(alloc, &out, .ControlHistoryEnd, "");

    const ready_len = @sizeOf(ipc.Header);
    const sent_in_live = @sizeOf(ipc.Header) + 2;
    var sent_bytes: usize = ready_len + sent_in_live;
    const pending_started = try alloc.dupe(u8, out.items[sent_bytes .. ready_len + @sizeOf(ipc.Header) + "started".len]);
    defer alloc.free(pending_started);

    try replaceRenderWithViewport(alloc, &out, &sent_bytes, "latest");

    var messages = try ipc.SocketBuffer.init(alloc);
    defer messages.deinit();
    try messages.buf.appendSlice(alloc, out.items);
    const started = messages.next().?;
    try std.testing.expectEqual(ipc.Tag.ControlLive, started.header.tag);
    try std.testing.expectEqualStrings("started", started.payload);
    try std.testing.expectEqualSlices(
        u8,
        pending_started,
        out.items[sent_bytes .. @sizeOf(ipc.Header) + "started".len],
    );
    try std.testing.expectEqual(ipc.Tag.ControlHistoryEnd, messages.next().?.header.tag);
    const viewport = messages.next().?;
    try std.testing.expectEqual(ipc.Tag.ControlViewport, viewport.header.tag);
    try std.testing.expectEqualStrings("latest", viewport.payload);
    try std.testing.expectEqual(@as(?ipc.SocketMsg, null), messages.next());
}

test "history larger than one public frame is chunked before history end" {
    const alloc = std.testing.allocator;
    const history = try alloc.alloc(u8, frame.max_payload_len + 1);
    defer alloc.free(history);
    @memset(history, 'x');

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try queueHistoryData(alloc, &out, history);

    var messages = try ipc.SocketBuffer.init(alloc);
    defer messages.deinit();
    try messages.buf.appendSlice(alloc, out.items);
    const first = messages.next().?;
    try std.testing.expectEqual(ipc.Tag.ControlHistoryChunk, first.header.tag);
    try std.testing.expectEqual(frame.max_payload_len, first.payload.len);
    const second = messages.next().?;
    try std.testing.expectEqual(ipc.Tag.ControlHistoryChunk, second.header.tag);
    try std.testing.expectEqual(@as(usize, 1), second.payload.len);
    try std.testing.expectEqual(ipc.Tag.ControlHistoryEnd, messages.next().?.header.tag);
    try std.testing.expectEqual(@as(?ipc.SocketMsg, null), messages.next());
}
