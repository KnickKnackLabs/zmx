const std = @import("std");
const util = @import("util.zig");

pub const SessionEntry = util.SessionEntry;

pub fn formatStatus(buf: []u8, session: SessionEntry) []const u8 {
    if (session.is_error) {
        if (session.error_name) |name| {
            if (std.mem.eql(u8, name, "ConnectionRefused")) return "cleaning up";
        }
        return "unreachable";
    }

    if (session.task_ended_at) |ended_at| {
        if (ended_at > 0) {
            if (session.task_exit_code) |code| {
                return std.fmt.bufPrint(buf, "exited ({d})", .{code}) catch "exited";
            }
            return "exited";
        }
    }

    return "running";
}

pub fn formatAge(buf: []u8, now: i64, created_at: u64) []const u8 {
    const created: i64 = @intCast(created_at);
    const elapsed: u64 = if (now > created) @intCast(now - created) else 0;

    if (elapsed < 60) return "just now";

    const minutes = elapsed / 60;
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{minutes}) catch "?";

    const hours = minutes / 60;
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "?";

    const days = hours / 24;
    if (days < 30) return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "?";

    return std.fmt.bufPrint(buf, "{d}mo ago", .{days / 30}) catch "?";
}

/// Write the stable machine-readable contract consumed by Shell and Portl.
/// Fields may be added, but existing names and meanings must remain stable.
pub fn writeJson(
    writer: *std.Io.Writer,
    sessions: []const SessionEntry,
    current_session: ?[]const u8,
    now: i64,
) !void {
    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try json.beginArray();
    for (sessions) |session| {
        try json.beginObject();

        try json.objectField("name");
        try json.write(session.name);

        try json.objectField("status");
        var status_buf: [32]u8 = undefined;
        try json.write(formatStatus(&status_buf, session));

        try json.objectField("pid");
        try json.write(session.pid);

        try json.objectField("clients");
        try json.write(session.clients_len);

        try json.objectField("exit_code");
        try json.write(session.task_exit_code);

        try json.objectField("created_at");
        try json.write(session.created_at);

        try json.objectField("age");
        var age_buf: [32]u8 = undefined;
        try json.write(formatAge(&age_buf, now, session.created_at));

        try json.objectField("is_current");
        try json.write(if (current_session) |current|
            std.mem.eql(u8, current, session.name)
        else
            false);

        try json.objectField("start_dir");
        try json.write(session.cwd);

        try json.objectField("cmd");
        try json.write(session.cmd);

        try json.endObject();
    }
    try json.endArray();
    try writer.writeByte('\n');
}

test "JSON output preserves the consumer contract and escapes strings" {
    const alloc = std.testing.allocator;
    const sessions = [_]SessionEntry{.{
        .name = "dev\"session",
        .pid = 123,
        .clients_len = 2,
        .is_error = false,
        .error_name = null,
        .cmd = "printf \\\"hello\\\"",
        .cwd = "/tmp/work",
        .created_at = 0,
        .task_ended_at = null,
        .task_exit_code = null,
    }};

    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try writeJson(&output.writer, &sessions, "dev\"session", 0);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, output.written(), .{});
    defer parsed.deinit();
    const session = parsed.value.array.items[0].object;

    try std.testing.expectEqualStrings("dev\"session", session.get("name").?.string);
    try std.testing.expectEqualStrings("running", session.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 123), session.get("pid").?.integer);
    try std.testing.expect(session.get("is_current").?.bool);
    try std.testing.expectEqualStrings("/tmp/work", session.get("start_dir").?.string);
}

test "JSON output represents an empty session list" {
    const alloc = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();

    try writeJson(&output.writer, &.{}, null, 0);
    try std.testing.expectEqualStrings("[]\n", output.written());
}
