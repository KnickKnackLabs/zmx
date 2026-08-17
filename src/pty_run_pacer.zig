const std = @import("std");

/// Pace command injection into an interactive PTY so readline consumes the
/// complete visible line before its final carriage return arrives.
pub const Pacer = struct {
    const max_chunk_bytes = 128;
    const chunk_delay = std.Io.Duration.fromMilliseconds(10);

    remaining: usize = 0,
    next_write: std.Io.Timestamp = .zero,

    pub fn begin(self: *Pacer, pending_bytes: usize) void {
        self.remaining = pending_bytes;
        self.next_write = .zero;
    }

    pub fn allowance(self: Pacer, now: std.Io.Timestamp, pending_bytes: usize) usize {
        if (pending_bytes == 0) return 0;
        if (self.remaining == 0) return pending_bytes;
        if (now.nanoseconds < self.next_write.nanoseconds) return 0;
        return @min(pending_bytes, self.remaining, max_chunk_bytes);
    }

    pub fn pollTimeout(self: Pacer, now: std.Io.Timestamp, pending_bytes: usize) ?i32 {
        if (pending_bytes == 0 or self.remaining == 0) return null;
        const wait_ns = self.next_write.nanoseconds - now.nanoseconds;
        if (wait_ns <= 0) return null;
        const rounded_ms = @divTrunc(wait_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@min(rounded_ms, std.math.maxInt(i32)));
    }

    pub fn recordWrite(self: *Pacer, now: std.Io.Timestamp, written: usize) void {
        if (self.remaining == 0) return;
        self.remaining -= @min(self.remaining, written);
        self.next_write = if (self.remaining == 0)
            .zero
        else
            now.addDuration(chunk_delay);
    }

    pub fn reset(self: *Pacer) void {
        self.* = .{};
    }
};

test "run input pacing waits between bounded PTY chunks" {
    var pacer = Pacer{};
    pacer.begin(600);

    const start = std.Io.Timestamp.zero;
    try std.testing.expectEqual(@as(usize, 128), pacer.allowance(start, 600));
    pacer.recordWrite(start, 128);
    try std.testing.expectEqual(@as(usize, 0), pacer.allowance(
        std.Io.Timestamp.fromNanoseconds(9 * std.time.ns_per_ms),
        472,
    ));
    try std.testing.expectEqual(@as(?i32, 1), pacer.pollTimeout(
        std.Io.Timestamp.fromNanoseconds(9 * std.time.ns_per_ms),
        472,
    ));
    try std.testing.expectEqual(@as(usize, 128), pacer.allowance(
        std.Io.Timestamp.fromNanoseconds(10 * std.time.ns_per_ms),
        472,
    ));
}
