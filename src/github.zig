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

pub const GitHubClient = struct {
    allocator: std.mem.Allocator,

    pub const ValidationError = error{
        GhNotInstalled,
        GhNotAuthenticated,
    };

    pub fn init(allocator: std.mem.Allocator) GitHubClient {
        return .{
            .allocator = allocator,
        };
    }

    /// Check if gh CLI is installed and authenticated
    pub fn validate(self: *GitHubClient) ValidationError!void {
        // Check if gh is installed by running 'gh --version'
        const version_argv = [_][]const u8{ "gh", "--version" };
        const version_result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &version_argv,
            .max_output_bytes = 4096,
        }) catch {
            return error.GhNotInstalled;
        };
        self.allocator.free(version_result.stdout);
        self.allocator.free(version_result.stderr);

        if (version_result.term.Exited != 0) {
            return error.GhNotInstalled;
        }

        // Check if gh is authenticated by running 'gh auth status'
        const auth_argv = [_][]const u8{ "gh", "auth", "status" };
        const auth_result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &auth_argv,
            .max_output_bytes = 4096,
        }) catch {
            return error.GhNotAuthenticated;
        };
        self.allocator.free(auth_result.stdout);
        self.allocator.free(auth_result.stderr);

        if (auth_result.term.Exited != 0) {
            return error.GhNotAuthenticated;
        }
    }

    pub fn searchPRsByChangedFiles(
        self: *GitHubClient,
        allocator: std.mem.Allocator,
        package_name: []const u8,
        days: u32,
    ) ![]PullRequest {
        const now = std.time.timestamp();
        const days_ago = now - (@as(i64, days) * 24 * 60 * 60);
        const date = try formatIsoDate(allocator, days_ago);
        defer allocator.free(date);

        const query = try std.fmt.allocPrint(
            allocator,
            "repo:NixOS/nixpkgs {s} type:pr created:>{s}",
            .{ package_name, date },
        );
        defer allocator.free(query);

        const encoded_query = try urlEncode(allocator, query);
        defer allocator.free(encoded_query);

        const endpoint = try std.fmt.allocPrint(
            allocator,
            "/search/issues?q={s}&per_page=100&sort=created&order=desc",
            .{encoded_query},
        );
        defer allocator.free(endpoint);

        const json_response = try self.makeRequest(endpoint);
        defer self.allocator.free(json_response);

        return try self.parseSearchResults(json_response);
    }

    pub fn checkCommitInBranch(
        self: *GitHubClient,
        allocator: std.mem.Allocator,
        commit_sha: []const u8,
        branch: []const u8,
    ) !bool {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "/repos/NixOS/nixpkgs/compare/{s}...{s}",
            .{ commit_sha, branch },
        );
        defer allocator.free(endpoint);

        const json_response = self.makeRequest(endpoint) catch {
            return false;
        };
        defer self.allocator.free(json_response);

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            json_response,
            .{},
        );
        defer parsed.deinit();

        const obj = parsed.value.object;

        if (obj.get("status")) |status_val| {
            const status = status_val.string;
            return std.mem.eql(u8, status, "ahead") or std.mem.eql(u8, status, "identical");
        }

        return false;
    }

    pub fn branchesContainingCommit(
        self: *GitHubClient,
        candidates: []const []const u8,
        commit_sha: []const u8,
    ) ![][]const u8 {
        if (candidates.len == 0) return &[_][]const u8{};

        const BranchCheckContext = struct {
            client: *GitHubClient,
            commit_sha: []const u8,
            branch: []const u8,
            result: bool = false,
        };

        const contexts = try self.allocator.alloc(BranchCheckContext, candidates.len);
        defer self.allocator.free(contexts);

        for (contexts, 0..) |*ctx, i| {
            ctx.* = .{
                .client = self,
                .commit_sha = commit_sha,
                .branch = candidates[i],
            };
        }

        var threads = try self.allocator.alloc(std.Thread, candidates.len);
        defer self.allocator.free(threads);

        const Worker = struct {
            fn check(ctx: *BranchCheckContext) void {
                ctx.result = ctx.client.checkCommitInBranch(ctx.client.allocator, ctx.commit_sha, ctx.branch) catch false;
            }
        };

        for (0..candidates.len) |i| {
            threads[i] = try std.Thread.spawn(.{}, Worker.check, .{&contexts[i]});
        }

        for (threads) |thread| {
            thread.join();
        }

        var result = try std.ArrayList([]const u8).initCapacity(self.allocator, candidates.len);
        errdefer {
            for (result.items) |item| self.allocator.free(item);
            result.deinit(self.allocator);
        }

        for (contexts) |ctx| {
            if (ctx.result) {
                const owned = try self.allocator.dupe(u8, ctx.branch);
                try result.append(self.allocator, owned);
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn makeRequest(self: *GitHubClient, endpoint: []const u8) ![]u8 {
        const argv = [_][]const u8{
            "gh",
            "api",
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "X-GitHub-Api-Version: 2022-11-28",
            endpoint,
        };

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &argv,
            .max_output_bytes = 10 * 1024 * 1024,
        }) catch {
            return error.GitHubRequestFailed;
        };

        if (result.term.Exited != 0) {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
            return error.GitHubRequestFailed;
        }

        self.allocator.free(result.stderr);
        return result.stdout;
    }

    fn parseSearchResults(self: *GitHubClient, json: []const u8) ![]PullRequest {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            json,
            .{},
        );
        defer parsed.deinit();

        const obj = parsed.value.object;
        const items = obj.get("items").?.array;

        var result = try std.ArrayList(PullRequest).initCapacity(self.allocator, items.items.len);
        errdefer {
            for (result.items) |*pr| pr.deinit(self.allocator);
            result.deinit(self.allocator);
        }

        for (items.items) |item| {
            const number = item.object.get("number").?.integer;
            const pr_details = try self.getPRDetails(self.allocator, number);
            try result.append(self.allocator, pr_details);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn getPRDetails(self: *GitHubClient, allocator: std.mem.Allocator, pr_number: i64) !PullRequest {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "/repos/NixOS/nixpkgs/pulls/{d}",
            .{pr_number},
        );
        defer allocator.free(endpoint);

        const json_response = try self.makeRequest(endpoint);
        defer self.allocator.free(json_response);

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            json_response,
            .{},
        );
        defer parsed.deinit();

        const obj = parsed.value.object;

        const title = try self.allocator.dupe(u8, obj.get("title").?.string);
        errdefer self.allocator.free(title);

        const base_branch = try self.allocator.dupe(u8, obj.get("base").?.object.get("ref").?.string);
        errdefer self.allocator.free(base_branch);

        const state = obj.get("state").?.string;
        const merged = if (obj.get("merged")) |m| m.bool else false;

        const status: PullRequestStatus = if (merged)
            .merged
        else if (std.mem.eql(u8, state, "open"))
            .open
        else
            .closed;

        const merge_commit_sha = if (obj.get("merge_commit_sha")) |sha_val|
            if (sha_val == .null) null else try self.allocator.dupe(u8, sha_val.string)
        else
            null;

        const merged_at = if (obj.get("merged_at")) |ma_val|
            if (ma_val == .null) null else try self.allocator.dupe(u8, ma_val.string)
        else
            null;

        return PullRequest{
            .number = pr_number,
            .title = title,
            .status = status,
            .base_branch = base_branch,
            .merge_commit_sha = merge_commit_sha,
            .merged_at = merged_at,
        };
    }
};

fn formatIsoDate(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return try std.fmt.allocPrint(
        allocator,
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

fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len * 2);
    errdefer result.deinit(allocator);

    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try result.append(allocator, c);
        } else if (c == ' ') {
            try result.append(allocator, '+');
        } else {
            try result.writer(allocator).print("%{X:0>2}", .{c});
        }
    }

    return try result.toOwnedSlice(allocator);
}
