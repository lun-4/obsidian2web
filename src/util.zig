const std = @import("std");
const libpcre = @import("libpcre");
const main = @import("main.zig");

const logger = std.log.scoped(.obsidian2web_util);

pub fn unsafeHTML(data: []const u8) UnsafeHTMLPrinter {
    return UnsafeHTMLPrinter{ .data = data };
}

pub const UnsafeHTMLPrinter = struct {
    data: []const u8,

    const Self = @This();

    pub fn format(
        value: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try encodeForHTML(writer, value.data);
    }
};

fn encodeForHTML(writer: anytype, in: []const u8) !void {
    for (in) |char| {
        _ = switch (char) {
            '&' => try writer.write("&amp;"),
            '<' => try writer.write("&lt;"),
            '>' => try writer.write("&gt;"),
            '"' => try writer.write("&quot;"),
            '\'' => try writer.write("&#x27;"),
            '\\' => try writer.write("&#92;"),
            else => try writer.writeByte(char),
        };
    }
}

pub const MatchList = std.ArrayList([]?libpcre.Capture);

pub fn captureWithCallback(
    regex: libpcre.Regex,
    full_string: []const u8,
    options: libpcre.Options,
    allocator: std.mem.Allocator,
    comptime ContextT: type,
    ctx: *ContextT,
    comptime callback: fn (
        ctx: *ContextT,
        full_string: []const u8,
        capture: []?libpcre.Capture,
    ) anyerror!void,
) anyerror!void {
    logger.debug("running regex {}", .{regex});
    var offset: usize = 0;

    while (true) {
        logger.debug("regex at offset {d}", .{offset});
        logger.debug("data to match={s}", .{full_string[offset..]});
        var maybe_single_capture = try regex.captures(
            allocator,
            full_string[offset..],
            options,
        );
        if (maybe_single_capture) |single_capture| {
            logger.debug("captured regex at offset {d}", .{offset});
            defer allocator.free(single_capture);

            const first_group = single_capture[0].?;
            for (single_capture, 0..) |maybe_group, idx| {
                if (maybe_group != null) {
                    // convert from relative offsets to absolute file offsets
                    single_capture[idx].?.start += offset;
                    single_capture[idx].?.end += offset;
                }
            }

            try callback(ctx, full_string, single_capture);
            offset += first_group.end;
        } else {
            logger.debug("nothing after offset={d}", .{offset});
            break;
        }
    }
}

pub fn WebPathPrinter(comptime ArgsT: anytype, comptime fmt: []const u8) type {
    return struct {
        ctx: main.Context,
        args: ArgsT,

        const Self = @This();

        pub fn format(
            self: Self,
            comptime outerFmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = outerFmt;
            _ = options;
            try std.fmt.format(writer, "{s}", .{
                self.ctx.build_file.config.webroot,
            });
            try std.fmt.format(writer, fmt, self.args);
        }
    };
}

pub fn fastWriteReplace(
    writer: anytype,
    input: []const u8,
    replace_from: []const u8,
    replace_to: []const u8,
) !void {
    var current_pos: usize = 0;
    var last_capture: ?libpcre.Capture = null;

    while (true) {
        const maybe_found_at = std.mem.indexOfPos(
            u8,
            input,
            current_pos,
            replace_from,
        );

        if (maybe_found_at) |found_at| {
            if (last_capture == null) {
                try writer.writeAll(input[0..found_at]);
            } else {
                try writer.writeAll(input[last_capture.?.end..found_at]);
            }

            try writer.writeAll(replace_to);
            last_capture = .{ .start = found_at, .end = found_at + replace_from.len };
            current_pos = last_capture.?.end;
        } else {
            break;
        }
    }

    if (last_capture == null)
        try writer.writeAll(input)
    else
        try writer.writeAll(input[last_capture.?.end..input.len]);
}

/// Caller owns returned memory.
pub fn replaceStrings(
    allocator: std.mem.Allocator,
    input: []const u8,
    replace_from: []const u8,
    replace_to: []const u8,
) ![]const u8 {
    const buffer_size = std.mem.replacementSize(
        u8,
        input,
        replace_from,
        replace_to,
    );
    var buffer = try allocator.alloc(u8, buffer_size);
    _ = std.mem.replace(
        u8,
        input,
        replace_from,
        replace_to,
        buffer,
    );

    return buffer;
}

pub const lexicographicalCompare = struct {
    pub fn inner(innerCtx: void, a: []const u8, b: []const u8) bool {
        _ = innerCtx;

        var i: usize = 0;
        if (a.len == 0 or b.len == 0) return false;
        while (a[i] == b[i]) : (i += 1) {
            if (i == a.len or i == b.len) return false;
        }

        return a[i] < b[i];
    }
}.inner;

pub const WebTitlePrinter = struct {
    title: []const u8,

    const Self = @This();

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        for (self.title) |character| {
            _ = try writer.writeByte(switch (character) {
                ' ' => '-',
                else => std.ascii.toLower(character),
            });
        }
    }
};

pub fn stripLeft(text: []const u8, strip: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, text, strip));
    return text[strip.len..];
}
