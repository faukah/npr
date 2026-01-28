const std = @import("std");

const BranchMapping = struct {
    pattern: []const u8,
    nexts: []const []const u8,
};

const branch_mappings = [_]BranchMapping{
    .{ .pattern = "^staging$", .nexts = &.{"staging-next"} },
    .{ .pattern = "^staging-next$", .nexts = &.{"master"} },
    .{ .pattern = "^staging-next-([\\d.]+)$", .nexts = &.{"release-$1"} },
    .{ .pattern = "^master$", .nexts = &.{ "nixpkgs-unstable", "nixos-unstable-small" } },
    .{ .pattern = "^nixos-(.*)-small$", .nexts = &.{"nixos-$1"} },
    .{ .pattern = "^release-([\\d.]+)$", .nexts = &.{ "nixpkgs-$1-darwin", "nixos-$1-small" } },
    .{ .pattern = "^staging-((1.|20)\\.\\d{2})$", .nexts = &.{"release-$1"} },
    .{ .pattern = "^staging-((2[1-9]|[3-90].)\\.\\d{2})$", .nexts = &.{"staging-next-$1"} },
    .{ .pattern = "^staging-nixos$", .nexts = &.{"master"} },
};

pub fn nextBranches(allocator: std.mem.Allocator, branch: []const u8) ![][]const u8 {
    var result = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }

    for (branch_mappings) |mapping| {
        if (try matchesPattern(branch, mapping.pattern)) {
            for (mapping.nexts) |next_pattern| {
                const expanded = try expandPattern(allocator, branch, mapping.pattern, next_pattern);
                try result.append(allocator, expanded);
            }
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn matchesPattern(branch: []const u8, pattern: []const u8) !bool {
    // Handle simple exact match after removing ^ and $
    if (std.mem.startsWith(u8, pattern, "^") and std.mem.endsWith(u8, pattern, "$")) {
        const inner = pattern[1 .. pattern.len - 1];

        // If no regex special chars, do exact match
        if (std.mem.indexOf(u8, inner, "(") == null and
            std.mem.indexOf(u8, inner, "[") == null and
            std.mem.indexOf(u8, inner, ".") == null)
        {
            return std.mem.eql(u8, branch, inner);
        }

        // Handle patterns with capture groups
        // This is a simplified regex matcher for the specific patterns we use
        return try simpleRegexMatch(branch, inner);
    }

    return false;
}

fn simpleRegexMatch(text: []const u8, pattern: []const u8) !bool {
    // Handle staging-next-XX.XX pattern
    if (std.mem.eql(u8, pattern, "staging-next-([\\d.]+)")) {
        if (!std.mem.startsWith(u8, text, "staging-next-")) return false;
        const suffix = text["staging-next-".len..];
        return isVersionNumber(suffix);
    }

    // Handle release-XX.XX pattern
    if (std.mem.eql(u8, pattern, "release-([\\d.]+)")) {
        if (!std.mem.startsWith(u8, text, "release-")) return false;
        const suffix = text["release-".len..];
        return isVersionNumber(suffix);
    }

    // Handle nixos-XXX-small pattern
    if (std.mem.eql(u8, pattern, "nixos-(.*)-small")) {
        return std.mem.startsWith(u8, text, "nixos-") and std.mem.endsWith(u8, text, "-small");
    }

    // Handle staging-XX.XX patterns (new releases 21+)
    if (std.mem.eql(u8, pattern, "staging-((2[1-9]|[3-90].)\\.\\d{2})")) {
        if (!std.mem.startsWith(u8, text, "staging-")) return false;
        const suffix = text["staging-".len..];
        if (suffix.len != 5) return false; // Must be XX.XX
        if (suffix[2] != '.') return false;

        const first_two = suffix[0..2];
        const major = std.fmt.parseInt(u8, first_two, 10) catch return false;
        return major >= 21;
    }

    return false;
}

fn isVersionNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c != '.' and (c < '0' or c > '9')) return false;
    }
    return true;
}

fn expandPattern(allocator: std.mem.Allocator, text: []const u8, pattern: []const u8, replacement: []const u8) ![]const u8 {
    // Extract capture group from text based on pattern
    if (std.mem.indexOf(u8, replacement, "$1")) |_| {
        const capture = try extractCapture(text, pattern);
        return try std.mem.replaceOwned(u8, allocator, replacement, "$1", capture);
    }

    return allocator.dupe(u8, replacement);
}

fn extractCapture(text: []const u8, pattern: []const u8) ![]const u8 {
    // Strip anchors from pattern for comparison
    var pat = pattern;
    if (std.mem.startsWith(u8, pat, "^")) pat = pat[1..];
    if (std.mem.endsWith(u8, pat, "$")) pat = pat[0 .. pat.len - 1];

    // Handle staging-next-XX.XX pattern
    if (std.mem.eql(u8, pat, "staging-next-([\\d.]+)")) {
        return text["staging-next-".len..];
    }

    // Handle release-XX.XX pattern
    if (std.mem.eql(u8, pat, "release-([\\d.]+)")) {
        return text["release-".len..];
    }

    // Handle nixos-XXX-small pattern
    if (std.mem.eql(u8, pat, "nixos-(.*)-small")) {
        const start = "nixos-".len;
        const end = text.len - "-small".len;
        return text[start..end];
    }

    // Handle staging-XX.XX patterns
    if (std.mem.indexOf(u8, pat, "staging-((") != null) {
        return text["staging-".len..];
    }

    return "";
}

/// Get all candidate branches that we track
pub fn allTrackedBranches(allocator: std.mem.Allocator) ![][]const u8 {
    var result = try std.ArrayList([]const u8).initCapacity(allocator, 3);
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }

    // Only track the three unstable branches
    const unstable_branches = [_][]const u8{
        "nixpkgs-unstable",
        "nixos-unstable",
        "nixos-unstable-small",
    };

    for (unstable_branches) |branch| {
        try result.append(allocator, try allocator.dupe(u8, branch));
    }

    return try result.toOwnedSlice(allocator);
}

test "staging-next pattern" {
    const allocator = std.testing.allocator;
    const nexts = try nextBranches(allocator, "staging-next");
    defer {
        for (nexts) |n| allocator.free(n);
        allocator.free(nexts);
    }

    try std.testing.expectEqual(@as(usize, 1), nexts.len);
    try std.testing.expectEqualStrings("master", nexts[0]);
}

test "master pattern" {
    const allocator = std.testing.allocator;
    const nexts = try nextBranches(allocator, "master");
    defer {
        for (nexts) |n| allocator.free(n);
        allocator.free(nexts);
    }

    try std.testing.expectEqual(@as(usize, 2), nexts.len);
}
