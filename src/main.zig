const std = @import("std");
const github = @import("github.zig");
const branches = @import("branches.zig");

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

const Config = struct {
    package_name: []const u8,
    days: u32 = 15,
    show_tree: bool = false,
};

fn printUsage(stdout: *std.fs.File.Writer, prog_name: []const u8) !void {
    stdout.interface.print(
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
    ) catch return stdout.err.?;
    stdout.interface.flush() catch return;
}

fn parseArgs(allocator: std.mem.Allocator, stdout: *std.fs.File.Writer, stderr: *std.fs.File.Writer) !?Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const prog_name = args.next() orelse "npr";

    var config = Config{
        .package_name = undefined,
    };

    var has_package = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stdout, prog_name);
            return null;
        } else if (std.mem.eql(u8, arg, "--days")) {
            const days_str = args.next() orelse {
                stderr.interface.print(
                    "Error: --days requires a value\n",
                    .{},
                ) catch return stderr.err.?;
                return error.InvalidArgs;
            };
            config.days = std.fmt.parseInt(u32, days_str, 10) catch {
                stderr.interface.print("Error: invalid days value: {s}\n", .{days_str}) catch return stderr.err.?;
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--tree")) {
            config.show_tree = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            stderr.interface.print(
                "Error: unknown option: {s}\n",
                .{arg},
            ) catch return stderr.err.?;
            try printUsage(stdout, prog_name);
            return error.InvalidArgs;
        } else {
            if (has_package) {
                stderr.interface.print("Error: multiple package names provided\n", .{}) catch return stderr.err.?;
                return error.InvalidArgs;
            }
            config.package_name = arg;
            has_package = true;
        }
    }

    if (!has_package) {
        stderr.interface.print("Error: package name required\n\n", .{}) catch return stderr.err.?;
        try printUsage(stdout, prog_name);
        return error.InvalidArgs;
    }

    return config;
}

fn printSimpleOutput(
    stdout: *std.fs.File.Writer,
    pr: github.PullRequest,
    reached: []const []const u8,
) !void {
    const status_str = switch (pr.status) {
        .open => Color.blue ++ "open" ++ Color.reset,
        .closed => Color.red ++ "closed" ++ Color.reset,
        .merged => Color.green ++ "merged" ++ Color.reset,
    };

    stdout.interface.print("{s}PR:{s} {s}{s}{s} ({s}) {s}#{d}{s}\n", .{
        Color.bold,
        Color.reset,
        Color.cyan,
        pr.title,
        Color.reset,
        status_str,
        Color.dim,
        pr.number,
        Color.reset,
    }) catch return stdout.err.?;
    stdout.interface.flush() catch return;

    if (pr.status == .merged) {
        if (reached.len > 0) {
            stdout.interface.print("   {s}└─{s} Reachable in: ", .{ Color.dim, Color.reset }) catch return stdout.err.?;
            for (reached, 0..) |branch, i| {
                if (i > 0) stdout.interface.print(
                    "{s},{s} ",
                    .{ Color.dim, Color.reset },
                ) catch return stdout.err.?;
                stdout.interface.print(
                    "{s}{s}{s}",
                    .{ Color.bright_green, branch, Color.reset },
                ) catch return stdout.err.?;
                stdout.interface.flush() catch return;
            }
            stdout.interface.print("\n", .{}) catch return stdout.err.?;
        } else {
            stdout.interface.print("   {s}└─{s} Reachable in: {s}None{s} {s}(pending Hydra/Mirror){s}\n", .{
                Color.dim,
                Color.reset,
                Color.yellow,
                Color.reset,
                Color.dim,
                Color.reset,
            }) catch return stdout.err.?;
            stdout.interface.flush() catch return;
        }
    }
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
    stdout: *std.fs.File.Writer,
    pr: github.PullRequest,
    reached_set: std.StringHashMap(void),
    base_branch: []const u8,
    indent: usize,
) !void {
    const status_str = switch (pr.status) {
        .open => "open",
        .closed => "closed",
        .merged => "merged",
    };

    if (indent == 0) {
        stdout.interface.print(
            "PR: {s} ({s}) #{d}\n",
            .{ pr.title, status_str, pr.number },
        ) catch return stdout.err.?;
    }

    // Print current branch
    const spaces = "                                        ";
    const indent_str = spaces[0..@min(indent, spaces.len)];

    const in_branch = reached_set.contains(base_branch);
    const status_icon = if (in_branch) "✓" else "✗";

    stdout.interface.print(
        "{s}{s} {s}\n",
        .{ indent_str, status_icon, base_branch },
    ) catch return stdout.err.?;

    // Get next branches
    const next = try branches.nextBranches(allocator, base_branch);
    defer {
        for (next) |n| allocator.free(n);
        allocator.free(next);
    }

    for (next) |next_branch| {
        try printTreeOutput(allocator, stdout, pr, reached_set, next_branch, indent + 2);
    }
    stdout.interface.flush() catch return;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    var stderr = std.fs.File.stderr().writer(&stderr_buf);

    const config = try parseArgs(allocator, &stdout, &stderr) orelse return;

    stdout.interface.print("Searching for {s}...\n", .{config.package_name}) catch return stdout.err.?;
    stdout.interface.flush() catch return;

    // Initialize GitHub client
    var gh_client = github.GitHubClient.init(allocator);

    // Search for PRs
    const prs = gh_client.searchPRsByChangedFiles(allocator, config.package_name, config.days) catch |err| {
        stderr.interface.print("Error searching GitHub: {}\n", .{err}) catch return stdout.err.?;
        stderr.interface.flush() catch return;
        return err;
    };

    if (prs.len == 0) {
        stderr.interface.print(
            "No PRs found for '{s}' in the last {d} days.\n",
            .{ config.package_name, config.days },
        ) catch return stdout.err.?;
        stderr.interface.flush() catch return;
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
        stdout.interface.print(
            "\r[{d}/{d}] ",
            .{ idx + 1, prs.len },
        ) catch return stdout.err.?;

        var reached_branches: [][]const u8 = &.{};
        defer {
            for (reached_branches) |branch| allocator.free(branch);
            if (reached_branches.len > 0) allocator.free(reached_branches);
        }

        // For merged PRs, check which branches contain the merge commit
        if (pr.status == .merged and pr.merge_commit_sha != null) {
            reached_branches = gh_client.branchesContainingCommit(
                tracked,
                pr.merge_commit_sha.?,
            ) catch blk: {
                break :blk &.{};
            };
        }

        // Clear progress line
        stdout.interface.print("\r{s}\r", .{" " ** 50}) catch return stdout.err.?;

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

            try printTreeOutput(allocator, &stdout, pr, reached_set, pr.base_branch, 0);
            stdout.interface.print("\n", .{}) catch return stdout.err.?;
            stdout.interface.flush() catch return;
        } else {
            try printSimpleOutput(&stdout, pr, reached_branches);
        }
    }
}
