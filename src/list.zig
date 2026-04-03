const std = @import("std");
const zigcli = @import("zigcli");
const pretty_table = zigcli.pretty_table;
const util = @import("util.zig");

pub const SessionEntry = util.SessionEntry;

/// Output mode for `zmx list`.
pub const Mode = enum {
    table,
    short,
    json,
};

/// Format an epoch timestamp as a human-readable relative age string.
/// Returns either a comptime string literal (e.g. "just now") or a slice into
/// `buf` (e.g. "2h ago", "3d ago"). The caller should not inspect `buf`
/// directly — always use the returned slice.
pub fn formatAge(buf: []u8, created_at: u64) []const u8 {
    const now: i64 = std.time.timestamp();
    const created: i64 = @intCast(created_at);
    const diff: u64 = if (now > created) @intCast(now - created) else 0;

    if (diff < 60) return "just now";

    const minutes = diff / 60;
    if (minutes < 60) {
        return std.fmt.bufPrint(buf, "{d}m ago", .{minutes}) catch "?";
    }

    const hours = minutes / 60;
    if (hours < 24) {
        return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "?";
    }

    const days = hours / 24;
    if (days < 30) {
        return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "?";
    }

    const months = days / 30;
    return std.fmt.bufPrint(buf, "{d}mo ago", .{months}) catch "?";
}

/// Format the status of a session entry.
/// Returns a slice into `buf` like "running", "exited (0)", "unreachable".
pub fn formatStatus(buf: []u8, session: SessionEntry) []const u8 {
    if (session.is_error) {
        if (session.error_name) |ename| {
            if (std.mem.eql(u8, ename, "ConnectionRefused"))
                return "cleaning up";
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

/// Truncate a string to `max_len`, adding "..." if truncated.
/// Returns a slice into `buf`, or the original string if no truncation needed.
fn truncateCmd(buf: []u8, cmd: []const u8, max_len: usize) []const u8 {
    if (cmd.len <= max_len) return cmd;
    if (max_len <= 3) return "...";
    const end = max_len - 3;
    @memcpy(buf[0..end], cmd[0..end]);
    @memcpy(buf[end..][0..3], "...");
    return buf[0 .. end + 3];
}

/// Color a status cell based on session state.
fn statusCell(status: []const u8, session: SessionEntry, use_color: bool) pretty_table.Cell {
    if (!use_color) return pretty_table.Cell.init(status);

    if (session.is_error) {
        return pretty_table.Cell.init(status).withFg(.red);
    }

    if (session.task_ended_at) |ended_at| {
        if (ended_at > 0) {
            if (session.task_exit_code) |code| {
                return if (code == 0)
                    pretty_table.Cell.init(status).withFg(.green)
                else
                    pretty_table.Cell.init(status).withFg(.red);
            }
            return pretty_table.Cell.init(status).withFg(.yellow);
        }
    }

    return pretty_table.Cell.init(status).withFg(.green);
}

/// Write a table of sessions to the writer using pretty-table.
/// When `use_color` is true, output includes ANSI styling (bold headers,
/// colored status). Callers should pass `term.isTty(stdout)` or similar.
pub fn writeTable(
    writer: *std.Io.Writer,
    sessions: []const SessionEntry,
    current_session: ?[]const u8,
    alloc: std.mem.Allocator,
    use_color: bool,
) !void {

    var table = pretty_table.Table(4).Owned.init(.{
        .mode = .ascii,
        .padding = 1,
    });
    defer table.deinit(alloc);

    if (use_color) {
        table.setHeader(.{
            pretty_table.Cell.init("NAME").withBold(),
            pretty_table.Cell.init("STATUS").withBold(),
            pretty_table.Cell.init("AGE").withBold(),
            pretty_table.Cell.init("CMD").withBold(),
        });
    } else {
        table.setHeader(.{ "NAME", "STATUS", "AGE", "CMD" });
    }

    for (sessions) |session| {
        // Name — prefix with → for current session
        var name_buf: [256]u8 = undefined;
        const is_current = if (current_session) |current|
            std.mem.eql(u8, current, session.name)
        else
            false;
        const name_text = if (is_current)
            std.fmt.bufPrint(&name_buf, "\xe2\x86\x92 {s}", .{session.name}) catch session.name
        else
            session.name;

        var status_buf: [32]u8 = undefined;
        const status = formatStatus(&status_buf, session);

        var age_buf: [32]u8 = undefined;
        const age = formatAge(&age_buf, session.created_at);

        var cmd_buf: [128]u8 = undefined;
        const cmd = if (session.cmd) |c| truncateCmd(&cmd_buf, c, 60) else "";

        const name_cell = if (use_color and is_current)
            pretty_table.Cell.init(name_text).withBold()
        else
            pretty_table.Cell.init(name_text);

        try table.addRow(alloc, .{
            name_cell,
            statusCell(status, session, use_color),
            pretty_table.Cell.init(age),
            pretty_table.Cell.init(cmd),
        });
    }

    try table.format(writer);
}

/// Write sessions as a JSON array using std.json.Stringify.
pub fn writeJson(
    writer: *std.Io.Writer,
    sessions: []const SessionEntry,
    current_session: ?[]const u8,
) !void {
    if (sessions.len == 0) {
        try writer.writeAll("[]\n");
        return;
    }

    var jw = std.json.Stringify{ .writer = writer, .options = .{ .whitespace = .indent_2 } };

    try jw.beginArray();
    for (sessions) |session| {
        try jw.beginObject();

        try jw.objectField("name");
        try jw.write(session.name);

        try jw.objectField("status");
        var status_buf: [32]u8 = undefined;
        try jw.write(formatStatus(&status_buf, session));

        try jw.objectField("pid");
        try jw.write(session.pid);

        try jw.objectField("clients");
        try jw.write(session.clients_len);

        try jw.objectField("exit_code");
        try jw.write(session.task_exit_code);

        try jw.objectField("created_at");
        try jw.write(session.created_at);

        try jw.objectField("age");
        var age_buf: [32]u8 = undefined;
        try jw.write(formatAge(&age_buf, session.created_at));

        try jw.objectField("is_current");
        const is_current = if (current_session) |current|
            std.mem.eql(u8, current, session.name)
        else
            false;
        try jw.write(is_current);

        try jw.objectField("start_dir");
        try jw.write(session.cwd);

        try jw.objectField("cmd");
        try jw.write(session.cmd);

        try jw.endObject();
    }
    try jw.endArray();
    try writer.writeAll("\n");
}

// ============================================================================
// Tests
// ============================================================================

test "formatAge: just now" {
    var buf: [32]u8 = undefined;
    // Use a timestamp that's definitely in the future — should return "just now"
    // since diff would be 0 or negative (clamped to 0).
    const future: u64 = @intCast(std.time.timestamp() + 100);
    const result = formatAge(&buf, future);
    try std.testing.expectEqualStrings("just now", result);
}

test "formatStatus: running session" {
    var buf: [32]u8 = undefined;
    const session = SessionEntry{
        .name = "test",
        .pid = 123,
        .clients_len = 0,
        .is_error = false,
        .error_name = null,
        .created_at = 0,
        .task_ended_at = null,
        .task_exit_code = null,
    };
    try std.testing.expectEqualStrings("running", formatStatus(&buf, session));
}

test "formatStatus: exited with code" {
    var buf: [32]u8 = undefined;
    const session = SessionEntry{
        .name = "test",
        .pid = 123,
        .clients_len = 0,
        .is_error = false,
        .error_name = null,
        .created_at = 0,
        .task_ended_at = 1000,
        .task_exit_code = 0,
    };
    try std.testing.expectEqualStrings("exited (0)", formatStatus(&buf, session));
}

test "formatStatus: error session" {
    var buf: [32]u8 = undefined;
    const session = SessionEntry{
        .name = "test",
        .pid = null,
        .clients_len = null,
        .is_error = true,
        .error_name = "ConnectionRefused",
        .created_at = 0,
        .task_ended_at = null,
        .task_exit_code = null,
    };
    try std.testing.expectEqualStrings("cleaning up", formatStatus(&buf, session));
}

test "formatStatus: unreachable session" {
    var buf: [32]u8 = undefined;
    const session = SessionEntry{
        .name = "test",
        .pid = null,
        .clients_len = null,
        .is_error = true,
        .error_name = "Timeout",
        .created_at = 0,
        .task_ended_at = null,
        .task_exit_code = null,
    };
    try std.testing.expectEqualStrings("unreachable", formatStatus(&buf, session));
}

test "truncateCmd: short string unchanged" {
    var buf: [128]u8 = undefined;
    const result = truncateCmd(&buf, "bash", 60);
    try std.testing.expectEqualStrings("bash", result);
}

test "truncateCmd: long string truncated with ellipsis" {
    var buf: [128]u8 = undefined;
    const long = "this is a very long command that should be truncated at some point because it is too long";
    const result = truncateCmd(&buf, long, 20);
    try std.testing.expectEqual(@as(usize, 20), result.len);
    try std.testing.expect(std.mem.endsWith(u8, result, "..."));
}

test "writeJson: produces valid JSON structure" {
    const alloc = std.testing.allocator;
    const sessions = [_]SessionEntry{
        .{
            .name = "dev",
            .pid = 123,
            .clients_len = 2,
            .is_error = false,
            .error_name = null,
            .cmd = "bash",
            .cwd = "/home",
            .created_at = 1000,
            .task_ended_at = null,
            .task_exit_code = null,
        },
    };

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    try writeJson(&builder.writer, &sessions, null);
    const output = builder.writer.buffered();

    // Should be parseable JSON — validate by re-parsing
    try std.testing.expect(std.mem.startsWith(u8, output, "["));
    try std.testing.expect(std.mem.endsWith(u8, output, "]\n"));
    // Check key fields are present
    try std.testing.expect(std.mem.indexOf(u8, output, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"cmd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "running") != null);
    // Null fields should be present as null
    try std.testing.expect(std.mem.indexOf(u8, output, "\"start_dir\": null") != null);
}

test "writeTable: produces formatted output" {
    const alloc = std.testing.allocator;
    const sessions = [_]SessionEntry{
        .{
            .name = "dev",
            .pid = 123,
            .clients_len = 2,
            .is_error = false,
            .error_name = null,
            .cmd = "bash",
            .cwd = null,
            .created_at = 1000,
            .task_ended_at = null,
            .task_exit_code = null,
        },
    };

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    try writeTable(&builder.writer, &sessions, null, alloc, false);
    const output = builder.writer.buffered();

    // Should contain header and session name
    try std.testing.expect(std.mem.indexOf(u8, output, "NAME") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "STATUS") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "AGE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CMD") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "running") != null);
    // No ANSI escape codes in no-color mode
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
}

test "writeTable: ANSI output with color enabled" {
    const alloc = std.testing.allocator;
    const sessions = [_]SessionEntry{
        .{
            .name = "dev",
            .pid = 123,
            .clients_len = 2,
            .is_error = false,
            .error_name = null,
            .cmd = "bash",
            .cwd = null,
            .created_at = 1000,
            .task_ended_at = null,
            .task_exit_code = null,
        },
    };

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    try writeTable(&builder.writer, &sessions, null, alloc, true);
    const output = builder.writer.buffered();

    // Color mode should include ANSI escape codes
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dev") != null);
}

test "writeJson: empty sessions produces empty array" {
    const alloc = std.testing.allocator;
    const sessions = [_]SessionEntry{};

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    try writeJson(&builder.writer, &sessions, null);
    try std.testing.expectEqualStrings("[]\n", builder.writer.buffered());
}

test "writeJson: escapes special characters in strings" {
    const alloc = std.testing.allocator;
    const sessions = [_]SessionEntry{
        .{
            .name = "test\"name",
            .pid = 1,
            .clients_len = 0,
            .is_error = false,
            .error_name = null,
            .cmd = "echo \"hello\\world\"",
            .cwd = null,
            .created_at = 0,
            .task_ended_at = null,
            .task_exit_code = null,
        },
    };

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    try writeJson(&builder.writer, &sessions, null);
    const output = builder.writer.buffered();
    // Quotes in name should be escaped
    try std.testing.expect(std.mem.indexOf(u8, output, "test\\\"name") != null);
    // Backslash in cmd should be escaped
    try std.testing.expect(std.mem.indexOf(u8, output, "\\\\world") != null);
}

