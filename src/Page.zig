const std = @import("std");
const main = @import("main.zig");
const util = @import("util.zig");
const chrono = @import("chrono");
const Context = main.Context;
const OwnedStringList = main.OwnedStringList;
const logger = std.log.scoped(.obsidian2web_page);

page_type: PageType,
ctx: *const Context,
filesystem_path: []const u8,
title: []const u8,
attributes: PageAttributes,

tags: ?OwnedStringList = null,
titles: ?TitleList = null,
state: State = .{ .unbuilt = {} },
has_footnotes: bool = false,

maybe_first_image: ?[]const u8 = null,

const Self = @This();

pub const Title = struct {
    text: []const u8,
    level: usize,
};

pub const TitleList = std.array_list.Managed(Title);

pub const State = union(enum) {
    unbuilt: void,
    pre: []const u8,
    main: void,
    post: void,
};

pub const PageType = enum { md, canvas, asset };

pub const PageAttributes = struct {
    ctime: i64,

    fn parseString(data: []const u8) []const u8 {
        return std.mem.trim(u8, data, "\"");
    }

    fn parseDate(date_string: []const u8) !i64 {
        var it = std.mem.splitSequence(u8, date_string, "-");
        const year = try std.fmt.parseInt(std.time.epoch.Year, it.next().?, 10);
        const month_int = try std.fmt.parseInt(u4, it.next().?, 10);
        const month = try std.meta.intToEnum(std.time.epoch.Month, month_int);
        const day = try std.fmt.parseInt(u5, it.next().?, 10);
        const ymd = chrono.date.YearMonthDay.fromNumbers(year, month.numeric(), day);
        return ymd.toDaysSinceUnixEpoch() * std.time.s_per_day;
    }

    fn parseTimestamp(timestamp: []const u8) !i64 {
        // iso8601 lol
        var parts_it = std.mem.splitSequence(u8, timestamp, "T");

        // example `%at=2025-08-01T19:09:44.158Z`
        const date_part = parts_it.next() orelse return error.InvalidTimestamp;

        // then parse date
        return parseDate(date_part);
    }

    pub fn fromFile(file: std.fs.File) !@This() {
        const stat = try file.stat();
        var self = @This(){
            // the problem with relying purely on ctime is that editors may just
            // delete the file then recreate it, instead of editing a file in place
            // (maybe to prevent corruption, idk, i dont care).
            //
            // so always prefer to NOT rely on ctime from fs, instead use timestamps inside the file
            .ctime = @as(i64, @intCast(@divTrunc(stat.ctime, std.time.ns_per_s))),
        };
        var first_bytes_buffer: [512]u8 = undefined;

        const bytes_read = try file.readAll(&first_bytes_buffer);
        const first_bytes = first_bytes_buffer[0..bytes_read];

        // obsidian has the +++-form, but i also have the %at= form myself (for obsidian-maid, my plugin)
        // first attempt to do %at= because mine is more epic

        const AT_MARKER = "%at=";
        const maybe_at_sign_index = std.mem.indexOf(u8, first_bytes, AT_MARKER);
        if (maybe_at_sign_index) |at_sign_index| {
            const end_at_sign = std.mem.indexOfAnyPos(u8, first_bytes, at_sign_index + 1, " \n") orelse return error.InvalidAtSign;
            const timestamp_text = first_bytes[at_sign_index + AT_MARKER.len .. end_at_sign];
            self.ctime = try parseTimestamp(timestamp_text);
            return self;
        }

        // then try to do obsidian's
        const first_plus_sign_idx = std.mem.indexOf(u8, first_bytes, "+++") orelse return self;
        const last_plus_sign_idx = std.mem.indexOfPos(u8, first_bytes, first_plus_sign_idx + 1, "+++") orelse return self;

        logger.debug("idx {d} {d}", .{ first_plus_sign_idx, last_plus_sign_idx });
        const attributes_text = first_bytes[first_plus_sign_idx + 3 .. last_plus_sign_idx];
        var lines = std.mem.splitSequence(u8, attributes_text, "\n");
        logger.debug("attrs text found: '{s}'", .{attributes_text});
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var key_value_iterator = std.mem.splitSequence(u8, line, "=");
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

        const delta = @abs(attrs.ctime - current_time);
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

        const naive_dt = chrono.date.YearMonthDay.fromDaysSinceUnixEpoch(@truncate(@divTrunc(attrs.ctime, std.time.s_per_day)));
        try std.testing.expectEqual(date_from_curtime.year, @as(u16, @intCast(naive_dt.year)));
        try std.testing.expectEqual(month_from_curtime.month.numeric(), naive_dt.month.number());
        try std.testing.expectEqual(month_from_curtime.day_index + 1, naive_dt.day);
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
        const naive_dt = chrono.date.YearMonthDay.fromDaysSinceUnixEpoch(@truncate(@divTrunc(attrs.ctime, std.time.s_per_day)));

        try std.testing.expectEqual(@as(i23, 2023), naive_dt.year);
        try std.testing.expectEqual(@as(u4, 3), naive_dt.month.number());
        try std.testing.expectEqual(@as(u5, 4), naive_dt.day);

        const date_from_attrs = (std.time.epoch.EpochSeconds{
            .secs = @as(u64, @intCast(attrs.ctime)),
        }).getEpochDay().calculateYearDay();

        const month_from_attrs = date_from_attrs.calculateMonthDay();

        try std.testing.expectEqual(@as(i19, 2023), date_from_attrs.year);
        try std.testing.expectEqual(@as(i19, 3), month_from_attrs.month.numeric());
        try std.testing.expectEqual(@as(i19, 4), month_from_attrs.day_index + 1);
    }
};

pub fn relativePathWithoutExtension(self: Self) []const u8 {
    return switch (self.page_type) {
        .asset => unreachable,
        .md => self.filesystem_path[0 .. self.filesystem_path.len - 3],
        .canvas => self.filesystem_path[0 .. self.filesystem_path.len - 7],
    };
}

/// assumes given path is a ".md" file.
pub fn fromPath(ctx: *const Context, fspath: []const u8) !Self {
    const title_offset: usize =
        if (std.mem.endsWith(u8, fspath, ".md")) 3 else if (std.mem.endsWith(u8, fspath, ".canvas")) 7 else return error.InvalidPath;
    const page_type: PageType =
        if (std.mem.endsWith(u8, fspath, ".md")) .md else if (std.mem.endsWith(u8, fspath, ".canvas")) .canvas else unreachable;

    const title_raw = std.fs.path.basename(fspath);
    const title = title_raw[0 .. title_raw.len - title_offset];
    logger.info("create page with title '{s}' @ {s}", .{ title, fspath });

    var file = try std.fs.cwd().openFile(fspath, .{});
    defer file.close();
    const attributes = try PageAttributes.fromFile(file);

    return Self{
        .page_type = page_type,
        .ctx = ctx,
        .filesystem_path = fspath,
        .attributes = attributes,
        .title = title,
    };
}

pub fn fromAssetPath(ctx: *const Context, fspath: []const u8) !Self {
    logger.info("create asset with fspath {s}", .{fspath});

    var file = try std.fs.cwd().openFile(fspath, .{});
    defer file.close();
    const attributes = try PageAttributes.fromFile(file);

    return Self{
        .page_type = .asset,
        .ctx = ctx,
        .filesystem_path = fspath,
        .attributes = attributes,
        .title = "",
    };
}

pub fn deinit(self: Self) void {
    if (self.tags) |tags| {
        for (tags.items) |tag| self.ctx.allocator.free(tag);
        tags.deinit();
    }
    if (self.titles) |titles| {
        for (titles.items) |title| self.ctx.allocator.free(title.text);
        titles.deinit();
    }
    if (self.maybe_first_image) |image| self.ctx.allocator.free(image);
}

pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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

    const raw_output_path = try std.fs.path.resolve(
        allocator,
        &[_][]const u8{ "public", self.relativePath() },
    );
    defer allocator.free(raw_output_path);

    switch (self.page_type) {
        .md => return try util.replaceStrings(
            allocator,
            raw_output_path,
            ".md",
            ".html",
        ),
        .canvas => return try util.replaceStrings(
            allocator,
            raw_output_path,
            ".canvas",
            ".html",
        ),
        .asset => unreachable,
    }
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

    const trimmed_output_path = util.stripLeft(
        output_path,
        "public" ++ std.fs.path.sep_str,
    );

    const trimmed_output_path_2 = try util.replaceStrings(
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
    var i: usize = 0;
    var out_cursor: usize = 0;

    // snip dangerous characters from preview
    while (i < page_preview_text_read_bytes) : (i += 1) {
        //std.debug.print("i {d}, out_cursor {d}, cur {s}\n", .{ i, out_cursor, &[_]u8{buffer[i]} });

        // [[ or ]] become [ or ]
        const current_char = buffer[i];
        var next_char_v: ?u8 = null;
        if (i + 1 < page_preview_text_read_bytes) {
            next_char_v = buffer[i + 1];
        }
        const next_char = next_char_v;
        if (current_char == '[' and next_char == '[') {
            buffer[out_cursor] = '[';
            out_cursor += 1;
            i += 1; // skip next [
        } else if (current_char == ']' and next_char == ']') {
            buffer[out_cursor] = ']';
            out_cursor += 1;
            i += 1; // skip next ]

        } else if (current_char == '\n') {
            buffer[out_cursor] = ' ';
            out_cursor += 1;
        } else {
            buffer[out_cursor] = current_char;
            out_cursor += 1;
        }
    }
    return buffer[0..out_cursor];
}

/// Returns amount of seconds representing the age of the given page (determined via ctime)
pub fn age(self: Self) usize {
    const now = std.time.timestamp();
    return @intCast(now - self.attributes.ctime);
}
