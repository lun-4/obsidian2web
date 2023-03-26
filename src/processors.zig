const std = @import("std");
const libpcre = @import("libpcre");
const testing = @import("testing.zig");
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
    const TEST_DATA = .{
        .{ "[ ] among us", "<code>[ ]</code> among us" },
        .{ "[x] among us", "<code>[x]</code> among us" },
    };

    try testing.runTestWithDataset(TEST_DATA);
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

            logger.debug(
                "{s} has link to web path '{s}'",
                .{ pctx.page.title, web_path },
            );

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

test "cross page link processor" {
    const TEST_DATA = .{
        .{ "awooga1", "[[awooga2]]", "<a href=\"/awooga2.html\">awooga2</a>" },
        .{ "awooga2", "[[awooga1]]", "<a href=\"/awooga1.html\">awooga1</a>" },
    };

    const allocator = std.testing.allocator;

    var test_ctx = testing.TestContext.init();
    defer test_ctx.deinit();

    inline for (TEST_DATA) |test_entry| {
        const page_title = test_entry.@"0";
        const page_input = test_entry.@"1";
        try test_ctx.createPage(page_title, page_input);
    }

    try test_ctx.run();

    inline for (TEST_DATA) |test_entry| {
        const page_title = test_entry.@"0";
        const expected_page_output = test_entry.@"2";

        const page = test_ctx.ctx.pageFromTitle(page_title).?;

        const htmlpath = try page.fetchHtmlPath(std.testing.allocator);
        defer std.testing.allocator.free(htmlpath);

        var output_file = try std.fs.cwd().openFile(htmlpath, .{});
        defer output_file.close();
        var output_text = try output_file.reader().readAllAlloc(std.testing.allocator, 1024);
        defer allocator.free(output_text);

        const maybe_found = std.mem.indexOf(u8, output_text, expected_page_output);
        if (maybe_found == null) {
            logger.err("text '{s}' not found in '{s}'", .{
                expected_page_output,
                htmlpath,
            });
        }
        try std.testing.expect(maybe_found != null);
    }
}

pub const TagProcessor = struct {
    regex: libpcre.Regex,

    // TODO why doesnt this work on tags in the beginning of the line
    const REGEX: [:0]const u8 = "#[\\w\\-_]+";
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
        if (first_character != ' ' and first_character != '\n') {
            logger.warn("ignoring '{s}' firstchar '{s}'", .{ raw_text, &[_]u8{first_character} });
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

test "tag processor" {
    const TEST_DATA = .{
        .{ "#awooga", "<a href=\"/_/tags/awooga.html\">#awooga</a>", "awooga" },
    };

    inline for (TEST_DATA) |test_entry| {
        const input = test_entry.@"0";
        const expected_output = test_entry.@"1";
        const expected_tag_entry = test_entry.@"2";

        var test_ctx = testing.TestContext.init();
        defer test_ctx.deinit();

        try testing.runTestWithSingleEntry(&test_ctx, "test", input, expected_output);

        var pages_it = test_ctx.ctx.pages.iterator();
        var page = pages_it.next().?.value_ptr;
        try std.testing.expectEqualSlices(
            u8,
            expected_tag_entry,
            page.tags.?.items[0],
        );
    }
}

// using this because if we dont do it then the tag processor will process
// comments inside code, and we dont want that.
pub const EscapeHashtagsInCode = struct {
    regex: libpcre.Regex,

    const REGEX = "```([\\w\\W]+)```";
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
        const full_match = captures[0].?;
        const raw_text = file_contents[full_match.start..full_match.end];
        logger.warn("codeblock {s}", .{raw_text});

        try util.fastWriteReplace(pctx.out, raw_text, "#", "&#35;");
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

test "table of contents processor" {
    const TEST_DATA = .{
        .{ "# awooga", "<h1 id=\"awooga\">awooga <a href=\"#awooga\">#</a></h1>", "awooga" },
    };

    inline for (TEST_DATA) |test_entry| {
        const input = test_entry.@"0";
        const expected_output = test_entry.@"1";
        const expected_title_entry = test_entry.@"2";

        var test_ctx = testing.TestContext.init();
        defer test_ctx.deinit();

        try testing.runTestWithSingleEntry(&test_ctx, "test", input, expected_output);

        var pages_it = test_ctx.ctx.pages.iterator();
        var page = pages_it.next().?.value_ptr;
        try std.testing.expectEqualSlices(
            u8,
            expected_title_entry,
            page.titles.?.items[0],
        );
    }
}

/// Wrap checkmarks in <code> HTML blocks.
pub const CodeHighlighterProcessor = struct {
    regex: libpcre.Regex,

    const REGEX = "<code class=\"language-(\\w+)\">([\\S\\n--]+)<\\/code>";
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
        const language_match = captures[1].?;
        const code_text_match = captures[2].?;
        const language = file_contents[language_match.start..language_match.end];
        const code_text = file_contents[code_text_match.start..code_text_match.end];
        logger.debug("found lang={s} {s}", .{ language, code_text });

        var ctx = pctx.ctx;
        if (!ctx.build_file.config.code_highlight) {
            const original_text_match = captures[0].?;
            try pctx.out.writeAll(
                file_contents[original_text_match.start..original_text_match.end],
            );
        }

        // spit code_text to separatte file, feed to pygments

        var file = try std.fs.cwd().createFile("/tmp/o2w_sex2", .{});
        defer file.close();

        try file.writeAll(code_text);

        var argv = root.SliceList.init(ctx.allocator);
        defer argv.deinit();

        try argv.appendSlice(&[_][]const u8{
            "pygmentize",
            "-f",
            "html",
            "-l",
            language,
            "-O",
            "cssclass=pygments",
            "/tmp/o2w_sex2",
        });

        const result = try std.ChildProcess.exec(.{
            .allocator = ctx.allocator,
            .argv = argv.items,
            .max_output_bytes = 100 * 1024,
            .expand_arg0 = .expand,
        });

        defer ctx.allocator.free(result.stdout);
        defer ctx.allocator.free(result.stderr);

        logger.debug(
            "pygments sent stdout {d} bytes, stderr {d} bytes",
            .{ result.stdout.len, result.stderr.len },
        );

        switch (result.term) {
            .Exited => |code| if (code != 0) {
                logger.err("pygmentize returned {} => {s}", .{ code, result.stderr });
                return error.PygmentsFailed;
            },
            else => |code| {
                logger.err("pygmentize returned {} => {s}", .{ code, result.stderr });
                return error.PygmentsFailed;
            },
        }

        var tmpfile = try std.fs.cwd().createFile("/tmp/test", .{ .read = true });
        defer tmpfile.close();

        // TODO why tf pygments emits &amp;quot; insteadd of &quot; lmfao
        // i have to run it twice because of brokeen architecture mess
        try util.fastWriteReplace(tmpfile.writer(), result.stdout, "&amp;", "&");
        try tmpfile.seekTo(0);
        const tmpfile_after_replace = try tmpfile.reader().readAllAlloc(pctx.ctx.allocator, std.math.maxInt(usize));
        defer pctx.ctx.allocator.free(tmpfile_after_replace);
        try util.fastWriteReplace(pctx.out, tmpfile_after_replace, "&amp;", "&");
    }
};

test "code highlighter" {
    std.testing.log_level = .debug;
    const TEST_DATA = .{
        .{
            \\ ```diff
            \\ - b
            \\ + a
            \\ ```
            ,
            "",
        },
    };

    try testing.runTestWithDataset(TEST_DATA);
}
