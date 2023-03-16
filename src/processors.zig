const std = @import("std");
const libpcre = @import("libpcre");
const root = @import("main.zig");
const ProcessorContext = root.ProcessorContext;
const StringBuffer = root.StringBuffer;
const logger = std.log.scoped(.obsidian2web_processors);
const util = @import("util.zig");
const Page = @import("Page.zig");

const DefaultRegexOptions = .{ .Ucp = true, .Utf8 = true };

/// Wrap checkmarks in <code> HTML blocks.
pub const CheckmarkProcessor = struct {
    regex: libpcre.Regex,

    const REGEX = "\\[.\\]";
    const Self = @This();

    pub fn init() !Self {
        return Self{
            .regex = try libpcre.Regex.compile(REGEX, DefaultRegexOptions),
        };
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

test "checkmark processor" {
    // TODO wrap test in more shenanigans for full text match
    const DATASET = .{
        .{ "[ ] among us", "<code>[ ]</code>" },
        .{ "[x] among us", "<code>[x]</code>" },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;

    const build_file = root.BuildFile{
        .allocator = allocator,
        .vault_path = undefined,
        .includes = root.SliceList.init(allocator),
        .config = .{},
    };
    defer build_file.deinit();

    var tmp_dir_realpath_buffer: [std.os.PATH_MAX]u8 = undefined;
    const tmp_dir_realpath = try tmp.dir.realpath(
        ".",
        &tmp_dir_realpath_buffer,
    );

    var vault_dir = try std.fs.cwd().openIterableDir(tmp_dir_realpath, .{});
    defer vault_dir.close();

    var ctx = root.Context.init(allocator, build_file, vault_dir);
    defer ctx.deinit();

    inline for (DATASET) |test_entry| {
        const input = test_entry.@"0";
        const expected_output = test_entry.@"1";
        {
            var file = try tmp.dir.createFile("test.html", .{});
            defer file.close();
            _ = try file.write(input);
        }

        var file_realpath_buffer: [std.os.PATH_MAX]u8 = undefined;
        const file_realpath = try tmp.dir.realpath(
            "test.html",
            &file_realpath_buffer,
        );

        var page = Page{
            .ctx = &ctx,
            .filesystem_path = file_realpath,
            .title = "among",
            .ctime = 0,
        };
        defer page.deinit();

        var processor = try CheckmarkProcessor.init();
        defer processor.deinit();

        var out = root.ByteList.init(allocator);
        defer out.deinit();

        const Holder = root.Holder(CheckmarkProcessor, root.ByteList.Writer);
        var last_capture: ?libpcre.Capture = null;
        const holder = Holder{
            .ctx = &ctx,
            .processor = processor,
            .page = &page,
            .last_capture = &last_capture,
            .out = out.writer(),
        };

        const end_idx = std.mem.indexOf(u8, input, "]").?;

        var caps = [_]?libpcre.Capture{
            libpcre.Capture{ .start = 0, .end = end_idx + 1 },
        };
        try processor.handle(holder, input, &caps);

        try std.testing.expectEqualStrings(expected_output, out.items);
    }
}

pub const CrossPageLinkProcessor = struct {
    const REGEX = "\\[\\[.+\\]\\]";

    regex: libpcre.Regex,

    const Self = @This();

    pub fn init() !Self {
        return Self{
            .regex = try libpcre.Regex.compile(REGEX, DefaultRegexOptions),
        };
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
    const REGEX: [:0]const u8 = "#[\\S\\-_]+";
    const Self = @This();

    pub fn init() !Self {
        return Self{
            .regex = try libpcre.Regex.compile(REGEX, DefaultRegexOptions),
        };
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

    const REGEX: [:0]const u8 = "^(#+) [\\S\\-_: ]+";
    const Self = @This();

    pub fn init() !Self {
        return Self{ .regex = try libpcre.Regex.compile(
            REGEX,
            .{ .Ucp = true, .Utf8 = true, .Multiline = true },
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

        const hashtag_match = captures[1].?;
        const hashtag_length = hashtag_match.end - hashtag_match.start;

        const title = raw_text[hashtag_length + 1 ..];
        const web_title_id = util.WebTitlePrinter{ .title = title };

        const level = hashtag_length;

        var titles = if (pctx.page.titles) |*titles| titles else blk: {
            pctx.page.titles = root.OwnedStringList.init(ctx.allocator);
            break :blk &pctx.page.titles.?;
        };

        try titles.append(try ctx.allocator.dupe(u8, title));
        logger.debug("anchor found: {s}", .{title});
        try pctx.out.print(
            "<h{d} id=\"{s}\">{s} <a href=\"#{s}\">#</a></h{d}>",
            .{ level, web_title_id, title, web_title_id, level },
        );
    }
};
