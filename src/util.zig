const std = @import("std");

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
