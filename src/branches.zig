const std = @import("std");

const tracked_branches = [_][]const u8{
    "nixpkgs-unstable",
    "nixos-unstable",
    "nixos-unstable-small",
};

pub fn allTrackedBranches(allocator: std.mem.Allocator) ![][]const u8 {
    return dupeStrings(allocator, &tracked_branches);
}

pub fn nextBranches(allocator: std.mem.Allocator, branch: []const u8) ![][]const u8 {
    var result = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer freeStrings(allocator, result.items);

    if (std.mem.eql(u8, branch, "staging")) {
        try appendLiteral(allocator, &result, "staging-next");
    } else if (std.mem.eql(u8, branch, "staging-next") or std.mem.eql(u8, branch, "staging-nixos")) {
        try appendLiteral(allocator, &result, "master");
    } else if (std.mem.eql(u8, branch, "master")) {
        try appendLiteral(allocator, &result, "nixpkgs-unstable");
        try appendLiteral(allocator, &result, "nixos-unstable-small");
    } else if (stripPrefix(branch, "staging-next-")) |version| {
        if (isVersionNumber(version)) try appendFmt(allocator, &result, "release-{s}", .{version});
    } else if (stripPrefix(branch, "release-")) |version| {
        if (isVersionNumber(version)) {
            try appendFmt(allocator, &result, "nixpkgs-{s}-darwin", .{version});
            try appendFmt(allocator, &result, "nixos-{s}-small", .{version});
        }
    } else if (stripPrefix(branch, "nixos-")) |name| {
        if (stripSuffix(name, "-small")) |channel| try appendFmt(allocator, &result, "nixos-{s}", .{channel});
    } else if (stripPrefix(branch, "staging-")) |version| {
        if (parseReleaseVersion(version)) |release| {
            if (release.major <= 20) {
                try appendFmt(allocator, &result, "release-{s}", .{version});
            } else {
                try appendFmt(allocator, &result, "staging-next-{s}", .{version});
            }
        }
    }

    return try result.toOwnedSlice(allocator);
}

const ReleaseVersion = struct { major: u8, minor: u8 };

fn parseReleaseVersion(version: []const u8) ?ReleaseVersion {
    if (version.len != 5 or version[2] != '.') return null;
    const major = std.fmt.parseInt(u8, version[0..2], 10) catch return null;
    const minor = std.fmt.parseInt(u8, version[3..5], 10) catch return null;
    return .{ .major = major, .minor = minor };
}

fn isVersionNumber(version: []const u8) bool {
    if (version.len == 0) return false;
    for (version) |c| {
        if (c != '.' and !std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn stripPrefix(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    return s[prefix.len..];
}

fn stripSuffix(s: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, s, suffix)) return null;
    return s[0 .. s.len - suffix.len];
}

fn appendLiteral(
    allocator: std.mem.Allocator,
    result: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    try result.append(allocator, try allocator.dupe(u8, value));
}

fn appendFmt(
    allocator: std.mem.Allocator,
    result: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var string: std.Io.Writer.Allocating = .init(allocator);
    errdefer string.deinit();

    try string.writer.print(fmt, args);
    try result.append(allocator, try string.toOwnedSlice());
}

fn dupeStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![][]const u8 {
    var result = try std.ArrayList([]const u8).initCapacity(allocator, strings.len);
    errdefer freeStrings(allocator, result.items);

    for (strings) |string| try appendLiteral(allocator, &result, string);
    return try result.toOwnedSlice(allocator);
}

fn freeStrings(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
}

fn expectNext(branch: []const u8, expected: []const []const u8) !void {
    const allocator = std.testing.allocator;
    const next = try nextBranches(allocator, branch);
    defer {
        for (next) |n| allocator.free(n);
        allocator.free(next);
    }

    try std.testing.expectEqual(expected.len, next.len);
    for (expected, next) |e, n| try std.testing.expectEqualStrings(e, n);
}

test "branch flow" {
    try expectNext("staging", &.{"staging-next"});
    try expectNext("staging-next", &.{"master"});
    try expectNext("master", &.{ "nixpkgs-unstable", "nixos-unstable-small" });
    try expectNext("nixos-unstable-small", &.{"nixos-unstable"});
    try expectNext("release-25.11", &.{ "nixpkgs-25.11-darwin", "nixos-25.11-small" });
    try expectNext("staging-20.09", &.{"release-20.09"});
    try expectNext("staging-25.11", &.{"staging-next-25.11"});
}
