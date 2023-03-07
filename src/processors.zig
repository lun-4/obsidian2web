const std = @import("std");
const libpcre = @import("libpcre");
const root = @import("root");
const ProcessorContext = root.ProcessorContext;
const StringBuffer = root.StringBuffer;
const logger = std.log.scoped(.obsidian2web_processors);
const encodeForHTML = root.encodeForHTML;

pub const CheckmarkProcessor = struct {
    regex: libpcre.Regex,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.regex.deinit();
    }

    pub fn handle(self: *Self, ctx: ProcessorContext, result: *StringBuffer) !void {
        _ = self;
        const match = ctx.captures[0].?;
        const check = ctx.file_contents[match.start..match.end];
        try result.writer().print("<code>{s}</code>", .{check});
    }
};

pub const LinkProcessor = struct {
    regex: libpcre.Regex,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.regex.deinit();
    }

    pub fn handle(self: *Self, ctx: ProcessorContext, result: *StringBuffer) !void {
        _ = self;
        const match = ctx.captures[0].?;

        logger.info("match {} {}", .{ match.start, match.end });
        const referenced_title = ctx.file_contents[match.start + 2 .. match.end - 2];
        logger.info("link to '{s}'", .{referenced_title});

        var maybe_page_local_path = ctx.titles.get(referenced_title);
        if (maybe_page_local_path) |page_local_path| {
            var page = ctx.pages.get(page_local_path).?;
            const safe_referenced_title = try encodeForHTML(result.allocator, referenced_title);
            defer result.allocator.free(safe_referenced_title);
            try result.writer().print(
                "<a href=\"{s}/{?s}\">{s}</a>",
                .{
                    ctx.build_file.config.webroot,
                    page.web_path,
                    safe_referenced_title,
                },
            );
        } else {
            if (ctx.build_file.config.strict_links) {
                logger.err(
                    "file '{s}' has link to file '{s}' which is not included!",
                    .{ ctx.current_html_path, referenced_title },
                );
                return error.InvalidLinksFound;
            } else {
                try result.writer().print("[[{s}]]", .{referenced_title});
            }
        }
    }
};

pub const WebLinkProcessor = struct {
    regex: libpcre.Regex,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.regex.deinit();
    }

    pub fn handle(self: *Self, ctx: ProcessorContext, result: *StringBuffer) !void {
        _ = self;
        const full_match = ctx.captures[0].?;
        const first_character = ctx.file_contents[full_match.start .. full_match.start + 1];

        const match = ctx.captures[1].?;

        logger.info("link match {} {}", .{ match.start, match.end });
        const web_link = ctx.file_contents[match.start..match.end];
        logger.info("text web link to '{s}' (first char '{s}')", .{ web_link, first_character });

        const safe_web_link = try encodeForHTML(result.allocator, web_link);
        defer result.allocator.free(safe_web_link);
        try result.writer().print(
            "{s}<a href=\"{s}\">{s}</a>",
            .{ first_character, web_link, safe_web_link },
        );
    }
};
