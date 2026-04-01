const std = @import("std");

const Io = std.Io;

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

const ParseOptions = struct {
    /// The package name to search for in changed files of PRs.
    package_name: []const u8 = undefined,

    /// Days to search back, the default is 15.
    days: u32 = 15,

    /// Show the detailed branch tree for each PR instead of a simple list of reachable branches.
    show_tree: bool = false,

    show_help: bool = false,

    diagnostics: ?union(enum) {
        /// Invalid package name.
        invalid_package_name: []const u8,

        /// Invalid days. Must be a positive integer.
        invalid_days: []const u8,

        /// Invalid boolean passed.for `--tree`.
        invalid_tree: []const u8,

        /// Unknown option supplied
        unknown_option: []const u8,

        /// Multiple package names supplied.
        multiple_package_names: []const u8,

        /// No package name supplied
        no_package_name: []const u8,
    } = null,
};

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

fn parseArgs(allocator: std.mem.Allocator, _args: std.process.Args) !ParseOptions {
    var args = try _args.iterateAllocator(allocator);
    var options: ParseOptions = .{};
    var has_package = false;

    // Skip program name
    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.show_help = true;
        } else if (std.mem.eql(u8, arg, "--days") or std.mem.eql(u8, arg, "-d")) {
            const days_str = args.next() orelse {
                options.diagnostics = .{ .invalid_days = "No days value supplied" };
                break;
            };
            options.days = std.fmt.parseInt(u32, days_str, 10) catch {
                const message = try std.fmt.allocPrint(allocator, "Invalid value for --days: {s}", .{days_str});
                options.diagnostics = .{ .invalid_days = message };
                break;
            };
        } else if (std.mem.eql(u8, arg, "--tree") or std.mem.eql(u8, arg, "-t")) {
            options.show_tree = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            const message = try std.fmt.allocPrint(allocator, "unknown option: {s}", .{arg});
            options.diagnostics = .{ .unknown_option = message };
            break;
        } else {
            if (has_package) {
                options.diagnostics = .{ .multiple_package_names = "multiple package names provided." };
                break;
            }
            options.package_name = arg;
            has_package = true;
        }
    }

    if (options.diagnostics == null and !has_package) {
        options.diagnostics = .{ .no_package_name = "package name required." };
    }
    return options;
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
    try stdout.flush();

    if (pr.status != .merged)
        return;

    if (reached.len > 0) {
        try stdout.print("   {s}└─{s} Reachable in: ", .{ Color.dim, Color.reset });

        for (reached, 0..) |branch, i| {
            if (i > 0)
                try stdout.print("{s},{s} ", .{ Color.dim, Color.reset });

            try stdout.print("{s}{s}{s}", .{ Color.bright_green, branch, Color.reset });
        }

        try stdout.print("\n", .{});
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
    stdout.flush() catch return;
}

fn computeReachability(
    allocator: std.mem.Allocator,
    reached_set: *std.StringHashMap(void),
    base_branch: []const u8,
) !bool {
    // Get next branches
    const next = try branches.nextBranches(allocator, base_branch);
    defer {
        for (next) |n| allocator.free(n);
        allocator.free(next);
    }

    // Recursively check children to determine if any downstream is reachable
    var any_child_reached = false;
    for (next) |next_branch| {
        const child_reached = try computeReachability(allocator, reached_set, next_branch);
        any_child_reached = any_child_reached or child_reached;
    }

    // A branch is reachable if it's directly in reached_set OR any downstream branch is reachable
    const directly_reached = reached_set.contains(base_branch);
    const is_reachable = directly_reached or any_child_reached;

    // Add to reached_set if reachable
    if (is_reachable and !directly_reached) {
        const owned = try allocator.dupe(u8, base_branch);
        try reached_set.put(owned, {});
    }

    return is_reachable;
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
    defer {
        for (next) |n| allocator.free(n);
        allocator.free(next);
    }

    for (next) |next_branch| {
        try printBranchTree(allocator, stdout, reached_set, next_branch, indent + 2);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var io_buf: [4096]u8 = undefined;

    var stdout_writer = Io.File.stdout().writer(io, io_buf[0 .. io_buf.len / 2]);
    var stderr_writer = Io.File.stderr().writer(io, io_buf[io_buf.len / 2 ..]);
    var stderr = &stderr_writer.interface;
    var stdout = &stdout_writer.interface;

    const config = try parseArgs(
        allocator,
        init.minimal.args,
    );

    if (config.diagnostics) |diag| {
        switch (diag) {
            inline else => |message| {
                try stderr.print("Error: {s}\n", .{message});
                allocator.free(message);
            },
        }
        try stderr.flush();
        return;
    }

    if (config.show_help) {
        try printUsage(stdout, "npr");
        return;
    }
    // Initialize GitHub client
    var gh_client = github.GitHubClient.init(allocator);

    // Validate gh CLI is installed and authenticated
    gh_client.validate(io) catch |err| switch (err) {
        error.GhNotInstalled => {
            try stderr.print("Error: GitHub CLI (gh) is not installed.\nInstall it from https://cli.github.com/\n", .{});
            try stderr.flush();
            return err;
        },
        error.GhNotAuthenticated => {
            try stderr.print("Error: GitHub CLI is not authenticated.\nRun 'gh auth login' to authenticate.\n", .{});
            try stderr.flush();
            return err;
        },
    };

    try stdout.print("Searching for {s}...\n", .{config.package_name});
    try stdout.flush();

    // Search for PRs
    const prs = gh_client.searchPRsByChangedFiles(io, config.package_name, config.days) catch |err| {
        try stderr.print("Error searching GitHub: {}\n", .{err});
        try stderr.flush();
        return err;
    };

    if (prs.len == 0) {
        try stderr.print("No PRs found for '{s}' in the last {d} days.\n", .{ config.package_name, config.days });
        try stderr.flush();
        return;
    }

    // Get all tracked branches for checking
    const tracked = try branches.allTrackedBranches(allocator);
    defer {
        for (tracked) |branch| allocator.free(branch);
        allocator.free(tracked);
    }

    // Free PRs at end
    defer {
        for (prs) |*pr| {
            var mutable_pr = pr.*;
            mutable_pr.deinit(allocator);
        }
        allocator.free(prs);
    }

    // Process each PR sequentially
    for (prs, 0..) |pr, idx| {
        try stdout.print(
            "\r[{d}/{d}] ",
            .{ idx + 1, prs.len },
        );

        var reached_branches: [][]const u8 = &.{};
        defer {
            for (reached_branches) |branch| allocator.free(branch);
            if (reached_branches.len > 0) allocator.free(reached_branches);
        }

        // For merged PRs, check which branches contain the merge commit
        if (pr.status == .merged and pr.merge_commit_sha != null) {
            reached_branches = gh_client.branchesContainingCommit(
                io,
                tracked,
                pr.merge_commit_sha.?,
            ) catch blk: {
                break :blk &.{};
            };
        }

        // Clear progress line
        try stdout.print("\r{s}\r", .{" " ** 50});

        if (config.show_tree) {
            var reached_set = std.StringHashMap(void).init(allocator);
            defer {
                // Free the keys we added during computeReachability
                var it = reached_set.keyIterator();
                while (it.next()) |key| {
                    // Only free keys we allocated
                    var is_original = false;
                    for (reached_branches) |branch| {
                        if (key.*.ptr == branch.ptr) {
                            is_original = true;
                            break;
                        }
                    }
                    if (!is_original) {
                        allocator.free(key.*);
                    }
                }
                reached_set.deinit();
            }

            for (reached_branches) |branch| {
                try reached_set.put(branch, {});
            }

            _ = try computeReachability(allocator, &reached_set, pr.base_branch);

            try printTreeOutput(allocator, stdout, pr, reached_set);
            try stdout.print("\n", .{});
            try stdout.flush();
        } else {
            try printSimpleOutput(stdout, pr, reached_branches);
        }
    }
}
