const std = @import("std");
const libpcre = @import("libpcre");
const root = @import("root");
const ProcessorContext = root.ProcessorContext;
const StringBuffer = root.StringBuffer;
const logger = std.log.scoped(.obsidian2web_processors);
const util = @import("util.zig");

/// Wrap checkmarks in <code> HTML blocks.
pub const CheckmarkProcessor = struct {
    regex: libpcre.Regex,

    const REGEX = "\\[.\\]";
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
        const match = captures[0].?;
        const check = file_contents[match.start..match.end];
        try pctx.out.print("<code>{s}</code>", .{check});
    }
};

pub const CrossPageLinkProcessor = struct {
    const REGEX = "\\[\\[.+\\]\\]";

    regex: libpcre.Regex,

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
        const match = captures[0].?;
        const referenced_title = file_contents[match.start + 2 .. match.end - 2];
        logger.debug(
            "{s} has link to '{s}'",
            .{ pctx.page.title, referenced_title },
        );

        var ctx = pctx.ctx;

        var maybe_page_local_path = ctx.titles.get(referenced_title);
        if (maybe_page_local_path) |page_local_path| {
            var referenced_page = ctx.pages.get(page_local_path).?;
            var web_path = try referenced_page.fetchWebPath(pctx.ctx.allocator);
            defer pctx.ctx.allocator.free(web_path);
            try pctx.out.print(
                "<a href=\"{}\">{s}</a>",
                .{
                    ctx.webPath("/{s}", .{web_path}),
                    util.unsafeHTML(referenced_title),
                },
            );
        } else {
            if (ctx.build_file.config.strict_links) {
                logger.err(
                    "file '{s}' has link to file '{s}' which is not included!",
                    .{ pctx.page, referenced_title },
                );
                return error.InvalidLinksFound;
            } else {
                try pctx.out.print("[[{s}]]", .{referenced_title});
            }
        }
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

        logger.debug("found tag: text='{s}' name='{s}'", .{ tag_text, tag_name });
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

pub const TableOfContentsProcessor = struct {
    regex: libpcre.Regex,

    const REGEX: [:0]const u8 = "^# [a-zA-Z0-9-_]+";
    const Self = @This();

    pub fn init() !Self {
        return Self{ .regex = try libpcre.Regex.compile(
            REGEX,
            .{ .Multiline = true },
        ) };
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
        const title = raw_text[2..];
        const web_title_id = util.WebTitlePrinter{ .title = title };
        const level = 1;

        var titles = if (pctx.page.titles) |*titles| titles else blk: {
            pctx.page.titles = root.OwnedStringList.init(ctx.allocator);
            break :blk &pctx.page.titles.?;
        };

        try titles.append(try ctx.allocator.dupe(u8, title));
        try pctx.out.print(
            "<h{d} id=\"{s}\">{s} <a href=\"#{s}\">#</a></h{d}>",
            .{ level, web_title_id, title, web_title_id, level },
        );
    }
};
