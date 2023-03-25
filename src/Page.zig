const std = @import("std");
const main = @import("main.zig");
const util = @import("util.zig");
const Context = main.Context;
const OwnedStringList = main.OwnedStringList;
const logger = std.log.scoped(.obsidian2web_page);

ctx: *const Context,
filesystem_path: []const u8,
title: []const u8,
ctime: i128,

tags: ?OwnedStringList = null,
titles: ?OwnedStringList = null,
state: State = .{ .unbuilt = {} },

const Self = @This();

pub const State = union(enum) {
    unbuilt: void,
    pre: []const u8,
    main: void,
    post: void,
};

/// assumes given path is a ".md" file.
pub fn fromPath(ctx: *const Context, fspath: []const u8) !Self {
    const title_raw = std.fs.path.basename(fspath);
    const title = title_raw[0 .. title_raw.len - 3];
    logger.info("create page with title '{s}' @ {s}", .{ title, fspath });
    var stat = try std.fs.cwd().statFile(fspath);
    return Self{
        .ctx = ctx,
        .filesystem_path = fspath,
        .ctime = stat.ctime,
        .title = title,
    };
}

pub fn deinit(self: Self) void {
    if (self.tags) |tags| {
        for (tags.items) |tag| self.ctx.allocator.free(tag);
        tags.deinit();
    }
    if (self.titles) |titles| {
        for (titles.items) |title| self.ctx.allocator.free(title);
        titles.deinit();
    }
}

pub fn format(
    self: Self,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    return writer.print("Page<path='{s}'>", .{self.filesystem_path});
}

pub fn relativePath(self: Self) []const u8 {
    const relative_fspath = util.stripLeft(self.filesystem_path, self.ctx.build_file.vault_path)[1..];
    std.debug.assert(relative_fspath[0] != '/'); // must be relative
    return relative_fspath;
}

pub fn fetchHtmlPath(self: Self, allocator: std.mem.Allocator) ![]const u8 {
    // output_path = relative_fspath with ".md" replaced to ".html"

    var raw_output_path = try std.fs.path.resolve(
        allocator,
        &[_][]const u8{ "public", self.relativePath() },
    );
    defer allocator.free(raw_output_path);

    return try util.replaceStrings(
        allocator,
        raw_output_path,
        ".md",
        ".html",
    );
}

pub fn fetchWebPath(
    self: Self,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const output_path = try self.fetchHtmlPath(allocator);
    defer allocator.free(output_path);

    // to generate web_path, we need to:
    //  - take html_path
    //  - remove public/
    //  - replace std.fs.path.sep to '/'
    //  - Uri.escapeString

    var trimmed_output_path = util.stripLeft(
        output_path,
        "public" ++ std.fs.path.sep_str,
    );

    var trimmed_output_path_2 = try util.replaceStrings(
        allocator,
        trimmed_output_path,
        std.fs.path.sep_str,
        "/",
    );
    defer allocator.free(trimmed_output_path_2);
    const web_path = try customEscapeString(allocator, trimmed_output_path_2);
    return web_path;
}

/// unreserved  = ALPHA / DIGIT / "-" / "." / "_" / "~"
fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn isAuthoritySeparator(c: u8) bool {
    return switch (c) {
        '/', '?', '#' => true,
        else => false,
    };
}

// stolen from std.Uri
fn customEscapeString(allocator: std.mem.Allocator, input: []const u8) error{OutOfMemory}![]const u8 {
    var outsize: usize = 0;
    for (input) |c| {
        outsize += if (isUnreserved(c) or c == '/') @as(usize, 1) else 3;
    }
    var output = try allocator.alloc(u8, outsize);
    var outptr: usize = 0;

    for (input) |c| {
        if (isUnreserved(c) or c == '/') {
            output[outptr] = c;
            outptr += 1;
        } else {
            var buf: [2]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{X:0>2}", .{c}) catch unreachable;

            output[outptr + 0] = '%';
            output[outptr + 1] = buf[0];
            output[outptr + 2] = buf[1];
            outptr += 3;
        }
    }
    return output;
}
