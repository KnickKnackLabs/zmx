//! Tracked client environments: line records on IPC and quoted POSIX shell output.
const std = @import("std");

pub const ValidationError = error{ InvalidEnvName, InvalidEnvValue, InvalidEnvRecord };

fn validateName(name: []const u8) error{InvalidEnvName}!void {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_'))
        return error.InvalidEnvName;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidEnvName;
    }
}

fn validateValue(value: []const u8) error{InvalidEnvValue}!void {
    if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return error.InvalidEnvValue;
}

/// Validate before returning any bytes for forwarding. Values cannot introduce
/// additional records into the newline-delimited upstream wire format.
pub fn capture(
    alloc: std.mem.Allocator,
    names: []const u8,
    env: *const std.process.Environ.Map,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var iter = std.mem.splitScalar(u8, names, ',');
    while (iter.next()) |entry| {
        const name = std.mem.trim(u8, entry, " \t\r\n");
        if (name.len == 0) continue;
        try validateName(name);
        if (env.get(name)) |value| {
            try validateValue(value);
            try out.appendSlice(alloc, name);
            try out.append(alloc, '=');
            try out.appendSlice(alloc, value);
        } else {
            try out.append(alloc, '-');
            try out.appendSlice(alloc, name);
        }
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

const Entry = struct {
    name: []const u8,
    value: ?[]const u8,
};

const Iterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    fn init(payload: []const u8) Iterator {
        return .{ .lines = std.mem.splitScalar(u8, payload, '\n') };
    }

    fn next(self: *Iterator) ValidationError!?Entry {
        while (self.lines.next()) |line| {
            if (line.len == 0) continue;
            if (line[0] == '-') {
                try validateName(line[1..]);
                return .{ .name = line[1..], .value = null };
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidEnvRecord;
            const name = line[0..eq];
            const value = line[eq + 1 ..];
            try validateName(name);
            try validateValue(value);
            return .{ .name = name, .value = value };
        }
        return null;
    }
};

pub fn validate(payload: []const u8) ValidationError!void {
    var it = Iterator.init(payload);
    while (try it.next()) |_| {}
}

pub fn getValue(name: []const u8, payload: []const u8) (ValidationError || error{EnvVarNotFound})![]const u8 {
    try validateName(name);
    try validate(payload);
    var it = Iterator.init(payload);
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value orelse error.EnvVarNotFound;
    }
    return error.EnvVarNotFound;
}

pub fn writeShell(w: *std.Io.Writer, payload: []const u8) !void {
    // Check the entire reply before emitting any commands, including when a
    // malformed record follows valid ones that would fill the output buffer.
    try validate(payload);
    var it = Iterator.init(payload);
    while (try it.next()) |entry| {
        if (entry.value) |value| {
            try w.print("export {s}='", .{entry.name});
            for (value) |c| {
                if (c == '\'') {
                    try w.writeAll("'\\''");
                } else {
                    try w.writeByte(c);
                }
            }
            try w.writeAll("';\n");
        } else {
            try w.print("unset {s};\n", .{entry.name});
        }
    }
}

test "capture preserves set, empty and unset values and selection whitespace" {
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("DISPLAY", ":1");
    try env.put("_EMPTY2", "");
    const payload = try capture(alloc, "DISPLAY, _EMPTY2, , SSH_AUTH_SOCK,", &env);
    defer alloc.free(payload);
    try std.testing.expectEqualStrings("DISPLAY=:1\n_EMPTY2=\n-SSH_AUTH_SOCK\n", payload);
    try std.testing.expectEqualStrings("", try getValue("_EMPTY2", payload));
    try std.testing.expectError(error.EnvVarNotFound, getValue("SSH_AUTH_SOCK", payload));
    try std.testing.expectError(error.EnvVarNotFound, getValue("MISSING", payload));
    const empty = try capture(alloc, "", &env);
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "capture rejects invalid names whether set or unset" {
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try std.testing.expectError(error.InvalidEnvName, capture(alloc, "A=B", &env));
    const names = [_][]const u8{ "2BAD", "A-B", "A B", "A\nB", "X;touch injected;#", "$(id)", "é" };
    for (names) |name| {
        try std.testing.expectError(error.InvalidEnvName, capture(alloc, name, &env));
        try env.put(name, "value");
        try std.testing.expectError(error.InvalidEnvName, capture(alloc, name, &env));
    }
}

test "capture rejects record injection and unrepresentable values" {
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    for ([_][]const u8{ "\n", "safe\nINJECTED=value", "safe\n-X;touch injected;#", "a\rb", "a\x00b" }) |value| {
        try env.put("VALUE", value);
        try std.testing.expectError(error.InvalidEnvValue, capture(alloc, "UNSET,VALUE", &env));
    }
}

test "received records reject malformed set and unset names and invalid values" {
    const Case = struct { payload: []const u8, err: ValidationError };
    for ([_]Case{
        .{ .payload = "=value\n", .err = error.InvalidEnvName },
        .{ .payload = "2BAD=value\n", .err = error.InvalidEnvName },
        .{ .payload = "X;touch injected;#=value\n", .err = error.InvalidEnvName },
        .{ .payload = "-X;touch injected;#\n", .err = error.InvalidEnvName },
        .{ .payload = "-\n", .err = error.InvalidEnvName },
        .{ .payload = "-X=oops\n", .err = error.InvalidEnvName },
        .{ .payload = "MISSING_DELIMITER\n", .err = error.InvalidEnvRecord },
        .{ .payload = "VALUE=a\x00b\n", .err = error.InvalidEnvValue },
        .{ .payload = "VALUE=a\rb\n", .err = error.InvalidEnvValue },
    }) |case| {
        try std.testing.expectError(case.err, validate(case.payload));
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try std.testing.expectError(case.err, writeShell(&out.writer, case.payload));
        try std.testing.expectEqual(@as(usize, 0), out.written().len);
    }
}

test "shell output and value lookup validate even a late malformed record" {
    const payload = "GOOD=" ++ ("x" ** 5000) ++ "\n-X;touch injected;#\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidEnvName, writeShell(&out.writer, payload));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expectError(error.InvalidEnvName, getValue("GOOD", payload));
}

test "shell output quotes value syntax literally and preserves empty versus unset" {
    const payload = "VALUE=it's $(id); `id` \\ = \t café\nEMPTY=\n-MISSING\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeShell(&out.writer, payload);
    try std.testing.expectEqualStrings(
        "export VALUE='it'\\''s $(id); `id` \\ = \t café';\nexport EMPTY='';\nunset MISSING;\n",
        out.written(),
    );
    try std.testing.expectEqualStrings("it's $(id); `id` \\ = \t café", try getValue("VALUE", payload));
}
