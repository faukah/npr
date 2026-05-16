const std = @import("std");

pub const PullRequestStatus = enum {
    open,
    closed,
    merged,
};

pub const PullRequest = struct {
    number: i64,
    title: []const u8,
    status: PullRequestStatus,
    base_branch: []const u8,
    merge_commit_sha: ?[]const u8,
    merged_at: ?[]const u8,

    pub fn deinit(self: *PullRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.base_branch);
        if (self.merge_commit_sha) |sha| allocator.free(sha);
        if (self.merged_at) |date| allocator.free(date);
    }
};

const json_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

const SearchResponse = struct {
    items: []const struct { number: i64 },
};

const CompareResponse = struct {
    status: []const u8,
};

const PullResponse = struct {
    number: i64,
    title: []const u8,
    state: []const u8,
    merged: bool,
    merge_commit_sha: ?[]const u8,
    merged_at: ?[]const u8,
    base: struct { ref: []const u8 },
};

pub const GitHubClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,

    pub const ValidationError = error{
        GhNotInstalled,
        GhNotAuthenticated,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *std.process.Environ.Map,
    ) !GitHubClient {
        try sanitizeEnv(environ_map);
        return .{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
        };
    }

    pub fn validate(self: *GitHubClient) ValidationError!void {
        if (!self.commandSucceeds(&.{ "gh", "--version" })) return error.GhNotInstalled;
        if (!self.commandSucceeds(&.{ "gh", "auth", "status" })) return error.GhNotAuthenticated;
    }

    pub fn searchPRsByChangedFiles(
        self: *GitHubClient,
        package_name: []const u8,
        days: u32,
    ) ![]PullRequest {
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const days_ago = now - (@as(i64, days) * std.time.s_per_day);

        var date_buffer: [20]u8 = undefined;
        const date = try formatIsoDate(&date_buffer, days_ago);

        var endpoint: std.Io.Writer.Allocating = .init(self.allocator);
        defer endpoint.deinit();

        try endpoint.writer.writeAll("/search/issues?q=");
        try writeUrlEncoded(&endpoint.writer, "repo:NixOS/nixpkgs ");
        try writeUrlEncoded(&endpoint.writer, package_name);
        try writeUrlEncoded(&endpoint.writer, " type:pr created:>");
        try writeUrlEncoded(&endpoint.writer, date);
        try endpoint.writer.writeAll("&per_page=100&sort=created&order=desc");

        const json_response = try self.makeRequest(endpoint.written());
        defer self.allocator.free(json_response);

        return try self.parseSearchResults(json_response);
    }

    pub fn checkCommitInBranch(
        self: *GitHubClient,
        commit_sha: []const u8,
        branch: []const u8,
    ) !bool {
        var endpoint_buffer: [256]u8 = undefined;
        const endpoint = std.fmt.bufPrint(
            &endpoint_buffer,
            "/repos/NixOS/nixpkgs/compare/{s}...{s}",
            .{ commit_sha, branch },
        ) catch return false;

        const json_response = self.makeRequest(endpoint) catch return false;
        defer self.allocator.free(json_response);

        const parsed = try std.json.parseFromSlice(CompareResponse, self.allocator, json_response, json_options);
        defer parsed.deinit();

        return std.mem.eql(u8, parsed.value.status, "ahead") or
            std.mem.eql(u8, parsed.value.status, "identical");
    }

    pub fn branchesContainingCommit(
        self: *GitHubClient,
        candidates: []const []const u8,
        commit_sha: []const u8,
    ) ![][]const u8 {
        var result = try std.ArrayList([]const u8).initCapacity(self.allocator, candidates.len);
        errdefer {
            for (result.items) |item| self.allocator.free(item);
            result.deinit(self.allocator);
        }

        for (candidates) |branch| {
            if (self.checkCommitInBranch(commit_sha, branch) catch false) {
                try result.append(self.allocator, try self.allocator.dupe(u8, branch));
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn commandSucceeds(self: *GitHubClient, argv: []const []const u8) bool {
        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .environ_map = self.environ_map,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch return false;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return childSucceeded(result.term);
    }

    fn makeRequest(self: *GitHubClient, endpoint: []const u8) ![]u8 {
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{
                "gh",
                "api",
                "-H",
                "Accept: application/vnd.github+json",
                "-H",
                "X-GitHub-Api-Version: 2022-11-28",
                endpoint,
            },
            .environ_map = self.environ_map,
            .stdout_limit = .limited(10 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch return error.GitHubRequestFailed;
        errdefer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (!childSucceeded(result.term)) return error.GitHubRequestFailed;
        return result.stdout;
    }

    fn parseSearchResults(self: *GitHubClient, json: []const u8) ![]PullRequest {
        const parsed = try std.json.parseFromSlice(SearchResponse, self.allocator, json, json_options);
        defer parsed.deinit();

        var result = try std.ArrayList(PullRequest).initCapacity(self.allocator, parsed.value.items.len);
        errdefer {
            for (result.items) |*pr| pr.deinit(self.allocator);
            result.deinit(self.allocator);
        }

        for (parsed.value.items) |item| {
            try result.append(self.allocator, try self.getPRDetails(item.number));
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn getPRDetails(self: *GitHubClient, pr_number: i64) !PullRequest {
        var endpoint_buffer: [64]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(
            &endpoint_buffer,
            "/repos/NixOS/nixpkgs/pulls/{d}",
            .{pr_number},
        );

        const json_response = try self.makeRequest(endpoint);
        defer self.allocator.free(json_response);

        const parsed = try std.json.parseFromSlice(PullResponse, self.allocator, json_response, json_options);
        defer parsed.deinit();

        const pr = parsed.value;
        const title = try self.allocator.dupe(u8, pr.title);
        errdefer self.allocator.free(title);

        const base_branch = try self.allocator.dupe(u8, pr.base.ref);
        errdefer self.allocator.free(base_branch);

        const status: PullRequestStatus = if (pr.merged)
            .merged
        else if (std.mem.eql(u8, pr.state, "open"))
            .open
        else
            .closed;

        const merge_commit_sha = if (pr.merge_commit_sha) |sha| try self.allocator.dupe(u8, sha) else null;
        errdefer if (merge_commit_sha) |sha| self.allocator.free(sha);

        const merged_at = if (pr.merged_at) |date| try self.allocator.dupe(u8, date) else null;
        errdefer if (merged_at) |date| self.allocator.free(date);

        return .{
            .number = pr.number,
            .title = title,
            .status = status,
            .base_branch = base_branch,
            .merge_commit_sha = merge_commit_sha,
            .merged_at = merged_at,
        };
    }
};

fn childSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn sanitizeEnv(env: *std.process.Environ.Map) !void {
    _ = env.swapRemove("GH_FORCE_TTY");
    _ = env.swapRemove("FORCE_COLOR");

    try env.put("NO_COLOR", "1");
    try env.put("CLICOLOR", "0");
    try env.put("CLICOLOR_FORCE", "0");
    try env.put("GH_NO_UPDATE_NOTIFIER", "1");
    try env.put("GH_PAGER", "cat");
}

fn formatIsoDate(buffer: []u8, timestamp: i64) ![]const u8 {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return try std.fmt.bufPrint(
        buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn writeUrlEncoded(writer: *std.Io.Writer, input: []const u8) !void {
    const hex = "0123456789ABCDEF";

    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try writer.writeByte(c);
        } else if (c == ' ') {
            try writer.writeByte('+');
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[c >> 4]);
            try writer.writeByte(hex[c & 0x0f]);
        }
    }
}
