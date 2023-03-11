const std = @import("std");
const libpcre = @import("libpcre");
const root = @import("root");
const ProcessorContext = root.ProcessorContext;
const StringBuffer = root.StringBuffer;
const logger = std.log.scoped(.obsidian2web_processors);
const util = @import("util.zig");

pub const CheckmarkProcessor = struct {
    regex: libpcre.Regex,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.regex.deinit();
    }

    // TODO change from *StringBuffer to `anytype` writer.
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
            try result.writer().print(
                "<a href=\"{s}/{?s}\">{s}</a>",
                .{
                    ctx.build_file.config.webroot,
                    page.web_path,
                    util.unsafeHTML(referenced_title),
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

        try result.writer().print(
            "{s}<a href=\"{s}\">{s}</a>",
            .{ first_character, web_link, util.unsafeHTML(web_link) },
        );
    }
};

pub const TagProcessor = struct {
    regex: libpcre.Regex,

    // why doesnt this work on tags in the beginning of the line
    const REGEX: [:0]const u8 = "#[a-zA-Z0-9-_]+";
    const Self = @This();

    pub fn init() !Self {
        return Self{ .regex = try libpcre.Regex.compile(REGEX, .{}) };
    }

    pub fn deinit(self: Self) void {
        self.regex.deinit();
    }

    pub fn handle(
        self: Self,
        /// Processor context. `pctx.ctx` gives Context
        pctx: anytype,
        file_contents: []const u8,
        captures: []?libpcre.Capture,
    ) !void {
        _ = self;
        var ctx = pctx.ctx;

        const full_match = captures[0].?;
        const raw_text = file_contents[full_match.start..full_match.end];

        // TODO try to do this first_character check in pure regex
        // rather than doing it in code like this lmao

        const first_character = if (full_match.start == 0) ' ' else file_contents[full_match.start - 1];
        if (first_character != ' ' and first_character != '>') {
            return try pctx.out.print("{s}", .{raw_text});
        }

        const tag_text = std.mem.trimLeft(u8, raw_text, " ");
        const tag_name = tag_text[1..];

        // tag index pages will be generated after processor finishes
        var tags = if (pctx.page.tags) |*tags| tags else blk: {
            pctx.page.tags = root.OwnedStringList.init(ctx.allocator);
            break :blk &pctx.page.tags.?;
        };
        try tags.append(try ctx.allocator.dupe(u8, tag_name));

        logger.info("found tag: text='{s}' name='{s}'", .{ tag_text, tag_name });
        try pctx.out.print(
            "{s}<a href=\"{}\">{s}</a>",
            .{
                if (raw_text[0] == ' ') " " else "",
                ctx.webPath("/_/tags/{s}.html", .{tag_name}),
                tag_text,
            },
        );
    }
};
