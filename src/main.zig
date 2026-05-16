const std = @import("std");

const branches = @import("branches.zig");
const github = @import("github.zig");

const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";

    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const cyan = "\x1b[36m";

    const bright_green = "\x1b[92m";
};

const Options = struct {
    package_name: ?[]const u8 = null,
    days: u32 = 15,
    show_tree: bool = false,
    show_help: bool = false,
    diagnostic: ?ArgDiagnostic = null,
};

const ArgDiagnostic = union(enum) {
    missing_days_value,
    invalid_days: []const u8,
    nonpositive_days,
    unknown_option: []const u8,
    multiple_package_names,
    no_package_name,
};

fn parseArgs(args: []const [:0]const u8) Options {
    var options: Options = .{};

    var i: usize = 1; // Skip program name.
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.show_help = true;
        } else if (std.mem.eql(u8, arg, "--days") or std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.len) {
                options.diagnostic = .missing_days_value;
                break;
            }

            const value: []const u8 = args[i];
            options.days = std.fmt.parseInt(u32, value, 10) catch {
                options.diagnostic = .{ .invalid_days = value };
                break;
            };
            if (options.days == 0) {
                options.diagnostic = .nonpositive_days;
                break;
            }
        } else if (std.mem.eql(u8, arg, "--tree") or std.mem.eql(u8, arg, "-t")) {
            options.show_tree = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            options.diagnostic = .{ .unknown_option = arg };
            break;
        } else if (options.package_name != null) {
            options.diagnostic = .multiple_package_names;
            break;
        } else {
            options.package_name = arg;
        }
    }

    if (options.diagnostic == null and !options.show_help and options.package_name == null) {
        options.diagnostic = .no_package_name;
    }

    return options;
}

fn printUsage(stdout: *std.Io.Writer, prog_name: []const u8) !void {
    try stdout.print(
        \\Usage: {s} [options] <package-name>
        \\
        \\Search for recent NixOS PRs affecting a package and show which branches they've reached.
        \\
        \\Options:
        \\  --days <n>     Search PRs from last n days (default: 15)
        \\  --tree         Show detailed branch tree for each PR
        \\  --help         Show this help message
        \\
        \\Requires the GitHub CLI (gh) to be installed and authenticated.
        \\
        \\Examples:
        \\  {s} forgejo
        \\  {s} --days 30 --tree python311
        \\
    ,
        .{ prog_name, prog_name, prog_name },
    );
    try stdout.flush();
}

fn printArgDiagnostic(stderr: *std.Io.Writer, diagnostic: ArgDiagnostic) !void {
    try stderr.writeAll("Error: ");
    switch (diagnostic) {
        .missing_days_value => try stderr.writeAll("No days value supplied"),
        .invalid_days => |value| try stderr.print("Invalid value for --days: {s}", .{value}),
        .nonpositive_days => try stderr.writeAll("--days must be a positive integer"),
        .unknown_option => |option| try stderr.print("unknown option: {s}", .{option}),
        .multiple_package_names => try stderr.writeAll("multiple package names provided."),
        .no_package_name => try stderr.writeAll("package name required."),
    }
    try stderr.writeByte('\n');
    try stderr.flush();
}

fn printSimpleOutput(
    stdout: *std.Io.Writer,
    pr: github.PullRequest,
    reached: []const []const u8,
) !void {
    const status_str = switch (pr.status) {
        .open => Color.blue ++ "open" ++ Color.reset,
        .closed => Color.red ++ "closed" ++ Color.reset,
        .merged => Color.green ++ "merged" ++ Color.reset,
    };

    try stdout.print("{s}PR:{s} {s}{s}{s} ({s}) {s}#{d}{s}\n", .{
        Color.bold,
        Color.reset,
        Color.cyan,
        pr.title,
        Color.reset,
        status_str,
        Color.dim,
        pr.number,
        Color.reset,
    });

    if (pr.status != .merged) {
        try stdout.flush();
        return;
    }

    if (reached.len > 0) {
        try stdout.print("   {s}└─{s} Reachable in: ", .{ Color.dim, Color.reset });
        for (reached, 0..) |branch, i| {
            if (i > 0) try stdout.print("{s},{s} ", .{ Color.dim, Color.reset });
            try stdout.print("{s}{s}{s}", .{ Color.bright_green, branch, Color.reset });
        }
        try stdout.writeByte('\n');
    } else {
        try stdout.print("   {s}└─{s} Reachable in: {s}None{s} {s}(pending Hydra/Mirror){s}\n", .{
            Color.dim,
            Color.reset,
            Color.yellow,
            Color.reset,
            Color.dim,
            Color.reset,
        });
    }

    try stdout.flush();
}

fn printTreeOutput(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    pr: github.PullRequest,
    reached_set: std.StringHashMap(void),
) !void {
    const status_str = switch (pr.status) {
        .open => "open",
        .closed => "closed",
        .merged => "merged",
    };

    try stdout.print("PR: {s} ({s}) #{d}\n", .{ pr.title, status_str, pr.number });
    try printBranchTree(allocator, stdout, reached_set, pr.base_branch, 0);
    try stdout.flush();
}

fn printBranchTree(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    reached_set: std.StringHashMap(void),
    branch: []const u8,
    indent: usize,
) !void {
    const status_icon = if (reached_set.contains(branch)) "✓" else "✗";

    try stdout.splatByteAll(' ', indent);
    try stdout.print("{s} {s}\n", .{ status_icon, branch });

    const next = try branches.nextBranches(allocator, branch);
    defer freeStringList(allocator, next);

    for (next) |next_branch| {
        try printBranchTree(allocator, stdout, reached_set, next_branch, indent + 2);
    }
}

fn freeStringList(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_buffer: [2048]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_file = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stdout = &stdout_file.interface;
    const stderr = &stderr_file.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const prog_name = if (args.len > 0) args[0] else "npr";
    const options = parseArgs(args);

    if (options.show_help) {
        try printUsage(stdout, prog_name);
        return 0;
    }

    if (options.diagnostic) |diagnostic| {
        try printArgDiagnostic(stderr, diagnostic);
        return 1;
    }

    const package_name = options.package_name orelse unreachable;
    var gh_client = try github.GitHubClient.init(allocator, io, init.environ_map);

    gh_client.validate() catch |err| {
        switch (err) {
            error.GhNotInstalled => try stderr.print(
                "Error: GitHub CLI (gh) is not installed.\nInstall it from https://cli.github.com/\n",
                .{},
            ),
            error.GhNotAuthenticated => try stderr.print(
                "Error: GitHub CLI is not authenticated.\nRun 'gh auth login' to authenticate.\n",
                .{},
            ),
        }
        try stderr.flush();
        return 1;
    };

    try stdout.print("Searching for {s}...\n", .{package_name});
    try stdout.flush();

    const prs = gh_client.searchPRsByChangedFiles(package_name, options.days) catch |err| {
        try stderr.print("Error searching GitHub: {}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer {
        for (prs) |*pr| pr.deinit(allocator);
        allocator.free(prs);
    }

    if (prs.len == 0) {
        try stderr.print("No PRs found for '{s}' in the last {d} days.\n", .{ package_name, options.days });
        try stderr.flush();
        return 0;
    }

    const tracked = try branches.allTrackedBranches(allocator);
    defer freeStringList(allocator, tracked);

    for (prs, 0..) |pr, idx| {
        try stdout.print("\r[{d}/{d}] ", .{ idx + 1, prs.len });
        try stdout.flush();

        var reached_branches: [][]const u8 = &.{};
        defer freeStringList(allocator, reached_branches);

        if (pr.status == .merged) {
            if (pr.merge_commit_sha) |sha| {
                reached_branches = gh_client.branchesContainingCommit(tracked, sha) catch &.{};
            }
        }

        try stdout.print("\r{s}\r", .{" " ** 50});

        if (options.show_tree) {
            var reached_set = std.StringHashMap(void).init(allocator);
            defer reached_set.deinit();

            for (reached_branches) |branch| try reached_set.put(branch, {});

            try printTreeOutput(allocator, stdout, pr, reached_set);
            try stdout.writeByte('\n');
            try stdout.flush();
        } else {
            try printSimpleOutput(stdout, pr, reached_branches);
        }
    }

    return 0;
}
