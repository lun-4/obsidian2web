const std = @import("std");
const main = @import("main.zig");
const util = @import("util.zig");
const chrono = @import("chrono");
const Context = main.Context;
const OwnedStringList = main.OwnedStringList;
const logger = std.log.scoped(.obsidian2web_page);

ctx: *const Context,
filesystem_path: []const u8,
title: []const u8,
attributes: PageAttributes,

tags: ?OwnedStringList = null,
titles: ?OwnedStringList = null,
state: State = .{ .unbuilt = {} },

maybe_first_image: ?[]const u8 = null,

const Self = @This();

pub const State = union(enum) {
    unbuilt: void,
    pre: []const u8,
    main: void,
    post: void,
};

pub const PageAttributes = struct {
    ctime: i64,

    fn parseString(data: []const u8) []const u8 {
        return std.mem.trim(u8, data, "\"");
    }

    fn parseDate(date_string: []const u8) !i64 {
        var it = std.mem.split(u8, date_string, "-");
        const year = try std.fmt.parseInt(std.time.epoch.Year, it.next().?, 10);
        const month_int = try std.fmt.parseInt(u4, it.next().?, 10);
        const month = try std.meta.intToEnum(std.time.epoch.Month, month_int);
        const day = try std.fmt.parseInt(u5, it.next().?, 10);

        logger.warn("{d} - {} - {d}", .{ year, month, day });
        const naive_dt = try chrono.NaiveDateTime.ymd_hms(year, month.numeric(), day, 0, 0, 0);
        logger.debug("dt {}", .{naive_dt.date});
        const dt = chrono.DateTime.utc(naive_dt, chrono.timezone.UTC);
        logger.debug("dt {}", .{dt});
        logger.debug("dt ts {}", .{dt.toTimestamp()});
        return dt.toTimestamp();
    }

    pub fn fromFile(file: std.fs.File) !@This() {
        var stat = try file.stat();
        var self = @This(){
            .ctime = @as(i64, @intCast(@divTrunc(stat.ctime, std.time.ns_per_s))),
        };
        var first_bytes_buffer: [256]u8 = undefined;

        const bytes_read = try file.reader().read(&first_bytes_buffer);
        const first_bytes = first_bytes_buffer[0..bytes_read];

        logger.debug("first '{s}'", .{first_bytes});
        const first_plus_sign_idx = std.mem.indexOf(u8, first_bytes, "+++") orelse return self;
        const last_plus_sign_idx = std.mem.indexOfPos(u8, first_bytes, first_plus_sign_idx + 1, "+++") orelse return self;

        logger.debug("idx {d} {d}", .{ first_plus_sign_idx, last_plus_sign_idx });
        const attributes_text = first_bytes[first_plus_sign_idx + 3 .. last_plus_sign_idx];
        var lines = std.mem.split(u8, attributes_text, "\n");
        logger.debug("text '{s}'", .{attributes_text});
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var key_value_iterator = std.mem.split(u8, line, "=");
            const key = std.mem.trim(u8, key_value_iterator.next() orelse continue, " ");
            const value = std.mem.trim(u8, key_value_iterator.next() orelse {
                logger.err("key '{s}' does not have value", .{key});
                return error.InvalidAttribute;
            }, " ");

            if (std.mem.eql(u8, key, "date")) {
                const date_string = parseString(value);
                self.ctime = try parseDate(date_string);
            }
        }
        return self;
    }

    test "fallbacks to system ctime" {
        const This = @This();
        std.testing.log_level = .debug;

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        const current_time = std.time.timestamp();
        var file = try tmp_dir.dir.createFile("test.md", .{ .read = true });
        defer file.close();

        const attrs = try This.fromFile(file);

        const delta = try std.math.absInt(attrs.ctime - current_time);
        logger.debug("curtime = {d}", .{current_time});
        logger.debug("ctime = {d}", .{attrs.ctime});
        logger.debug("delta = {d}", .{delta});
        try std.testing.expect(delta < 10);

        const date_from_attrs = (std.time.epoch.EpochSeconds{
            .secs = @as(u64, @intCast(attrs.ctime)),
        }).getEpochDay().calculateYearDay();
        const date_from_curtime = (std.time.epoch.EpochSeconds{
            .secs = @as(u64, @intCast(current_time)),
        }).getEpochDay().calculateYearDay();

        try std.testing.expectEqual(date_from_curtime.day, date_from_attrs.day);
        try std.testing.expectEqual(date_from_curtime.year, date_from_attrs.year);

        const month_from_curtime = date_from_curtime.calculateMonthDay();

        const naive_dt = try chrono.NaiveDateTime.from_timestamp(attrs.ctime, 0);
        try std.testing.expectEqual(date_from_curtime.year, @as(u16, @intCast(naive_dt.date.year())));
        try std.testing.expectEqual(month_from_curtime.month.numeric(), naive_dt.date.month().number());
        try std.testing.expectEqual(month_from_curtime.day_index + 1, naive_dt.date.day());
    }

    test "parses ctime" {
        const This = @This();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        var file = try tmp_dir.dir.createFile("test.md", .{ .read = true });
        defer file.close();

        try file.writeAll(
            \\+++
            \\date="2023-03-04"
            \\+++
        );
        try file.seekTo(0);
        const attrs = try This.fromFile(file);
        const naive_dt = try chrono.NaiveDateTime.from_timestamp(attrs.ctime, 0);

        try std.testing.expectEqual(@as(i19, 2023), naive_dt.date.year());
        try std.testing.expectEqual(@as(i19, 3), naive_dt.date.month().number());
        try std.testing.expectEqual(@as(i19, 4), naive_dt.date.day());

        const date_from_attrs = (std.time.epoch.EpochSeconds{
            .secs = @as(u64, @intCast(attrs.ctime)),
        }).getEpochDay().calculateYearDay();

        const month_from_attrs = date_from_attrs.calculateMonthDay();

        try std.testing.expectEqual(@as(i19, 2023), date_from_attrs.year);
        try std.testing.expectEqual(@as(i19, 3), month_from_attrs.month.numeric());
        try std.testing.expectEqual(@as(i19, 4), month_from_attrs.day_index + 1);
    }
};

/// assumes given path is a ".md" file.
pub fn fromPath(ctx: *const Context, fspath: []const u8) !Self {
    const title_raw = std.fs.path.basename(fspath);
    const title = title_raw[0 .. title_raw.len - 3];
    logger.info("create page with title '{s}' @ {s}", .{ title, fspath });

    var file = try std.fs.cwd().openFile(fspath, .{});
    defer file.close();
    const attributes = try PageAttributes.fromFile(file);

    return Self{
        .ctx = ctx,
        .filesystem_path = fspath,
        .attributes = attributes,
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
    if (self.maybe_first_image) |image| self.ctx.allocator.free(image);
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
    const stripped = util.stripLeft(self.filesystem_path, self.ctx.build_file.vault_path);
    // if you triggered this assertion, its likely vault path ended with a slash,
    // removing it should work.
    std.debug.assert(stripped[0] == '/'); // TODO better path handling code
    const relative_fspath = stripped[1..];
    std.debug.assert(relative_fspath[0] != '/'); // must be relative afterwards
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

pub fn fetchPreview(self: Self, buffer: []u8) ![]const u8 {
    var page_fd = try std.fs.cwd().openFile(
        self.filesystem_path,
        .{ .mode = .read_only },
    );
    defer page_fd.close();
    const page_preview_text_read_bytes = try page_fd.read(buffer);
    return buffer[0..page_preview_text_read_bytes];
}
