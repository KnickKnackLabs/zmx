const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const build_options = @import("build_options");
const ghostty_vt = @import("ghostty-vt");
const clap = @import("clap");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const completions = @import("completions.zig");
const util = @import("util.zig");
const list_mod = @import("list.zig");
const output = @import("output.zig");
const cross = @import("cross.zig");
const socket = @import("socket.zig");

pub const version = build_options.version;
pub const git_sha = build_options.git_sha;
pub const ghostty_version = build_options.ghostty_version;

var log_system = log.LogSystem{};

pub const std_options: std.Options = .{
    .logFn = zmxLogFn,
    .log_level = .debug,
};

fn zmxLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    log_system.log(level, scope, format, args);
}

var sigwinch_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var sigterm_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/lib/std/posix.zig#L3505
const O_NONBLOCK: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");

// ---------------------------------------------------------------------------
// CLI definitions (zig-clap)
// ---------------------------------------------------------------------------

const Command = enum {
    attach,
    run,
    send,
    print,
    write,
    tail,
    detach,
    list,
    completions,
    kill,
    rm,
    history,
    wait,
    version,
    help,
};

/// Parse a command name, accepting both full names and short aliases.
fn parseCommand(in: []const u8) error{NameNotPartOfEnum}!Command {
    const aliases = .{
        .{ "attach", Command.attach },
        .{ "a", Command.attach },
        .{ "run", Command.run },
        .{ "r", Command.run },
        .{ "send", Command.send },
        .{ "s", Command.send },
        .{ "print", Command.print },
        .{ "p", Command.print },
        .{ "write", Command.write },
        .{ "wr", Command.write },
        .{ "tail", Command.tail },
        .{ "t", Command.tail },
        .{ "detach", Command.detach },
        .{ "d", Command.detach },
        .{ "list", Command.list },
        .{ "l", Command.list },
        .{ "completions", Command.completions },
        .{ "c", Command.completions },
        .{ "kill", Command.kill },
        .{ "k", Command.kill },
        .{ "rm", Command.rm },
        .{ "history", Command.history },
        .{ "hi", Command.history },
        .{ "wait", Command.wait },
        .{ "w", Command.wait },
        .{ "version", Command.version },
        .{ "v", Command.version },
        .{ "help", Command.help },
        .{ "h", Command.help },
    };
    inline for (aliases) |entry| {
        if (std.mem.eql(u8, in, entry[0])) return entry[1];
    }
    return error.NameNotPartOfEnum;
}

/// Top-level parameters: --help, --version, and the subcommand positional.
const main_params = clap.parseParamsComptime(
    \\-h, --help     Display this help message
    \\-v, --version  Show version information
    \\<command>
    \\
);

const main_parsers = .{
    .command = parseCommand,
};

/// Parameters for `list`.
const list_params = clap.parseParamsComptime(
    \\-h, --help    Display this help message
    \\    --short   Use short output format
    \\    --json    Output as JSON
    \\
);

/// Parameters for `history`.
const history_params = clap.parseParamsComptime(
    \\-h, --help   Display this help message
    \\    --vt     Output with VT escape sequences
    \\    --html   Output as HTML
    \\<str>
    \\
);

/// Parameters for `kill`.
const kill_params = clap.parseParamsComptime(
    \\-h, --help    Display this help message
    \\    --force   Force kill by removing the socket file
    \\<str>...
    \\
);

/// Parameters for `rm`.
const rm_params = clap.parseParamsComptime(
    \\-h, --help   Display this help message
    \\<str>...
    \\
);

/// Parameters for `completions`.
const completions_params = clap.parseParamsComptime(
    \\-h, --help   Display this help message
    \\<str>
    \\
);

fn isHelpFlag(arg: ?[]const u8) bool {
    if (arg) |a| {
        return std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h");
    }
    return false;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "parseCommand — full names" {
    try std.testing.expectEqual(Command.attach, try parseCommand("attach"));
    try std.testing.expectEqual(Command.run, try parseCommand("run"));
    try std.testing.expectEqual(Command.detach, try parseCommand("detach"));
    try std.testing.expectEqual(Command.list, try parseCommand("list"));
    try std.testing.expectEqual(Command.completions, try parseCommand("completions"));
    try std.testing.expectEqual(Command.kill, try parseCommand("kill"));
    try std.testing.expectEqual(Command.rm, try parseCommand("rm"));
    try std.testing.expectEqual(Command.history, try parseCommand("history"));
    try std.testing.expectEqual(Command.wait, try parseCommand("wait"));
    try std.testing.expectEqual(Command.version, try parseCommand("version"));
    try std.testing.expectEqual(Command.help, try parseCommand("help"));
}

test "parseCommand — aliases" {
    try std.testing.expectEqual(Command.attach, try parseCommand("a"));
    try std.testing.expectEqual(Command.run, try parseCommand("r"));
    try std.testing.expectEqual(Command.detach, try parseCommand("d"));
    try std.testing.expectEqual(Command.list, try parseCommand("l"));
    try std.testing.expectEqual(Command.completions, try parseCommand("c"));
    try std.testing.expectEqual(Command.kill, try parseCommand("k"));
    try std.testing.expectEqual(Command.rm, try parseCommand("rm"));
    try std.testing.expectEqual(Command.history, try parseCommand("hi"));
    try std.testing.expectEqual(Command.wait, try parseCommand("w"));
    try std.testing.expectEqual(Command.version, try parseCommand("v"));
    try std.testing.expectEqual(Command.help, try parseCommand("h"));
}

test "parseCommand — unknown commands" {
    try std.testing.expectError(error.NameNotPartOfEnum, parseCommand("foo"));
    try std.testing.expectError(error.NameNotPartOfEnum, parseCommand(""));
    try std.testing.expectError(error.NameNotPartOfEnum, parseCommand("att"));
    try std.testing.expectError(error.NameNotPartOfEnum, parseCommand("ATTACH"));
}

test "isHelpFlag" {
    try std.testing.expect(isHelpFlag("--help"));
    try std.testing.expect(isHelpFlag("-h"));
    try std.testing.expect(!isHelpFlag(null));
    try std.testing.expect(!isHelpFlag("--version"));
    try std.testing.expect(!isHelpFlag("help"));
    try std.testing.expect(!isHelpFlag(""));
}

pub fn main() !void {
    // use c_allocator to avoid "reached unreachable code" panic in DebugAllocator when forking
    const alloc = std.heap.c_allocator;

    // Every subcommand may write to a Unix-domain socket; a peer that
    // disappears between probe and send would otherwise kill us before
    // write() can return BrokenPipe. Inherited across fork, so this also
    // covers the daemon.
    ignoreSigpipe();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // skip program name

    var cfg = try Cfg.init(alloc);
    defer cfg.deinit(alloc);

    const log_path = try std.fs.path.join(alloc, &.{ cfg.log_dir, "zmx.log" });
    defer alloc.free(log_path);
    try log_system.init(alloc, log_path, cfg.log_mode);
    defer log_system.deinit();

    // Parse top-level: --help, --version, and the subcommand.
    // terminating_positional stops parsing after the command so the remaining
    // iterator can be consumed by each subcommand handler.
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &args, .{
        .diagnostic = &diag,
        .allocator = alloc,
        .terminating_positional = 0,
    }) catch |err| {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;
        if (err == error.NameNotPartOfEnum) {
            // The user typed an unknown command. diag.arg isn't populated for
            // positional value-parse errors, so report generically.
            output.printError("unknown command — run 'zmx --help' for usage", .{}) catch {};
        } else {
            diag.reportToFile(.stderr(), err) catch {};
        }
        stderr.flush() catch {};
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.help != 0) return help();
    if (res.args.version != 0) return printVersion(alloc, &cfg);

    const command = res.positionals[0] orelse return list(&cfg, .table);

    switch (command) {
        .help => return help(),
        .version => return printVersion(alloc, &cfg),
        .detach => {
            if (isHelpFlag(args.next())) {
                return subcommandUsage("detach", "", "Detach all clients from current session (ctrl+\\ for current client)");
            }
            return detachAll(&cfg);
        },

        .list => {
            var list_diag = clap.Diagnostic{};
            var list_res = clap.parseEx(clap.Help, &list_params, clap.parsers.default, &args, .{
                .diagnostic = &list_diag,
                .allocator = alloc,
            }) catch |err| {
                list_diag.reportToFile(.stderr(), err) catch {};
                std.process.exit(1);
            };
            defer list_res.deinit();

            if (list_res.args.help != 0) {
                return subcommandUsage("list", "[--short] [--json]", "List active sessions");
            }
            if (list_res.args.json != 0 and list_res.args.short != 0) {
                std.log.err("cannot use --json and --short together", .{});
                return;
            }
            const mode: list_mod.Mode = if (list_res.args.json != 0)
                .json
            else if (list_res.args.short != 0)
                .short
            else
                .table;
            return list(&cfg, mode);
        },

        .completions => {
            var comp_diag = clap.Diagnostic{};
            var comp_res = clap.parseEx(clap.Help, &completions_params, clap.parsers.default, &args, .{
                .diagnostic = &comp_diag,
                .allocator = alloc,
            }) catch |err| {
                comp_diag.reportToFile(.stderr(), err) catch {};
                std.process.exit(1);
            };
            defer comp_res.deinit();

            if (comp_res.args.help != 0) {
                return subcommandUsage("completions", "<shell>", "Completion scripts for shell integration (bash, zsh, or fish)");
            }
            const arg = comp_res.positionals[0] orelse return;
            const shell = completions.Shell.fromString(arg) orelse return;
            return printCompletions(shell);
        },

        .history => {
            var hist_diag = clap.Diagnostic{};
            var hist_res = clap.parseEx(clap.Help, &history_params, clap.parsers.default, &args, .{
                .diagnostic = &hist_diag,
                .allocator = alloc,
            }) catch |err| {
                hist_diag.reportToFile(.stderr(), err) catch {};
                std.process.exit(1);
            };
            defer hist_res.deinit();

            if (hist_res.args.help != 0) {
                return subcommandUsage("history", "<name> [--vt|--html]", "Output session scrollback");
            }

            var format: util.HistoryFormat = .plain;
            if (hist_res.args.vt != 0 and hist_res.args.html != 0) {
                const msg = "error: --vt and --html are mutually exclusive\n";
                std.fs.File.stderr().writeAll(msg) catch {};
                std.process.exit(1);
            }
            if (hist_res.args.vt != 0) format = .vt;
            if (hist_res.args.html != 0) format = .html;

            const sesh_env = socket.getSeshNameFromEnv();
            const sesh = try socket.getSeshName(alloc, hist_res.positionals[0] orelse sesh_env);
            defer alloc.free(sesh);
            return history(&cfg, sesh, format);
        },

        .attach => {
            const first_arg = args.next();
            if (isHelpFlag(first_arg)) {
                return subcommandUsage("attach", "<name> [command...]", "Attach to session, creating session if needed");
            }
            const session_name = first_arg orelse "";

            var command_args: std.ArrayList([]const u8) = .empty;
            defer command_args.deinit(alloc);
            while (args.next()) |arg| {
                try command_args.append(alloc, arg);
            }

            const clients = try std.ArrayList(*Client).initCapacity(alloc, 10);
            var cmd: ?[][]const u8 = null;
            if (command_args.items.len > 0) {
                cmd = command_args.items;
            }

            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = std.posix.getcwd(&cwd_buf) catch "";

            const sesh = try socket.getSeshName(alloc, session_name);
            defer alloc.free(sesh);
            var daemon = Daemon{
                .running = true,
                .cfg = &cfg,
                .alloc = alloc,
                .clients = clients,
                .session_name = sesh,
                .socket_path = undefined,
                .pid = undefined,
                .command = cmd,
                .cwd = cwd,
                .created_at = @intCast(std.time.timestamp()),
            };
            daemon.socket_path = socket.getSocketPath(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
                error.NameTooLong => return socket.printSessionNameTooLong(sesh, cfg.socket_dir),
                error.OutOfMemory => return err,
            };
            std.log.info("socket path={s}", .{daemon.socket_path});
            return attach(&daemon);
        },

        .run => {
            const first_arg = args.next();
            if (isHelpFlag(first_arg)) {
                return subcommandUsage("run", "<name> [-d] [command...]", "Send command without attaching, creating session if needed");
            }
            const session_name = first_arg orelse "";

            var cmd_args_raw: std.ArrayList([]const u8) = .empty;
            defer cmd_args_raw.deinit(alloc);
            // Recognize -d / --detach anywhere after the session name.
            // KKL's `run` is already non-blocking (ack-then-return), so
            // the flag is accepted for compatibility with upstream and
            // the bats integration suite but does not change behavior.
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detach")) {
                    continue;
                }
                try cmd_args_raw.append(alloc, arg);
            }
            const clients = try std.ArrayList(*Client).initCapacity(alloc, 10);

            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = std.posix.getcwd(&cwd_buf) catch "";

            const sesh = try socket.getSeshName(alloc, session_name);
            defer alloc.free(sesh);
            var daemon = Daemon{
                .running = true,
                .cfg = &cfg,
                .alloc = alloc,
                .clients = clients,
                .session_name = sesh,
                .socket_path = undefined,
                .pid = undefined,
                .command = null,
                .cwd = cwd,
                .created_at = @intCast(std.time.timestamp()),
                .is_task_mode = true,
                .task_command = cmd_args_raw.items,
            };
            daemon.socket_path = socket.getSocketPath(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
                error.NameTooLong => return socket.printSessionNameTooLong(sesh, cfg.socket_dir),
                error.OutOfMemory => return err,
            };
            std.log.info("socket path={s}", .{daemon.socket_path});
            return run(&daemon, cmd_args_raw.items);
        },

        .send, .print => |which| {
            const first_arg = args.next();
            if (isHelpFlag(first_arg)) {
                const label = if (which == .send) "send" else "print";
                const desc = if (which == .send)
                    "Send raw bytes to session PTY input (no marker, no CR appended)"
                else
                    "Inject text into session output stream (visible to attached clients)";
                return subcommandUsage(label, "<name> <text...>", desc);
            }
            const session_name = first_arg orelse return error.SessionNameRequired;
            if (session_name.len == 0) return error.SessionNameRequired;

            var text_parts: std.ArrayList([]const u8) = .empty;
            defer text_parts.deinit(alloc);
            while (args.next()) |arg| {
                try text_parts.append(alloc, arg);
            }

            const sesh = try socket.getSeshName(alloc, session_name);
            defer alloc.free(sesh);
            const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
                error.NameTooLong => return socket.printSessionNameTooLong(sesh, cfg.socket_dir),
                error.OutOfMemory => return err,
            };
            defer alloc.free(socket_path);

            const tag: ipc.Tag = if (which == .send) .Input else .Output;
            return sendRaw(&cfg, sesh, socket_path, text_parts.items, tag);
        },

        .write => {
            const first_arg = args.next();
            if (isHelpFlag(first_arg)) {
                return subcommandUsage(
                    "write",
                    "<name> <file_path>",
                    "Write stdin to file_path inside the session shell (works over SSH)",
                );
            }
            const session_name = first_arg orelse return error.SessionNameRequired;
            if (session_name.len == 0) return error.SessionNameRequired;
            const file_path = args.next() orelse return error.FilePathRequired;

            const sesh = try socket.getSeshName(alloc, session_name);
            defer alloc.free(sesh);

            var daemon = Daemon{
                .running = true,
                .cfg = &cfg,
                .alloc = alloc,
                .clients = try std.ArrayList(*Client).initCapacity(alloc, 0),
                .session_name = sesh,
                .socket_path = undefined,
                .pid = undefined,
                .created_at = @intCast(std.time.timestamp()),
            };
            daemon.socket_path = socket.getSocketPath(alloc, cfg.socket_dir, sesh) catch |err| switch (err) {
                error.NameTooLong => return socket.printSessionNameTooLong(sesh, cfg.socket_dir),
                error.OutOfMemory => return err,
            };
            defer alloc.free(daemon.socket_path);
            return writeFile(&daemon, file_path);
        },

        .tail => {
            return error.NotImplemented; // see follow-up: port upstream tail() loop
        },

        .kill => {
            var kill_diag = clap.Diagnostic{};
            var kill_res = clap.parseEx(clap.Help, &kill_params, clap.parsers.default, &args, .{
                .diagnostic = &kill_diag,
                .allocator = alloc,
            }) catch |err| {
                kill_diag.reportToFile(.stderr(), err) catch {};
                std.process.exit(1);
            };
            defer kill_res.deinit();

            if (kill_res.args.help != 0) {
                return subcommandUsage("kill", "<name>... [--force]", "Kill a session and all attached clients");
            }

            const force = kill_res.args.force != 0;

            var args_raw: std.ArrayList([]const u8) = .empty;
            defer {
                for (args_raw.items) |sesh| {
                    alloc.free(sesh);
                }
                args_raw.deinit(alloc);
            }
            for (kill_res.positionals[0]) |session_name| {
                const sesh = try socket.getSeshName(alloc, session_name);
                try args_raw.append(alloc, sesh);
            }
            // if no args are provided we assume they want to kill all sessions matching the
            // prefix.
            if (args_raw.items.len == 0) {
                const prefix = socket.getSeshPrefix();
                if (prefix.len == 0) {
                    return error.SessionNameRequired;
                }
                try args_raw.append(alloc, try alloc.dupe(u8, prefix));
            }
            var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
            defer {
                for (sessions.items) |session| {
                    session.deinit(alloc);
                }
                sessions.deinit(alloc);
            }
            for (sessions.items) |session| {
                for (args_raw.items) |prefix| {
                    if (!std.mem.startsWith(u8, session.name, prefix)) {
                        continue;
                    }
                    kill(&cfg, session.name, force) catch |err| {
                        output.printError("kill {s}: {s}", .{ session.name, @errorName(err) }) catch {};
                        break;
                    };
                    output.printSuccess("killed {s}", .{session.name}) catch {};
                    break;
                }
            }
            return;
        },

        .rm => {
            var rm_diag = clap.Diagnostic{};
            var rm_res = clap.parseEx(clap.Help, &rm_params, clap.parsers.default, &args, .{
                .diagnostic = &rm_diag,
                .allocator = alloc,
            }) catch |err| {
                rm_diag.reportToFile(.stderr(), err) catch {};
                std.process.exit(1);
            };
            defer rm_res.deinit();

            if (rm_res.args.help != 0) {
                return subcommandUsage("rm", "<name>...", "Remove a session (kill if running, delete socket)");
            }

            var args_raw: std.ArrayList([]const u8) = .empty;
            defer {
                for (args_raw.items) |sesh| {
                    alloc.free(sesh);
                }
                args_raw.deinit(alloc);
            }
            for (rm_res.positionals[0]) |session_name| {
                const sesh = try socket.getSeshName(alloc, session_name);
                try args_raw.append(alloc, sesh);
            }
            // Unlike kill/wait, rm does not fall back to getSeshPrefix() when
            // called with no arguments. Removing all prefix-matching sessions
            // by default is too destructive.
            if (args_raw.items.len == 0) {
                return error.SessionNameRequired;
            }
            var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
            defer {
                for (sessions.items) |session| {
                    session.deinit(alloc);
                }
                sessions.deinit(alloc);
            }
            for (sessions.items) |session| {
                for (args_raw.items) |prefix| {
                    if (std.mem.startsWith(u8, session.name, prefix)) {
                        rmSession(&cfg, session.name) catch |err| {
                            output.printError("rm {s}: {s}", .{ session.name, @errorName(err) }) catch {};
                            break;
                        };
                        output.printSuccess("removed {s}", .{session.name}) catch {};
                        break;
                    }
                }
            }
            return;
        },

        .wait => {
            const first_arg = args.next();
            if (isHelpFlag(first_arg)) {
                return subcommandUsage("wait", "<name>...", "Wait for session tasks to complete");
            }

            var args_raw: std.ArrayList([]const u8) = .empty;
            defer {
                for (args_raw.items) |sesh| {
                    alloc.free(sesh);
                }
                args_raw.deinit(alloc);
            }
            // Include the first arg we already consumed (if it wasn't --help)
            if (first_arg) |fa| {
                const sesh = try socket.getSeshName(alloc, fa);
                try args_raw.append(alloc, sesh);
            }
            while (args.next()) |session_name| {
                const sesh = try socket.getSeshName(alloc, session_name);
                try args_raw.append(alloc, sesh);
            }
            // if no args are provided we assume they want to wait for all sessions matching the
            // prefix.
            if (args_raw.items.len == 0) {
                const prefix = socket.getSeshPrefix();
                if (prefix.len == 0) {
                    return error.SessionNameRequired;
                }
                try args_raw.append(alloc, prefix);
            }
            return wait(&cfg, args_raw);
        },
    }
}

/// Client represents each terminal that has connected to a session.
///
/// Multiple Clients can connect to a single session.
const Client = struct {
    alloc: std.mem.Allocator,
    socket_fd: i32,
    has_pending_output: bool = false,
    read_buf: ipc.SocketBuffer,
    write_buf: std.ArrayList(u8),

    pub fn deinit(self: *Client) void {
        posix.close(self.socket_fd);
        self.read_buf.deinit();
        self.write_buf.deinit(self.alloc);
    }
};

/// Cfg is zmx's configuration container.
///
/// The purpose of this container is to hold anything that can be modified by the user.
const Cfg = struct {
    socket_dir: []const u8,
    log_dir: []const u8,
    max_scrollback: usize = 10_000_000,
    dir_mode: u32 = 0o750,
    log_mode: u32 = 0o640,

    pub fn init(alloc: std.mem.Allocator) !Cfg {
        const socket_dir = try socketDir(alloc);
        const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{socket_dir});
        errdefer alloc.free(log_dir);

        const dir_mode = if (std.posix.getenv("ZMX_DIR_MODE")) |m|
            std.fmt.parseInt(u32, m, 8) catch 0o750
        else
            0o750;

        const log_mode = if (std.posix.getenv("ZMX_LOG_MODE")) |m|
            std.fmt.parseInt(u32, m, 8) catch 0o640
        else
            0o640;

        var cfg = Cfg{
            .socket_dir = socket_dir,
            .log_dir = log_dir,
            .dir_mode = dir_mode,
            .log_mode = log_mode,
        };

        try cfg.mkdir();

        return cfg;
    }

    fn socketDir(alloc: std.mem.Allocator) ![]const u8 {
        const tmpdir = std.mem.trimRight(u8, posix.getenv("TMPDIR") orelse "/tmp", "/");
        const uid = posix.getuid();

        const socket_dir: []const u8 = if (posix.getenv("ZMX_DIR")) |zmxdir|
            try alloc.dupe(u8, zmxdir)
        else if (posix.getenv("XDG_RUNTIME_DIR")) |xdg_runtime|
            try std.fmt.allocPrint(alloc, "{s}/zmx", .{xdg_runtime})
        else
            try std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });
        errdefer alloc.free(socket_dir);

        return socket_dir;
    }

    pub fn deinit(self: *Cfg, alloc: std.mem.Allocator) void {
        if (self.socket_dir.len > 0) alloc.free(self.socket_dir);
        if (self.log_dir.len > 0) alloc.free(self.log_dir);
    }

    pub fn mkdir(self: *Cfg) !void {
        posix.mkdirat(posix.AT.FDCWD, self.socket_dir, @intCast(self.dir_mode)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        posix.mkdirat(posix.AT.FDCWD, self.log_dir, @intCast(self.dir_mode)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
};

const EnsureSessionResult = struct {
    created: bool,
    is_daemon: bool,
};

/// Daemon is responsible for managing a zmx session.
///
/// It holds all the state for a running session.  Instead of a single daemon for all sessions, we
/// create a daemon for every session.  This has some benefits. The ipc communication between
/// session clients and the daemon doesn't need to be tagged with the session name.  If a daemon
/// crashes for one session won't crash all the other sessions.
///
/// Conceptually it's also much simpler to reason about.
const Daemon = struct {
    cfg: *Cfg,
    alloc: std.mem.Allocator,
    clients: std.ArrayList(*Client),
    // Controls which client is the leader. The leader controls terminal
    // state and cols/rows of the session.
    leader_client_fd: ?i32 = null,
    session_name: []const u8,
    socket_path: []const u8,
    running: bool,
    pid: i32,
    command: ?[]const []const u8 = null,
    cwd: []const u8 = "",
    has_pty_output: bool = false,
    has_had_client: bool = false,
    created_at: u64, // unix timestamp (ns)
    is_task_mode: bool = false, // flag for when session is run as a task
    task_exit_code: ?u8 = null, // null = running or n/a, set when task completes
    task_ended_at: ?u64 = null, // timestamp when task exited
    task_command: ?[]const []const u8 = null,
    is_fish: bool = false, // true if the session's foreground shell is fish
    pty_fd: i32 = -1, // set by daemonLoop so handleRun can probe the foreground process
    pty_write_buf: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Daemon) void {
        self.clients.deinit(self.alloc);
        self.pty_write_buf.deinit(self.alloc);
        self.alloc.free(self.socket_path);
    }

    pub fn shutdown(self: *Daemon) void {
        std.log.info("shutting down daemon session_name={s}", .{self.session_name});
        self.running = false;

        for (self.clients.items) |client| {
            client.deinit();
            self.alloc.destroy(client);
        }
        self.clients.clearRetainingCapacity();
    }

    pub fn closeClient(self: *Daemon, client: *Client, i: usize, shutdown_on_last: bool) bool {
        const fd = client.socket_fd;
        // leader is disconnected; clear ref so another client can claim
        // leadership on next user input (fixes neurosnap/zmx#141).
        if (self.leader_client_fd == client.socket_fd) {
            std.log.info(
                "unsetting leader session={s} fd={d}",
                .{ self.session_name, client.socket_fd },
            );
            self.leader_client_fd = null;
        }
        client.deinit();
        self.alloc.destroy(client);
        _ = self.clients.orderedRemove(i);
        std.log.info("client disconnected fd={d} remaining={d}", .{ fd, self.clients.items.len });
        if (shutdown_on_last and self.clients.items.len == 0) {
            self.shutdown();
            return true;
        }
        return false;
    }

    fn setLeader(self: *Daemon, client: *Client) !void {
        std.log.info("setting new leader client_fd={d}", .{client.socket_fd});
        self.leader_client_fd = client.socket_fd;
        // Ask the new leader to send back its window size so we can
        // resize the pty and ghostty state to match.
        try ipc.appendMessage(self.alloc, &client.write_buf, .Resize, "");
        client.has_pending_output = true;
    }

    /// Runs in the forked child. Either execs or returns an error (caller
    /// must exit on error -- returning would fall through to parent code).
    fn execChild(self: *Daemon) !noreturn {
        const alloc = std.heap.c_allocator;

        // main() set SIGPIPE to SIG_IGN, which (unlike handlers) survives
        // exec. Restore the default so the shell and its children behave
        // normally (e.g. `yes | head` should exit 141 via SIGPIPE).
        const dfl: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.PIPE, &dfl, null);

        const session_env = try std.fmt.allocPrintSentinel(
            alloc,
            "ZMX_SESSION={s}",
            .{self.session_name},
            0,
        );
        _ = cross.c.putenv(session_env.ptr);

        if (self.command) |cmd_args| {
            const argv = try alloc.allocSentinel(?[*:0]const u8, cmd_args.len, null);
            for (cmd_args, 0..) |arg, i| {
                argv[i] = try alloc.dupeZ(u8, arg);
            }
            const err = std.posix.execvpeZ(argv[0].?, argv.ptr, std.c.environ);
            std.log.err("execvpe failed: cmd={s} err={s}", .{ cmd_args[0], @errorName(err) });
            std.posix.exit(1);
        }

        const shell = util.detectShell();
        // Use "-shellname" as argv[0] to signal login shell (traditional method)
        const login_shell = try std.fmt.allocPrintSentinel(
            alloc,
            "-{s}",
            .{std.fs.path.basename(shell)},
            0,
        );
        const argv = [_:null]?[*:0]const u8{ login_shell, null };
        const err = std.posix.execveZ(shell, &argv, std.c.environ);
        std.log.err("execve failed: err={s}", .{@errorName(err)});
        std.posix.exit(1);
    }

    /// spawnPty runs forkpty() and executes the shell or shell command the user provides.
    fn spawnPty(self: *Daemon) !c_int {
        const size = ipc.getTerminalSize(posix.STDOUT_FILENO);
        var ws: cross.c.struct_winsize = .{
            .ws_row = size.rows,
            .ws_col = size.cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        var master_fd: c_int = undefined;
        const pid = cross.forkpty(&master_fd, null, null, &ws);
        if (pid < 0) {
            return error.ForkPtyFailed;
        }

        if (pid == 0) { // child pid code path
            // In the forked child, ANY error must exit rather than propagate:
            // a returned error falls through to the parent code path below,
            // running a second daemon on the same socket (or worse, hitting
            // errdefers that delete the parent's socket file).
            execChild(self) catch |err| {
                std.log.err("child setup failed: {s}", .{@errorName(err)});
                std.posix.exit(1);
            };
            unreachable; // execChild either execs or exits, never returns ok
        }
        // master pid code path
        self.pid = pid;
        std.log.info("pty spawned session={s} pid={d}", .{ self.session_name, pid });

        // make pty non-blocking
        const flags = try posix.fcntl(master_fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(master_fd, posix.F.SETFL, flags | O_NONBLOCK);
        return master_fd;
    }

    /// ensureSession "upserts" a session by checking if the unix socket exists already.
    /// If not it creates one and spawns the daemon.
    fn ensureSession(self: *Daemon) !EnsureSessionResult {
        var dir = try std.fs.openDirAbsolute(self.cfg.socket_dir, .{});
        defer dir.close();

        const exists = try socket.sessionExists(dir, self.session_name);
        var should_create = !exists;

        if (exists) {
            if (ipc.probeSession(self.alloc, self.socket_path)) |result| {
                posix.close(result.fd);
                if (self.command != null) {
                    std.log.warn(
                        "session already exists, ignoring command session={s}",
                        .{self.session_name},
                    );
                }
            } else |err| switch (err) {
                // Daemon is definitively gone: safe to replace.
                error.ConnectionRefused => {
                    socket.cleanupStaleSocket(dir, self.session_name);
                    should_create = true;
                },
                // Probe didn't respond in time -- daemon may just be busy.
                // The probe is only to decide create-vs-attach; the session
                // exists, so proceed to attach rather than fail or orphan.
                else => {
                    std.log.warn(
                        "probe slow ({s}), proceeding to attach session={s}",
                        .{ @errorName(err), self.session_name },
                    );
                },
            }
        }

        if (should_create) {
            std.log.info("creating session={s}", .{self.session_name});
            const server_sock_fd = try socket.createSocket(self.socket_path);

            // creates the daemon
            const pid = try posix.fork();
            if (pid == 0) { // child (daemon)
                // becomes the session leader and detaches process from its controlling terminal
                _ = try posix.setsid();

                log_system.deinit();

                // Redirect stdin/stdout/stderr to /dev/null. The daemon
                // communicates via its unix socket, not stdio. Without
                // this, any pipe on FDs 0-2 (e.g. from bats' `run`
                // keyword) stays open for the daemon's lifetime, causing
                // the caller to hang waiting for EOF.
                {
                    const devnull = std.posix.open(
                        "/dev/null",
                        .{ .ACCMODE = .RDWR },
                        0,
                    ) catch |err| {
                        std.log.warn("failed to open /dev/null: {s}", .{@errorName(err)});
                        return err;
                    };
                    inline for (.{ posix.STDIN_FILENO, posix.STDOUT_FILENO, posix.STDERR_FILENO }) |fd| {
                        _ = posix.dup2(devnull, fd) catch |err| {
                            std.log.warn("dup2 /dev/null -> {d}: {s}", .{ fd, @errorName(err) });
                            return err;
                        };
                    }
                    if (devnull > 2) posix.close(devnull);
                }

                // Close file descriptors inherited from the parent that the
                // daemon doesn't need. This prevents test harnesses (like
                // bats) from hanging — they wait for their internal FDs (3+)
                // to close before exiting.
                //
                // Must run BEFORE log_system.init() — otherwise the new log
                // FD gets closed, and spawnPty() reuses that FD number for
                // the PTY master, causing log writes to leak into the terminal.
                //
                // Skip server_sock_fd (needed for IPC) and dir.fd (needed to
                // delete the socket file on shutdown).
                {
                    const dir_fd = @as(i32, @intCast(dir.fd));
                    var fd: i32 = 3;
                    while (fd < 64) : (fd += 1) {
                        if (fd == server_sock_fd or fd == dir_fd) continue;
                        _ = std.c.close(fd);
                    }
                }
                const session_log_name = try std.fmt.allocPrint(
                    self.alloc,
                    "{s}.log",
                    .{self.session_name},
                );
                defer self.alloc.free(session_log_name);
                const session_log_path = try std.fs.path.join(
                    self.alloc,
                    &.{ self.cfg.log_dir, session_log_name },
                );
                defer self.alloc.free(session_log_path);
                try log_system.init(self.alloc, session_log_path, self.cfg.log_mode);

                // If spawnPty fails, clean up here. Once it succeeds,
                // the inner block's defer takes ownership of cleanup to
                // avoid double-closing server_sock_fd on daemonLoop error.
                const pty_fd = self.spawnPty() catch |err| {
                    posix.close(server_sock_fd);
                    dir.deleteFile(self.session_name) catch {};
                    return err;
                };

                defer {
                    self.handleKill();
                    self.deinit();
                    posix.close(pty_fd);
                    _ = posix.waitpid(self.pid, 0);
                    posix.close(server_sock_fd);
                    std.log.info("deleting socket file session_name={s}", .{self.session_name});
                    dir.deleteFile(self.session_name) catch |err| {
                        std.log.warn("failed to delete socket file err={s}", .{@errorName(err)});
                    };
                }

                try daemonLoop(self, server_sock_fd, pty_fd);
                return .{ .created = true, .is_daemon = true };
            }
            posix.close(server_sock_fd);
            std.Thread.sleep(10 * std.time.ns_per_ms);
            return .{ .created = true, .is_daemon = false };
        }

        return .{ .created = false, .is_daemon = false };
    }

    const PTY_WRITE_BUF_MAX = 256 * 1024;

    /// Queue bytes for the PTY's stdin. Flushed by daemonLoop on POLLOUT.
    /// Drops the payload if the buffer is over cap -- same failure mode as
    /// the old direct-write ptyWrite (drop on EAGAIN), just at a 64x higher
    /// threshold. Capping avoids OOM when the shell stops reading; dropping
    /// new (not old) bytes avoids tearing a partially-accepted sequence.
    fn queuePtyInput(self: *Daemon, data: []const u8) void {
        if (data.len == 0) return;
        if (self.pty_write_buf.items.len + data.len > PTY_WRITE_BUF_MAX) {
            std.log.warn(
                "pty input dropped {d} bytes (buffer full, shell not reading)",
                .{data.len},
            );
            return;
        }
        self.pty_write_buf.appendSlice(self.alloc, data) catch |err| {
            std.log.warn(
                "pty input dropped {d} bytes: {s}",
                .{ data.len, @errorName(err) },
            );
        };
    }

    pub fn handleInput(self: *Daemon, client: *Client, payload: []const u8) !void {
        std.log.debug("buffering pty input data={x}", .{payload});
        // Leader forwards everything (ansi escape codes + text).
        if (self.leader_client_fd == client.socket_fd) {
            self.queuePtyInput(payload);
            return;
        }

        // Non-leaders are read-only until they send genuine user input.
        // Non-keyboard traffic (mouse, focus events) does not steal
        // leadership and does not reach the PTY.
        if (util.isUserInput(payload)) {
            try self.setLeader(client);
            self.queuePtyInput(payload);
        }
    }

    pub fn handleInit(
        self: *Daemon,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;

        const resize = std.mem.bytesToValue(ipc.Resize, payload);

        // Serialize terminal state BEFORE resize to capture correct cursor position.
        // Resizing triggers reflow which can move the cursor, and the shell's
        // SIGWINCH-triggered redraw will run after our snapshot is sent.
        // Only serialize on re-attach (has_had_client), not first attach, to avoid
        // interfering with shell initialization (DA1 queries, etc.)
        if (self.has_pty_output and self.has_had_client) {
            const cursor = &term.screens.active.cursor;
            std.log.debug(
                "cursor before serialize: x={d} y={d} pending_wrap={}",
                .{ cursor.x, cursor.y, cursor.pending_wrap },
            );
            if (util.serializeTerminalState(self.alloc, term)) |term_output| {
                std.log.debug("serialize terminal state", .{});
                // Rewrite OSC 133;A to include redraw=0 so the outer
                // terminal does not clear prompt lines on resize
                // (upstream bbbe245, fixes #111).
                const restore_data = util.rewritePromptRedraw(self.alloc, term_output) orelse term_output;
                defer self.alloc.free(term_output);
                defer if (restore_data.ptr != term_output.ptr) self.alloc.free(restore_data);
                ipc.appendMessage(self.alloc, &client.write_buf, .Output, restore_data) catch |err| {
                    std.log.warn(
                        "failed to buffer terminal state for client err={s}",
                        .{@errorName(err)},
                    );
                };
                client.has_pending_output = true;
            }
        }

        var ws: cross.c.struct_winsize = .{
            .ws_row = resize.rows,
            .ws_col = resize.cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = cross.c.ioctl(pty_fd, cross.c.TIOCSWINSZ, &ws);
        // Disable prompt_redraw before resize. The daemon's internal
        // terminal would otherwise clear prompt lines expecting the
        // shell to redraw them, but the shell's redraw goes to the PTY
        // (forwarded to clients), not to this daemon terminal. The
        // clearing corrupts the daemon's snapshot state.
        const saved_prompt_redraw = term.flags.shell_redraws_prompt;
        term.flags.shell_redraws_prompt = .false;
        defer term.flags.shell_redraws_prompt = saved_prompt_redraw;
        try term.resize(self.alloc, resize.cols, resize.rows);

        // Mark that we've had a client init, so subsequent clients get terminal state
        self.has_had_client = true;

        std.log.debug("init resize rows={d} cols={d}", .{ resize.rows, resize.cols });
    }

    pub fn handleResize(
        self: *Daemon,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;

        // Resize is a leader-only operation. If there's no leader yet, the
        // resizing client becomes leader.
        if (self.leader_client_fd == null) {
            try self.setLeader(client);
        }
        if (self.leader_client_fd != client.socket_fd) return;

        const resize = std.mem.bytesToValue(ipc.Resize, payload);
        var ws: cross.c.struct_winsize = .{
            .ws_row = resize.rows,
            .ws_col = resize.cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = cross.c.ioctl(pty_fd, cross.c.TIOCSWINSZ, &ws);
        // Disable prompt_redraw before resize (same rationale as handleInit).
        const saved_prompt_redraw = term.flags.shell_redraws_prompt;
        term.flags.shell_redraws_prompt = .false;
        defer term.flags.shell_redraws_prompt = saved_prompt_redraw;
        try term.resize(self.alloc, resize.cols, resize.rows);
        std.log.debug("resize rows={d} cols={d}", .{ resize.rows, resize.cols });
    }

    pub fn handleDetach(self: *Daemon, client: *Client, i: usize) void {
        std.log.info("client detach fd={d}", .{client.socket_fd});
        _ = self.closeClient(client, i, false);
    }

    pub fn handleDetachAll(self: *Daemon) void {
        std.log.info("detach all clients={d}", .{self.clients.items.len});
        for (self.clients.items) |client_to_close| {
            client_to_close.deinit();
            self.alloc.destroy(client_to_close);
        }
        self.clients.clearRetainingCapacity();
    }

    pub fn handleKill(self: *Daemon) void {
        std.log.info("kill received session={s}", .{self.session_name});
        self.shutdown();
        // gracefully shutdown shell processes, shells tend to ignore SIGTERM so we send SIGHUP
        // instead
        //   https://www.gnu.org/software/bash/manual/html_node/Signals.html
        // negative pid means kill process and children
        std.log.info("sending SIGHUP session={s} pid={d}", .{ self.session_name, self.pid });
        posix.kill(-self.pid, posix.SIG.HUP) catch |err| {
            std.log.warn("failed to send SIGHUP to pty child err={s}", .{@errorName(err)});
        };
        std.Thread.sleep(500 * std.time.ns_per_ms);
        posix.kill(-self.pid, posix.SIG.KILL) catch |err| {
            std.log.warn("failed to send SIGKILL to pty child err={s}", .{@errorName(err)});
        };
    }

    pub fn handleInfo(self: *Daemon, client: *Client) !void {
        const clients_len = self.clients.items.len - 1;

        // Build command string from args, re-quoting args that contain
        // shell-special characters so the displayed command is copy-pasteable.
        var cmd_buf: [ipc.MAX_CMD_LEN]u8 = undefined;
        var cmd_len: u16 = 0;
        const cur_cmd = self.command orelse self.task_command;
        if (cur_cmd) |args| {
            for (args, 0..) |arg, i| {
                const quoted = if (util.shellNeedsQuoting(arg))
                    util.shellQuote(self.alloc, arg) catch null
                else
                    null;
                defer if (quoted) |q| self.alloc.free(q);
                const src = quoted orelse arg;

                const need = src.len + @as(usize, if (i > 0) 1 else 0);
                if (cmd_len + need > ipc.MAX_CMD_LEN) {
                    const ellipsis = "...";
                    if (cmd_len + ellipsis.len <= ipc.MAX_CMD_LEN) {
                        @memcpy(cmd_buf[cmd_len..][0..ellipsis.len], ellipsis);
                        cmd_len += ellipsis.len;
                    }
                    break;
                }

                if (i > 0) {
                    cmd_buf[cmd_len] = ' ';
                    cmd_len += 1;
                }
                @memcpy(cmd_buf[cmd_len..][0..src.len], src);
                cmd_len += @intCast(src.len);
            }
        }

        // Copy cwd
        var cwd_buf: [ipc.MAX_CWD_LEN]u8 = undefined;
        const cwd_len: u16 = @intCast(@min(self.cwd.len, ipc.MAX_CWD_LEN));
        @memcpy(cwd_buf[0..cwd_len], self.cwd[0..cwd_len]);

        const info = ipc.Info{
            .clients_len = clients_len,
            .pid = self.pid,
            .cmd_len = cmd_len,
            .cwd_len = cwd_len,
            .cmd = cmd_buf,
            .cwd = cwd_buf,
            .created_at = self.created_at,
            .task_ended_at = self.task_ended_at orelse 0,
            .task_exit_code = self.task_exit_code orelse 0,
        };
        try ipc.appendMessage(self.alloc, &client.write_buf, .Info, std.mem.asBytes(&info));
        client.has_pending_output = true;
    }

    pub fn handleHistory(
        self: *Daemon,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        const format: util.HistoryFormat = if (payload.len > 0)
            std.meta.intToEnum(util.HistoryFormat, payload[0]) catch .plain
        else
            .plain;
        if (util.serializeTerminal(self.alloc, term, format)) |serialized| {
            defer self.alloc.free(serialized);
            try ipc.appendMessage(self.alloc, &client.write_buf, .History, serialized);
            client.has_pending_output = true;
        } else {
            try ipc.appendMessage(self.alloc, &client.write_buf, .History, "");
            client.has_pending_output = true;
        }
    }

    pub fn handleOutput(self: *Daemon, payload: []const u8, vt_stream: anytype) !void {
        try vt_stream.nextSlice(payload);
        self.has_pty_output = true;
        for (self.clients.items) |client| {
            try ipc.appendMessage(self.alloc, &client.write_buf, .Output, payload);
            client.has_pending_output = true;
        }
        if (self.clients.items.len > 0) {
            posix.kill(self.pid, posix.SIG.WINCH) catch |err| {
                std.log.warn("failed to send SIGWINCH err={s}", .{@errorName(err)});
            };
        }
    }

    pub fn handleWrite(self: *Daemon, client: *Client, payload: []const u8) !void {
        // Wire format: [u32 path len][path bytes][file content]
        if (payload.len < @sizeOf(u32)) return error.InvalidPayload;
        const path_len = std.mem.bytesToValue(u32, payload[0..@sizeOf(u32)]);
        if (payload.len < @sizeOf(u32) + path_len) return error.InvalidPayload;
        const file_path = payload[@sizeOf(u32)..][0..path_len];
        const file_content = payload[@sizeOf(u32) + path_len ..];

        // Inject file creation through the PTY so it works over SSH.
        // Base64-encode content and pipe through printf | base64 -d > file.
        // Chunk large files to stay under command-line length limits.
        // 48000 is divisible by 3 (clean base64 boundaries) and encodes
        // to ~64KB, well under typical ARG_MAX.
        const chunk_size = 48000;
        var offset: usize = 0;
        var is_first = true;

        while (offset < file_content.len or is_first) {
            const end = @min(offset + chunk_size, file_content.len);
            const chunk = file_content[offset..end];

            const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
            const encoded = try self.alloc.alloc(u8, encoded_len);
            defer self.alloc.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, chunk);

            self.queuePtyInput("printf '%s' '");
            self.queuePtyInput(encoded);
            if (is_first) {
                self.queuePtyInput("' | base64 -d > '");
            } else {
                self.queuePtyInput("' | base64 -d >> '");
            }
            self.queuePtyInput(file_path);
            self.queuePtyInput("'");
            self.queuePtyInput("\r");

            offset = end;
            is_first = false;
        }

        try ipc.appendMessage(self.alloc, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        self.has_had_client = true;
        std.log.debug(
            "write command len={d} file_path={s}",
            .{ file_content.len, file_path },
        );
    }

    pub fn handleRun(self: *Daemon, client: *Client, payload: []const u8) !void {
        // Reset task tracking so the new command's exit marker is detected.
        // Without this, a second `zmx run` on the same session is ignored
        // because task_exit_code is still set from the first run.
        self.task_exit_code = null;
        self.task_ended_at = null;
        self.is_task_mode = true;

        if (payload.len == 0) return;

        // Auto-detect the foreground process on the PTY so we can pick the
        // right shell syntax for the task-completion marker. Replaces the
        // old client-side SHELL-env heuristic (upstream 758a137).
        if (self.pty_fd >= 0) {
            var name_buf: [64]u8 = undefined;
            if (cross.getForegroundProcessName(self.pty_fd, &name_buf)) |name| {
                self.is_fish = std.mem.eql(u8, name, "fish");
                std.log.debug("foreground process={s} is_fish={}", .{ name, self.is_fish });
            }
        }

        // Daemon appends the task marker so the client never injects
        // shell-specific syntax, keeping Ctrl-C recovery clean.
        const marker = if (self.is_fish)
            "; echo ZMX_TASK_COMPLETED:$status"
        else
            "; echo ZMX_TASK_COMPLETED:$?";

        // Payload may already end with \r (client convention). Strip it so
        // we append marker before the CR that submits to readline.
        const cmd = payload;
        if (cmd.len > 0 and cmd[cmd.len - 1] == '\r') {
            self.queuePtyInput(cmd[0 .. cmd.len - 1]);
        } else {
            self.queuePtyInput(cmd);
        }
        self.queuePtyInput(marker);
        self.queuePtyInput("\r");

        try ipc.appendMessage(self.alloc, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        self.has_had_client = true;
        std.log.debug("run command len={d}", .{payload.len});
    }
};

fn printVersion(alloc: std.mem.Allocator, cfg: *Cfg) !void {
    var ver = version;
    if (builtin.mode == .Debug) {
        ver = git_sha;
    }
    try output.printVersionTable(alloc, ver, ghostty_version, cfg.socket_dir, cfg.log_dir);
}

fn printCompletions(shell: completions.Shell) !void {
    const script = shell.getCompletionScript();
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("{s}\n", .{script});
    try w.interface.flush();
}

fn subcommandUsage(name: []const u8, args_text: []const u8, description: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(
        \\
        \\Usage: zmx {s} {s}
        \\
        \\  {s}
        \\
        \\Run 'zmx --help' for global usage information.
        \\
    , .{ name, args_text, description });
    try w.interface.flush();
}

fn help() !void {
    const help_text =
        \\zmx - session persistence for terminal processes
        \\
        \\Usage: zmx <command> [args]
        \\
        \\Commands:
        \\  [a]ttach <name> [command...]   Attach to session, creating session if needed
        \\  [r]un <name> [command...]      Send command without attaching, creating session if needed
        \\  [d]etach                       Detach all clients from current session (ctrl+\ for current client)
        \\  [l]ist [--short]               List active sessions
        \\  [k]ill <name>... [--force]     Kill a session and all attached clients
        \\  rm <name>...                   Remove a session (kill if running, delete socket)
        \\  [hi]story <name> [--vt|--html] Output session scrollback (--vt or --html for escape sequences)
        \\  [w]ait <name>...               Wait for session tasks to complete
        \\  [c]ompletions <shell>          Completion scripts for shell integration (bash, zsh, or fish)
        \\  [v]ersion                      Show version information
        \\  [h]elp                         Show this help message
        \\
        \\Environment variables:
        \\  - SHELL                Determines which shell is used when creating a session
        \\  - ZMX_DIR              Controls which folder is used to store unix socket files (prio: 1)
        \\  - XDG_RUNTIME_DIR      Controls which folder is used to store unix socket files (prio: 2)
        \\  - TMPDIR               Controls which folder is used to store unix socket files (prio: 3)
        \\  - ZMX_SESSION          The session name we inject into every zmx session automatically
        \\  - ZMX_SESSION_PREFIX   Adds this value to the start of every session name for all commands
        \\
    ;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(help_text, .{});
    try w.interface.flush();
}

fn wait(cfg: *Cfg, session_names: std.ArrayList([]const u8)) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Highest match count seen so far. Lets us distinguish "sessions haven't
    // appeared yet" (keep polling) from "sessions we were tracking
    // disappeared" (fail -- daemon crashed or was killed).
    var max_seen: i32 = 0;
    var zero_match_iters: u32 = 0;

    while (true) {
        var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
        var total: i32 = 0;
        var done: i32 = 0;
        var agg_exit_code: u8 = 0;

        for (sessions.items) |session| {
            var found = false;
            for (session_names.items) |prefix| {
                if (std.mem.startsWith(u8, session.name, prefix)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                continue;
            }

            total += 1;
            if (session.is_error) {
                // Daemon unreachable (probe timed out). On Timeout the socket
                // is no longer deleted, so this session would otherwise
                // persist as task_ended_at==0 forever → infinite "still
                // waiting". Count it as done+failed so wait terminates.
                output.printError("{s}: unreachable ({s})", .{ session.name, session.error_name orelse "unknown" }) catch {};
                agg_exit_code = 1;
                done += 1;
                continue;
            }
            if (session.task_ended_at == 0) {
                output.printInfo("waiting for {s}", .{session.name}) catch {};
                continue;
            }
            if (session.task_exit_code == 0) {
                output.printSuccess("{s} completed", .{session.name}) catch {};
            } else {
                output.printError("{s} exited ({d})", .{ session.name, session.task_exit_code.? }) catch {};
            }
            if (session.task_exit_code != 0) {
                agg_exit_code = session.task_exit_code orelse 0;
            }
            done += 1;
        }

        for (sessions.items) |session| {
            session.deinit(alloc);
        }
        sessions.deinit(alloc);

        // Check disappearance BEFORE completion: if one of N sessions
        // crashed and the remaining N-1 happen to be done, total==done
        // would be a false success.
        if (total < max_seen) {
            output.printError("{d} session(s) disappeared before completing", .{max_seen - total}) catch {};
            std.process.exit(1);
            return;
        }
        max_seen = total;

        if (total > 0 and total == done) {
            if (agg_exit_code == 0) {
                output.printSuccess("all tasks completed", .{}) catch {};
            } else {
                output.printError("tasks failed", .{}) catch {};
            }
            std.process.exit(agg_exit_code);
            return;
        }

        if (max_seen == 0) {
            // `zmx run foo && zmx wait foo` is essentially sequential, so
            // matching sessions should be visible from the first poll. If
            // nothing appears after a few iterations it's almost certainly a
            // typo, not a slow start.
            zero_match_iters += 1;
            if (zero_match_iters >= 3) {
                output.printError("no matching sessions found", .{}) catch {};
                std.process.exit(2);
                return;
            }
        }

        std.Thread.sleep(3000 * std.time.ns_per_ms);
    }
}

fn list(cfg: *Cfg, mode: list_mod.Mode) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const current_session = std.process.getEnvVarOwned(alloc, "ZMX_SESSION") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (current_session) |name| alloc.free(name);
    var buf: [8192]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);

    var sessions = try util.get_session_entries(alloc, cfg.socket_dir);
    defer {
        for (sessions.items) |session| {
            session.deinit(alloc);
        }
        sessions.deinit(alloc);
    }

    if (sessions.items.len == 0) {
        switch (mode) {
            .short => return,
            .json => {
                try stdout.interface.writeAll("[]\n");
                try stdout.interface.flush();
                return;
            },
            .table => {
                output.printInfo("no sessions", .{}) catch {};
                return;
            },
        }
    }

    std.mem.sort(util.SessionEntry, sessions.items, {}, util.SessionEntry.lessThan);

    switch (mode) {
        .short => {
            for (sessions.items) |session| {
                if (session.is_error) continue;
                try stdout.interface.print("{s}\n", .{session.name});
                try stdout.interface.flush();
            }
        },
        .json => {
            try list_mod.writeJson(&stdout.interface, sessions.items, current_session);
            try stdout.interface.flush();
        },
        .table => {
            const use_color = std.posix.isatty(std.posix.STDOUT_FILENO);
            try list_mod.writeTable(&stdout.interface, sessions.items, current_session, alloc, use_color);
            try stdout.interface.flush();
        },
    }
}

fn detachAll(cfg: *Cfg) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const session_name = std.process.getEnvVarOwned(alloc, "ZMX_SESSION") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.log.err("ZMX_SESSION env var not found: are you inside a zmx session?", .{});
            return;
        },
        else => return err,
    };
    defer alloc.free(session_name);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);
    const result = ipc.probeSession(alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(dir, session_name);
        return;
    };
    defer posix.close(result.fd);
    ipc.send(result.fd, .DetachAll, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };
}

fn kill(cfg: *Cfg, session_name: []const u8, force: bool) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try socket.sessionExists(dir, session_name);
    if (!exists) {
        output.printError("session \"{s}\" does not exist", .{session_name}) catch {};
        return error.SessionNotFound;
    }
    const result = ipc.probeSession(alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (force or err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(dir, session_name);
            output.printSuccess("cleaned up stale session {s}", .{session_name}) catch {};
        } else {
            output.printWarn("{s} is unresponsive ({s}) — try again, use --force, or kill the process directly", .{ session_name, @errorName(err) }) catch {};
        }
        return;
    };

    defer posix.close(result.fd);
    ipc.send(result.fd, .Kill, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };
}

fn rmSession(cfg: *Cfg, session_name: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try socket.sessionExists(dir, session_name);
    if (!exists) {
        output.printError("session \"{s}\" does not exist", .{session_name}) catch {};
        return error.SessionNotFound;
    }

    std.log.info("removing session={s}", .{session_name});

    // Best-effort graceful shutdown: if the daemon is responsive, send
    // Kill so it can clean up (close clients, SIGHUP child, delete its
    // own socket). If not responsive, skip to force-cleanup.
    if (ipc.probeSession(alloc, socket_path)) |result| {
        ipc.send(result.fd, .Kill, "") catch |err| {
            std.log.debug("kill send failed for {s}: {s}", .{ session_name, @errorName(err) });
        };
        posix.close(result.fd);

        // Poll for the daemon to clean up its own socket, rather than
        // sleeping a fixed duration. 50ms polls, 500ms max.
        var waited: u64 = 0;
        const poll_interval = 50 * std.time.ns_per_ms;
        const max_wait = 500 * std.time.ns_per_ms;
        while (waited < max_wait) {
            std.Thread.sleep(poll_interval);
            waited += poll_interval;
            const still_exists = socket.sessionExists(dir, session_name) catch break;
            if (!still_exists) break;
        }
    } else |err| {
        std.log.debug("probe failed for {s}: {s}", .{ session_name, @errorName(err) });
    }

    // Delete the socket file if it still exists (daemon may have already
    // cleaned it up during graceful shutdown, or may be unresponsive).
    dir.deleteFile(session_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            std.log.warn("failed to delete socket file err={s}", .{@errorName(err)});
            return err;
        },
    };
}

fn history(cfg: *Cfg, session_name: []const u8, format: util.HistoryFormat) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const socket_path = socket.getSocketPath(alloc, cfg.socket_dir, session_name) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(session_name, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer alloc.free(socket_path);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const exists = try socket.sessionExists(dir, session_name);
    if (!exists) {
        output.printError("session \"{s}\" does not exist", .{session_name}) catch {};
        return error.SessionNotFound;
    }
    const result = ipc.probeSession(alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(dir, session_name);
        return;
    };
    defer posix.close(result.fd);

    const format_byte = [_]u8{@intFromEnum(format)};
    ipc.send(result.fd, .History, &format_byte) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    while (true) {
        var poll_fds = [_]posix.pollfd{.{ .fd = result.fd, .events = posix.POLL.IN, .revents = 0 }};
        const poll_result = posix.poll(&poll_fds, 5000) catch return;
        if (poll_result == 0) {
            std.log.err("timeout waiting for history response", .{});
            return;
        }

        const n = sb.read(result.fd) catch return;
        if (n == 0) return;

        while (sb.next()) |msg| {
            if (msg.header.tag == .History) {
                _ = posix.write(posix.STDOUT_FILENO, msg.payload) catch return;
                return;
            }
        }
    }
}

fn attach(daemon: *Daemon) !void {
    const sesh = socket.getSeshNameFromEnv();
    if (sesh.len > 0) {
        return error.CannotAttachToSessionInSession;
    }

    const result = try daemon.ensureSession();
    if (result.is_daemon) return;

    const client_sock = try socket.sessionConnect(daemon.socket_path);
    std.log.info("attached session={s}", .{daemon.session_name});
    //  This is typically used with tcsetattr() to modify terminal settings.
    //      - you first get the current settings with tcgetattr()
    //      - modify the desired attributes in the termios structure
    //      - then apply the changes with tcsetattr().
    //  This prevents unintended side effects by preserving other settings.
    // restore stdin fd to its original state after exiting.
    // Use TCSAFLUSH to discard any unread input, preventing stale input after detach.
    //
    // tcgetattr fails when stdin is not a TTY (e.g. piped). In that case,
    // skip terminal setup entirely rather than applying undefined stack bytes
    // via tcsetattr.
    var orig_termios: cross.c.termios = undefined;
    const stdin_is_tty = cross.c.tcgetattr(posix.STDIN_FILENO, &orig_termios) == 0;

    defer {
        if (stdin_is_tty) {
            _ = cross.c.tcsetattr(posix.STDIN_FILENO, cross.c.TCSAFLUSH, &orig_termios);
        }
        // Reset terminal modes on detach:
        // - Mouse: 1000=basic, 1002=button-event, 1003=any-event, 1006=SGR extended
        // - 2004=bracketed paste, 1004=focus events, 1049=alt screen
        // - 25h=show cursor
        // NOTE: We intentionally do NOT clear screen or home cursor here because we dont
        // want to corrupt any programs that rely on it including ghostty's session restore.
        const restore_seq = "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l" ++
            "\x1b[?2004l\x1b[?1004l\x1b[?1049l" ++
            // Restore pre-attach Kitty keyboard protocol mode so Ctrl combos
            // return to legacy encoding in the user's outer shell.
            "\x1b[<u" ++
            "\x1b[?25h";
        _ = posix.write(posix.STDOUT_FILENO, restore_seq) catch {};
    }

    if (stdin_is_tty) {
        var raw_termios = orig_termios;
        //  set raw mode after successful connection.
        //      disables canonical mode (line buffering), input echoing, signal generation from
        //      control characters (like Ctrl+C), and flow control.
        cross.c.cfmakeraw(&raw_termios);

        // Additional granular raw mode settings for precise control
        // (matches what abduco and shpool do)
        raw_termios.c_cc[cross.c.VLNEXT] = cross.c._POSIX_VDISABLE; // Disable literal-next (Ctrl-V)
        // We want to intercept Ctrl+\ (SIGQUIT) so we can use it as a detach key
        raw_termios.c_cc[cross.c.VQUIT] = cross.c._POSIX_VDISABLE; // Disable SIGQUIT (Ctrl+\)
        raw_termios.c_cc[cross.c.VMIN] = 1; // Minimum chars to read: return after 1 byte
        raw_termios.c_cc[cross.c.VTIME] = 0; // Read timeout: no timeout, return immediately

        _ = cross.c.tcsetattr(posix.STDIN_FILENO, cross.c.TCSANOW, &raw_termios);
    }

    // Clear screen before attaching. This provides a clean slate before
    // the session restore.
    const clear_seq = "\x1b[2J\x1b[H";
    _ = try posix.write(posix.STDOUT_FILENO, clear_seq);

    try clientLoop(client_sock);
}

/// Send raw bytes to a session's PTY. Tag selects semantics:
///   .Input  — delivered as keystrokes (send / print-as-keystrokes)
///   .Output — injected into the session output stream (print)
fn sendRaw(
    cfg: *Cfg,
    session_name: []const u8,
    socket_path: []const u8,
    text_parts: [][]const u8,
    tag: ipc.Tag,
) !void {
    const alloc = std.heap.c_allocator;

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(alloc);

    if (text_parts.len > 0) {
        for (text_parts, 0..) |part, i| {
            if (i > 0) try payload.append(alloc, ' ');
            try payload.appendSlice(alloc, part);
        }
    } else {
        // Read from stdin when no text arguments provided.
        const stdin_fd = posix.STDIN_FILENO;
        if (!std.posix.isatty(stdin_fd)) {
            while (true) {
                var tmp: [4096]u8 = undefined;
                const n = posix.read(stdin_fd, &tmp) catch |err| {
                    if (err == error.WouldBlock) break;
                    return err;
                };
                if (n == 0) break;
                try payload.appendSlice(alloc, tmp[0..n]);
            }
            // For .Input, strip a trailing newline — the caller is expected
            // to supply \r explicitly when they want the shell to submit
            // the line. For .Output, forward bytes exactly as-is.
            if (tag != .Output and payload.items.len > 0 and payload.items[payload.items.len - 1] == '\n') {
                _ = payload.pop();
            }
        }
    }

    if (payload.items.len == 0) return error.TextRequired;

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const probe_result = ipc.probeSession(alloc, socket_path) catch |err| {
        std.log.err("session unresponsive: {s}", .{@errorName(err)});
        if (err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(dir, session_name);
            output.printError("cleaned up stale session {s}", .{session_name}) catch {};
        } else {
            output.printError(
                "session {s} is unresponsive ({s})\ndaemon may be busy: try again",
                .{ session_name, @errorName(err) },
            ) catch {};
        }
        return;
    };
    defer posix.close(probe_result.fd);

    ipc.send(probe_result.fd, tag, payload.items) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };
}

/// Write stdin contents to `file_path` inside the session's shell.
/// Works over SSH because the daemon injects base64-chunked printf
/// commands through the PTY (see Daemon.handleWrite).
fn writeFile(daemon: *Daemon, file_path: []const u8) !void {
    const alloc = daemon.alloc;

    // Slurp stdin.
    var content = std.ArrayList(u8).empty;
    defer content.deinit(alloc);
    const stdin_fd = posix.STDIN_FILENO;
    if (!std.posix.isatty(stdin_fd)) {
        while (true) {
            var tmp: [4096]u8 = undefined;
            const n = posix.read(stdin_fd, &tmp) catch |err| {
                if (err == error.WouldBlock) break;
                return err;
            };
            if (n == 0) break;
            try content.appendSlice(alloc, tmp[0..n]);
        }
    }

    // Wire format: [u32 path len][path bytes][file content]
    var wire_buf = std.ArrayList(u8).empty;
    defer wire_buf.deinit(alloc);
    const path_len: u32 = @intCast(file_path.len);
    try wire_buf.appendSlice(alloc, std.mem.asBytes(&path_len));
    try wire_buf.appendSlice(alloc, file_path);
    try wire_buf.appendSlice(alloc, content.items);

    const probe_result = ipc.probeSession(alloc, daemon.socket_path) catch |err| {
        std.log.err("session not ready: {s}", .{@errorName(err)});
        return error.SessionNotReady;
    };
    defer posix.close(probe_result.fd);

    ipc.send(probe_result.fd, .Write, wire_buf.items) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };
    output.printSuccess("wrote {d} bytes to {s}", .{ content.items.len, file_path }) catch {};
}

fn run(daemon: *Daemon, command_args: [][]const u8) !void {
    const alloc = daemon.alloc;

    var cmd_to_send: ?[]const u8 = null;
    var allocated_cmd: ?[]u8 = null;
    defer if (allocated_cmd) |cmd| alloc.free(cmd);

    const result = try daemon.ensureSession();
    if (result.is_daemon) return;

    if (result.created) {
        output.printSuccess("session \"{s}\" created", .{daemon.session_name}) catch {};
    }

    // The daemon detects the running shell and appends the task-completion
    // marker server-side (see Daemon.handleRun). Client just sends the
    // raw command bytes.

    if (command_args.len > 0) {
        var cmd_list = std.ArrayList(u8).empty;
        defer cmd_list.deinit(alloc);

        for (command_args, 0..) |arg, i| {
            if (i > 0) try cmd_list.append(alloc, ' ');
            if (util.shellNeedsQuoting(arg)) {
                const quoted = try util.shellQuote(alloc, arg);
                defer alloc.free(quoted);
                try cmd_list.appendSlice(alloc, quoted);
            } else {
                try cmd_list.appendSlice(alloc, arg);
            }
        }

        cmd_to_send = try cmd_list.toOwnedSlice(alloc);
        allocated_cmd = @constCast(cmd_to_send.?);
    } else {
        const stdin_fd = posix.STDIN_FILENO;
        if (!std.posix.isatty(stdin_fd)) {
            var stdin_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
            defer stdin_buf.deinit(alloc);

            while (true) {
                var tmp: [4096]u8 = undefined;
                const n = posix.read(stdin_fd, &tmp) catch |err| {
                    if (err == error.WouldBlock) break;
                    return err;
                };
                if (n == 0) break;
                try stdin_buf.appendSlice(alloc, tmp[0..n]);
            }

            // Strip a trailing newline — the daemon appends \r after the
            // marker. This keeps the "last line" of piped input from
            // getting split across the marker.
            if (stdin_buf.items.len > 0 and
                (stdin_buf.items[stdin_buf.items.len - 1] == '\n' or
                 stdin_buf.items[stdin_buf.items.len - 1] == '\r'))
            {
                _ = stdin_buf.pop();
            }

            if (stdin_buf.items.len > 0) {
                cmd_to_send = try alloc.dupe(u8, stdin_buf.items);
                allocated_cmd = @constCast(cmd_to_send.?);
            }
        }
    }

    if (cmd_to_send == null) {
        return error.CommandRequired;
    }

    const probe_result = ipc.probeSession(alloc, daemon.socket_path) catch |err| {
        std.log.err("session not ready: {s}", .{@errorName(err)});
        return error.SessionNotReady;
    };
    defer posix.close(probe_result.fd);

    ipc.send(probe_result.fd, .Run, cmd_to_send.?) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };

    var poll_fds = [_]posix.pollfd{
        .{ .fd = probe_result.fd, .events = posix.POLL.IN, .revents = 0 },
    };
    const poll_result = posix.poll(&poll_fds, 5000) catch return error.PollFailed;
    if (poll_result == 0) {
        std.log.err("timeout waiting for ack", .{});
        return error.Timeout;
    }

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    const n = sb.read(probe_result.fd) catch return error.ReadFailed;
    if (n == 0) return error.ConnectionClosed;

    while (sb.next()) |msg| {
        if (msg.header.tag == .Ack) {
            output.printSuccess("command sent", .{}) catch {};
            return;
        }
    }

    return error.NoAckReceived;
}

/// clientLoop sends ipc commands to its corresponding daemon.  It uses poll() as its non-blocking
/// mechanism. It will send stdin to the daemon and receive stdout from the daemon.
fn clientLoop(client_sock_fd: i32) !void {
    // use c_allocator to avoid "reached unreachable code" panic in DebugAllocator when forking
    const alloc = std.heap.c_allocator;
    defer posix.close(client_sock_fd);

    setupSigwinchHandler();

    // Make socket non-blocking to avoid blocking on writes
    var sock_flags = try posix.fcntl(client_sock_fd, posix.F.GETFL, 0);
    sock_flags |= O_NONBLOCK;
    _ = try posix.fcntl(client_sock_fd, posix.F.SETFL, sock_flags);

    // Buffer for outgoing socket writes
    var sock_write_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer sock_write_buf.deinit(alloc);

    // Send init message with terminal size (buffered)
    const size = ipc.getTerminalSize(posix.STDOUT_FILENO);
    try ipc.appendMessage(alloc, &sock_write_buf, .Init, std.mem.asBytes(&size));

    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(alloc, 4);
    defer poll_fds.deinit(alloc);

    var read_buf = try ipc.SocketBuffer.init(alloc);
    defer read_buf.deinit();

    var stdout_buf = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer stdout_buf.deinit(alloc);

    const stdin_fd = posix.STDIN_FILENO;

    // Make stdin non-blocking. O_NONBLOCK is set on the open file description,
    // which is shared with the parent shell; restore on exit to avoid
    // corrupting the parent's stdin.
    const stdin_orig_flags = try posix.fcntl(stdin_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(stdin_fd, posix.F.SETFL, stdin_orig_flags | O_NONBLOCK);
    defer _ = posix.fcntl(stdin_fd, posix.F.SETFL, stdin_orig_flags) catch {};

    while (true) {
        // Check for pending SIGWINCH
        if (sigwinch_received.swap(false, .acq_rel)) {
            const next_size = ipc.getTerminalSize(posix.STDOUT_FILENO);
            try ipc.appendMessage(alloc, &sock_write_buf, .Resize, std.mem.asBytes(&next_size));
        }

        poll_fds.clearRetainingCapacity();

        try poll_fds.append(alloc, .{
            .fd = stdin_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        });

        // Poll socket for read, and also for write if we have pending data
        var sock_events: i16 = posix.POLL.IN;
        if (sock_write_buf.items.len > 0) {
            sock_events |= posix.POLL.OUT;
        }
        try poll_fds.append(alloc, .{
            .fd = client_sock_fd,
            .events = sock_events,
            .revents = 0,
        });

        if (stdout_buf.items.len > 0) {
            try poll_fds.append(alloc, .{
                .fd = posix.STDOUT_FILENO,
                .events = posix.POLL.OUT,
                .revents = 0,
            });
        }

        _ = posix.poll(poll_fds.items, -1) catch |err| {
            if (err == error.Interrupted) continue; // EINTR from signal, loop again
            return err;
        };

        // Handle stdin -> socket (Input)
        const inp_flags = (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL);
        if (poll_fds.items[0].revents & inp_flags != 0) {
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = posix.read(stdin_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                return err;
            };

            if (n_opt) |n| {
                if (n > 0) {
                    // Check for detach sequences (ctrl+\ as first byte or Kitty escape sequence)
                    if (util.isCtrlBackslash(buf[0..n])) {
                        try ipc.appendMessage(alloc, &sock_write_buf, .Detach, "");
                    } else {
                        try ipc.appendMessage(alloc, &sock_write_buf, .Input, buf[0..n]);
                    }
                } else {
                    // EOF on stdin
                    return;
                }
            }
        }

        // Handle socket read (incoming Output messages from daemon)
        if (poll_fds.items[1].revents & posix.POLL.IN != 0) {
            const n = read_buf.read(client_sock_fd) catch |err| {
                if (err == error.WouldBlock) continue;
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                    return;
                }
                std.log.err("daemon read err={s}", .{@errorName(err)});
                return err;
            };
            if (n == 0) {
                return; // Server closed connection
            }

            while (read_buf.next()) |msg| {
                switch (msg.header.tag) {
                    .Output => {
                        if (msg.payload.len > 0) {
                            try stdout_buf.appendSlice(alloc, msg.payload);
                        }
                    },
                    else => {},
                }
            }
        }

        // Handle socket write (flush buffered messages to daemon)
        if (poll_fds.items[1].revents & posix.POLL.OUT != 0) {
            if (sock_write_buf.items.len > 0) {
                const n = posix.write(client_sock_fd, sock_write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                        return;
                    }
                    return err;
                };
                if (n > 0) {
                    try sock_write_buf.replaceRange(alloc, 0, n, &[_]u8{});
                }
            }
        }

        if (stdout_buf.items.len > 0) {
            const n = posix.write(posix.STDOUT_FILENO, stdout_buf.items) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (n > 0) {
                try stdout_buf.replaceRange(alloc, 0, n, &[_]u8{});
            }
        }

        if (poll_fds.items[1].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
            return;
        }
    }
}

/// dameonLoop is what the daemon runs to send and receive ipc commands from its corresponding
/// clients.  It uses poll() as its non-blocking mechanism.
fn daemonLoop(daemon: *Daemon, server_sock_fd: i32, pty_fd: i32) !void {
    std.log.info("daemon started session={s} pty_fd={d}", .{ daemon.session_name, pty_fd });
    daemon.pty_fd = pty_fd;
    setupSigtermHandler();
    var poll_fds = try std.ArrayList(posix.pollfd).initCapacity(daemon.alloc, 8);
    defer poll_fds.deinit(daemon.alloc);

    const init_size = ipc.getTerminalSize(pty_fd);
    var term = try ghostty_vt.Terminal.init(daemon.alloc, .{
        .cols = init_size.cols,
        .rows = init_size.rows,
        .max_scrollback = daemon.cfg.max_scrollback,
    });
    defer term.deinit(daemon.alloc);
    var vt_stream = term.vtStream();
    defer vt_stream.deinit();

    daemon_loop: while (daemon.running) {
        if (sigterm_received.swap(false, .acq_rel)) {
            std.log.info(
                "SIGTERM received, shutting down gracefully session={s}",
                .{daemon.session_name},
            );
            break :daemon_loop;
        }

        poll_fds.clearRetainingCapacity();

        try poll_fds.append(daemon.alloc, .{
            .fd = server_sock_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        });

        var pty_events: i16 = posix.POLL.IN;
        if (daemon.pty_write_buf.items.len > 0) {
            pty_events |= posix.POLL.OUT;
        }
        try poll_fds.append(daemon.alloc, .{
            .fd = pty_fd,
            .events = pty_events,
            .revents = 0,
        });

        for (daemon.clients.items) |client| {
            var events: i16 = posix.POLL.IN;
            if (client.has_pending_output) {
                events |= posix.POLL.OUT;
            }
            try poll_fds.append(daemon.alloc, .{
                .fd = client.socket_fd,
                .events = events,
                .revents = 0,
            });
        }

        _ = posix.poll(poll_fds.items, -1) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };

        if (poll_fds.items[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
            std.log.err("server socket error revents={d}", .{poll_fds.items[0].revents});
            break :daemon_loop;
        } else if (poll_fds.items[0].revents & posix.POLL.IN != 0) {
            const client_fd = try posix.accept(
                server_sock_fd,
                null,
                null,
                posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            );
            const client = try daemon.alloc.create(Client);
            client.* = Client{
                .alloc = daemon.alloc,
                .socket_fd = client_fd,
                .read_buf = try ipc.SocketBuffer.init(daemon.alloc),
                .write_buf = undefined,
            };
            client.write_buf = try std.ArrayList(u8).initCapacity(client.alloc, 4096);
            try daemon.clients.append(daemon.alloc, client);
            std.log.info(
                "client connected fd={d} total={d}",
                .{ client_fd, daemon.clients.items.len },
            );
        }

        const inp_flags = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;
        if (poll_fds.items[1].revents & inp_flags != 0) {
            // Read from PTY
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = posix.read(pty_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                break :blk 0;
            };

            if (n_opt) |n| {
                if (n == 0) {
                    // EOF: Shell exited
                    std.log.info("shell exited pty_fd={d}", .{pty_fd});
                    break :daemon_loop;
                } else {
                    // Feed PTY output to terminal emulator for state tracking
                    try vt_stream.nextSlice(buf[0..n]);
                    daemon.has_pty_output = true;

                    // When no clients are attached, respond to terminal
                    // queries (e.g. DA1/DA2) on behalf of the terminal.
                    // This prevents shells like from fish from waiting 2s
                    // and then sending a no DA query response warning because
                    // there's no client terminal to respond to the query.
                    if (daemon.clients.items.len == 0 and
                        daemon.pty_write_buf.items.len < Daemon.PTY_WRITE_BUF_MAX)
                    {
                        util.respondToDeviceAttributes(daemon.alloc, &daemon.pty_write_buf, buf[0..n]);
                    }

                    // In run mode, scan output for exit code marker
                    if (daemon.is_task_mode and daemon.task_exit_code == null) {
                        if (util.findTaskExitMarker(buf[0..n])) |exit_code| {
                            daemon.task_exit_code = exit_code;
                            daemon.task_ended_at = @intCast(std.time.timestamp());

                            std.log.info("task completed exit_code={d}", .{exit_code});
                            // Shell continues running - no break here
                        }
                    }

                    // Broadcast data to all clients.
                    // Rewrite OSC 133;A to include redraw=0 so the outer
                    // terminal does not clear prompt lines on resize
                    // (upstream bbbe245, fixes #111).
                    const broadcast_data = util.rewritePromptRedraw(daemon.alloc, buf[0..n]) orelse buf[0..n];
                    defer if (broadcast_data.ptr != buf[0..n].ptr) daemon.alloc.free(broadcast_data);
                    for (daemon.clients.items) |client| {
                        ipc.appendMessage(daemon.alloc, &client.write_buf, .Output, broadcast_data) catch |err| {
                            std.log.warn(
                                "failed to buffer output for client err={s}",
                                .{@errorName(err)},
                            );
                            continue;
                        };
                        client.has_pending_output = true;
                    }
                }
            }
        }

        if (poll_fds.items[1].revents & posix.POLL.OUT != 0) {
            while (daemon.pty_write_buf.items.len > 0) {
                const n = posix.write(pty_fd, daemon.pty_write_buf.items) catch |err| {
                    if (err != error.WouldBlock) {
                        std.log.warn("pty write failed: {s}", .{@errorName(err)});
                        daemon.pty_write_buf.clearRetainingCapacity();
                    }
                    break;
                };
                if (n == 0) break;
                daemon.pty_write_buf.replaceRange(daemon.alloc, 0, n, &[_]u8{}) catch unreachable;
            }
        }

        var i: usize = daemon.clients.items.len;
        // Only iterate over clients that were present when poll_fds was constructed
        // poll_fds contains [server, pty, client0, client1, ...]
        // So number of clients in poll_fds is poll_fds.items.len - 2
        const num_polled_clients = poll_fds.items.len - 2;
        if (i > num_polled_clients) {
            // If we have more clients than polled (i.e. we just accepted one), start from the
            // polled ones
            i = num_polled_clients;
        }

        clients_loop: while (i > 0) {
            i -= 1;
            const client = daemon.clients.items[i];
            const revents = poll_fds.items[i + 2].revents;

            if (revents & posix.POLL.IN != 0) {
                const n = client.read_buf.read(client.socket_fd) catch |err| {
                    if (err == error.WouldBlock) continue;
                    std.log.debug(
                        "client read err={s} fd={d}",
                        .{ @errorName(err), client.socket_fd },
                    );
                    const last = daemon.closeClient(client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n == 0) {
                    // Client closed connection
                    const last = daemon.closeClient(client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                }

                while (client.read_buf.next()) |msg| {
                    switch (msg.header.tag) {
                        .Input => try daemon.handleInput(client, msg.payload),
                        .Output => try daemon.handleOutput(msg.payload, &vt_stream),
                        .Init => try daemon.handleInit(client, pty_fd, &term, msg.payload),
                        .Resize => try daemon.handleResize(client, pty_fd, &term, msg.payload),
                        .Detach => {
                            daemon.handleDetach(client, i);
                            break :clients_loop;
                        },
                        .DetachAll => {
                            daemon.handleDetachAll();
                            break :clients_loop;
                        },
                        .Kill => {
                            break :daemon_loop;
                        },
                        .Info => try daemon.handleInfo(client),
                        .History => try daemon.handleHistory(client, &term, msg.payload),
                        .Run => try daemon.handleRun(client, msg.payload),
                        .Write => try daemon.handleWrite(client, msg.payload),
                        .Ack, .Switch, .TaskComplete => {},
                        _ => std.log.warn(
                            "ignoring unknown IPC tag={d}",
                            .{@intFromEnum(msg.header.tag)},
                        ),
                    }
                }
            }

            if (revents & posix.POLL.OUT != 0) {
                // Flush pending output buffers
                const n = posix.write(client.socket_fd, client.write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    // Error on write, close client
                    const last = daemon.closeClient(client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n > 0) {
                    client.write_buf.replaceRange(daemon.alloc, 0, n, &[_]u8{}) catch unreachable;
                }

                if (client.write_buf.items.len == 0) {
                    client.has_pending_output = false;
                }
            }

            if (revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                const last = daemon.closeClient(client, i, false);
                if (last) break :daemon_loop;
            }
        }
    }
}

fn handleSigwinch(_: i32, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    sigwinch_received.store(true, .release);
}

fn handleSigterm(_: i32, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    sigterm_received.store(true, .release);
}

// No SA_RESTART: we want the signal to interrupt poll() so the
// loop can check the flag. On BSD/macOS, SA_RESTART makes poll restartable,
// which would leave an idle daemon deaf to SIGTERM until other I/O wakes it.
fn setupSigwinchHandler() void {
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = handleSigwinch },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO,
    };
    posix.sigaction(posix.SIG.WINCH, &act, null);
}

fn setupSigtermHandler() void {
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = handleSigterm },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
}

fn ignoreSigpipe() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &act, null);
}
