comptime {
    _ = @import("main.zig");
    _ = @import("util.zig");
    _ = @import("socket.zig");
    _ = @import("ipc.zig");
    _ = @import("label.zig");
    _ = @import("list.zig");
    _ = @import("signal.zig");
    _ = @import("loop.zig");
    _ = @import("cfg.zig");
    _ = @import("daemonize.zig");
    _ = @import("control.zig");
    _ = @import("control/adapter.zig");
    _ = @import("control/client.zig");
    _ = @import("control/daemon.zig");
    _ = @import("control/frame.zig");
    _ = @import("pty_run_pacer.zig");
}
